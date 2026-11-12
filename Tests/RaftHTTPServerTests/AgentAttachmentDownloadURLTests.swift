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
    let ownerKey: String
}

private func makeAgentAttachmentFixture(
    suffix: String, bytes: Data = Data("local bytes".utf8),
    filename: String = "quarterly report.pdf", mimeType: String = "application/pdf"
) -> AgentAttachmentFixture {
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
        filename: filename,
        mimeType: mimeType,
        sizeBytes: bytes.count,
        bytes: bytes
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
        sendKey: sendKey,
        ownerKey: accounts.mintAccessTokenForTesting(userId: ownerId)
    )
}

@Test(arguments: [false, true])
func agentAttachmentDownloadPreservesEveryByteAndContentLength(empty: Bool) async throws {
    // Invalid UTF-8, NULs and every high byte must survive HTTP serialization.
    let bytes = empty ? Data() : Data((0..<4096).map { UInt8($0 % 256) })
    let fixture = makeAgentAttachmentFixture(
        suffix: empty ? "804" : "803", bytes: bytes,
        filename: "binary payload.bin", mimeType: "application/octet-stream")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let response = try await agentAttachmentGet(
                client, key: fixture.readKey,
                path: "/internal/agent-api/attachments/\(fixture.visibleId)")
            #expect(response.status == .ok)
            #expect(response.body.data == bytes)
            #expect(response.headers[.contentLength] == String(bytes.count))
            #expect(response.headers[.contentType] == "application/octet-stream")
            #expect(response.headers[.cacheControl] == "private, immutable, max-age=31536000")
            #expect(response.headers[.contentDisposition] ==
                "attachment; filename=\"binary payload.bin\"; filename*=UTF-8''binary%20payload.bin")
        }
    }
}

/// Agent streaming uses attachments.ts presentation helpers without accepting
/// the human endpoint's Range selection (internalAgentApi.ts:4890-4917).
@Test(arguments: ["uppercase", "existing-charset", "json", "unicode-image", "empty-mime"])
func agentAttachmentPresentationMatchesPinnedMimeAndFilenameRules(profile: String) async throws {
    let filename = profile == "unicode-image" ? "café \"review\".png" : "legacy.txt"
    let mime: String
    let expectedType: String
    switch profile {
    case "uppercase": mime = "TEXT/PLAIN"; expectedType = "TEXT/PLAIN; charset=utf-8"
    case "existing-charset": mime = "text/plain; CHARSET=ISO-8859-1"; expectedType = mime
    case "json": mime = "application/problem+json"; expectedType = "application/problem+json; charset=utf-8"
    case "unicode-image": mime = "image/png"; expectedType = mime
    default: mime = ""; expectedType = "application/octet-stream"
    }
    let bytes = Data([0, 255, 1, 128, 13])
    let f = makeAgentAttachmentFixture(suffix: "805", bytes: bytes, filename: filename, mimeType: mime)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.readKey)"
            headers[.range] = "bytes=1-2"
            let response = try await client.get(URI(string: "/internal/agent-api/attachments/\(f.visibleId)"), headers: headers)
            #expect(response.status == .ok)
            #expect(response.body.data == bytes)
            #expect(response.headers[.contentLength] == String(bytes.count))
            #expect(response.headers[.contentRange] == nil)
            #expect(response.headers[.contentType] == expectedType)
            let expectedDisposition = profile == "unicode-image"
                ? "inline; filename=\"caf_ _review_.png\"; filename*=UTF-8''caf%C3%A9%20%22review%22.png"
                : "attachment; filename=\"legacy.txt\"; filename*=UTF-8''legacy.txt"
            #expect(response.headers[.contentDisposition] == expectedDisposition)
        }
    }
}

/// attachments.ts:492-499 repairs a stored filename once. Repair is not
/// idempotent for doubly encoded input, so both published transports must agree.
@Test func attachmentPresentationNormalizesStoredFilenameExactlyOnceForHumanAndAgent() async throws {
    let filename = "\u{00C3}\u{0083}\u{00C2}\u{00A9}.txt"
    let bytes = Data("one filename repair".utf8)
    let f = makeAgentAttachmentFixture(suffix: "806", bytes: bytes, filename: filename, mimeType: "text/plain")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for (path, key) in [("/api/attachments/\(f.visibleId)", f.ownerKey),
                                ("/internal/agent-api/attachments/\(f.visibleId)", f.readKey)] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[HTTPField.Name("X-Server-Id")!] = f.serverId
                let response = try await client.get(URI(string: path), headers: headers)
                #expect(response.status == .ok)
                #expect(response.body.data == bytes)
                #expect(response.headers[.contentDisposition] ==
                    "attachment; filename=\"__.txt\"; filename*=UTF-8''%C3%83%C2%A9.txt")
            }
        }
    }
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
