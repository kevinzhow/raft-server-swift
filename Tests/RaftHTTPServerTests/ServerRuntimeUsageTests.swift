import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class RuntimeUsageBehavior: @unchecked Sendable {
    var value = "fresh"
}

private struct RuntimeFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let adminEmail: String
    let memberId: String
    let memberEmail: String
    let bystanderEmail: String
    let machineId: String
}

private func makeRuntimeFixture(suffix: String) -> RuntimeFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 600_001 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 600_001 + number)
    let memberId = String(format: "11111111-1111-4111-8111-%012d", 601_001 + number)
    let bystanderId = String(format: "11111111-1111-4111-8111-%012d", 602_001 + number)
    let ownerEmail = "runtime-owner-\(suffix)@slock.test"
    let adminEmail = "runtime-admin-\(suffix)@slock.test"
    let memberEmail = "runtime-member-\(suffix)@slock.test"
    let bystanderEmail = "runtime-bystander-\(suffix)@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail), (bystanderId, bystanderEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-\(suffix)", name: "Runtime", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: bystanderId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "runtime-computer-\(suffix)")
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, online: true, attachedByUserId: memberId)
    accounts.setMachineOnline(machineId: machine, online: true)
    return RuntimeFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        adminEmail: adminEmail,
        memberId: memberId,
        memberEmail: memberEmail,
        bystanderEmail: bystanderEmail,
        machineId: machine
    )
}

private func runtimeLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func runtimeHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func runtimeObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func machineRuntimeOptionsAndModelsRespectAuthority() async throws {
    let fixture = makeRuntimeFixture(suffix: "996")
    fixture.accounts.setMachineRuntimeModels(machineId: fixture.machineId, runtime: "codex", models: [("gpt-5.4", "GPT 5.4")])
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await runtimeLogin(client, email: fixture.ownerEmail)
            let member = try await runtimeLogin(client, email: fixture.memberEmail)
            let bystander = try await runtimeLogin(client, email: fixture.bystanderEmail)
            let optionsPath = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-options"
            let ownerOptions = try await client.get(URI(string: optionsPath), headers: runtimeHeaders(owner, fixture.serverId))
            #expect(ownerOptions.status == .ok)
            let ownerBody = try runtimeObject(ownerOptions)
            #expect(ownerBody["context"] as? String == "new_agent")
            let options = ownerBody["options"] as? [[String: Any]] ?? []
            #expect(options.contains { $0["runtimeId"] as? String == "codex" })
            #expect(try await client.get(URI(string: optionsPath), headers: runtimeHeaders(member, fixture.serverId)).status == .forbidden)
            #expect(try await client.get(URI(string: optionsPath), headers: runtimeHeaders(bystander, fixture.serverId)).status == .forbidden)

            let modelsPath = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-models/codex"
            let models = try await client.get(URI(string: modelsPath), headers: runtimeHeaders(owner, fixture.serverId))
            #expect(models.status == .ok)
            #expect(try runtimeObject(models) as NSDictionary == [
                "kind": "live",
                "value": ["models": [["id": "gpt-5.4", "label": "GPT 5.4"]], "default": "gpt-5.4"],
                "models": [["id": "gpt-5.4", "label": "GPT 5.4"]],
                "default": "gpt-5.4",
            ] as NSDictionary)
            #expect(try await client.get(URI(string: modelsPath), headers: runtimeHeaders(bystander, fixture.serverId)).status == .forbidden)

            let rescanPath = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtimes/rescan"
            #expect(try await client.send(.post, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: rescanPath)).status == .ok)
            fixture.accounts.setMachineOnline(machineId: fixture.machineId, online: false)
            #expect(try await client.send(.post, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: rescanPath)).status == .conflict)
        }
    }
}

