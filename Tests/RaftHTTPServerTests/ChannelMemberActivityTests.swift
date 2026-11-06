import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelMembersReportBatchedAgentActivity() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111454"
    let serverId = "33333333-3333-4333-8333-333333333566"
    accounts.addAccount(id: ownerId, email: "members-activity@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "members-activity", name: "Members Activity", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"members-activity@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"members-activity-room\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            for name in ["members-a", "members-b"] {
                let agent = accounts.oauth.createAgent(serverId: serverId, name: name)
                accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)
                accounts.setAgentActivity(agentId: agent, activity: "online", detail: "batched")
            }

            let response = try await client.send(.get, headers: headers, to: "/api/channels/\(channelId)/members")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let agents = body?["agents"] as? [[String: Any]] ?? []
            #expect(agents.count == 2)
            for agent in agents {
                #expect(agent["activity"] as? String == "online")
                #expect(agent["activityDetail"] as? String == "batched")
            }
        }
    }
}
