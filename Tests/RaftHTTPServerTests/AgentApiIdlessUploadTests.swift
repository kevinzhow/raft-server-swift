import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func agentIdlessMultipart(channelId: String, filename: String, content: String, mimeType: String) -> (contentType: String, body: Data) {
    let boundary = "----raft-agent-api-upload"
    var data = Data()
    func append(_ string: String) { data.append(Data(string.utf8)) }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"channelId\"\r\n\r\n")
    append("\(channelId)\r\n")
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"mimeType\"\r\n\r\n")
    append("\(mimeType)\r\n")
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
    append("Content-Type: \(mimeType)\r\n\r\n")
    append(content)
    append("\r\n")
    append("--\(boundary)--\r\n")
    return ("multipart/form-data; boundary=\(boundary)", data)
}

@Test func agentApiUploadUsesTheIdlessRouteAndBoundIdentity() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001022001"
    let ownerId = "11111111-1111-4111-8111-000001022001"
    let agentEmail = "idless-upload-owner@slock.test"
    accounts.addAccount(id: ownerId, email: agentEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "idless-upload", name: "Idless Upload", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "idless-upload-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "idless-upload-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "idless-upload-agent", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send"], name: "idless")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let multipart = agentIdlessMultipart(channelId: channel, filename: "native.txt", content: "native agent upload", mimeType: "text/plain")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = multipart.contentType
            let upload = try await client.send(.post, headers: headers, to: "/internal/agent-api/upload") { request in
                request.body = .init(data: multipart.body)
            }
            #expect(upload.status == .ok)
            let body = (try JSONSerialization.jsonObject(with: Data((upload.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let id = try #require(body["id"] as? String)
            #expect(body["filename"] as? String == "native.txt")
            #expect(body["mimeType"] as? String == "text/plain")
            #expect(body["sizeBytes"] as? Int == "native agent upload".utf8.count)
            #expect(body["thumbnailUrl"] is NSNull)

            var downloadHeaders = HTTPFields()
            downloadHeaders[.authorization] = "Bearer \(key)"
            let download = try await client.get(URI(string: "/internal/agent-api/attachments/\(id)"), headers: downloadHeaders)
            #expect(download.status == .ok)
            #expect(download.body.string == "native agent upload")
            #expect(download.headers[HTTPField.Name("Content-Type")!] == "text/plain")
            #expect(download.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
        }
    }
}

@Test func agentApiAttachmentDownloadServesUnicodePDFFilenames() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001022002"
    let ownerId = "11111111-1111-4111-8111-000001022002"
    accounts.addAccount(id: ownerId, email: "unicode-upload-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "unicode-upload", name: "Unicode Upload", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "unicode-upload-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "unicode-upload-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "unicode-upload-agent", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send"], name: "unicode")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let filename = "résumé-资料.pdf"
            let multipart = agentIdlessMultipart(channelId: channel, filename: filename, content: "%PDF-1.4 unicode", mimeType: "application/pdf")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = multipart.contentType
            let upload = try await client.send(.post, headers: headers, to: "/internal/agent-api/upload") { request in
                request.body = .init(data: multipart.body)
            }
            #expect(upload.status == .ok)
            let uploaded = (try JSONSerialization.jsonObject(with: Data((upload.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let id = try #require(uploaded["id"] as? String)
            #expect(uploaded["filename"] as? String == filename)

            var downloadHeaders = HTTPFields()
            downloadHeaders[.authorization] = "Bearer \(key)"
            let download = try await client.get(URI(string: "/internal/agent-api/attachments/\(id)"), headers: downloadHeaders)
            #expect(download.status == .ok)
            let disposition = download.headers[HTTPField.Name("Content-Disposition")!] ?? ""
            #expect(disposition.contains("filename*=UTF-8''"), Comment(rawValue: disposition))
            #expect(disposition.contains("r%C3%A9sum%C3%A9"))
        }
    }
}
