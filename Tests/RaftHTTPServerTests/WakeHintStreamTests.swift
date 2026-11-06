import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct WakeStreamFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let ownerId: String
    let ownerToken: String
    let agentId: String
    let agentKey: String
    let machineKey: String
}

private func wakeUTF8Chunk(_ span: Span<UInt8>) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(span.count)
    for index in span.indices {
        bytes.append(span[index])
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func makeWakeStreamFixture() -> WakeStreamFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111635"
    let serverId = "33333333-3333-4333-8333-333333333675"
    accounts.addAccount(id: ownerId, email: "wake-stream@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "wake-stream", name: "Wake Stream", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "wake-stream-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: "wake-stream-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "StreamBot", creatorUserId: ownerId)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    let machine = accounts.registerMachineWithKeyForTesting(serverId: serverId, userId: ownerId, name: "wake-stream-machine")
    return WakeStreamFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "wake-stream-key"),
        machineKey: machine.apiKey
    )
}

private func wakeStreamPost(
    _ client: any Client,
    _ f: WakeStreamFixture,
    content: String
) async throws -> (id: String, seq: Int) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.ownerToken)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = f.serverId
    let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(f.channelId)\",\"content\":\"\(content)\"}")
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let id = try #require(json["id"] as? String)
    return (id, try #require(f.accounts.humanMessageSequence(id: id)))
}

private func wakeStreamGet(
    _ client: any Client,
    _ f: WakeStreamFixture,
    lastEventId: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.agentKey)"
    headers[.accept] = "text/event-stream"
    if let lastEventId { headers[HTTPField.Name("Last-Event-ID")!] = lastEventId }
    let response = try await client.get("/internal/agent-api/wake-hints", headers: headers)
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

private final class WakeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    func wait(until predicate: (String) -> Bool, timeoutMs: Int) async -> String {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            let snapshot = value
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return value
    }
}

@Test func wakeHintStreamReplaysPendingHintsWithoutDrainingOrLeakingBodies() async throws {
    let f = makeWakeStreamFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let posted = try await wakeStreamPost(client, f, content: "SECRET-BODY-do-not-stream")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.agentKey)"
            headers[.accept] = "text/event-stream"
            let stream = try await client.send(.get, headers: headers, to: "/internal/agent-api/wake-hints/stream")
            #expect(stream.status == .ok)
            #expect((stream.headers[.contentType] ?? "").contains("text/event-stream"))
            let buffer = WakeBuffer()
            let reader = Task {
                try await stream.body.withStreamingBytes { span in
                    buffer.append(wakeUTF8Chunk(span))
                }
            }
            let text = await buffer.wait(until: { $0.contains("event: wake-hint") }, timeoutMs: 3_000)
            #expect(text.contains("event: wake-hint"))
            #expect(text.contains("id: \(posted.seq)"), "the hint replay names its server seq")
            #expect(text.contains(posted.id), "the frame names the message id")
            #expect(!text.contains("SECRET-BODY-do-not-stream"), "the wake hint never carries message content")

            // Peeking again still sees the hint: the stream is not a drain.
            let peek = try await wakeStreamGet(client, f)
            #expect(peek.status == .ok)
            let hints = (peek.body["wake_hints"] as? [[String: Any]]) ?? []
            #expect(hints.contains { ($0["seq"] as? NSNumber)?.intValue == posted.seq })
            reader.cancel()
        }
    }
}

@Test func wakeHintStreamSkipsAlreadySeenHintsFromLastEventId() async throws {
    let f = makeWakeStreamFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await wakeStreamPost(client, f, content: "first hint")
            let second = try await wakeStreamPost(client, f, content: "second hint")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.agentKey)"
            headers[.accept] = "text/event-stream"
            headers[HTTPField.Name("Last-Event-ID")!] = "\(first.seq)"
            let stream = try await client.send(.get, headers: headers, to: "/internal/agent-api/wake-hints/stream")
            #expect(stream.status == .ok)
            let buffer = WakeBuffer()
            let reader = Task {
                try await stream.body.withStreamingBytes { span in
                    buffer.append(wakeUTF8Chunk(span))
                }
            }
            let text = await buffer.wait(until: { $0.contains("id: \(second.seq)") }, timeoutMs: 3_000)
            #expect(text.contains("id: \(second.seq)"), "newer hints are replayed")
            #expect(!text.contains("id: \(first.seq)"), "already-seen hints are not replayed")
            reader.cancel()
        }
    }
}

@Test func wakeHintStreamPushesDurablePendingOnTheNextTick() async throws {
    let f = makeWakeStreamFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.agentKey)"
            headers[.accept] = "text/event-stream"
            let stream = try await client.send(.get, headers: headers, to: "/internal/agent-api/wake-hints/stream")
            let buffer = WakeBuffer()
            let reader = Task {
                try await stream.body.withStreamingBytes { span in
                    buffer.append(wakeUTF8Chunk(span))
                }
            }
            _ = await buffer.wait(until: { $0.contains(": connected") }, timeoutMs: 2_000)
            // No emitter announces this wake: the durable pending hint has to be
            // discovered by the stream's own tick.
            let posted = try await wakeStreamPost(client, f, content: "late wake")
            let text = await buffer.wait(until: { $0.contains("id: \(posted.seq)") }, timeoutMs: 4_000)
            #expect(text.contains("id: \(posted.seq)"), "the tick discovered the durable pending hint")
            reader.cancel()
        }
    }
}

@Test func wakeHintStreamRejectsBadCredentialsAndCursorsBeforeStreaming() async throws {
    let f = makeWakeStreamFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            func open(_ headers: HTTPFields) async throws -> ClientResponse {
                try await client.send(.get, headers: headers, to: "/internal/agent-api/wake-hints/stream")
            }
            let unauthenticated = try await open(HTTPFields())
            #expect(unauthenticated.status == .unauthorized)
            #expect((unauthenticated.headers[.contentType] ?? "").contains("text/event-stream") == false)
            let unauthenticatedBody = (try? JSONSerialization.jsonObject(with: Data((unauthenticated.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(unauthenticatedBody["code"] as? String == "auth_required")

            var machineHeaders = HTTPFields()
            machineHeaders[.authorization] = "Bearer \(f.machineKey)"
            let machine = try await open(machineHeaders)
            #expect(machine.status == .unauthorized)
            #expect((machine.body.string ?? "").contains("text/event-stream") == false)

            var badCursor = HTTPFields()
            badCursor[.authorization] = "Bearer \(f.agentKey)"
            badCursor[HTTPField.Name("Last-Event-ID")!] = "not-a-seq"
            let cursor = try await open(badCursor)
            #expect(cursor.status == .badRequest)
            let cursorBody = (try? JSONSerialization.jsonObject(with: Data((cursor.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(cursorBody["code"] as? String == "since_invalid")
        }
    }
}
