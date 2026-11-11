import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct LegacyMachineGateFixture {
    let accounts: EmailLoginDirectory
    let serverA: String
    let serverB: String
    let ownerId: String
    let agentA: String
    let agentB: String
    let peerAgent: String
    let machineA: String
    let machineB: String
    let machineKeyA: String
    let machineKeyB: String
    let legacyKeyA: String
    let legacyKeyPeer: String
    let credentialKey: String
}

private func makeLegacyMachineGateFixture(_ suffix: String) -> LegacyMachineGateFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-00000126\(suffix)"
    let serverA = "33333333-3333-4333-8333-00000126\(suffix)"
    let serverB = "33333333-3333-4333-8333-00000127\(suffix)"
    accounts.addAccount(id: ownerId, email: "gate-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "gate-a-\(suffix)", name: "Gate A", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "gate-b-\(suffix)", name: "Gate B", ownerId: ownerId)
    let agentA = accounts.oauth.createAgent(serverId: serverA, name: "GateAgentA\(suffix)")
    let agentB = accounts.oauth.createAgent(serverId: serverB, name: "GateAgentB\(suffix)")
    let peerAgent = accounts.oauth.createAgent(serverId: serverA, name: "GatePeer\(suffix)")
    let machineA = accounts.registerMachine(serverId: serverA, userId: ownerId, name: "gate-machine-a-\(suffix)")
    let machineB = accounts.registerMachine(serverId: serverA, userId: ownerId, name: "gate-machine-b-\(suffix)")
    accounts.assignAgentMachineForTesting(agentId: agentA, machineId: machineA)
    return LegacyMachineGateFixture(
        accounts: accounts,
        serverA: serverA,
        serverB: serverB,
        ownerId: ownerId,
        agentA: agentA,
        agentB: agentB,
        peerAgent: peerAgent,
        machineA: machineA,
        machineB: machineB,
        machineKeyA: accounts.machineAPIKey(machineId: machineA) ?? "",
        machineKeyB: accounts.machineAPIKey(machineId: machineB) ?? "",
        legacyKeyA: accounts.registerMachineForAgent(serverId: serverA, agentId: agentA),
        legacyKeyPeer: accounts.registerMachineForAgent(serverId: serverA, agentId: peerAgent),
        credentialKey: accounts.mintAgentCredential(
            agentId: agentA,
            scopes: ["read", "send", "tasks"],
            name: "gate-credential-\(suffix)"
        )
    )
}

private func gateJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func gateTaskClaim(
    _ client: any Client,
    agentId: String,
    key: String?,
    body: String = "{\"channel\":\"#gate-room\",\"task_numbers\":[]}"
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let key { headers[.authorization] = "Bearer \(key)" }
    return try await client.send(.post, headers: headers, to: "/internal/agent/\(agentId)/tasks/claim") { request in
        request.body = .init(string: body)
    }
}

@Test func legacyAgentTaskRoutesRequireAMachineKey() async throws {
    let fixture = makeLegacyMachineGateFixture("01")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let missing = try await gateTaskClaim(client, agentId: fixture.agentA, key: nil)
            #expect(missing.status == .unauthorized)
            #expect(gateJSON(missing)["error"] as? String == "Missing machine API key")

            let invalid = try await gateTaskClaim(client, agentId: fixture.agentA, key: "sk_machine_deadbeef")
            #expect(invalid.status == .unauthorized)
            #expect(gateJSON(invalid)["error"] as? String == "Invalid machine API key")

            // A live `sk_agent_*` credential belongs to the agent-api surface,
            // never to the legacy machine surface.
            let wrongPrincipal = try await gateTaskClaim(
                client, agentId: fixture.agentA, key: fixture.credentialKey
            )
            #expect(wrongPrincipal.status == .unauthorized)
            #expect(gateJSON(wrongPrincipal)["error"] as? String
                == "Invalid authentication: machine API key required")

            fixture.accounts.markMachineLegacyMigratedForTesting(machineId: fixture.machineA, at: Date())
            let migrated = try await gateTaskClaim(client, agentId: fixture.agentA, key: fixture.machineKeyA)
            #expect(migrated.status == .unauthorized)
            #expect(gateJSON(migrated)["error"] as? String
                == "Legacy machine key has been migrated to a Computer attachment")
            #expect(gateJSON(migrated)["code"] as? String == "legacy_machine_key_migrated")
        }
    }
}

