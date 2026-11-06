import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func memberGraphProjectsVisibleChannelEdgesOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111482"
    let memberId = "11111111-1111-4111-8111-111111111483"
    let serverId = "33333333-3333-4333-8333-333333333586"
    accounts.addAccount(id: ownerId, email: "graph-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "graph-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "graph", name: "Graph", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "graph-public", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: publicChannel, userId: memberId)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "graph-private", creatorUserId: ownerId)
    accounts.oauth.setChannelType(id: privateChannel, type: "private")
    let archivedChannel = accounts.oauth.createChannel(serverId: serverId, name: "graph-archived", creatorUserId: ownerId)
    accounts.oauth.setChannelArchived(id: archivedChannel, archivedAt: Date())
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: memberId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: publicChannel, parentMessageId: UUID().uuidString.lowercased())
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "GraphBot")
    accounts.oauth.addChannelAgent(channelId: publicChannel, agentId: agent)
    let deletedAgent = accounts.oauth.createAgent(serverId: serverId, name: "DeletedBot")
    accounts.oauth.deleteAgent(id: deletedAgent)

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
                request.body = .init(string: "{\"email\":\"graph-member@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/member-graph")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let channels = body["channels"] as? [[String: Any]] ?? []
            let ids = channels.compactMap { $0["id"] as? String }
            let allChannel = accounts.oauth.allChannelId(serverId: serverId) ?? ""
            #expect(ids.contains(allChannel))
            #expect(ids.contains(publicChannel))
            for hidden in [privateChannel, archivedChannel, dm, thread] {
                #expect(!ids.contains(hidden))
            }
            let agents = body["agents"] as? [[String: Any]] ?? []
            #expect(agents.contains { $0["id"] as? String == agent })
            #expect(!agents.contains { $0["id"] as? String == deletedAgent })
            let edges = body["edges"] as? [[String: Any]] ?? []
            #expect(edges.contains { $0["channelId"] as? String == allChannel && $0["memberType"] as? String == "human" && $0["memberId"] as? String == ownerId })
            #expect(edges.contains { $0["channelId"] as? String == publicChannel && $0["memberType"] as? String == "agent" && $0["memberId"] as? String == agent })
            #expect(!edges.contains { $0["memberId"] as? String == deletedAgent })
            #expect(!(String(data: Data((response.body.string ?? "").utf8), encoding: .utf8) ?? "").contains("@slock.test"))
        }
    }
}
