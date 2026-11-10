import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import Testing
import Vapor
import VaporTesting

/// The production AEAD backend has no plaintext presign capability. These are
/// published proxy/null-expiry/bytes assertions, not presign TTL evidence.
@Test(.timeLimit(.minutes(1))) func attachmentProxyURLsHaveNullExpiryAndPreserveDisposition() async throws {
    try await withSingleURLStorage { storage in
        let setup = AttachmentPreviewAccounts(storage: storage.storage)
        try await withApp { app in
            configure(app, services: singleURLServices(setup.accounts, environment: ["CDN_BASE_URL": "https://cdn.example.test"]))
            try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                let videoBytes = Data("synthetic uploaded video bytes".utf8)
                let audioBytes = Data("synthetic uploaded audio bytes".utf8)
                let pdfBytes = Data("%PDF-synthetic uploaded bytes".utf8)
                let video = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "clip.mp4", mime: "video/mp4", bytes: videoBytes)
                let audio = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "voice.mp3", mime: "audio/mpeg", bytes: audioBytes)
                let pdf = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "doc.pdf", mime: "application/pdf", bytes: pdfBytes)
                let cases: [(String, Data, String, String?, Bool)] = [
                    (video, videoBytes, "?disposition=inline", "inline", true),
                    (audio, audioBytes, "?disposition=inline", "inline", true),
                    (video, videoBytes, "?disposition=attachment", "attachment", false),
                    (video, videoBytes, "?disposition=inline&download=1", "attachment", false),
                    (video, videoBytes, "", nil, false),
                    (pdf, pdfBytes, "?disposition=inline", "inline", true),
                ]
                for (id, bytes, query, disposition, inline) in cases {
                    let response = try await client.get(URI(string: "/api/attachments/\(id)/url\(query)"),
                        headers: singleURLHeaders(setup.authorization, setup.serverId))
                    #expect(response.status == .ok)
                    let wire = try await singleURLWire(response)
                    let parsed = try #require(URLComponents(string: wire.url))
                    #expect(parsed.host == "127.0.0.1")
                    #expect(parsed.port == client.port)
                    #expect(parsed.queryItems?.first { $0.name == "disposition" }?.value == disposition)
                    let fetched = try await client.get(URI(string: wire.url))
                    #expect(fetched.status == .ok)
                    let plaintext = try await attachmentPreviewBody(fetched)
                    #expect(plaintext == bytes)
                    #expect(fetched.headers[.contentDisposition]?.hasPrefix(inline ? "inline;" : "attachment;") == true)
                }
            }
        }
    }
}
