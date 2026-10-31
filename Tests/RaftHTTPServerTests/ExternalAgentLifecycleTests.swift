import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func externalAgentsRejectManagedLifecycleAndMachineAssignment() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111593"
    let serverId = "33333333-3333-4333-8333-333333333647"
    accounts.addAccount(id: ownerId, email: "external-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "external", name: "External", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "external-agent", runtime: "external")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "ext-machine")

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
                request.body = .init(string: "{\"email\":\"external-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            for action in ["start", "stop", "reset"] {
                let response = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/\(action)") { request in
                    request.body = .init(string: "{\"mode\":\"session\"}")
                }
                #expect(response.status == .badRequest)
                #expect((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "External agents do not use Raft-managed runtime lifecycle")
            }
            let assign = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/assign-machine") { request in
                request.body = .init(string: "{\"machineId\":\"\(machine)\"}")
            }
            #expect(assign.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((assign.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "External agents cannot be assigned to a Computer")
        }
    }
}
