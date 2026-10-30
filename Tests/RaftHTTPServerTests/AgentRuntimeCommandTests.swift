import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func runtimeCommandIsRejectedOutsideClaudeAndPatchUpdatesThePresetModel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111276"
    let serverId = "33333333-3333-4333-8333-333333333463"
    accounts.addAccount(id: ownerId, email: "runtime-command@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-command", name: "Runtime Command Server", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"runtime-command@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let rejected = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"runtime-command-agent\",\"runtimeConfig\":{\"version\":1,\"runtime\":\"codex\",\"command\":\"codex-alt\",\"model\":{\"kind\":\"preset\",\"id\":\"gpt-5.5\"},\"mode\":{\"kind\":\"default\"},\"reasoningEffort\":null,\"envVars\":null}}")
            }
            #expect(rejected.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((rejected.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "runtimeConfig.command is not supported for runtime: codex")

            let created = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"runtime-dynamic-model-agent\",\"runtimeConfig\":{\"version\":1,\"runtime\":\"codex\",\"model\":{\"kind\":\"preset\",\"id\":\"gpt-5.5\"},\"mode\":{\"kind\":\"default\"},\"reasoningEffort\":null,\"envVars\":null}}")
            }
            #expect(created.status == .ok)
            let createdId = (try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            let patched = try await client.send(.patch, headers: headers, to: "/api/agents/\(createdId)") { request in
                request.body = .init(string: "{\"runtime\":\"codex\",\"model\":\"gpt-5.6-sol\",\"runtimeConfig\":{\"version\":1,\"runtime\":\"codex\",\"model\":{\"kind\":\"preset\",\"id\":\"gpt-5.6-sol\"},\"mode\":{\"kind\":\"default\"},\"reasoningEffort\":null,\"envVars\":null},\"reasoningEffort\":null}")
            }
            #expect(patched.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((patched.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["model"] as? String == "gpt-5.6-sol")
            #expect((body?["runtimeConfig"] as? [String: Any])?["model"].flatMap { ($0 as? [String: Any])?["id"] as? String } == "gpt-5.6-sol")

            let get = try await client.send(.get, headers: headers, to: "/api/agents/\(createdId)")
            #expect((try JSONSerialization.jsonObject(with: Data((get.body.string ?? "").utf8)) as? [String: Any])?["model"] as? String == "gpt-5.6-sol")
        }
    }
}