@Test func legacyAgentTaskRoutesCheckAgentServerAndMachineOwnership() async throws {
    let fixture = makeLegacyMachineGateFixture("02")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let crossServer = try await gateTaskClaim(
                client, agentId: fixture.agentB, key: fixture.machineKeyA
            )
            #expect(crossServer.status == .notFound)
            #expect(gateJSON(crossServer)["error"] as? String == "Agent not found")

            let unknown = try await gateTaskClaim(
                client, agentId: "11111111-1111-4111-8111-000001269999", key: fixture.machineKeyA
            )
            #expect(unknown.status == .notFound)
            #expect(gateJSON(unknown)["error"] as? String == "Agent not found")

            // Same server, different machine: the exact upstream 403.
            let wrongMachine = try await gateTaskClaim(
                client, agentId: fixture.agentA, key: fixture.machineKeyB
            )
            #expect(wrongMachine.status == .forbidden)
            #expect(gateJSON(wrongMachine)["error"] as? String
                == "This agent is not assigned to your machine")

            // A daemon-compat key row bound to a different agent.
            let wrongLegacyKey = try await gateTaskClaim(
                client, agentId: fixture.agentA, key: fixture.legacyKeyPeer
            )
            #expect(wrongLegacyKey.status == .forbidden)
            #expect(gateJSON(wrongLegacyKey)["error"] as? String
                == "This agent is not assigned to your machine")

            // The legacy key bound to this agent authenticates and reaches the
            // task handler (which then refuses the missing channel/tasks body).
            let legacy = try await gateTaskClaim(client, agentId: fixture.agentA, key: fixture.legacyKeyA)
            #expect(legacy.status == .badRequest)
        }
    }
}

@Test func legacyAgentTaskRoutesEnforceTheKeyedGrant() async throws {
    let fixture = makeLegacyMachineGateFixture("03")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            fixture.accounts.setAgentGrantsForTesting(agentId: fixture.agentA, scopes: ["task:read"])
            let denied = try await gateTaskClaim(client, agentId: fixture.agentA, key: fixture.machineKeyA)
            #expect(denied.status == .forbidden)
            let body = gateJSON(denied)
            #expect(body["error"] as? String == "missing required scope")
            #expect(body["requiredScope"] as? String == "task:write")
            #expect(body["reason"] as? String == "missing_scope")

            fixture.accounts.setAgentGrantsForTesting(agentId: fixture.agentA, scopes: ["task:write"])
            let allowed = try await gateTaskClaim(client, agentId: fixture.agentA, key: fixture.machineKeyA)
            #expect(allowed.status == .badRequest)
        }
    }
}

@Test func revokedAgentCredentialIsRefusedOnTheAgentApiTaskRoute() async throws {
    let fixture = makeLegacyMachineGateFixture("04")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            func claim() async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(fixture.credentialKey)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks/claim") { request in
                    request.body = .init(string: "{\"channel\":\"#gate-room\",\"task_numbers\":[]}")
                }
            }
            // Live but not yet revoked: the credential reaches the handler.
            let live = try await claim()
            #expect(live.status == .badRequest)

            fixture.accounts.revokeAgentCredentialForTesting(apiKey: fixture.credentialKey)
            let revoked = try await claim()
            #expect(revoked.status == .unauthorized)
        }
    }
}

