import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct SlackMentionFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001104001"
    let ownerId = "11111111-1111-4111-8111-000001104001"
    var agentAId = ""
    var agentBId = ""
    var channelId = ""
    var channelName = ""
    var keyA = ""
    var keyB = ""
    var slackId = ""
    var otherId = ""

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "slack-mention-owner@mention.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "slack-mention", name: "Slack Mention Test", ownerId: ownerId)
        agentAId = accounts.oauth.createAgent(serverId: serverId, name: "SlackMentionAlpha", creatorUserId: ownerId, runtime: "external")
        agentBId = accounts.oauth.createAgent(serverId: serverId, name: "SlackMentionBravo", creatorUserId: ownerId, runtime: "external")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "slack-mention-room", creatorUserId: ownerId, type: "channel")
        channelName = "slack-mention-room"
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: channelName, humanIds: [ownerId], agentIds: [agentAId, agentBId])
        keyA = accounts.mintAgentCredential(agentId: agentAId, scopes: ["send", "read"], name: "slack-a")
        keyB = accounts.mintAgentCredential(agentId: agentBId, scopes: ["send", "read"], name: "slack-b")
        let content = "hi @SlackMentionAlpha see #\(channelName) <result>"
        slackId = accounts.addExternalProjectionMessageForTesting(channelId: channelId, senderName: "Alice External", content: content, externalMessageId: "1722387723.000100", provider: "slack")
        otherId = accounts.addExternalProjectionMessageForTesting(channelId: channelId, senderName: "Alice External", content: content, externalMessageId: "1722387723.000200", provider: "other-chat")
        accounts.addStoredMentionForTesting(channelId: channelId, messageId: slackId, targetId: agentAId, targetType: "agent", handle: "SlackMentionAlpha")
    }

    func events(_ client: any Client, _ key: String) async throws -> [String: [String: Any]] {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(key)"
        let response = try await client.get(URI(string: "/internal/agent-api/events"), headers: headers)
        let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
        let rows = body["events"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
            guard let id = row["message_id"] as? String else { return nil }
            return (id, row)
        })
    }

    func history(_ client: any Client, _ key: String) async throws -> [String: [String: Any]] {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(key)"
        let response = try await client.get(URI(string: "/internal/agent-api/history?channel=%23\(channelName)"), headers: headers)
        let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
        let rows = body["messages"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
            guard let id = row["id"] as? String else { return nil }
            return (id, row)
        })
    }

    func resolve(_ client: any Client, _ key: String, _ messageId: String) async throws -> [String: Any] {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(key)"
        let response = try await client.get(URI(string: "/internal/agent-api/messages/\(messageId)/resolve"), headers: headers)
        let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
        return body["message"] as? [String: Any] ?? [:]
    }
}

private func assertSlackOrdinary(_ row: [String: Any]?, _ fixture: SlackMentionFixture, mentioned: Bool, _ label: String) {
    guard let row else { Issue.record(Comment(rawValue: label + ": Slack message missing")); return }
    #expect(row["mentioned"] as? Bool == mentioned, Comment(rawValue: label))
    let content = row["content"] as? String ?? ""
    #expect(content.contains("@SlackMentionAlpha"), Comment(rawValue: label))
    #expect(content.contains("#slack-mention-room"), Comment(rawValue: label))
    #expect(content.contains("<result>"), Comment(rawValue: label))
    #expect(!content.contains("user:"), Comment(rawValue: label))
    #expect((row["external_message"] as? [String: Any])?["provider"] as? String == "slack", Comment(rawValue: label))
    _ = fixture
}

private func assertOtherInert(_ row: [String: Any]?, _ label: String) {
    guard let row else { Issue.record(Comment(rawValue: label + ": non-Slack message missing")); return }
    #expect(row["mentioned"] as? Bool == false, Comment(rawValue: label))
    let content = row["content"] as? String ?? ""
    #expect(content.contains("user:SlackMentionAlpha"), Comment(rawValue: label))
    #expect(content.contains("&lt;result&gt;"), Comment(rawValue: label))
    #expect((row["external_message"] as? [String: Any])?["provider"] as? String == "other-chat", Comment(rawValue: label))
}

@Test func slackBridgedMentionsReachAgentHistoryEventsAndResolve() async throws {
    var fixture = SlackMentionFixture()
    fixture.seed()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let eventsA = try await fixture.events(client, fixture.keyA)
            assertSlackOrdinary(eventsA[fixture.slackId], fixture, mentioned: true, "events A")
            assertOtherInert(eventsA[fixture.otherId], "events A")
            let eventsB = try await fixture.events(client, fixture.keyB)
            assertSlackOrdinary(eventsB[fixture.slackId], fixture, mentioned: false, "events B")

            let historyA = try await fixture.history(client, fixture.keyA)
            assertSlackOrdinary(historyA[fixture.slackId], fixture, mentioned: true, "history A")
            assertOtherInert(historyA[fixture.otherId], "history A")
            let historyB = try await fixture.history(client, fixture.keyB)
            assertSlackOrdinary(historyB[fixture.slackId], fixture, mentioned: false, "history B")

            assertSlackOrdinary(try await fixture.resolve(client, fixture.keyA, fixture.slackId), fixture, mentioned: true, "resolve A")
            assertSlackOrdinary(try await fixture.resolve(client, fixture.keyB, fixture.slackId), fixture, mentioned: false, "resolve B")
            assertOtherInert(try await fixture.resolve(client, fixture.keyA, fixture.otherId), "resolve A")
        }
    }
}
