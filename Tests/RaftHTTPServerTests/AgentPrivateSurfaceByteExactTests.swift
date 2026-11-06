import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Locks the bytes (status, headers that matter, exact body text) of the agent
/// private-surface routes the typed service now answers. The expected strings are
/// the member order and escaping the retired string-built handlers printed.

private let ownerId = "11111111-1111-4111-8111-111111111791"
private let serverId = "33333333-3333-4333-8333-333333333791"

private func makeFixture() -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: ownerId, email: "byte-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "byte-surface", name: "Byte Surface", ownerId: ownerId)
    return accounts
}

private func withRoutes(
    _ accounts: EmailLoginDirectory,
    _ body: @escaping (_ call: @escaping (HTTPRequest.Method, String, String?) async throws -> ClientResponse) async throws -> Void
) async throws {
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            try await body { method, path, json in
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                headers[.contentType] = "application/json"
                return try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let json { request.body = .init(string: json) }
                }
            }
        }
    }
}

@Test func createAgentPublishesTheExactMemberOrderAndEscaping() async throws {
    let accounts = makeFixture()
    try await withRoutes(accounts) { call in
        let plain = try await call(.post, "/api/agents", """
        {"name":"byte-agent","runtimeConfig":{"runtime":"claude","model":{"kind":"preset","id":"opus"}}}
        """)
        #expect(plain.status == .ok)
        let plainBody = plain.body.string ?? ""
        let plainObject = try JSONSerialization.jsonObject(with: Data(plainBody.utf8)) as? [String: Any]
        let plainId = plainObject?["id"] as? String ?? ""
        #expect(plainBody == "{\"id\":\"\(plainId)\",\"name\":\"byte-agent\",\"runtime\":\"claude\",\"model\":\"opus\",\"external\":false,\"machineId\":null,\"reasoningEffort\":null,\"envVars\":{},\"runtimeConfig\":{\"envVars\":{},\"mode\":{\"kind\":\"default\"},\"model\":{\"id\":\"opus\",\"kind\":\"preset\"},\"reasoningEffort\":null,\"runtime\":\"claude\",\"version\":1},\"creator\":{\"type\":\"human\",\"id\":\"\(ownerId)\"},\"displayName\":\"byte-agent\",\"description\":null,\"avatarUrl\":null,\"serverRole\":\"member\"}")
        #expect(plain.headers[HTTPField.Name("Content-Length")!] == String(plainBody.utf8.count))

        // The stored config text keeps `JSONSerialization`'s slash escaping and
        // blanks the provider key in the reply; the derived env keeps the key.
        let custom = try await call(.post, "/api/agents", """
        {"name":"byte-custom","runtimeConfig":{"runtime":"claude","model":{"kind":"preset","id":"opus"},"provider":{"kind":"custom","apiUrl":"https://x.example/v1","apiKey":"k-1"}}}
        """)
        let customBody = custom.body.string ?? ""
        let customId = (try JSONSerialization.jsonObject(with: Data(customBody.utf8)) as? [String: Any])?["id"] as? String ?? ""
        #expect(customBody == "{\"id\":\"\(customId)\",\"name\":\"byte-custom\",\"runtime\":\"claude\",\"model\":\"opus\",\"external\":false,\"machineId\":null,\"reasoningEffort\":null,\"envVars\":{\"ANTHROPIC_API_KEY\":\"k-1\",\"ANTHROPIC_BASE_URL\":\"https:\\/\\/x.example\\/v1\"},\"runtimeConfig\":{\"envVars\":{},\"mode\":{\"kind\":\"default\"},\"model\":{\"id\":\"opus\",\"kind\":\"preset\"},\"provider\":{\"apiKey\":\"\",\"apiUrl\":\"https:\\/\\/x.example\\/v1\",\"kind\":\"custom\"},\"reasoningEffort\":null,\"runtime\":\"claude\",\"version\":1},\"creator\":{\"type\":\"human\",\"id\":\"\(ownerId)\"},\"displayName\":\"byte-custom\",\"description\":null,\"avatarUrl\":null,\"serverRole\":\"member\"}")
        #expect(accounts.agentRuntimeConfigForTesting(agentId: customId)?.contains("\"apiKey\":\"k-1\"") == true)

        let external = try await call(.post, "/api/agents", "{\"name\":\"byte-external\",\"external\":true}")
        let externalBody = external.body.string ?? ""
        let externalId = (try JSONSerialization.jsonObject(with: Data(externalBody.utf8)) as? [String: Any])?["id"] as? String ?? ""
        #expect(externalBody == "{\"id\":\"\(externalId)\",\"name\":\"byte-external\",\"runtime\":\"external\",\"model\":\"external\",\"external\":true,\"machineId\":null,\"reasoningEffort\":null,\"envVars\":null,\"runtimeConfig\":{\"envVars\":null,\"mode\":{\"kind\":\"default\"},\"model\":{\"id\":\"external\",\"kind\":\"preset\"},\"reasoningEffort\":null,\"runtime\":\"external\",\"version\":1},\"creator\":{\"type\":\"human\",\"id\":\"\(ownerId)\"},\"displayName\":\"byte-external\",\"description\":null,\"avatarUrl\":null,\"serverRole\":\"member\"}")
    }
}