@Test func everyLegacyAgentRouteSharesTheOwnershipGate() async throws {
    let fixture = makeLegacyMachineGateFixture("05")
    let routes: [(method: HTTPRequest.Method, path: String, body: String?)] = [
        (.get, "/internal/agent/\(fixture.agentA)/reminders", nil),
        (.post, "/internal/agent/\(fixture.agentA)/reminders", "{}"),
        (.delete, "/internal/agent/\(fixture.agentA)/reminders/r-1", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/reminders/r-1/snooze", "{}"),
        (.patch, "/internal/agent/\(fixture.agentA)/reminders/r-1", "{}"),
        (.get, "/internal/agent/\(fixture.agentA)/reminders/r-1/log", nil),
        (.post, "/internal/agent/\(fixture.agentA)/send", "{\"target\":\"#gate-room\",\"content\":\"probe\"}"),
        (.post, "/internal/agent/\(fixture.agentA)/receive-ack", "{\"seqs\":[1]}"),
        (.post, "/internal/agent/\(fixture.agentA)/runtime-profile/migration-done", "{}"),
        (.get, "/internal/agent/\(fixture.agentA)/server", nil),
        (.patch, "/internal/agent/\(fixture.agentA)/server", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/channels", "{}"),
        (.patch, "/internal/agent/\(fixture.agentA)/channels/c-1", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/channels/c-1/members", "{}"),
        (.delete, "/internal/agent/\(fixture.agentA)/channels/c-1/members", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/channels/c-1/join", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/channels/c-1/leave", "{}"),
        (.get, "/internal/agent/\(fixture.agentA)/channel-members?channel=%23gate-room", nil),
        (.get, "/internal/agent/\(fixture.agentA)/history?channel=%23gate-room", nil),
        (.post, "/internal/agent/\(fixture.agentA)/tasks", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/tasks/claim", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/tasks/update-status", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/tasks/delete", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/tasks/convert", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/messages/m-1/reactions", "{}"),
        (.delete, "/internal/agent/\(fixture.agentA)/messages/m-1/reactions", "{}"),
        (.post, "/internal/agent/\(fixture.agentA)/threads/unfollow", "{}"),
        (.get, "/internal/agent/\(fixture.agentA)/search?q=probe", nil),
        (.post, "/internal/agent/\(fixture.agentA)/upload", ""),
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            for route in routes {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(fixture.machineKeyB)"
                if route.body != nil { headers[.contentType] = "application/json" }
                let response = try await client.send(route.method, headers: headers, to: URI(string: route.path)) { request in
                    if let body = route.body { request.body = .init(string: body) }
                }
                #expect(response.status == .forbidden, "\(route.method) \(route.path)")
                #expect(gateJSON(response)["error"] as? String
                    == "This agent is not assigned to your machine", "\(route.method) \(route.path)")
            }
        }
    }
}

@Test func agentApiTaskListChecksCapabilityThenTheKeyedGrant() async throws {
    let fixture = makeLegacyMachineGateFixture("06")
    let readOnlyKey = fixture.accounts.mintAgentCredential(
        agentId: fixture.agentA, scopes: ["read"], name: "gate-read-only-06"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            func list(_ key: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                return try await client.get(URI(string: "/internal/agent-api/tasks?channel=%23gate-room"), headers: headers)
            }

            let noCapability = try await list(readOnlyKey)
            #expect(noCapability.status == .forbidden)
            let capabilityBody = gateJSON(noCapability)
            #expect(capabilityBody["error"] as? String
                == "Agent credential is not authorized for this capability")
            #expect(capabilityBody["code"] as? String == "capability_not_authorized")
            #expect(capabilityBody["requiredCapability"] as? String == "tasks")

            fixture.accounts.setAgentGrantsForTesting(
                agentId: fixture.agentA, scopes: ["task:write"]
            )
            let noGrant = try await list(fixture.credentialKey)
            #expect(noGrant.status == .forbidden)
            let grantBody = gateJSON(noGrant)
            #expect(grantBody["error"] as? String == "missing required scope")
            #expect(grantBody["requiredScope"] as? String == "task:read")
            #expect(grantBody["reason"] as? String == "missing_scope")
        }
    }
}

@Test func ownedMachineRowReachesTheSearchHandler() async throws {
    let fixture = makeLegacyMachineGateFixture("07")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.machineKeyA)"
            let search = try await client.get(
                URI(string: "/internal/agent/\(fixture.agentA)/search?q=probe"),
                headers: headers
            )
            #expect(search.status == .ok)
            #expect(gateJSON(search)["results"] as? [[String: Any]] != nil)

            let legacy = try await client.get(
                URI(string: "/internal/agent/\(fixture.agentA)/search?q=probe"),
                headers: {
                    var headers = HTTPFields()
                    headers[.authorization] = "Bearer \(fixture.legacyKeyA)"
                    return headers
                }()
            )
            #expect(legacy.status == .ok)
        }
    }
}
