import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func deletedAgentsStopBlockingProviderConnectionDeletion() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111640"
    let serverId = "33333333-3333-4333-8333-333333333680"
    accounts.addAccount(id: ownerId, email: "provider-detach-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "provider-detach", name: "Provider Detach", ownerId: ownerId)
    accounts.setProviderConnectionsEnabled(serverId: serverId, enabled: true)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "orphaned-provider-agent")
    try await withApp { app in
        try configureProviderConnectionsTestApp(
            app, accounts: accounts, credentialMasterKey: Data((32..<64).map { UInt8($0) })
        )
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"provider-detach-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8))) as? [String: Any]
            headers[.authorization] = "Bearer \(token?["accessToken"] as? String ?? "")"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let createdResponse = try await client.send(.post, headers: headers, to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Orphaned DeepSeek\",\"providerId\":\"deepseek\",\"apiKey\":\"detach-secret-value\"}")
            }
            #expect(createdResponse.status == .created)
            #expect((createdResponse.body.string ?? "").contains("detach-secret-value") == false)
            let created = try JSONSerialization.jsonObject(with: Data((createdResponse.body.string ?? "").utf8)) as? [String: Any]
            let connectionId = try #require(created?["id"] as? String)
            accounts.assignAgentToProviderConnection(
                connectionId: connectionId, serverId: serverId,
                agentId: agentId, computerName: "orphaned-agent-machine"
            )

            // Legacy orphan: the Agent is soft-deleted while its assignment row
            // survives, so the connection itself stays blocked until detached.
            accounts.oauth.deleteAgent(id: agentId)
            let blocked = try await client.send(.delete, headers: headers, to: "/api/provider-connections/\(connectionId)")
            #expect(blocked.status == .ok, "a soft-deleted Agent no longer blocks deletion")

            // The old assignment path is gone with the connection.
            let listedAfter = try await client.send(.get, headers: headers, to: "/api/provider-connections")
            let connections = (try JSONSerialization.jsonObject(with: Data((listedAfter.body.string ?? "").utf8)) as? [String: Any])?["connections"] as? [[String: Any]] ?? []
            #expect(!connections.contains { ($0["id"] as? String) == connectionId })
        }
    }
}

@Test func deletedAgentAssignmentStillListsAndDetachesWithoutLeakingCredentials() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111641"
    let serverId = "33333333-3333-4333-8333-333333333681"
    accounts.addAccount(id: ownerId, email: "provider-orphan-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "provider-orphan", name: "Provider Orphan", ownerId: ownerId)
    accounts.setProviderConnectionsEnabled(serverId: serverId, enabled: true)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "orphan-listed-agent")
    try await withApp { app in
        try configureProviderConnectionsTestApp(
            app, accounts: accounts, credentialMasterKey: Data((32..<64).map { UInt8($0) })
        )
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"provider-orphan-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8))) as? [String: Any]
            headers[.authorization] = "Bearer \(token?["accessToken"] as? String ?? "")"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let createdResponse = try await client.send(.post, headers: headers, to: "/api/provider-connections") { request in
                request.body = .init(string: "{\"name\":\"Assigned DeepSeek\",\"providerId\":\"deepseek\",\"apiKey\":\"orphan-secret-value\"}")
            }
            let connectionId = try #require(((try JSONSerialization.jsonObject(with: Data((createdResponse.body.string ?? "").utf8))) as? [String: Any])?["id"] as? String)
            accounts.assignAgentToProviderConnection(
                connectionId: connectionId, serverId: serverId,
                agentId: agentId, computerName: "orphan-listed-machine"
            )
            accounts.oauth.deleteAgent(id: agentId)

            let listed = try await client.send(.get, headers: headers, to: "/api/provider-connections/\(connectionId)/agents")
            #expect(listed.status == .ok)
            #expect((listed.body.string ?? "").contains("orphan-secret-value") == false)
            let rows = ((try JSONSerialization.jsonObject(with: Data((listed.body.string ?? "").utf8))) as? [String: Any])?["agents"] as? [[String: Any]] ?? []
            #expect(rows.map { $0["id"] as? String } == [agentId])
            #expect(rows.first?["deleted"] as? Bool == true)

            let detached = try await client.send(.delete, headers: headers, to: "/api/provider-connections/\(connectionId)/agents/\(agentId)")
            #expect(detached.status == .ok)
            let freed = try await client.send(.delete, headers: headers, to: "/api/provider-connections/\(connectionId)")
            #expect(freed.status == .ok)
        }
    }
}