@Test func runtimeAccountUsageReadsAndManualRefreshStates() async throws {
    let fixture = makeRuntimeFixture(suffix: "997")
    let snapshot = "{\"protocolVersion\":2,\"provider\":\"codex\",\"collectedAt\":\"2026-11-01T00:00:00.000Z\",\"staleAfter\":\"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(1800)))\",\"collectorVersion\":\"1.6.2\",\"accounts\":[]}"
    let behavior = RuntimeUsageBehavior()
    fixture.accounts.runtimeAccountUsageManualRefresh = { _, _ in
        behavior.value == "timeout" ? .timeout : .snapshot(json: snapshot)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await runtimeLogin(client, email: fixture.ownerEmail)
            let member = try await runtimeLogin(client, email: fixture.memberEmail)
            let bystander = try await runtimeLogin(client, email: fixture.bystanderEmail)
            let url = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-account-usage/codex"
            let missing = try await client.get(URI(string: url), headers: runtimeHeaders(owner, fixture.serverId))
            #expect(missing.status == .ok)
            #expect(missing.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            #expect(try runtimeObject(missing) as NSDictionary == ["state": "missing", "snapshot": NSNull()] as NSDictionary)
            #expect(try await client.get(URI(string: url), headers: runtimeHeaders(member, fixture.serverId)).status == .ok)
            #expect(try await client.get(URI(string: url), headers: runtimeHeaders(bystander, fixture.serverId)).status == .forbidden)
            #expect(try await client.get(
                URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-account-usage/unknown"),
                headers: runtimeHeaders(owner, fixture.serverId)
            ).status == .notFound)

            let refresh = url + "/refresh"
            func post(_ body: String, _ token: String) async throws -> ClientResponse {
                try await client.send(.post, headers: runtimeHeaders(token, fixture.serverId), to: URI(string: refresh)) { request in
                    request.body = .init(string: body)
                }
            }
            #expect(try await post("{\"reason\":\"stale_or_missing\"}", bystander).status == .forbidden)
            let requested = try await post("{\"reason\":\"stale_or_missing\"}", owner)
            #expect(requested.status == .accepted)
            #expect(try runtimeObject(requested) as NSDictionary == ["accepted": true, "state": "requested"] as NSDictionary)
            let cooldown = try await post("{\"reason\":\"stale_or_missing\"}", owner)
            #expect(cooldown.status == .accepted)
            #expect(try runtimeObject(cooldown)["state"] as? String == "cooldown")

            let kimi = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-account-usage/kimi/refresh"
            let fresh = try await client.send(.post, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: kimi)) { request in
                request.body = .init(string: "{\"reason\":\"manual\"}")
            }
            #expect(fresh.status == .ok)
            let freshBody = try runtimeObject(fresh)
            #expect(freshBody["state"] as? String == "fresh")
            #expect(freshBody["snapshot"] is [String: Any])
            let freshRead = try await client.get(
                URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-account-usage/kimi"),
                headers: runtimeHeaders(owner, fixture.serverId)
            )
            #expect(try runtimeObject(freshRead)["state"] as? String == "fresh")

            behavior.value = "timeout"
            let grok = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-account-usage/grok/refresh"
            let timedOut = try await client.send(.post, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: grok)) { request in
                request.body = .init(string: "{\"reason\":\"manual\"}")
            }
            #expect(timedOut.status == .ok)
            #expect(try runtimeObject(timedOut)["state"] as? String == "timeout")

            fixture.accounts.setMachineOnline(machineId: fixture.machineId, online: false)
            let claude = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)/runtime-account-usage/claude/refresh"
            let offline = try await client.send(.post, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: claude)) { request in
                request.body = .init(string: "{\"reason\":\"manual\"}")
            }
            #expect(offline.status == .accepted)
            #expect(try runtimeObject(offline)["state"] as? String == "computer_offline")
        }
    }
}

@Test func machineDeleteCleansProfilesButRefusesActiveAgents() async throws {
    let fixture = makeRuntimeFixture(suffix: "998")
    let agentId = fixture.accounts.oauth.createAgent(serverId: fixture.serverId, name: "profile-agent-998", runtime: "codex")
    fixture.accounts.setAgentRuntimeProfileForTesting(agentId: agentId, machineId: fixture.machineId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await runtimeLogin(client, email: fixture.ownerEmail)
            let path = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)"
            let blocked = try await client.send(.delete, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: path))
            #expect(blocked.status == .conflict)
            #expect(((try runtimeObject(blocked)["error"] as? String) ?? "").contains("runtime profiles still reference active agents"))
            #expect(fixture.accounts.agentRuntimeProfileMachineId(agentId: agentId) == fixture.machineId)

            fixture.accounts.oauth.deleteAgent(id: agentId)
            let cleaned = try await client.send(.delete, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: path))
            #expect(cleaned.status == .ok)
            #expect(fixture.accounts.agentRuntimeProfileMachineId(agentId: agentId) == nil)

            let staleMachine = fixture.accounts.registerMachine(serverId: fixture.serverId, userId: fixture.ownerId, name: "stale-profile-machine-998")
            let staleAgent = fixture.accounts.oauth.createAgent(serverId: fixture.serverId, name: "stale-agent-998", runtime: "codex")
            fixture.accounts.setAgentRuntimeProfileForTesting(agentId: staleAgent, machineId: staleMachine, staleAfterMigration: true)
            let staleDelete = try await client.send(
                .delete,
                headers: runtimeHeaders(owner, fixture.serverId),
                to: URI(string: "/api/servers/\(fixture.serverId)/machines/\(staleMachine)")
            )
            #expect(staleDelete.status == .ok)
            #expect(fixture.accounts.agentRuntimeProfileMachineId(agentId: staleAgent) == nil)
        }
    }
}

