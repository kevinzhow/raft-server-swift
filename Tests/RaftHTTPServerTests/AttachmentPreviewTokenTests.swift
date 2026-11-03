import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func htmlPreviewTokenIsScopedExpiringAndFramed() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001017001"
    let ownerId = "11111111-1111-4111-8111-000001017001"
    let ownerEmail = "preview-token-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "preview-token", name: "Preview Token", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "preview-token-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "preview-token-room")
    let first = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "first.html", mimeType: "text/html", sizeBytes: 64)
    let second = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "second.html", mimeType: "text/html", sizeBytes: 64)
    let html = "<!doctype html><html><body>ok</body></html>"
    accounts.attachmentPreviewBody = { id in id == first ? html : nil }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func mint(_ id: String) async throws -> (url: String, previewToken: String) {
                let response = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: headers)
                #expect(response.status == .ok)
                let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                let url = try #require(body["url"] as? String)
                let components = URLComponents(string: url)
                let previewToken = try #require(components?.queryItems?.first { $0.name == "previewToken" }?.value)
                #expect(components?.queryItems?.first { $0.name == "token" }?.value == nil)
                #expect(components?.queryItems?.first { $0.name == "serverId" }?.value == serverId)
                let expiresAt = try #require(body["expiresAt"] as? String)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                #expect((formatter.date(from: expiresAt) ?? .distantPast) > Date())
                return (url, previewToken)
            }

            let firstMint = try await mint(first)
            let preview = try await client.get(URI(string: firstMint.url))
            #expect(preview.status == .ok)
            #expect(preview.headers[HTTPField.Name("Content-Type")!] == "text/html; charset=utf-8")
            #expect(preview.headers[HTTPField.Name("X-Frame-Options")!] == nil)
            #expect((preview.headers[HTTPField.Name("Content-Security-Policy")!] ?? "").contains("frame-ancestors 'self'"))
            #expect(preview.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            #expect(try await collectedBody(preview) == html + AttachmentPreviewBridge.script)

            let crossAttachment = try await client.get(
                URI(string: "/api/attachments/\(second)/html-preview?serverId=\(serverId)&previewToken=\(firstMint.previewToken)")
            )
            #expect(crossAttachment.status == .unauthorized)

            for path in [
                "/api/attachments/\(first)?previewToken=\(firstMint.previewToken)",
                "/api/attachments/\(first)/url?previewToken=\(firstMint.previewToken)",
                "/api/attachments/\(first)/html-preview-url?previewToken=\(firstMint.previewToken)",
            ] {
                #expect(try await client.get(URI(string: path)).status == .unauthorized)
            }

            let expired = accounts.mintAttachmentPreviewToken(attachmentId: first, serverId: serverId, actorId: ownerId, expiresIn: -1)
            let expiredResponse = try await client.get(
                URI(string: "/api/attachments/\(first)/html-preview?serverId=\(serverId)&previewToken=\(expired)")
            )
            #expect(expiredResponse.status == .unauthorized)
            let wrongAudience = accounts.mintAttachmentPreviewToken(attachmentId: first, serverId: serverId, actorId: ownerId, audience: "attachment-download")
            #expect(try await client.get(URI(string: "/api/attachments/\(first)/html-preview?serverId=\(serverId)&previewToken=\(wrongAudience)")).status == .unauthorized)
            let wrongType = accounts.mintAttachmentPreviewToken(attachmentId: first, serverId: serverId, actorId: ownerId, type: "access")
            #expect(try await client.get(URI(string: "/api/attachments/\(first)/html-preview?serverId=\(serverId)&previewToken=\(wrongType)")).status == .unauthorized)

            let leaked = try await client.get(
                URI(string: "/api/attachments/\(first)/html-preview?serverId=\(serverId)&token=\(token)")
            )
            #expect(leaked.status == .forbidden)
        }
    }
}

private func collectedBody(_ response: ClientResponse) async throws -> String {
    final class Box: @unchecked Sendable {
        var text = ""
        let lock = NSLock()
    }
    let box = Box()
    try await response.body.withStreamingBytes { span in
        var bytes: [UInt8] = []
        bytes.reserveCapacity(span.count)
        for index in span.indices { bytes.append(span[index]) }
        box.lock.withLock { box.text += String(decoding: bytes, as: UTF8.self) }
    }
    return box.lock.withLock { box.text }
}
