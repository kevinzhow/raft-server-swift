import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private final class PresignRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(key: String, ttl: Int, disposition: String, contentType: String)] = []
    var url = "https://objects.example.test/private/object?X-Amz-Signature=do-not-log-this"

    func append(_ key: String, _ ttl: Int, _ disposition: String, _ contentType: String) {
        lock.lock()
        storage.append((key, ttl, disposition, contentType))
        lock.unlock()
    }

    var calls: [(key: String, ttl: Int, disposition: String, contentType: String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct AgentAttachmentFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let visibleId: String
    let privateId: String
    let readKey: String
    let sendKey: String
}

private func makeAgentAttachmentFixture(suffix: String) -> AgentAttachmentFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 140_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 140_000 + number)
    accounts.addAccount(id: ownerId, email: "agent-dl-url-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "dl-url-\(suffix)", name: "Agent Download URL Test", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "DownloadUrlBot-\(suffix)", runtime: "claude")
    let visibleChannel = accounts.oauth.createChannel(serverId: serverId, name: "dl-url-room-\(suffix)", creatorUserId: ownerId)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: visibleChannel, memberId: member, name: "dl-url-room-\(suffix)")
    }
    accounts.oauth.addChannelHuman(channelId: visibleChannel, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: visibleChannel, agentId: agent)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "dl-url-private-\(suffix)", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private", name: "dl-url-private-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)

    let visibleId = "00000000-0000-4000-8000-00000000c\(String(format: "%03d", number % 1000))"
    let privateId = "00000000-0000-4000-8000-00000000d\(String(format: "%03d", number % 1000))"
    accounts.addAgentAttachmentForTesting(
        channelId: visibleChannel,
        id: visibleId,
        uploaderId: ownerId,
        filename: "quarterly report.pdf",
        mimeType: "application/pdf",
        sizeBytes: 11,
        bytes: Data("local bytes".utf8)
    )
    accounts.addAgentAttachmentForTesting(
        channelId: privateChannel,
        id: privateId,
        uploaderId: ownerId,
        filename: "private.txt",
        mimeType: "text/plain",
        sizeBytes: 7,
        bytes: Data("private".utf8)
    )
    let readKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "dl-url-read-\(suffix)")
    let sendKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send"], name: "dl-url-send-\(suffix)")
    return AgentAttachmentFixture(
        accounts: accounts,
        serverId: serverId,
        visibleId: visibleId,
        privateId: privateId,
        readKey: readKey,
        sendKey: sendKey
    )
}

private func agentAttachmentGet(_ client: any Client, key: String, path: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    return try await client.get(URI(string: path), headers: headers)
}

@Test func agentAttachmentDownloadURLPresignsVisibleAttachmentsAndCloaksTheRest() async throws {
    let fixture = makeAgentAttachmentFixture(suffix: "801")
    let recorder = PresignRecorder()
    fixture.accounts.setAgentAttachmentPresignForTesting { key, ttl, disposition, contentType in
        recorder.append(key, ttl, disposition, contentType)
        return recorder.url
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let before = Date()
            let response = try await agentAttachmentGet(
                client,
                key: fixture.readKey,
                path: "/internal/agent-api/attachments/\(fixture.visibleId)/url"
            )
            let after = Date()
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(body["url"] as? String == recorder.url)
            #expect(body["filename"] as? String == "quarterly report.pdf")
            #expect(body["mimeType"] as? String == "application/pdf")
            let expiresAtString = try #require(body["expiresAt"] as? String)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expiresAt = try #require(formatter.date(from: expiresAtString))
            #expect(expiresAt >= before.addingTimeInterval(299))
            #expect(expiresAt <= after.addingTimeInterval(301))
            let call = try #require(recorder.calls.first)
            #expect(recorder.calls.count == 1)
            #expect(call.key == "\(fixture.serverId)/\(fixture.visibleId).pdf")
            #expect(call.ttl == 300)
            #expect(call.disposition == "attachment; filename=\"quarterly report.pdf\"; filename*=UTF-8''quarterly%20report.pdf")
            #expect(call.contentType == "application/pdf")

            for hiddenId in [fixture.privateId, UUID().uuidString.lowercased(), "e66f3b51"] {
                let viaURL = try await agentAttachmentGet(
                    client,
                    key: fixture.readKey,
                    path: "/internal/agent-api/attachments/\(hiddenId)/url"
                )
                let viaDownload = try await agentAttachmentGet(
                    client,
                    key: fixture.readKey,
                    path: "/internal/agent-api/attachments/\(hiddenId)"
                )
                #expect(viaURL.status == .notFound)
                #expect(viaDownload.status == .notFound)
                #expect(viaURL.body.string == viaDownload.body.string)
                let bodyObject = (try? JSONSerialization.jsonObject(with: Data((viaURL.body.string ?? "").utf8))) as? [String: Any]
                #expect(bodyObject?["code"] as? String == "ATTACHMENT_UNAVAILABLE")
            }
            #expect(recorder.calls.count == 1)

            let deniedURL = try await agentAttachmentGet(
                client,
                key: fixture.sendKey,
                path: "/internal/agent-api/attachments/\(fixture.visibleId)/url"
            )
            let deniedDownload = try await agentAttachmentGet(
                client,
                key: fixture.sendKey,
                path: "/internal/agent-api/attachments/\(fixture.visibleId)"
            )
            #expect(deniedURL.status == .forbidden)
            #expect(deniedDownload.status == .forbidden)
            #expect(deniedURL.body.string == deniedDownload.body.string)
            #expect(recorder.calls.count == 1)
        }
    }
}

@Test func agentAttachmentDownloadURLWithoutPresignAnswers409WhileDownloadStreams() async throws {
    let fixture = makeAgentAttachmentFixture(suffix: "802")
    fixture.accounts.setAgentAttachmentPresignForTesting(nil)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let response = try await agentAttachmentGet(
                client,
                key: fixture.readKey,
                path: "/internal/agent-api/attachments/\(fixture.visibleId)/url"
            )
            #expect(response.status == .conflict)
            let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
            #expect(body?["error"] as? String == "This Server's file storage cannot mint download URLs.")
            #expect(body?["code"] as? String == "download_url_unavailable")

            let hidden = try await agentAttachmentGet(
                client,
                key: fixture.readKey,
                path: "/internal/agent-api/attachments/\(fixture.privateId)/url"
            )
            #expect(hidden.status == .notFound)

            let streamed = try await agentAttachmentGet(
                client,
                key: fixture.readKey,
                path: "/internal/agent-api/attachments/\(fixture.visibleId)"
            )
            #expect(streamed.status == .ok)
            #expect(streamed.body.string == "local bytes")
        }
    }
}
