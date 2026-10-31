import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentDirectMessagesListOnlyAgentToAgentDMs() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111612"
    let serverId = "33333333-3333-4333-8333-333333333659"
    accounts.addAccount(id: ownerId, email: "agent-dm-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-dm", name: "Agent DM", ownerId: ownerId)
    let agentA = accounts.oauth.createAgent(serverId: serverId, name: "agent-a", creatorUserId: ownerId)
    let agentB = accounts.oauth.createAgent(serverId: serverId, name: "agent-b", creatorUserId: ownerId)
    let agentDm = accounts.createAgentDirectChannelForTesting(serverId: serverId, firstAgentId: agentA, secondAgentId: agentB)
    _ = accounts.addHumanMessageForTesting(channelId: agentDm, senderId: agentA, content: "agent to agent preview", senderType: "agent")
    let humanDm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: agentA)
    _ = accounts.addHumanMessageForTesting(channelId: humanDm, senderId: ownerId, content: "human private message")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"agent-dm-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: "/api/agents/\(agentA)/agent-dms")
            #expect(response.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.count == 1)
            #expect(rows.first?["id"] as? String == agentDm)
            #expect(rows.first?["peerId"] as? String == agentB)
            #expect(rows.first?["peerName"] as? String == "agent-b")
            #expect(rows.first?["lastMessagePreview"] as? String == "agent to agent preview")
        }
    }
}
