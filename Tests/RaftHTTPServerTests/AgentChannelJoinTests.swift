import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentChannelJoinNeedsChannelsScopeAndAServerRole() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111395"
    let serverId = "33333333-3333-4333-8333-333333333531"
    accounts.addAccount(id: ownerId, email: "agent-join-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-join", name: "Agent Join", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "join-capability-agent")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "agent-join-public", creatorUserId: ownerId)
    let secondChannelId = accounts.oauth.createChannel(serverId: serverId, name: "agent-join-second", creatorUserId: ownerId)
    let credential = accounts.mintAgentCredential(agentId: agentId, scopes: ["channels"], name: "join-capability-test")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func join(_ key: String, _ channel: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                return try await client.send(.post, headers: headers, to: "/internal/agent-api/channels/\(channel)/join")
            }

            #expect(try await join(credential, secondChannelId).status == .ok)
            #expect(accounts.oauth.channelAgentIds(channelId: secondChannelId).contains(agentId))

            accounts.oauth.removeAgentMember(serverId: serverId, agentId: agentId)
            let idempotent = try await join(credential, secondChannelId)
            #expect(idempotent.status == .ok)

            let denied = try await join(credential, channelId)
            #expect(denied.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((denied.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Server role cannot join public channels")
            #expect(!accounts.oauth.channelAgentIds(channelId: channelId).contains(agentId))

            let readOnly = accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "no-channels")
            #expect(try await join(readOnly, channelId).status == .unauthorized)
        }
    }
}
