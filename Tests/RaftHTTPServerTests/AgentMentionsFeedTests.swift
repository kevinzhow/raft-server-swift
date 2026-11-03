import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct MentionFeedFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let ownerId: String
    let agentId: String
    let agentKey: String
    let readOnlyKey: String
}

private func makeMentionFeedFixture(_ suffix: String) -> MentionFeedFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001240\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001240\(suffix)"
    accounts.addAccount(id: ownerId, email: "mention-feed-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-feed-\(suffix)", name: "Mention Feed \(suffix)", ownerId: ownerId)
    let channelName = "mention-feed-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "MentionFeedBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    return MentionFeedFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        ownerId: ownerId,
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["mentions", "read"], name: "mention-feed-\(suffix)"),
        readOnlyKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "mention-read-\(suffix)")
    )
}

private func mentionFeedGet(
    _ client: any Client,
    _ f: MentionFeedFixture,
    key: String,
    query: String = ""
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    let response = try await client.get(URI(string: "/internal/agent-api/mentions\(query)"), headers: headers)
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func agentMentionsOnlyReturnTargetVisibleRows() async throws {
    let f = makeMentionFeedFixture("901")
    let pending = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: pending, channelId: f.channelId, senderId: f.ownerId, content: "pending mention")
    f.accounts.addMessageMention(messageId: pending, targetType: "agent", targetId: f.agentId, notifiableAtSend: false)
    let notified = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: notified, channelId: f.channelId, senderId: f.ownerId, content: "notified mention")
    f.accounts.addMessageMention(
        messageId: notified,
        targetType: "agent",
        targetId: f.agentId,
        notifiableAtSend: false,
        notifiedAt: Date(),
        notifiedByType: "user",
        notifiedById: f.ownerId,
        notifiedAction: "notify_only"
    )
    let ordinary = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: ordinary, channelId: f.channelId, senderId: f.ownerId, content: "ordinary mention")
    f.accounts.addMessageMention(messageId: ordinary, targetType: "agent", targetId: f.agentId)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let feed = try await mentionFeedGet(client, f, key: f.agentKey)
            #expect(feed.status == .ok)
            let rows = try #require(feed.body["mentions"] as? [[String: Any]])
            let ids = Set(rows.compactMap { $0["messageId"] as? String })
            #expect(ids == Set([notified, ordinary]), "pending outsider mention rows stay out of the target feed")
            #expect(!ids.contains(pending))
        }
    }
}

@Test func agentMentionsPageNewestFirstWithLimitPlusOneProbe() async throws {
    let f = makeMentionFeedFixture("902")
    var messages: [(id: String, seq: Int)] = []
    for index in 1...2 {
        let id = UUID().uuidString.lowercased()
        f.accounts.insertHumanMessage(id: id, channelId: f.channelId, senderId: f.ownerId, content: "mention \(index)")
        f.accounts.addMessageMention(messageId: id, targetType: "agent", targetId: f.agentId)
        messages.append((id, f.accounts.humanMessageSequence(id: id) ?? 0))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let exact = try await mentionFeedGet(client, f, key: f.agentKey, query: "?limit=2")
            #expect(exact.status == .ok)
            #expect((exact.body["mentions"] as? [[String: Any]] ?? []).compactMap { $0["messageId"] as? String } == [messages[1].id, messages[0].id])
            #expect(exact.body["has_more"] as? Bool == false, "exactly limit rows must not imply another page")

            let third = UUID().uuidString.lowercased()
            f.accounts.insertHumanMessage(id: third, channelId: f.channelId, senderId: f.ownerId, content: "mention 3")
            f.accounts.addMessageMention(messageId: third, targetType: "agent", targetId: f.agentId)

            let over = try await mentionFeedGet(client, f, key: f.agentKey, query: "?limit=2")
            #expect((over.body["mentions"] as? [[String: Any]] ?? []).compactMap { $0["messageId"] as? String } == [third, messages[1].id])
            #expect(over.body["has_more"] as? Bool == true)
        }
    }
}

@Test func agentMentionsRequireTheMentionsCapability() async throws {
    let f = makeMentionFeedFixture("903")
    let id = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: id, channelId: f.channelId, senderId: f.ownerId, content: "mention for scope gate")
    f.accounts.addMessageMention(messageId: id, targetType: "agent", targetId: f.agentId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let denied = try await mentionFeedGet(client, f, key: f.readOnlyKey)
            #expect(denied.status == .unauthorized)
            #expect(denied.body["code"] as? String == "auth_required")
        }
    }
}
