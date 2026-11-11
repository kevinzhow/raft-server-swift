import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func runtimeProfileMigrationDoneReturnsDeprecatedShapes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111881001"
    let serverId = "33333333-3333-4333-8333-333333881001"
    accounts.addAccount(id: ownerId, email: "runtime-profile-owner-881@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-profile-route", name: "Runtime Profile Route", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "runtime-profile-agent-881", runtime: "codex")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "runtime-profile-machine-881")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    let machineKey = accounts.machineAPIKey(machineId: machine) ?? ""

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func migrationDone(_ body: String, key: String? = nil) async throws -> ClientResponse {
                let key = key ?? machineKey
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Agent-Launch-Id")!] = "legacy-launch"
                return try await client.send(.post, headers: headers, to: "/internal/agent/\(agent)/runtime-profile/migration-done") { request in
                    request.body = .init(string: body)
                }
            }
            func payload(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let message = "Runtime Profile migration acknowledgments are deprecated; runtime changes reset the session automatically."

            let noop = try await migrationDone("{\"migrationKey\":\"\"}")
            #expect(noop.status == .ok)
            #expect(payload(noop)["ok"] as? Bool == true)
            #expect(payload(noop)["deprecated"] as? Bool == true)
            #expect(payload(noop)["noop"] as? String == "no pending migration")
            #expect(payload(noop)["message"] as? String == message)

            let handled = try await migrationDone("{\"migrationKey\":\"legacy-key\"}")
            #expect(handled.status == .ok)
            #expect(payload(handled)["ok"] as? Bool == true)
            #expect(payload(handled)["deprecated"] as? Bool == true)
            #expect(payload(handled)["noop"] == nil)
            #expect(payload(handled)["message"] as? String == message)

            let invalidKey = try await migrationDone("{\"migrationKey\":\"\"}", key: "mk_not_a_key")
            #expect(invalidKey.status == .unauthorized)
            #expect(payload(invalidKey)["error"] as? String
                == "Invalid authentication: machine API key required")
            #expect(payload(invalidKey)["code"] == nil)
        }
    }
}
