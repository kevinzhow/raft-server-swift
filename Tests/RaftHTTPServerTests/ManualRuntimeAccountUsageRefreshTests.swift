import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class ManualRefreshBehavior: @unchecked Sendable {
    enum Mode { case fresh, timeout, offline }
    var mode: Mode = .fresh
}

@Test func manualRuntimeAccountUsageRefreshWaitsAndMapsOutcomes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111666"
    let serverId = "33333333-3333-4333-8333-333333333687"
    accounts.addAccount(id: ownerId, email: "manual-usage@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "manual-usage", name: "Manual Usage", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "manual-usage-machine")
    accounts.setMachineOnline(machineId: machine, online: true)
    let behavior = ManualRefreshBehavior()
    let snapshot = "{\"protocolVersion\":2,\"provider\":\"codex\",\"collectedAt\":\"2026-10-11T08:00:00.000Z\",\"staleAfter\":\"2026-10-11T08:25:00.000Z\",\"collectorVersion\":\"1.6.2\",\"accounts\":[{\"accountKey\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"maskedLabel\":\"man****email@company.com\",\"planLabel\":\"Pro\",\"health\":\"ok\",\"windows\":[]}]}"
    accounts.machinesAndComputersStore.runtimeAccountUsageManualRefresh = { _, _ in
        switch behavior.mode {
        case .fresh: return .snapshot(json: snapshot)
        case .timeout: return .timeout
        case .offline: return .offline
        }
    }

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
                request.body = .init(string: "{\"email\":\"manual-usage@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            func refresh(_ provider: String, reason: String = "manual") async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/machines/\(machine)/runtime-account-usage/\(provider)/refresh") { request in
                    request.body = .init(string: "{\"reason\":\"\(reason)\"}")
                }
            }

            let fresh = try await refresh("codex")
            #expect(fresh.status == .ok)
            let freshBody = try JSONSerialization.jsonObject(with: Data((fresh.body.string ?? "").utf8)) as? [String: Any]
            #expect(freshBody?["accepted"] as? Bool == true)
            #expect(freshBody?["state"] as? String == "fresh")
            #expect((freshBody?["snapshot"] as? [String: Any])?["provider"] as? String == "codex")
            let cooling = try await refresh("codex")
            #expect(cooling.status == .accepted)
            #expect((try JSONSerialization.jsonObject(with: Data((cooling.body.string ?? "").utf8)) as? [String: Any])?["state"] as? String == "cooldown")

            behavior.mode = .timeout
            let timedOut = try await refresh("kimi")
            #expect(timedOut.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((timedOut.body.string ?? "").utf8)) as? [String: Any])?["state"] as? String == "timeout")

            behavior.mode = .offline
            let offline = try await refresh("grok")
            #expect(offline.status == .accepted)
            #expect((try JSONSerialization.jsonObject(with: Data((offline.body.string ?? "").utf8)) as? [String: Any])?["state"] as? String == "computer_offline")

            behavior.mode = .fresh
            let background = try await refresh("claude", reason: "stale_or_missing")
            #expect(background.status == .accepted)
            #expect((try JSONSerialization.jsonObject(with: Data((background.body.string ?? "").utf8)) as? [String: Any])?["state"] as? String == "requested")
        }
    }
}
