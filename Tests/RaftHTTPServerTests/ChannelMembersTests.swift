import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelMembersListsAgentsAndHumansForParticipants() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111327"
    let serverId = "33333333-3333-4333-8333-333333333495"
    accounts.addAccount(id: ownerId, email: "members-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "members", name: "Members", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "members-room", creatorUserId: ownerId)
    let firstAgent = accounts.oauth.createAgent(serverId: serverId, name: "members-agent-1")
    let secondAgent = accounts.oauth.createAgent(serverId: serverId, name: "members-agent-2")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: firstAgent)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: secondAgent)

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
                request.body = .init(string: "{\"email\":\"members-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let response = try await client.send(.get, headers: headers, to: "/api/channels/\(channelId)/members")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let agents = body?["agents"] as? [[String: Any]] ?? []
            #expect(agents.count == 2)
            #expect(Set(agents.compactMap { $0["id"] as? String }) == [firstAgent, secondAgent])
            #expect(agents.allSatisfy { $0["activity"] as? String == "offline" })
            #expect(agents.allSatisfy { $0.keys.contains("activityDetail") })
            #expect((body?["humans"] as? [[String: Any]])?.contains { $0["id"] as? String == ownerId } == true)

            var unauth = HTTPFields()
            unauth[HTTPField.Name("X-Server-Id")!] = serverId
            let refused = try await client.send(.get, headers: unauth, to: "/api/channels/\(channelId)/members")
            #expect(refused.status == .unauthorized)
        }
    }
}
