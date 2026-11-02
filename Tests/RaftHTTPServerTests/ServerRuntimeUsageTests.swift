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
