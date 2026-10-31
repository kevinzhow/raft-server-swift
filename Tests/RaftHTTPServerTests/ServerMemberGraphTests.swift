import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func memberGraphExposesOnlyVisibleOrdinaryChannelEdges() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111349"
    let memberId = "11111111-1111-4111-8111-111111111350"
    let serverId = "33333333-3333-4333-8333-333333333505"
    accounts.addAccount(id: ownerId, email: "graph-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "graph-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.addAccount(id: "11111111-1111-4111-8111-111111111400", email: "graph-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: "11111111-1111-4111-8111-111111111400")
    accounts.oauth.addOwnedServer(id: serverId, slug: "graph", name: "Graph", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "GraphBot")
    let deletedAgent = accounts.oauth.createAgent(serverId: serverId, name: "DeletedGraphBot")
    accounts.oauth.deleteAgent(id: deletedAgent)
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "graph-public", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: publicChannel, userId: memberId)
    accounts.oauth.addChannelAgent(channelId: publicChannel, agentId: agent)
    accounts.oauth.addChannelAgent(channelId: publicChannel, agentId: deletedAgent)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "graph-private", creatorUserId: ownerId, type: "private")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: memberId)
    accounts.oauth.addChannelAgent(channelId: privateChannel, agentId: agent)
    let archivedChannel = accounts.oauth.createChannel(serverId: serverId, name: "graph-archived", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: archivedChannel, userId: memberId)
    accounts.oauth.setChannelArchived(id: archivedChannel, archivedAt: Date())
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: memberId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: publicChannel, parentMessageId: UUID().uuidString.lowercased())
    let allChannel = accounts.oauth.allChannelId(serverId: serverId) ?? ""

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            let memberToken = try await login("graph-member@slock.test")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(memberToken)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let response = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/member-graph")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let humans = body?["humans"] as? [[String: Any]] ?? []
            let agents = body?["agents"] as? [[String: Any]] ?? []
            let channels = body?["channels"] as? [[String: Any]] ?? []
            let edges = body?["edges"] as? [[String: Any]] ?? []

            #expect(humans.contains { $0["id"] as? String == ownerId })
            #expect(humans.contains { $0["id"] as? String == memberId })
            #expect(agents.contains { $0["id"] as? String == agent })
            #expect(!agents.contains { $0["id"] as? String == deletedAgent })
            #expect(channels.contains { $0["id"] as? String == allChannel && $0["memberCount"] as? Int == 3 })
            #expect(channels.contains { $0["id"] as? String == publicChannel && $0["memberCount"] as? Int == 3 })
            #expect(!channels.contains { $0["id"] as? String == privateChannel })
            #expect(!channels.contains { $0["id"] as? String == archivedChannel })
            #expect(!channels.contains { $0["id"] as? String == dm })
            #expect(!channels.contains { $0["id"] as? String == thread })
            #expect(edges.contains { $0["channelId"] as? String == allChannel && $0["memberType"] as? String == "human" && $0["memberId"] as? String == ownerId })
            #expect(edges.contains { $0["channelId"] as? String == allChannel && $0["memberType"] as? String == "human" && $0["memberId"] as? String == memberId })
            #expect(edges.contains { $0["channelId"] as? String == allChannel && $0["memberType"] as? String == "agent" && $0["memberId"] as? String == agent })
            #expect(edges.contains { $0["channelId"] as? String == publicChannel && $0["memberType"] as? String == "agent" && $0["memberId"] as? String == agent })
            #expect(!edges.contains { $0["memberId"] as? String == deletedAgent })
            #expect(!edges.contains { $0["channelId"] as? String == privateChannel })
            #expect(!edges.contains { $0["channelId"] as? String == archivedChannel })
            #expect(!edges.contains { $0["channelId"] as? String == dm })
            #expect(!edges.contains { $0["channelId"] as? String == thread })
            let serialized = response.body.string ?? ""
            #expect(!serialized.contains("graph-owner@slock.test"))
            #expect(!serialized.contains("graph-member@slock.test"))

            var missingHeader = HTTPFields()
            missingHeader[.authorization] = "Bearer \(memberToken)"
            let missing = try await client.send(.get, headers: missingHeader, to: "/api/servers/\(serverId)/member-graph")
            #expect(missing.status == .badRequest)

            let outsiderToken = try await login("graph-outsider@slock.test")
            var outsiderHeaders = headers
            outsiderHeaders[.authorization] = "Bearer \(outsiderToken)"
            let outsider = try await client.send(.get, headers: outsiderHeaders, to: "/api/servers/\(serverId)/member-graph")
            #expect(outsider.status == .forbidden)
        }
    }
}
