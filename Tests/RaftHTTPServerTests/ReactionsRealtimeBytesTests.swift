import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private let rtOwner = "11111111-1111-4111-8111-111111180001"
private let rtPeer = "11111111-1111-4111-8111-111111180002"
private let rtServer = "33333333-3333-4333-8333-333333180001"
private let rtChannel = "44444444-4444-4444-8444-444444180001"
private let rtThread = "44444444-4444-4444-8444-444444180002"
private let rtSecond = "44444444-4444-4444-8444-444444180003"
private let rtMessage1 = "66666666-6666-4666-8666-666666180001"
private let rtMessage2 = "66666666-6666-4666-8666-666666180002"
private let rtMessage3 = "66666666-6666-4666-8666-666666180003"

private struct RealtimeFixture {
    let accounts: EmailLoginDirectory
    let ownerToken: String
    let agentId: String
    let agentKey: String
    let agentMentionsKey: String
}

private func makeRealtimeFixture() -> RealtimeFixture {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: rtOwner, email: "rt-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: rtOwner)
    accounts.addAccount(id: rtPeer, email: "rt-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: rtPeer)
    accounts.oauth.addOwnedServer(id: rtServer, slug: "rt-bytes", name: "RT Bytes", ownerId: rtOwner)
    accounts.addPostableChannel(serverId: rtServer, channelId: rtChannel, memberId: rtOwner, name: "rt-room")
    accounts.addPostableChannel(serverId: rtServer, channelId: rtSecond, memberId: rtOwner, name: "rt-second")
    accounts.addPostableChannel(
        serverId: rtServer,
        channelId: rtThread,
        memberId: rtOwner,
        kind: "thread",
        parentChannelId: rtChannel,
        parentMessageId: rtMessage1,
        name: "rt-thread"
    )
    accounts.addChannelMessageForTesting(
        id: rtMessage1, channelId: rtChannel, content: "first \"quoted\"", senderId: rtPeer,
        createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    accounts.addChannelMessageForTesting(
        id: rtMessage2, channelId: rtThread, content: "reply", senderId: rtPeer,
        createdAt: Date(timeIntervalSince1970: 1_700_000_200)
    )
    accounts.addChannelMessageForTesting(
        id: rtMessage3, channelId: rtSecond, content: "other", senderId: rtPeer,
        createdAt: Date(timeIntervalSince1970: 1_700_000_300)
    )
    for (channel, message) in [(rtChannel, rtMessage1), (rtThread, rtMessage2), (rtSecond, rtMessage3)] {
        accounts.addInboxFactForTesting(receiverId: rtOwner, serverId: rtServer, channelId: channel, messageId: message)
    }
    accounts.addMessageMention(messageId: rtMessage1, targetType: "user", targetId: rtOwner)
    let agentId = accounts.oauth.createAgent(serverId: rtServer, name: "RTBot", creatorUserId: rtOwner, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: rtChannel, agentId: agentId)
    accounts.oauth.addChannelAgent(channelId: rtThread, agentId: agentId)
    accounts.addMessageMention(messageId: rtMessage1, targetType: "agent", targetId: agentId)
    accounts.addMessageMention(messageId: rtMessage3, targetType: "agent", targetId: agentId)
    return RealtimeFixture(
        accounts: accounts,
        ownerToken: accounts.mintAccessTokenForTesting(userId: rtOwner),
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "rt-read"),
        agentMentionsKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["mentions"], name: "rt-mentions")
    )
}

private func rtHeaders(_ token: String, server: String? = rtServer) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    if let server { headers[HTTPField.Name("X-Server-Id")!] = server }
    return headers
}

private func expectGolden(
    _ label: String,
    _ response: ClientResponse,
    normalizing replacements: [String: String] = [:],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let golden = reactionsRealtimeGolden[label] else {
        Issue.record("no golden for \(label)", sourceLocation: sourceLocation)
        return
    }
    var body = response.body.string ?? ""
    for (needle, replacement) in replacements { body = body.replacingOccurrences(of: needle, with: replacement) }
    #expect(response.status.code == UInt(golden.status), "\(label) status", sourceLocation: sourceLocation)
    #expect(body == golden.body, "\(label) body", sourceLocation: sourceLocation)
    #expect(
        response.headers[HTTPField.Name("Cache-Control")!] == golden.cacheControl,
        "\(label) cache-control",
        sourceLocation: sourceLocation
    )
    #expect(response.headers[HTTPField.Name("Content-Type")!] == "application/json; charset=utf-8", sourceLocation: sourceLocation)
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow", sourceLocation: sourceLocation)
    #expect(
        response.headers[HTTPField.Name("Content-Length")!] == String((response.body.string ?? "").utf8.count),
        sourceLocation: sourceLocation
    )
}

