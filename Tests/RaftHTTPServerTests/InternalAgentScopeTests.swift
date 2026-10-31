import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func internalAgentSendChecksMachineOwnershipBeforeScope() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111426"
    let serverA = "33333333-3333-4333-8333-333333333548"
    let serverB = "33333333-3333-4333-8333-333333333549"
    accounts.addAccount(id: ownerId, email: "agent-scope@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "scope-a", name: "Scope A", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "scope-b", name: "Scope B", ownerId: ownerId)
    let agentA = accounts.oauth.createAgent(serverId: serverA, name: "ScopeAgentA")
    let agentB = accounts.oauth.createAgent(serverId: serverB, name: "ScopeAgentB")
    let machineA = accounts.registerMachine(serverId: serverA, userId: ownerId, name: "scope-machine-a")
    let apiKeyA = accounts.machineAPIKey(machineId: machineA) ?? ""
    let body = "{\"target\":\"#scope-room-a\",\"content\":\"probe\"}"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func send(_ agentId: String, _ key: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/internal/agent/\(agentId)/send") { request in
                    request.body = .init(string: body)
                }
            }
            func json(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let crossServer = try await send(agentB, apiKeyA)
            #expect(crossServer.status == .notFound)
            #expect(try json(crossServer)["error"] as? String == "Agent not found")

            let missing = try await send(UUID().uuidString.lowercased(), apiKeyA)
            #expect(missing.status == .notFound)
            #expect(try json(missing)["error"] as? String == "Agent not found")

            let sameServer = try await send(agentA, apiKeyA)
            #expect(sameServer.status == .notFound)
            #expect(try json(sameServer)["error"] as? String == "Channel not found")
            _ = agentA
        }
    }
}
