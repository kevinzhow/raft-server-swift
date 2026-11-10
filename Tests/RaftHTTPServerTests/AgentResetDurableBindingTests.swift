import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

/// Public refusal proof only. A successful production acceptance additionally
/// needs the actual retained BPR; this test does not install a fake executor.
@Test func resetWithoutTheTypedDurableBindingCannotReturnAccepted() async throws {
    let accounts = EmailLoginDirectory()
    let user = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    accounts.addAccount(id: user, email: "reset-\(user)@slock.test", password: "reset-fixture-password")
    accounts.markEmailVerified(userId: user)
    accounts.oauth.addOwnedServer(id: server, slug: "reset-\(server)", name: "Reset", ownerId: user)
    let agent = accounts.oauth.createAgent(serverId: server, name: "Reset target", creatorUserId: user, runtime: "codex")
    let machine = accounts.registerMachine(serverId: server, userId: user, name: "Unbound metadata only")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["codex"])
    accounts.setMachineOnline(machineId: machine, online: true)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"reset-\(user)@slock.test\",\"password\":\"reset-fixture-password\"}")
            }
            let body = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any]
            let token = try #require(body?["accessToken"] as? String)
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = server
            // A positive200/202 additionally requires the real durable runtime
            // and transports tested in the existing PG/NIO opt-in function.
            let start = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/start")
            #expect(start.status == .internalServerError)
            #expect(start.body.string == #"{"error":"Failed to start agent","code":"internal_error"}"#)
            let stop = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/stop")
            #expect(stop.status == .internalServerError)
            #expect(stop.body.string == #"{"error":"Failed to stop agent"}"#)
            for mode in ["restart", "session", "full"] {
                let response = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/reset") { request in
                    request.body = .init(string: "{\"mode\":\"\(mode)\"}")
                }
                #expect(response.status == .internalServerError)
                #expect(response.status != .accepted)
                #expect(response.body.string == #"{"error":"Failed to reset agent"}"#)
                let value = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                #expect(value?["error"] as? String == "Failed to reset agent")
            }
        }
    }
}
