import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func manageableAgentsUnionAcrossServersAndFilterByCreator() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111266"
    let memberId = "11111111-1111-4111-8111-111111111267"
    let emptyId = "11111111-1111-4111-8111-111111111268"
    let serverA = "33333333-3333-4333-8333-333333333453"
    let serverB = "33333333-3333-4333-8333-333333333454"
    let filterServer = "33333333-3333-4333-8333-333333333455"
    accounts.addAccount(id: ownerId, email: "manageable-multi@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "filter-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.addAccount(id: emptyId, email: "empty-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: emptyId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "manageable-a", name: "Server A", ownerId: memberId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "manageable-b", name: "Server B", ownerId: memberId)
    let a1 = accounts.oauth.createAgent(serverId: serverA, name: "agent-a1")
    let a2 = accounts.oauth.createAgent(serverId: serverA, name: "agent-a2")
    let b1 = accounts.oauth.createAgent(serverId: serverB, name: "agent-b1")
    accounts.oauth.addOwnedServer(id: filterServer, slug: "filter-test", name: "Filter Test", ownerId: ownerId)
    accounts.oauth.addMember(serverId: filterServer, userId: memberId, role: "member")
    let otherAgent = accounts.oauth.createAgent(serverId: filterServer, name: "filter-agent", creatorUserId: ownerId)
    let createdAgent = accounts.oauth.createAgent(serverId: filterServer, name: "creator-agent", creatorUserId: memberId)
    accounts.oauth.addOwnedServer(id: "33333333-3333-4333-8333-333333333456", slug: "empty-test", name: "Empty Test", ownerId: emptyId)

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
            func list(_ token: String) async throws -> (body: [String: Any], agents: [[String: Any]]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                let response = try await client.send(.get, headers: headers, to: "/api/agents/manageable")
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                let data = body["data"] as? [String: Any] ?? [:]
                return (data, data["agents"] as? [[String: Any]] ?? [])
            }

            let memberToken = try await login("filter-member@slock.test")
            let memberList = try await list(memberToken)
            let ids = memberList.agents.compactMap { $0["id"] as? String }
            #expect(ids.contains(a1))
            #expect(ids.contains(a2))
            #expect(ids.contains(b1))
            #expect(ids.contains(createdAgent))
            #expect(ids.contains(otherAgent) == false)
            #expect(memberList.agents.allSatisfy { ($0["serverId"] as? String)?.isEmpty == false })
            #expect(memberList.body["reason"] as? String == "ok")
            #expect(memberList.body["manageable_server_count"] as? Int == 3)
            #expect(memberList.body["suggested_next_action"] == nil)

            let emptyToken = try await login("empty-owner@slock.test")
            let emptyList = try await list(emptyToken)
            #expect(emptyList.agents.isEmpty)
            #expect(emptyList.body["reason"] as? String == "no_agents_on_manageable_servers")
            #expect(emptyList.body["manageable_server_count"] as? Int == 1)
            #expect(emptyList.body["suggested_next_action"] == nil)

            let ownerToken = try await login("manageable-multi@slock.test")
            let ownerList = try await list(ownerToken)
            let ownerIds = ownerList.agents.compactMap { $0["id"] as? String }
            #expect(ownerIds.contains(otherAgent))
            #expect(ownerIds.contains(createdAgent))
            #expect(ownerList.body["reason"] as? String == "ok")
            #expect(ownerList.body["manageable_server_count"] as? Int == 1)
        }
    }
}
