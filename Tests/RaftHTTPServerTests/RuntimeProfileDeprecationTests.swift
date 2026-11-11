import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func runtimeProfileMigrationAcknowledgmentsAreDeprecated() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111425"
    let serverId = "33333333-3333-4333-8333-333333333547"
    accounts.addAccount(id: ownerId, email: "runtime-profile@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-profile", name: "Runtime Profile", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "runtime-profile-agent")
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "runtime-profile-machine")
    accounts.assignAgentMachineForTesting(agentId: agentId, machineId: machineId)
    let apiKey = accounts.machineAPIKey(machineId: machineId) ?? ""
    let message = "Runtime Profile migration acknowledgments are deprecated; runtime changes reset the session automatically."

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func done(_ key: String, _ body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Agent-Launch-Id")!] = "legacy-launch"
                return try await client.send(.post, headers: headers, to: "/internal/agent/\(agentId)/runtime-profile/migration-done") { request in
                    request.body = .init(string: body)
                }
            }
            func json(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let noop = try await done(apiKey, "{\"migrationKey\":\"\"}")
            #expect(noop.status == .ok)
            let noopBody = try json(noop)
            #expect(noopBody["ok"] as? Bool == true)
            #expect(noopBody["deprecated"] as? Bool == true)
            #expect(noopBody["noop"] as? String == "no pending migration")
            #expect(noopBody["message"] as? String == message)

            let handled = try await done(apiKey, "{\"migrationKey\":\"legacy-key\"}")
            #expect(handled.status == .ok)
            let handledBody = try json(handled)
            #expect(Set(handledBody.keys) == ["ok", "deprecated", "message"])
            #expect(handledBody["message"] as? String == message)

            #expect(try await done("invalid-key", "{}").status == .unauthorized)
        }
    }
}