@Test func runtimeFormsServeV2OnlyRuntimesAndRejectV1() async throws {
    let fixture = makeRuntimeFixture(suffix: "999")
    fixture.accounts.setMachineRuntimeModels(machineId: fixture.machineId, runtime: "codex", models: [("gpt-5.4", "GPT 5.4")])
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await runtimeLogin(client, email: fixture.ownerEmail)
            let headers = runtimeHeaders(owner, fixture.serverId)
            let base = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)"

            let piV2 = try await client.get(URI(string: "\(base)/runtime-forms/v2/pi"), headers: headers)
            #expect(piV2.status == .ok)
            #expect(try runtimeObject(piV2)["protocolVersion"] as? Int == 2)
            let piV1 = try await client.get(URI(string: "\(base)/runtime-form-definitions/pi?schemaVersion=pi.create.v1"), headers: headers)
            #expect(piV1.status == .notFound)
            #expect(try runtimeObject(piV1)["issues"] as? NSArray == [[
                "code": "unknown_form_runtime", "pointer": "/runtimeId",
            ]] as NSArray)
            let piSource = try await client.get(URI(string: "\(base)/runtime-forms/v2/pi/option-sources/provider"), headers: headers)
            #expect(piSource.status == .ok)
            #expect(try runtimeObject(piSource)["defaultValue"] as? String == "configured")

            for runtime in ["codex", "grok"] {
                let v2 = try await client.get(URI(string: "\(base)/runtime-forms/v2/\(runtime)"), headers: headers)
                #expect(v2.status == .ok)
                #expect(try runtimeObject(v2)["protocolVersion"] as? Int == 2)
                let v1 = try await client.get(URI(string: "\(base)/runtime-form-definitions/\(runtime)?schemaVersion=\(runtime).create.v1"), headers: headers)
                #expect(v1.status == .notFound)
            }
            let codexModels = try await client.get(URI(string: "\(base)/runtime-forms/v2/codex/option-sources/model"), headers: headers)
            #expect(codexModels.status == .ok)
            #expect(try runtimeObject(codexModels)["optionSource"] as? NSDictionary == ["status": "ready"] as NSDictionary)
            let options = try runtimeObject(codexModels)["options"] as? [[String: Any]] ?? []
            #expect(options.first?["value"] as? String == "gpt-5.4")
        }
    }
}

@Test func machineDeleteRefusesActiveMigrationAndAllowsCompletedCleanup() async throws {
    let fixture = makeRuntimeFixture(suffix: "1000")
    let agentId = fixture.accounts.oauth.createAgent(serverId: fixture.serverId, name: "migration-agent-1000", runtime: "codex")
    fixture.accounts.setAgentRuntimeProfileForTesting(agentId: agentId, machineId: fixture.machineId, staleAfterMigration: true)
    let targetMachine = fixture.accounts.registerMachine(serverId: fixture.serverId, userId: fixture.ownerId, name: "migration-target-1000")
    let migrationId = "22222222-3333-4444-8555-666666667000"
    fixture.accounts.addAgentMigrationForTesting(
        id: migrationId,
        sourceMachineId: fixture.machineId,
        targetMachineId: targetMachine,
        state: "prep"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await runtimeLogin(client, email: fixture.ownerEmail)
            let path = "/api/servers/\(fixture.serverId)/machines/\(fixture.machineId)"
            let blocked = try await client.send(.delete, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: path))
            #expect(blocked.status == .conflict)
            #expect(try runtimeObject(blocked) as NSDictionary == [
                "error": "Cannot delete computer while an agent migration is in progress. Wait for it to finish or abort it first.",
                "code": "MACHINE_HAS_ACTIVE_MIGRATION",
            ] as NSDictionary)

            fixture.accounts.setAgentMigrationStateForTesting(id: migrationId, state: "completed")
            let cleaned = try await client.send(.delete, headers: runtimeHeaders(owner, fixture.serverId), to: URI(string: path))
            #expect(cleaned.status == .ok)
            #expect(fixture.accounts.agentRuntimeProfileMachineId(agentId: agentId) == nil)
        }
    }
}
