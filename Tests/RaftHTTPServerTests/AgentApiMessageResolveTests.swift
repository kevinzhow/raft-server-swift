import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentApiMessageResolveHandlesShortIdsVisibilityAndAmbiguity() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001027001"
    let ownerId = "11111111-1111-4111-8111-000001027001"
    let ownerEmail = "agent-resolve-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-resolve", name: "Agent Resolve", ownerId: ownerId)
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "resolve-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: ownerId, name: "resolve-public")
    accounts.oauth.addChannelHuman(channelId: publicChannel, userId: ownerId)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "resolve-private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private", name: "resolve-private")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
    let hiddenChannel = accounts.oauth.createChannel(serverId: serverId, name: "resolve-hidden", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: hiddenChannel, memberId: ownerId, kind: "private", name: "resolve-hidden")
    accounts.oauth.addChannelHuman(channelId: hiddenChannel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ResolveBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: privateChannel, agentId: agent)
    let readKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "read")
    let sendKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send"], name: "send")

    let full = "aaaaaaaa-1111-4111-8111-111111111111"
    let visible = "bbbbbbbb-1111-4111-8111-111111111111"
    let visible2 = "bbbbbbbb-2222-4222-8222-222222222222"
    let hidden = "cccccccc-1111-4111-8111-111111111111"
    let privateMessage = "dddddddd-1111-4111-8111-111111111111"
    _ = accounts.addChannelMessageForTesting(id: full, channelId: publicChannel, content: "resolve target", senderId: ownerId)
    _ = accounts.addChannelMessageForTesting(id: visible, channelId: publicChannel, content: "visible collision", senderId: ownerId)
    _ = accounts.addChannelMessageForTesting(id: visible2, channelId: publicChannel, content: "second visible collision", senderId: ownerId)
    _ = accounts.addChannelMessageForTesting(id: hidden, channelId: hiddenChannel, content: "hidden collision", senderId: ownerId)
    _ = accounts.addChannelMessageForTesting(id: privateMessage, channelId: privateChannel, content: "private visible", senderId: ownerId)

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
            func resolve(_ key: String, _ ref: String) async throws -> ClientResponse {
                try await client.get(URI(string: "/internal/agent-api/messages/\(ref)/resolve"), headers: headers(key))
            }
            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            let success = try await resolve(readKey, String(full.prefix(8)))
            #expect(success.status == .ok)
            let message = try #require(body(success)["message"] as? [String: Any])
            #expect(message["message_id"] as? String == full)
            #expect(message["channel_name"] as? String == "resolve-public")
            #expect(message["channel_type"] as? String == "channel")
            #expect(message["sender_type"] as? String == "human")
            #expect(message["sender_name"] as? String == "agent-resolve-owner")
            #expect(message["content"] as? String == "resolve target")

            let privateResult = try await resolve(readKey, privateMessage)
            #expect(privateResult.status == .ok)
            #expect((body(privateResult)["message"] as? [String: Any])?["channel_name"] as? String == "resolve-private")

            let missing = try await resolve(readKey, "4f9c2210")
            #expect(missing.status == .notFound)
            #expect(body(missing)["errorCode"] as? String == "NOT_FOUND")

            let hiddenOnly = try await resolve(readKey, String(hidden.prefix(8)))
            #expect(hiddenOnly.status == .notFound)

            let ambiguous = try await resolve(readKey, "bbbbbbbb")
            #expect(ambiguous.status == .badRequest)
            #expect(body(ambiguous)["errorCode"] as? String == "AMBIGUOUS_ID")

            let denied = try await resolve(sendKey, String(full.prefix(8)))
            #expect(denied.status == .forbidden)
            #expect(body(denied)["code"] as? String == "capability_not_authorized")
        }
    }
}
