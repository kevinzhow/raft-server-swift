import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func externalAgentPinsTheSentinelRuntimeAndRefusesAComputer() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111273"
    let serverId = "33333333-3333-4333-8333-333333333460"
    accounts.addAccount(id: ownerId, email: "external-create@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "external-create", name: "External Create Server", ownerId: ownerId)
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "available-machine")

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
                request.body = .init(string: "{\"email\":\"external-create@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let create = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"external-api-agent\",\"external\":true,\"runtime\":\"claude\",\"model\":\"sonnet\",\"runtimeConfig\":{\"version\":1,\"runtime\":\"claude\",\"provider\":{\"kind\":\"custom\",\"apiUrl\":\"https://gateway.example.test/v1\",\"apiKey\":\"sk-ant-test\"},\"model\":{\"kind\":\"preset\",\"id\":\"sonnet\"},\"mode\":{\"kind\":\"fast\"},\"reasoningEffort\":\"high\",\"envVars\":{\"SHOULD_DROP\":\"true\"}},\"reasoningEffort\":\"high\",\"envVars\":{\"SHOULD_DROP\":\"true\"},\"avatarUrl\":\"pixel:external-create\"}")
            }
            #expect(create.status == .ok)
            let created = try JSONSerialization.jsonObject(with: Data((create.body.string ?? "").utf8)) as? [String: Any]
            let createdId = created?["id"] as? String ?? ""
            #expect(created?["external"] as? Bool == true)
            #expect(created?["runtime"] as? String == "external")
            #expect(created?["model"] as? String == "external")
            #expect(created?["machineId"] == nil || created?["machineId"] is NSNull)
            #expect(created?["reasoningEffort"] == nil || created?["reasoningEffort"] is NSNull)
            #expect(created?["envVars"] == nil || created?["envVars"] is NSNull)
            let config = created?["runtimeConfig"] as? [String: Any]
            #expect(config?["runtime"] as? String == "external")
            #expect((config?["model"] as? [String: Any])?["id"] as? String == "external")
            #expect((config?["mode"] as? [String: Any])?["kind"] as? String == "default")
            #expect(config?["reasoningEffort"] == nil || config?["reasoningEffort"] is NSNull)
            #expect(config?["envVars"] == nil || config?["envVars"] is NSNull)

            let list = try await client.send(.get, headers: headers, to: "/api/agents")
            let rows = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.first { $0["id"] as? String == createdId }?["external"] as? Bool == true)

            let withMachine = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"external-machine-rejected\",\"external\":true,\"machineId\":\"\(machineId)\"}")
            }
            #expect(withMachine.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((withMachine.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "External agents cannot be assigned to a Computer")
        }
    }
}