@Test func reactionsRealtimeRoutesAreByteExact() async throws {
    let fixture = makeRealtimeFixture()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = rtHeaders(fixture.ownerToken)
            func post(_ path: String, _ body: String?, headers: HTTPFields? = nil) async throws -> ClientResponse {
                try await client.send(.post, headers: headers ?? owner, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            func get(_ path: String, headers: HTTPFields? = nil) async throws -> ClientResponse {
                try await client.send(.get, headers: headers ?? owner, to: URI(string: path))
            }
            for (label, path) in [
                ("inbox-all", "/api/channels/inbox"),
                ("inbox-unread", "/api/channels/inbox?filter=unread"),
                ("inbox-mentions-asc", "/api/channels/inbox?filter=mentions&sort=asc"),
                ("inbox-limit", "/api/channels/inbox?limit=1&offset=1"),
                ("inbox-dms", "/api/channels/inbox?scope=dms"),
                ("inbox-q", "/api/channels/inbox?q=OTHER"),
                ("inbox-channel", "/api/channels/inbox?channelId=\(rtChannel)"),
            ] {
                expectGolden(label, try await get(path))
            }
            expectGolden("inbox-noserver", try await get("/api/channels/inbox", headers: rtHeaders(fixture.ownerToken, server: nil)))
            var anon = HTTPFields()
            expectGolden("inbox-noauth", try await get("/api/channels/inbox", headers: anon))
            anon[.authorization] = "Bearer nope"
            expectGolden("inbox-badauth", try await get("/api/channels/inbox", headers: anon))

            var plain = HTTPFields()
            expectGolden("done-noauth", try await post("/api/channels/inbox/done", "{}", headers: plain))
            plain[.authorization] = "Bearer nope"
            expectGolden("done-badauth", try await post("/api/channels/inbox/done", "{}", headers: plain))
            expectGolden("done-empty", try await post("/api/channels/inbox/done", "{}"))
            expectGolden("done-nobody", try await post("/api/channels/inbox/done", nil))
            expectGolden("done-array", try await post("/api/channels/inbox/done", "[]"))
            expectGolden("done-numeric-channel", try await post("/api/channels/inbox/done", "{\"channelId\":7}"))
            expectGolden("done-space-memory", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtChannel)\",\"frontierSpace\":\"memory\"}"))
            expectGolden("done-space-number", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtChannel)\",\"frontierSpace\":4}"))
            expectGolden("done-leading-zero", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtChannel)\",\"throughActivitySeq\":\"01\"}"))
            expectGolden("done-null-seq", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtChannel)\",\"throughActivitySeq\":null}"))
            expectGolden("done-number-seq", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtChannel)\",\"throughActivitySeq\":1}"))
            expectGolden("done-int4", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtChannel)\",\"throughActivitySeq\":\"99999999999\"}"))
            expectGolden("done-beyond", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtChannel)\",\"throughActivitySeq\":\"4\"}"))
            expectGolden("done-thread-scope", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtThread)\"}"))
            expectGolden("done-ok-null-space", try await post("/api/channels/inbox/done", "{\"channelId\":\"\(rtChannel)\",\"frontierSpace\":null,\"throughActivitySeq\":\"1\"}"))
            expectGolden("inbox-after-done", try await get("/api/channels/inbox"))
            expectGolden("undone-ok", try await post("/api/channels/inbox/undone", "{\"channelId\":\"\(rtChannel)\"}"))
            expectGolden("undone-empty", try await post("/api/channels/inbox/undone", "{}"))
            expectGolden("undone-noauth", try await post("/api/channels/inbox/undone", "{}", headers: plain))
            expectGolden("undone-thread", try await post("/api/channels/inbox/undone", "{\"channelId\":\"\(rtThread)\"}"))
            expectGolden("undone-nonexistent", try await post("/api/channels/inbox/undone", "{\"channelId\":\"nope\"}"))

            expectGolden("tdone-empty", try await post("/api/channels/threads/done", "{}"))
            expectGolden("tdone-noauth", try await post("/api/channels/threads/done", "{}", headers: plain))
            expectGolden("tdone-channel", try await post("/api/channels/threads/done", "{\"threadChannelId\":\"\(rtChannel)\"}"))
            expectGolden("tdone-unknown", try await post("/api/channels/threads/done", "{\"threadChannelId\":\"nope\"}"))
            expectGolden("tdone-wrongserver", try await post("/api/channels/threads/done", "{\"threadChannelId\":\"\(rtThread)\"}", headers: rtHeaders(fixture.ownerToken, server: "other")))
            expectGolden("tdone-space", try await post("/api/channels/threads/done", "{\"threadChannelId\":\"\(rtThread)\",\"frontierSpace\":\"x\"}"))
            expectGolden("tdone-beyond", try await post("/api/channels/threads/done", "{\"threadChannelId\":\"\(rtThread)\",\"throughActivitySeq\":\"9\"}"))
            expectGolden("tdone-ok", try await post("/api/channels/threads/done", "{\"threadChannelId\":\"\(rtThread)\",\"throughActivitySeq\":\"2\"}"))
            expectGolden("tdone-ok-noserver", try await post("/api/channels/threads/done", "{\"threadChannelId\":\"\(rtThread)\"}", headers: rtHeaders(fixture.ownerToken, server: nil)))
            expectGolden("inbox-after-tdone", try await get("/api/channels/inbox"))
            expectGolden("tundone-ok", try await post("/api/channels/threads/undone", "{\"threadChannelId\":\"\(rtThread)\"}"))
            expectGolden("tundone-empty", try await post("/api/channels/threads/undone", "{}"))
            expectGolden("tundone-channel", try await post("/api/channels/threads/undone", "{\"threadChannelId\":\"\(rtChannel)\"}"))
            expectGolden("tundone-noauth", try await post("/api/channels/threads/undone", "{}", headers: plain))

            expectGolden("readall-noserver", try await post("/api/channels/inbox/read-all", "{}", headers: rtHeaders(fixture.ownerToken, server: nil)))
            expectGolden("readall-wrongserver", try await post("/api/channels/inbox/read-all", "{}", headers: rtHeaders(fixture.ownerToken, server: "other")))
            expectGolden("readall-noauth", try await post("/api/channels/inbox/read-all", "{}", headers: plain))
            expectGolden("readall-1", try await post("/api/channels/inbox/read-all", nil))
            expectGolden("readall-2", try await post("/api/channels/inbox/read-all", "{}"))
            expectGolden("inbox-after-readall", try await get("/api/channels/inbox"))

            func agent(_ key: String?) -> HTTPFields {
                var headers = HTTPFields()
                if let key { headers[.authorization] = "Bearer \(key)" }
                return headers
            }
            expectGolden("mentions-noauth", try await get("/internal/agent-api/mentions", headers: agent(nil)))
            expectGolden("mentions-badkey", try await get("/internal/agent-api/mentions", headers: agent("nope")))
            expectGolden("mentions-readkey", try await get("/internal/agent-api/mentions", headers: agent(fixture.agentKey)))
            expectGolden("mentions-ok", try await get("/internal/agent-api/mentions", headers: agent(fixture.agentMentionsKey)))
            expectGolden("mentions-limit", try await get("/internal/agent-api/mentions?limit=1", headers: agent(fixture.agentMentionsKey)))

            expectGolden("wake-noauth", try await get("/internal/agent-api/wake-hints", headers: agent(nil)))
            expectGolden("wake-badkey", try await get("/internal/agent-api/wake-hints", headers: agent("nope")))
            expectGolden("wake-mentionskey", try await get("/internal/agent-api/wake-hints", headers: agent(fixture.agentMentionsKey)))
            expectGolden("wake-since-bad", try await get("/internal/agent-api/wake-hints?since=abc", headers: agent(fixture.agentKey)))
            expectGolden("wake-since-neg", try await get("/internal/agent-api/wake-hints?since=-1", headers: agent(fixture.agentKey)))
            expectGolden("wake-ok", try await get("/internal/agent-api/wake-hints", headers: agent(fixture.agentKey)))
            expectGolden("wake-latest", try await get("/internal/agent-api/wake-hints?since=latest", headers: agent(fixture.agentKey)))
            expectGolden("wake-since-1", try await get("/internal/agent-api/wake-hints?since=1&limit=1", headers: agent(fixture.agentKey)))
            expectGolden("wake-limit", try await get("/internal/agent-api/wake-hints?limit=1", headers: agent(fixture.agentKey)))
            expectGolden("wake-limit-0", try await get("/internal/agent-api/wake-hints?limit=0", headers: agent(fixture.agentKey)))

            expectGolden("events-noauth", try await get("/internal/agent-api/events", headers: agent(nil)))
            expectGolden("events-badkey", try await get("/internal/agent-api/events", headers: agent("nope")))
            expectGolden("events-1", try await get("/internal/agent-api/events", headers: agent(fixture.agentKey)))
            expectGolden("events-2", try await get("/internal/agent-api/events", headers: agent(fixture.agentKey)))
        }
    }
}

