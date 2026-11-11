import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func seedOccurrence(accounts: EmailLoginDirectory, message: String, target: String) -> Bool {
    accounts.ensureMentionDeliveryOccurrenceForTesting(messageId: message, agentId: target) != nil
}

@Test func agentMentionDeliveriesRequireTheAuthorAndKeepTheAuthoredHandle() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001030001"
    let ownerId = "11111111-1111-4111-8111-000001030001"
    accounts.addAccount(id: ownerId, email: "mention-delivery-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-delivery", name: "Mention Delivery", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "mention-delivery-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "mention-delivery-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let author = accounts.oauth.createAgent(serverId: serverId, name: "MentionAuthor", runtime: "codex")
    let target = accounts.oauth.createAgent(serverId: serverId, name: "RenamedTarget", runtime: "codex")
    let stranger = accounts.oauth.createAgent(serverId: serverId, name: "MentionStranger", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: author)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: target)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: stranger)
    let authorKey = accounts.mintAgentCredential(agentId: author, scopes: ["read"], name: "author")
    let strangerKey = accounts.mintAgentCredential(agentId: stranger, scopes: ["read"], name: "stranger")
    let message = accounts.addChannelMessageForTesting(
        channelId: channel,
        content: "ping @OldName for the retry storm",
        senderId: author,
        senderType: "agent"
    )
    accounts.addStoredMentionForTesting(
        channelId: channel,
        messageId: message,
        targetId: target,
        targetType: "agent",
        handle: "@OldName"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func headers(_ key: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(key)"
                return fields
            }
            func get(_ key: String, _ id: String) async throws -> ClientResponse {
                try await client.get(URI(string: "/internal/agent-api/messages/\(id)/mention-deliveries"), headers: headers(key))
            }
            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            // A mention with no occurrence is absent from the occurrence-row
            // listing until the notify/add path records one.
            #expect(seedOccurrence(accounts: accounts, message: message, target: target))
            let own = try await get(authorKey, message)
            #expect(own.status == .ok)
            #expect(body(own)["messageId"] as? String == message)
            let delivery = try #require((body(own)["deliveries"] as? [[String: Any]])?.first)
            #expect(delivery["targetHandle"] as? String == "@OldName")
            // The pinned agent surface has no `targetId` member.
            #expect(delivery["targetId"] == nil)

            let notMine = try await get(strangerKey, message)
            let missing = try await get(strangerKey, "00000000-0000-4000-8000-000000009999")
            let malformed = try await get(strangerKey, "not-a-uuid")
            for response in [notMine, missing, malformed] {
                #expect(response.status == .notFound)
                #expect(body(response) as NSDictionary == ["status": "NOT_JOINABLE"] as NSDictionary)
            }
        }
    }
}
