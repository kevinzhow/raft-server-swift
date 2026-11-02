import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentAndLegacyJoinAreIdempotentBeforeCapabilityDenial() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001036001"
    let ownerId = "11111111-1111-4111-8111-000001036001"
    accounts.addAccount(id: ownerId, email: "join-idempotent-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "join-idempotent", name: "Join Idempotent", ownerId: ownerId)
    let joined = accounts.oauth.createChannel(serverId: serverId, name: "joined-room", creatorUserId: ownerId)
    let unjoined = accounts.oauth.createChannel(serverId: serverId, name: "unjoined-room", creatorUserId: ownerId)
    for channel in [joined, unjoined] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "room")
        accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "JoinBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: joined, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["channels"], name: "join")
    let legacyKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agent)
    // Upstream deletes the agent's server role; the idempotent join must still
    // succeed for a channel the agent is already in.
    accounts.oauth.removeAgentMember(serverId: serverId, agentId: agent)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            let joinedResponse = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/channels/\(joined)/join"))
            #expect(joinedResponse.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((joinedResponse.body.string ?? "").utf8)) as? [String: Any])?["ok"] as? Bool == true)
            #expect(accounts.oauth.channelAgentIds(channelId: joined).contains(agent))

            let denied = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/channels/\(unjoined)/join"))
            #expect(denied.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((denied.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Server role cannot join public channels")
            #expect(!accounts.oauth.channelAgentIds(channelId: unjoined).contains(agent))

            var legacyHeaders = HTTPFields()
            legacyHeaders[.authorization] = "Bearer \(legacyKey)"
            let legacyJoined = try await client.send(.post, headers: legacyHeaders, to: URI(string: "/internal/agent/\(agent)/channels/\(joined)/join"))
            #expect(legacyJoined.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((legacyJoined.body.string ?? "").utf8)) as? [String: Any])?["ok"] as? Bool == true)
            let legacyDenied = try await client.send(.post, headers: legacyHeaders, to: URI(string: "/internal/agent/\(agent)/channels/\(unjoined)/join"))
            #expect(legacyDenied.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((legacyDenied.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Server role cannot join public channels")
            #expect(!accounts.oauth.channelAgentIds(channelId: unjoined).contains(agent))
        }
    }
}