private let rtExternal = "66666666-6666-4666-8666-666666180011"
private let rtSystem = "66666666-6666-4666-8666-666666180012"
private let rtThirdParty = "77777777-7777-4777-8777-777777180001"
private let rtActionMessage = "66666666-6666-4666-8666-666666180013"

/// Seeds an external projection, a system notice, an action reply event and a
/// third-party app event on top of the base fixture; returns the client id so
/// the random record id can be normalized out of the bytes.
private func seedRichEvents(_ fixture: RealtimeFixture) throws -> String {
    let accounts = fixture.accounts
    _ = accounts.messagesAndThreadsStore.appendMessage(StoredHumanMessage(
        id: rtExternal, channelId: rtChannel, senderId: "external-projection-1", content: "hello <result> @owner",
        messageType: "chat", senderType: "external_projection",
        createdAt: Date(timeIntervalSince1970: 1_700_000_400),
        externalMessageId: "1722387723.000100", externalProvider: "slack", externalSenderName: "Alice External"
    ), ledger: .init(oauth: accounts.oauth))
    _ = accounts.messagesAndThreadsStore.appendMessage(StoredHumanMessage(
        id: rtSystem, channelId: rtSecond, senderId: "system", content: "system \"notice\"",
        messageType: "system", senderType: "system",
        createdAt: Date(timeIntervalSince1970: 1_700_000_500)
    ), ledger: .init(oauth: accounts.oauth))
    accounts.managedMCPAndCardsStore.appendPendingActionMessageEvent(
        agentId: fixture.agentId, messageId: rtActionMessage, content: "action \"reply\""
    )
    let created = try accounts.oauth.createClient(
        serverId: rtServer,
        createdByUserId: rtOwner,
        name: "RT App",
        clientId: "rt-app",
        allowedScopes: ["openid", "agent:event:write"]
    )
    accounts.oauth.addThirdPartyAgentEventForTesting(
        id: rtThirdParty,
        serverId: rtServer,
        agentId: fixture.agentId,
        clientRecordId: created.id,
        kind: "event",
        summary: "from app @owner",
        expiresAt: Date().addingTimeInterval(60_000),
        status: "delivering"
    )
    return created.id
}

