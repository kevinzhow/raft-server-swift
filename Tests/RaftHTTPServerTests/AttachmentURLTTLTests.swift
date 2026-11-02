import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class PresignRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(id: String, ttl: Int)] = []

    func append(_ id: String, _ ttl: Int) {
        lock.lock()
        storage.append((id, ttl))
        lock.unlock()
    }

    var calls: [(id: String, ttl: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Test func attachmentURLTTLIsFiveMinutesExceptInlineMediaPreview() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001016001"
    let ownerId = "11111111-1111-4111-8111-000001016001"
    let ownerEmail = "attachment-ttl-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "attachment-ttl", name: "Attachment TTL", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "attachment-ttl-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "attachment-ttl-room")
    let video = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "clip.mp4", mimeType: "video/mp4", sizeBytes: 42)
    let audio = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "voice.mp3", mimeType: "audio/mpeg", sizeBytes: 42)
    let pdf = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "doc.pdf", mimeType: "application/pdf", sizeBytes: 42)
    let recorder = PresignRecorder()
    accounts.attachmentPresign = { id, _, ttl in
        recorder.append(id, ttl)
        return "https://storage.example.test/\(id)"
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func ttl(_ id: String, _ query: String) async throws -> Int {
                let before = recorder.calls.count
                let response = try await client.get(URI(string: "/api/attachments/\(id)/url\(query)"), headers: headers)
                #expect(response.status == .ok)
                let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                let expiresAt = try #require(body["expiresAt"] as? String)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let date = try #require(formatter.date(from: expiresAt))
                let delta = date.timeIntervalSinceNow
                let recorded = recorder.calls[before].ttl
                #expect(abs(delta - Double(recorded)) < 30)
                return recorded
            }
            #expect(try await ttl(video, "?disposition=inline") == 3600)
            #expect(try await ttl(audio, "?disposition=inline") == 3600)
            #expect(try await ttl(video, "?disposition=attachment") == 300)
            #expect(try await ttl(video, "?disposition=inline&download=1") == 300)
            #expect(try await ttl(video, "") == 300)
            #expect(try await ttl(pdf, "?disposition=inline") == 300)
        }
    }
}
