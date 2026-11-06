import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct UnreadFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001100001"
    let ownerId = "11111111-1111-4111-8111-000001100001"
    var agentId = ""
    var channelId = ""
    var apiKey = ""

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "ax-unread-owner@unread.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "ax-unread", name: "Unread Test", ownerId: ownerId)
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "UnreadBot", creatorUserId: ownerId, runtime: "claude")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "ax-unread", creatorUserId: ownerId, type: "channel")
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "ax-unread", humanIds: [ownerId], agentIds: [agentId])
        apiKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "ax-unread")
    }

    @discardableResult
    func post(_ content: String, own: Bool = false, fresh: Bool = false) -> String {
        let id = accounts.addHumanMessageForTesting(
            channelId: channelId,
            senderId: own ? agentId : ownerId,
            content: content,
            senderType: own ? "agent" : "user"
        )
        _ = fresh
        return id
    }

    func read(_ client: any Client, _ query: String) async throws -> (status: HTTPResponse.Status, body: [String: Any], contents: [String]) {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(apiKey)"
        let response = try await client.get(URI(string: "/internal/agent-api/history?channel=%23ax-unread&\(query)"), headers: headers)
        let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
        let contents = (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
        return (response.status, body, contents)
    }
}

@Test func unreadReadsFromPositionMovesItAndRefusesAnchors() async throws {
    var fixture = UnreadFixture()
    fixture.seed()
    let accounts = fixture.accounts
    accounts.setReadPositionSettleForTesting(-10_000)
    fixture.post("one")
    let two = fixture.post("two")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let first = try await fixture.read(client, "unread=true")
            #expect(first.status == .ok)
            #expect(first.contents == ["one", "two"])
            #expect(first.body["unread_after_seq"] as? Int == 0)
            #expect(first.body["model_seen_up_to_seq"] as? Int == accounts.messageSeqForTesting(messageId: two))

            let empty = try await fixture.read(client, "unread=true")
            #expect(empty.contents.isEmpty)
            #expect(empty.body["unread_after_seq"] as? Int == accounts.messageSeqForTesting(messageId: two))

            let three = fixture.post("three")
            fixture.post("four")
            let afterOnly = try await fixture.read(client, "after=\(accounts.messageSeqForTesting(messageId: three) ?? 0)")
            #expect(afterOnly.contents == ["four"])
            let second = try await fixture.read(client, "unread=true")
            #expect(second.contents == ["three", "four"])
            #expect(second.body["unread_after_seq"] as? Int == accounts.messageSeqForTesting(messageId: two))
            let drained = try await fixture.read(client, "unread=true")
            #expect(drained.contents.isEmpty)

            let combined = try await fixture.read(client, "unread=true&after=1")
            #expect(combined.status == .badRequest)
            #expect(combined.body["errorCode"] as? String == "INVALID_ARG")
            #expect(combined.body["suggestedNextAction"] as? String == "raft message read --target '#ax-unread' --unread")
            let plain = try await fixture.read(client, "limit=5")
            #expect(plain.status == .ok)
            #expect(plain.body["unread_after_seq"] == nil)
        }
    }
}

@Test func unreadPagesAndSkipsOwnMessages() async throws {
    var fixture = UnreadFixture()
    fixture.seed()
    let accounts = fixture.accounts
    accounts.setReadPositionSettleForTesting(-10_000)
    fixture.post("a")
    fixture.post("b")
    fixture.post("c")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let page1 = try await fixture.read(client, "unread=true&limit=2")
            #expect(page1.contents == ["a", "b"])
            #expect(page1.body["has_newer"] as? Bool == true)
            let page2 = try await fixture.read(client, "unread=true&limit=2")
            #expect(page2.contents == ["c"])
            #expect(page2.body["has_newer"] as? Bool == false)
            #expect(try await fixture.read(client, "unread=true").contents.isEmpty)
        }
    }

    var ownFixture = UnreadFixture()
    ownFixture.seed()
    let ownAccounts = ownFixture.accounts
    ownAccounts.setReadPositionSettleForTesting(-10_000)
    ownFixture.post("one")
    ownFixture.post("self note", own: true)
    ownFixture.post("two")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: ownAccounts))
        try await app.testing { client in
            let read = try await ownFixture.read(client, "unread=true")
            #expect(read.contents == ["one", "two"], "the agent's own message is not unread")
            #expect(try await ownFixture.read(client, "unread=true").contents.isEmpty, "the read moved past the own message")
        }
    }
}

@Test func unreadTooRecentRowIsReturnedWithoutMovingUntilTheWindowPasses() async throws {
    var fixture = UnreadFixture()
    fixture.seed()
    let accounts = fixture.accounts
    accounts.setReadPositionSettleForTesting(2_000)
    fixture.post("settled")
    fixture.post("fresh", fresh: true)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let first = try await fixture.read(client, "unread=true")
            #expect(first.contents == ["settled", "fresh"])
            let firstPosition = first.body["unread_after_seq"] as? Int
            #expect(firstPosition == 0, "the too-recent row must not move the read position")

            accounts.setReadPositionSettleForTesting(-10_000)
            let afterWindow = try await fixture.read(client, "unread=true")
            #expect(afterWindow.contents.isEmpty, "the deferred advance moves over what the first read returned")
            accounts.setReadPositionSettleForTesting(2000)
        }
    }
}
