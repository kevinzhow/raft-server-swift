import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct FreshnessFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001113001"
    let ownerId = "11111111-1111-4111-8111-000001113001"
    var agentId = ""
    var channelId = ""
    var channelName = "freshness-room"
    var key = ""

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "freshness-owner@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "freshness", name: "Freshness", ownerId: ownerId)
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "FreshnessBot", creatorUserId: ownerId, runtime: "claude")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId, type: "channel")
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: channelName, humanIds: [ownerId], agentIds: [agentId])
        key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "freshness")
    }

    func human(_ content: String) -> (id: String, seq: Int) {
        let id = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: content)
        return (id, accounts.messageSeqForTesting(messageId: id) ?? 0)
    }

    func selfMessage(_ content: String) -> (id: String, seq: Int) {
        let id = accounts.addHumanMessageForTesting(channelId: channelId, senderId: agentId, content: content, senderType: "agent")
        return (id, accounts.messageSeqForTesting(messageId: id) ?? 0)
    }
}

private func freshnessSend(_ client: any Client, _ key: String, _ target: String, _ content: String, seen: Int) async throws -> [String: Any] {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    let data = try JSONSerialization.data(withJSONObject: ["target": target, "content": content, "seenUpToSeq": seen])
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
        request.body = .init(data: data)
    }
    return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func senderOnlyNewerDoesNotHoldButPeerRowsDo() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
    _ = fixture.selfMessage("previous agent progress")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let ownOnly = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "follow-up after own progress", seen: baseline.seq)
            #expect(ownOnly["state"] as? String == "sent")

            let freshUnread = fixture.human("peer update")
            _ = fixture.selfMessage("own later progress")
            let held = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "stale follow-up", seen: baseline.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 1)
            let heldRows = held["heldMessages"] as? [[String: Any]] ?? []
            #expect(heldRows.count == 1)
            #expect(heldRows.first?["id"] as? String == freshUnread.id)
            #expect(held["seenUpToSeq"] as? Int == freshUnread.seq)
        }
    }
}

@Test func readCursorIsNotFreshnessProofAndBoundedHoldDoesNotReadThrough() async throws {
    var fixture = FreshnessFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let baseline = fixture.human("baseline")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseline.seq)
    let freshUnread = fixture.human("fresh unread before read cursor advance")
    accounts.markAgentLegacyReadForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: freshUnread.seq)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, fixture.key, "#\(fixture.channelName)", "stale model state", seen: baseline.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 1)
            #expect((held["heldMessages"] as? [[String: Any]])?.first?["id"] as? String == freshUnread.id)
            #expect(held["seenUpToSeq"] as? Int == freshUnread.seq)
        }
    }

    var bounded = FreshnessFixture()
    bounded.seed()
    let boundedAccounts = bounded.accounts
    let base = bounded.human("baseline")
    boundedAccounts.markAgentLegacyReadForTesting(agentId: bounded.agentId, channelId: bounded.channelId, seq: base.seq)
    var latestSeq = 0
    for index in 1...5 {
        latestSeq = bounded.human("fresh unread \(index)").seq
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: boundedAccounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, bounded.key, "#\(bounded.channelName)", "many unread", seen: base.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 5)
            #expect(held["shownMessageCount"] as? Int == 3)
            #expect(held["omittedMessageCount"] as? Int == 2)
            #expect((held["heldMessages"] as? [[String: Any]])?.count == 3)
            #expect(held["seenUpToSeq"] as? Int == latestSeq)
            #expect(boundedAccounts.agentReadCursorForTesting(agentId: bounded.agentId, channelId: bounded.channelId) == base.seq)
        }
    }

    var allShown = FreshnessFixture()
    allShown.seed()
    let shownAccounts = allShown.accounts
    let shownBase = allShown.human("baseline")
    shownAccounts.markAgentLegacyReadForTesting(agentId: allShown.agentId, channelId: allShown.channelId, seq: shownBase.seq)
    let fresh = allShown.human("one fresh unread")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: shownAccounts))
        try await app.testing { client in
            let held = try await freshnessSend(client, allShown.key, "#\(allShown.channelName)", "one unread", seen: shownBase.seq)
            #expect(held["state"] as? String == "held")
            #expect(held["omittedMessageCount"] as? Int == 0)
            #expect(shownAccounts.agentReadCursorForTesting(agentId: allShown.agentId, channelId: allShown.channelId) == fresh.seq)
        }
    }
}
