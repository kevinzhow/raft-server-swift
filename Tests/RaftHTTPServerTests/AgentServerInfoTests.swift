import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentServerInfoProjectsRunnerAndMembership() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111499"
    let serverId = "33333333-3333-4333-8333-333333333595"
    accounts.addAccount(id: ownerId, email: "agent-info-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-info", name: "Agent Info", ownerId: ownerId)
    let joined = accounts.oauth.createChannel(serverId: serverId, name: "agent-info-joined", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: joined, memberId: ownerId, name: "agent-info-joined")
    let joinOnly = accounts.oauth.createChannel(serverId: serverId, name: "agent-info-open", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: joinOnly, memberId: ownerId, name: "agent-info-open")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "AgentInfoBot")
    accounts.oauth.addChannelAgent(channelId: joined, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "channels"], name: "info")

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
            let response = try await client.send(.get, headers: headers, to: "/internal/agent-api/server")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let runtime = body["runtimeContext"] as? [String: Any]
            #expect(runtime?["agentId"] as? String == agent)
            #expect(runtime?["runtime"] is String)
            #expect(body["serverRole"] as? String == "member")
            let capabilities = body["serverCapabilities"] as? [String: Any]
            #expect(capabilities?["addChannelMembers"] as? Bool == true)
            let channels = body["channels"] as? [[String: Any]] ?? []
            #expect(channels.first { $0["id"] as? String == joined }?["joined"] as? Bool == true)
            #expect(channels.first { $0["id"] as? String == joinOnly }?["joined"] as? Bool == false)
            let agents = body["agents"] as? [[String: Any]] ?? []
            let own = agents.first { $0["id"] as? String == agent }
            #expect(own?["name"] as? String == "AgentInfoBot")
            #expect(own?["role"] as? String == "member")
            #expect(own?["status"] as? String == "active")
            #expect(own?["activity"] is String)
        }
    }
}