@Test func reactionsRealtimeRichEventsAreByteExact() async throws {
    let fixture = makeRealtimeFixture()
    let accounts = fixture.accounts
    let clientId = try seedRichEvents(fixture)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.agentKey)"
            for label in ["rich-wake", "rich-events", "rich-wake-after", "rich-events-after"] {
                let path = label.hasPrefix("rich-wake") ? "/internal/agent-api/wake-hints" : "/internal/agent-api/events"
                let response = try await client.send(.get, headers: headers, to: URI(string: path))
                expectGolden(label, response, normalizing: [clientId: "<CLIENT>"])
            }
        }
    }
}

private func markThreadDeleted(_ accounts: EmailLoginDirectory) {
    accounts.serversAndChannelsStore.mutex.withLock { state in
        state.postableChannels[rtThread]?.deletedAt = Date()
    }
}

@Test func reactionsRealtimeDeletedThreadDoneKeepsOwnedReadCursor() async throws {
    let fixture = makeRealtimeFixture()
    let accounts = fixture.accounts
    markThreadDeleted(accounts)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = rtHeaders(fixture.ownerToken)
            let response = try await client.send(.post, headers: owner, to: "/api/channels/threads/done") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(rtThread)\"}")
            }
            expectGolden("deleted-done", response)
            #expect(accounts.oauth.channelReadCursor(channelId: rtThread, userId: rtOwner) == 2)
            let stranger = rtHeaders(accounts.mintAccessTokenForTesting(userId: rtPeer))
            let second = try await client.send(.post, headers: stranger, to: "/api/channels/threads/done") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(rtThread)\"}")
            }
            expectGolden("deleted-done-stranger", second)
        }
    }
}

