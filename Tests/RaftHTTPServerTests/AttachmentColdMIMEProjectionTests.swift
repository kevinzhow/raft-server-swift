import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private struct OmittedPartMIMEChip: Decodable {
    let id: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
}

@Test(.timeLimit(.minutes(2))) func multipartWithoutPartContentTypeHasCompleteColdAttachmentMIME() async throws {
    try await withSingleURLStorage { storage in
        let f = AttachmentPreviewAccounts(storage: storage.storage)
        try await withApp { app in
            configure(app, services: singleURLServices(f.accounts))
            try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                let cases: [(filename: String, partMIME: String?, resolved: String, bytes: Data)] = [
                    ("NOTES.MD", nil, "text/markdown", Data("# Retained markdown\n".utf8)),
                    ("payload.unknown", nil, "application/octet-stream", Data("opaque bytes\n".utf8)),
                    ("table.CSV", "application/octet-stream", "text/csv", Data("n\n1\n".utf8)),
                    ("explicit.PDF", "text/plain", "text/plain", Data("Declared plain text.\n".utf8)),
                ]
                var ids: [String] = []
                for item in cases {
                    let boundary = "omitted-part-mime-\(UUID().uuidString)"
                    var multipart = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(f.channelId)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(item.filename)\"\r\n".utf8)
                    if let mime = item.partMIME { multipart.append(Data("Content-Type: \(mime)\r\n".utf8)) }
                    multipart.append(Data("\r\n".utf8))
                    multipart.append(item.bytes)
                    multipart.append(Data("\r\n--\(boundary)--\r\n".utf8))
                    let body = multipart
                    var fields = singleURLHeaders(f.authorization, f.serverId)
                    fields[.contentType] = "multipart/form-data; boundary=\(boundary)"
                    let uploaded = try await client.send(.post, headers: fields, to: "/api/attachments/upload") { $0.body = .init(data: body) }
                    #expect(uploaded.status == .ok)
                    let object = try #require(JSONSerialization.jsonObject(with: try await attachmentPreviewBody(uploaded)) as? [String: Any])
                    let id = try #require((object["attachments"] as? [[String: Any]])?.first?["id"] as? String)
                    ids.append(id)
                    if item.partMIME == nil {
                        let retained = try #require(f.accounts.messagesAndThreadsStore.channelAttachments[id])
                        #expect(retained.mimeType == nil, "This upload really omitted the per-part header; inference belongs to the read projection")
                    }
                }
                var fields = singleURLHeaders(f.authorization, f.serverId)
                fields[.contentType] = "application/json"
                let request = try JSONSerialization.data(withJSONObject: ["channelId": f.channelId, "content": "omitted part MIME", "attachmentIds": ids])
                let sent = try await client.send(.post, headers: fields, to: "/api/messages") { $0.body = .init(data: request) }
                #expect(sent.status == .ok)
                let sentObject = try #require(JSONSerialization.jsonObject(with: try await attachmentPreviewBody(sent)) as? [String: Any])
                let messageId = try #require(sentObject["id"] as? String)
                for path in ["/api/messages/channel/\(f.channelId)",
                             "/api/messages/context/\(messageId)?channelId=\(f.channelId)",
                             "/api/messages/sync?channel_id=\(f.channelId)&since_seq=0",
                             "/api/messages/sync?since_seq=0"] {
                    let response = try await client.get(URI(string: path), headers: fields)
                    #expect(response.status == .ok)
                    let value = try JSONSerialization.jsonObject(with: try await attachmentPreviewBody(response))
                    let rows = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
                    let row = try #require(rows.first { $0["id"] as? String == messageId })
                    let attachments = try #require(row["attachments"] as? [[String: Any]])
                    let encoded = try JSONSerialization.data(withJSONObject: attachments)
                    let chips = try JSONDecoder().decode([OmittedPartMIMEChip].self, from: encoded)
                    #expect(chips.map(\.id) == ids)
                    for (chip, item) in zip(chips, cases) {
                        #expect(chip.filename == item.filename)
                        #expect(chip.filename.lowercased() == item.filename.lowercased())
                        #expect(chip.mimeType.lowercased() == item.resolved)
                        #expect(chip.sizeBytes == item.bytes.count)
                    }
                    #expect(attachments.allSatisfy { $0["storageKey"] == nil && $0["objectKey"] == nil })
                }
                // The actual existing adapter retained sealed objects; reads do
                // not manufacture physical metadata or write MIME back to rows.
                let sealed = storage.state.value.withLock { Array($0.ciphertext.values) }
                #expect(sealed.count == cases.count)
                #expect(sealed.allSatisfy { bytes in cases.allSatisfy { $0.bytes != bytes } })
                #expect(f.accounts.messagesAndThreadsStore.withState { $0.developmentAttachmentBytes.isEmpty })
                for index in [0, 1] {
                    #expect(f.accounts.messagesAndThreadsStore.channelAttachments[ids[index]]?.mimeType == nil)
                }
            }
        }
    }
}
