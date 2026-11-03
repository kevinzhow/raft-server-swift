import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AgentSurfaceFixture {
    let accounts: EmailLoginDirectory
    let agentKey: String
    let machineKey: String
}

private func makeAgentSurfaceFixture() -> AgentSurfaceFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111632"
    let serverId = "33333333-3333-4333-8333-333333333673"
    accounts.addAccount(id: ownerId, email: "agent-surface-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-surface", name: "Agent Surface", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "SurfaceBot", creatorUserId: ownerId)
    let machine = accounts.registerMachineWithKeyForTesting(serverId: serverId, userId: ownerId, name: "surface-machine")
    return AgentSurfaceFixture(
        accounts: accounts,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "surface-agent"),
        machineKey: machine.apiKey
    )
}

private func surfaceRequest(
    _ client: any Client,
    key: String?,
    method: HTTPRequest.Method,
    path: String,
    body: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let key { headers[.authorization] = "Bearer \(key)" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func unregisteredAgentSurfacePathsFailClosed() async throws {
    let f = makeAgentSurfaceFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // A registered agent-api surface still answers normally; the
            // catch-all does not shadow it.
            let registered = try await surfaceRequest(client, key: f.agentKey, method: .get, path: "/internal/agent-api")
            #expect(registered.status == .ok)

            let agentSibling = try await surfaceRequest(
                client, key: f.agentKey, method: .post,
                path: "/internal/agent-api/tasks/assign-not-registered", body: "{}"
            )
            #expect(agentSibling.status == .unauthorized)
            #expect(agentSibling.body["code"] as? String == "auth_policy_unregistered_path")

            let legacySibling = try await surfaceRequest(
                client, key: f.agentKey, method: .post,
                path: "/internal/agent/\(UUID().uuidString)/not-a-registered-surface", body: "{}"
            )
            #expect(legacySibling.status == .unauthorized)
            #expect(legacySibling.body["code"] as? String == "auth_policy_unregistered_path")

            // A machine principal is not the claimed principal for these
            // prefixes, so it fails as an invalid principal instead.
            let machine = try await surfaceRequest(
                client, key: f.machineKey, method: .post,
                path: "/internal/agent-api/tasks/assign-not-registered", body: "{}"
            )
            #expect(machine.status == .unauthorized)
            #expect(machine.body["code"] as? String == "invalid_principal")

            let unauthenticated = try await surfaceRequest(
                client, key: nil, method: .post,
                path: "/internal/agent-api/tasks/assign-not-registered", body: "{}"
            )
            #expect(unauthenticated.status == .unauthorized)
            #expect(unauthenticated.body["code"] as? String == "auth_required")
        }
    }
}