@Test func agentPrivateSurfaceRefusalsPublishTheirExactBodies() async throws {
    let accounts = makeFixture()
    try await withRoutes(accounts) { call in
        let reserved = try await call(.post, "/api/agents", "{\"name\":\"Here\"}")
        #expect(reserved.status == .badRequest)
        #expect(reserved.body.string == "{\"error\":\"This username is reserved. Choose another name.\"}")

        let invalid = try await call(.post, "/api/agents", "[]")
        #expect(invalid.status == .badRequest)
        #expect(invalid.body.string == "{\"error\":\"Invalid Agent\"}")

        let deprecated = try await call(.post, "/api/agents", "{\"name\":\"dep\",\"runtime\":\"kimi\"}")
        #expect(deprecated.body.string == "{\"error\":\"Runtime is deprecated and cannot be selected: kimi\"}")

        let provider = try await call(.post, "/api/agents", "{\"name\":\"prov\",\"external\":true,\"provider\":\"antiproton\"}")
        #expect(provider.status == .forbidden)
        #expect(provider.body.string == "{\"error\":\"The hosted runtime provider is not enabled for this server\",\"code\":\"agent_runtime_provider_disabled\"}")

        let missing = try await call(.get, "/api/agents/22222222-2222-4222-8222-222222222222/runtime-options", nil)
        #expect(missing.status == .notFound)
        #expect(missing.body.string == "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")

        let login = try await call(.post, "/api/agent/login", "{}")
        #expect(login.status == .notFound)
        #expect(login.body.string == "{\"error\":\"Self-hosted runner bootstrap is not enabled\",\"code\":\"self_hosted_runner_bootstrap_disabled\"}")
    }
}

@Test func agentReadsAndStatusPublishTheirExactBodies() async throws {
    let accounts = makeFixture()
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "byte-reader", creatorUserId: ownerId)
    let externalId = accounts.oauth.createAgent(
        serverId: serverId, name: "byte-ext", creatorUserId: ownerId,
        runtime: "external", runtimeConfigJSON: "{}", envVarsJSON: "null"
    )
    try await withRoutes(accounts) { call in
        let options = try await call(.get, "/api/agents/\(agentId)/runtime-options", nil)
        #expect(options.body.string == "{\"agentId\":\"\(agentId)\",\"runtimes\":[],\"models\":[]}")

        let manageable = try await call(.get, "/api/agents/manageable", nil)
        let manageableBody = manageable.body.string ?? ""
        #expect(manageableBody.hasPrefix("{\"ok\":true,\"data\":{\"agents\":["))
        #expect(manageableBody.hasSuffix("],\"reason\":\"ok\",\"manageable_server_count\":1}}"))

        let status = try await call(.get, "/api/agents/\(externalId)/external-status", nil)
        #expect(status.body.string == "{\"setupState\":\"waiting_for_login\",\"credentialLastUsedAt\":null,\"lastActivityAt\":null}")

        let notExternal = try await call(.get, "/api/agents/\(agentId)/external-status", nil)
        #expect(notExternal.status == .badRequest)
        #expect(notExternal.body.string == "{\"error\":\"Agent is not external\"}")

        let bootstrap = try await call(.post, "/api/agents/\(externalId)/bootstrap-tokens", "{}")
        #expect(bootstrap.status == .created)
        #expect(bootstrap.body.string == "{\"token\":\"bootstrap-disabled\",\"createdAt\":\"1970-01-01T00:00:00.000Z\",\"scopes\":[\"channels\",\"knowledge\",\"mentions\",\"reactions\",\"read\",\"send\",\"tasks\"]}")

        let wrongKind = try await call(.post, "/api/agents/\(agentId)/bootstrap-tokens", "{}")
        #expect(wrongKind.body.string == "{\"code\":\"agent_not_external\",\"error\":\"Only external Agents get bootstrap tokens\"}")

        let badMode = try await call(.patch, "/api/agents/\(agentId)", "{\"restartMode\":\"a\\\"b\"}")
        #expect(badMode.status == .badRequest)
        // The retired handler interpolated the mode unescaped; the bytes stay.
        #expect(badMode.body.string == "{\"error\":\"Invalid restart mode: a\"b\"}")

        let creator = try await call(.patch, "/api/agents/\(agentId)/creator", "{\"creatorType\":\"user\",\"creatorId\":\"\(ownerId)\"}")
        #expect(creator.body.string == "{\"creator\":{\"type\":\"human\",\"id\":\"\(ownerId)\"}}")

        let patched = try await call(.patch, "/api/agents/\(agentId)", "{\"description\":\"hello/world\",\"displayName\":\"Byte\"}")
        #expect(patched.status == .ok)
        let patchedBody = patched.body.string ?? ""
        #expect(patchedBody.hasPrefix("{\"id\":\"\(agentId)\",\"name\":\"byte-reader\",\"displayName\":\"Byte\",\"model\":\"\",\"runtime\":"))
        #expect(patchedBody.contains("\"description\":\"hello/world\",\"avatarUrl\":null,\"serverRole\":\"member\",\"runtimeConfig\":"))
    }
}

@Test func assistantOwnerReadsPublishTheirExactBodies() async throws {
    let accounts = makeFixture()
    accounts.createFeatureFlagForTesting(key: "identity_borrowing", defaultEnabled: true)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "byte-assistant", creatorUserId: ownerId)
    try await withRoutes(accounts) { call in
        let put = try await call(.put, "/api/agents/\(agentId)/assistant-owner", nil)
        #expect(put.body.string == "{\"assistantOf\":{\"userId\":\"\(ownerId)\"}}")
        let delete = try await call(.delete, "/api/agents/\(agentId)/assistant-owner", nil)
        #expect(delete.body.string == "{\"assistantOf\":null}")
    }
}
