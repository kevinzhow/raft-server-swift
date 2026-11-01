import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func discoveryLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func discoveryList(_ client: any Client, token: String) async throws -> (data: [String: Any], agents: [[String: Any]], status: HTTPResponse.Status) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    let response = try await client.get("/api/agents/manageable", headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let data = body["data"] as? [String: Any] ?? [:]
    return (data, data["agents"] as? [[String: Any]] ?? [], response.status)
}

@Test func agentDiscoveryUnionsManageableAgentsAcrossServers() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111661001"
    let serverA = "33333333-3333-4333-8333-333333661001"
    let serverB = "33333333-3333-4333-8333-333333661002"
    accounts.addAccount(id: userId, email: "manageable-multi@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "manageable-a", name: "Server A", ownerId: userId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "manageable-b", name: "Server B", ownerId: userId)
    let agentA1 = accounts.oauth.createAgent(serverId: serverA, name: "agent-a1")
    let agentA2 = accounts.oauth.createAgent(serverId: serverA, name: "agent-a2")
    let agentB1 = accounts.oauth.createAgent(serverId: serverB, name: "agent-b1")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await discoveryLogin(client, email: "manageable-multi@slock.test")
            let result = try await discoveryList(client, token: token)
            #expect(result.status == .ok)
            #expect(result.data["reason"] as? String == "ok")
            #expect(result.data["manageable_server_count"] as? Int == 2)
            #expect(result.data["suggested_next_action"] == nil)
            let ids = Set(result.agents.compactMap { $0["id"] as? String })
            #expect(ids == Set([agentA1, agentA2, agentB1]))
            for agent in result.agents {
                #expect((agent["serverId"] as? String)?.isEmpty == false)
                #expect(agent["serverName"] is String || agent["serverName"] is NSNull)
            }
        }
    }
}

@Test func agentDiscoveryKeepsOnlyCreatorAgentsWithoutCredentialAuthority() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111661002"
    let memberId = "11111111-1111-4111-8111-111111661003"
    let serverId = "33333333-3333-4333-8333-333333661003"
    accounts.addAccount(id: ownerId, email: "filter-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "filter-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "filter-test", name: "Filter Test", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let otherAgent = accounts.oauth.createAgent(serverId: serverId, name: "filter-agent", creatorUserId: ownerId)
    let createdAgent = accounts.oauth.createAgent(serverId: serverId, name: "creator-agent", creatorUserId: memberId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await discoveryLogin(client, email: "filter-member@slock.test")
            let result = try await discoveryList(client, token: token)
            #expect(result.status == .ok)
            #expect(result.agents.map { $0["id"] as? String } == [createdAgent])
            #expect(!result.agents.contains { $0["id"] as? String == otherAgent })
            #expect(result.data["reason"] as? String == "ok")
            #expect(result.data["manageable_server_count"] as? Int == 1)
            #expect(result.data["suggested_next_action"] == nil)
        }
    }
}

@Test func agentDiscoveryReportsEmptyManageableServersWithoutAnError() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111661004"
    let serverId = "33333333-3333-4333-8333-333333661004"
    accounts.addAccount(id: ownerId, email: "empty-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "empty-test", name: "Empty Test", ownerId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await discoveryLogin(client, email: "empty-owner@slock.test")
            let result = try await discoveryList(client, token: token)
            #expect(result.status == .ok)
            #expect(result.agents.isEmpty)
            #expect(result.data["reason"] as? String == "no_agents_on_manageable_servers")
            #expect(result.data["manageable_server_count"] as? Int == 1)
            #expect(result.data["suggested_next_action"] == nil)
        }
    }
}
