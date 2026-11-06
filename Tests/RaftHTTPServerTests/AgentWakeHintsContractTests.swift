import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct WakeFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let channelName: String
    let ownerId: String
    let ownerToken: String
    let agentId: String
    let agentKey: String
    let privateChannelId: String
}

private func makeWakeFixture(_ suffix: String) -> WakeFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001230\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001230\(suffix)"
    accounts.addAccount(id: ownerId, email: "wake-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "wake-\(suffix)", name: "Wake \(suffix)", ownerId: ownerId)
    let channelName = "wake-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let privateChannelId = accounts.oauth.createChannel(serverId: serverId, name: "wake-private-\(suffix)", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private", name: "wake-private-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "WakeBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.oauth.addChannelAgent(channelId: privateChannelId, agentId: agentId)
    return WakeFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        channelName: channelName,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "wake-\(suffix)"),
        privateChannelId: privateChannelId
    )
}

private func wakeHumanHeaders(_ f: WakeFixture) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.ownerToken)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = f.serverId
    return headers
}

private func wakeAgentHeaders(_ f: WakeFixture) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.agentKey)"
    return headers
}

@discardableResult
private func wakePostHuman(
    _ client: any Client,
    _ f: WakeFixture,
    content: String,
    channelId: String? = nil
) async throws -> (id: String, seq: Int) {
    let target = channelId ?? f.channelId
    let response = try await client.send(.post, headers: wakeHumanHeaders(f), to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(target)\",\"content\":\"\(content)\"}")
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let id = try #require(json["id"] as? String)
    return (id, try #require(f.accounts.humanMessageSequence(id: id)))
}

private func wakeGet(
    _ client: any Client,
    _ f: WakeFixture,
    path: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any], raw: String) {
    let response = try await client.get(URI(string: path), headers: wakeAgentHeaders(f))
    let raw = response.body.string ?? ""
    let body = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, body, raw)
}

@Test func wakeHintsAreContentFreeRepeatablePeekAndEventsDrain() async throws {
    let f = makeWakeFixture("901")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await wakePostHuman(client, f, content: "queued wake body must not leak")
            let second = try await wakePostHuman(client, f, content: "second queued body")

            let hints = try await wakeGet(client, f, path: "/internal/agent-api/wake-hints?since=latest")
            #expect(hints.status == .ok)
            #expect(!hints.raw.contains("queued wake body must not leak"))
            let rows = try #require(hints.body["wake_hints"] as? [[String: Any]])
            #expect(rows.compactMap { $0["seq"] as? Int } == [first.seq, second.seq])
            #expect(rows[0]["event_id"] as? String == "wake-hint:\(first.id)")
            #expect(rows[0]["message_id"] as? String == first.id)
            #expect(rows[0]["target"] as? String == "#\(f.channelName)")
            #expect(rows[0]["wake_reason"] as? String == "message_pending")
            #expect(rows[0]["content"] == nil)

            let repeatPeek = try await wakeGet(client, f, path: "/internal/agent-api/wake-hints?since=latest")
            #expect((repeatPeek.body["wake_hints"] as? [[String: Any]] ?? []).compactMap { $0["seq"] as? Int } == [first.seq, second.seq], "the peek repeats until drained")

            let events = try await wakeGet(client, f, path: "/internal/agent-api/events")
            let eventRows = try #require(events.body["events"] as? [[String: Any]])
            #expect(eventRows.compactMap { $0["seq"] as? Int } == [first.seq, second.seq])
            #expect(eventRows.compactMap { $0["content"] as? String } == ["queued wake body must not leak", "second queued body"])

            let afterDrain = try await wakeGet(client, f, path: "/internal/agent-api/wake-hints?since=latest")
            #expect((afterDrain.body["wake_hints"] as? [[String: Any]])?.isEmpty == true)
        }
    }
}

@Test func wakeHintsSupportSeqFilteringAndLimitWithoutConsuming() async throws {
    let f = makeWakeFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var posted: [(id: String, seq: Int)] = []
            for index in 1...3 {
                posted.append(try await wakePostHuman(client, f, content: "queued body \(index)"))
            }
            let filtered = try await wakeGet(client, f, path: "/internal/agent-api/wake-hints?since=\(posted[0].seq)&limit=1")
            #expect(filtered.status == .ok)
            let rows = try #require(filtered.body["wake_hints"] as? [[String: Any]])
            #expect(rows.compactMap { $0["seq"] as? Int } == [posted[1].seq])
            #expect(filtered.body["last_hint_seq"] as? Int == posted[1].seq)
            #expect(filtered.body["has_more"] as? Bool == true)
            #expect(!filtered.raw.contains("queued body"), "hints stay content-free")

            // The peek consumed nothing: the event pull still returns all three.
            let events = try await wakeGet(client, f, path: "/internal/agent-api/events")
            #expect((events.body["events"] as? [[String: Any]] ?? []).compactMap { $0["seq"] as? Int } == posted.map(\.seq))
        }
    }
}

@Test func eventsConsumeEveryReturnedBatchExactlyOnce() async throws {
    let f = makeWakeFixture("903")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let message = try await wakePostHuman(client, f, content: "consume once")
            let first = try await wakeGet(client, f, path: "/internal/agent-api/events")
            #expect((first.body["events"] as? [[String: Any]] ?? []).compactMap { $0["message_id"] as? String } == [message.id])
            let second = try await wakeGet(client, f, path: "/internal/agent-api/events")
            #expect((second.body["events"] as? [[String: Any]])?.isEmpty == true)
            #expect(second.body["has_more"] as? Bool == false)
        }
    }
}

@Test func wakeHintsRejectAnInvalidSinceValue() async throws {
    let f = makeWakeFixture("904")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let invalid = try await wakeGet(client, f, path: "/internal/agent-api/wake-hints?since=not-a-seq")
            #expect(invalid.status == .badRequest)
            #expect(invalid.body["code"] as? String == "since_invalid")
        }
    }
}

@Test func eventsDropMessagesOncePrivateMembershipIsRemoved() async throws {
    let f = makeWakeFixture("905")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            _ = try await wakePostHuman(client, f, content: "private before removal", channelId: f.privateChannelId)
            f.accounts.oauth.removeChannelAgent(channelId: f.privateChannelId, agentId: f.agentId)
            let events = try await wakeGet(client, f, path: "/internal/agent-api/events")
            let rows = try #require(events.body["events"] as? [[String: Any]])
            #expect(!rows.contains { ($0["content"] as? String) == "private before removal" }, "removed private deliveries are dropped")
        }
    }
}