// MARK: - Atomic sections

/// Collects values from concurrent workers.
private final class Collected<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func add(_ value: Value) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Value] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Concurrent read-alls each bump the read-state version of every scope once:
/// the versions of a scope are exactly 1...N, none lost or repeated.
@Test func concurrentReadAllNeverLosesAReadStateVersion() throws {
    let fixture = makeRealtimeFixture()
    let service = fixture.accounts.reactionsRealtime
    let token = fixture.ownerToken
    let workers = 24
    let versions = Collected<Int>()
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        guard let response = try? service.inboxReadAll(authorization: "Bearer \(token)", serverId: rtServer),
              let scope = response.scopes.first(where: { $0.scopeId == rtChannel })
        else { return }
        versions.add(scope.readStateVersion)
    }
    #expect(versions.all.sorted() == Array(1...workers))
}

/// Concurrent event drains hand each message to exactly one caller.
@Test func concurrentEventDrainsDeliverEachMessageOnce() throws {
    let fixture = makeRealtimeFixture()
    let accounts = fixture.accounts
    for index in 0..<4 {
        accounts.addChannelMessageForTesting(
            id: "66666666-6666-4666-8666-66666618010\(index)",
            channelId: rtChannel,
            content: "burst \(index)",
            senderId: rtPeer,
            createdAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(index))
        )
    }
    let service = accounts.reactionsRealtime
    let delivered = Collected<String>()
    let key = fixture.agentKey
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
        guard let response = try? service.agentThirdPartyEvents(authorization: "Bearer \(key)") else { return }
        for case .message(_, let messageId, _, _, _, _, _, _, _, _, _, _) in response.events {
            delivered.add(messageId)
        }
    }
    let ids = delivered.all
    #expect(ids.count == Set(ids).count)
    // Three base messages plus the four burst messages.
    #expect(Set(ids).count == 7)
}

/// Done and Undone on one scope never leave the three rows half-written.
@Test func concurrentDoneAndUndoneKeepScopeRowsConsistent() throws {
    let fixture = makeRealtimeFixture()
    let accounts = fixture.accounts
    let service = accounts.reactionsRealtime
    let token = "Bearer \(fixture.ownerToken)"
    let body = InboxScopeRequest(channelId: rtChannel, throughActivitySeq: .string("1"))
    DispatchQueue.concurrentPerform(iterations: 64) { index in
        if index.isMultiple(of: 2) {
            _ = try? service.channelInboxDone(authorization: token, serverId: rtServer, body: body)
        } else {
            _ = try? service.inboxUndone(authorization: token, serverId: rtServer, body: body)
        }
    }
    let key = "\(rtOwner)\n\(rtChannel)"
    let state = accounts.messagesAndThreadsStore.state
    let inScopes = state.inboxDoneScopes.contains(key)
    #expect((state.inboxDoneAt[key] != nil) == inScopes)
    #expect((state.inboxDoneFrontiers[key] != nil) == inScopes)
}

/// Queued action replies are taken exactly once by concurrent drains.
@Test func concurrentActionEventTakesReturnEachEventOnce() throws {
    let store = ManagedMCPAndCardsStore()
    for index in 0..<40 {
        store.appendPendingActionMessageEvent(agentId: "agent-a", messageId: "m\(index)", content: "c")
    }
    store.appendPendingActionMessageEvent(agentId: "agent-b", messageId: "other", content: "c")
    let taken = Collected<String>()
    DispatchQueue.concurrentPerform(iterations: 12) { _ in
        for event in store.takePendingActionMessageEvents(agentId: "agent-a") { taken.add(event.messageId) }
    }
    #expect(taken.all.sorted() == (0..<40).map { "m\($0)" }.sorted())
    #expect(store.takePendingActionMessageEvents(agentId: "agent-b").map(\.messageId) == ["other"])
}
