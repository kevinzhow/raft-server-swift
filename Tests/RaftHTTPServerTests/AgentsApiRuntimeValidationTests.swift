import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct RuntimeValidationFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let ownerId: String
    let token: String
}

private func makeRuntimeValidationFixture(_ suffix: String) -> RuntimeValidationFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001050\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001050\(suffix)"
    let slug = "runtime-validation-\(suffix)"
    accounts.addAccount(id: ownerId, email: "runtime-validation-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Runtime Validation \(suffix)", ownerId: ownerId)
    return RuntimeValidationFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: slug,
        ownerId: ownerId,
        token: accounts.mintAccessTokenForTesting(userId: ownerId)
    )
}

private func runtimeHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func runtimeObject(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func agentCreateRejectsCursorProviderConfig() async throws {
    let f = makeRuntimeValidationFixture("001")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.send(.post, headers: runtimeHeaders(f.token, f.serverId), to: "/api/agents") { request in
                request.body = .init(string: """
                {"name":"cursor-provider-agent-001","runtimeConfig":{"version":1,"runtime":"cursor","provider":{"kind":"custom","apiUrl":"https://gateway.example.test/v1","apiKey":"sk-ant-test"},"model":{"kind":"custom","name":"custom-cursor-model"}}}
                """)
            }
            #expect(response.status == .badRequest)
            #expect(try runtimeObject(response)["error"] as? String == "runtimeConfig.provider is not supported for runtime: cursor")
        }
    }
}

@Test func agentCreateRejectsMalformedStructuredRuntimeConfig() async throws {
    let f = makeRuntimeValidationFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let missingModelName = try await client.send(.post, headers: runtimeHeaders(f.token, f.serverId), to: "/api/agents") { request in
                request.body = .init(string: """
                {"name":"bad-runtime-config-agent-002","runtimeConfig":{"version":1,"runtime":"claude","model":{"kind":"custom"}}}
                """)
            }
            #expect(missingModelName.status == .badRequest)
            #expect(try runtimeObject(missingModelName)["error"] as? String == "runtimeConfig.model.name is required")

            let missingProviderKey = try await client.send(.post, headers: runtimeHeaders(f.token, f.serverId), to: "/api/agents") { request in
                request.body = .init(string: """
                {"name":"bad-provider-key-agent-002","runtimeConfig":{"version":1,"runtime":"claude","provider":{"kind":"custom","apiUrl":"https://gateway.example.test/v1"},"model":{"kind":"preset","id":"sonnet"}}}
                """)
            }
            #expect(missingProviderKey.status == .badRequest)
            #expect(try runtimeObject(missingProviderKey)["error"] as? String == "runtimeConfig.provider.apiKey is required")
        }
    }
}

@Test func agentCreateRejectsDeprecatedRuntimes() async throws {
    let f = makeRuntimeValidationFixture("003")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let legacy = try await client.send(.post, headers: runtimeHeaders(f.token, f.serverId), to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"legacy-kimi-agent-003\",\"runtime\":\"kimi\"}")
            }
            #expect(legacy.status == .badRequest)
            #expect(try runtimeObject(legacy)["error"] as? String == "Runtime is deprecated and cannot be selected: kimi")

            let structured = try await client.send(.post, headers: runtimeHeaders(f.token, f.serverId), to: "/api/agents") { request in
                request.body = .init(string: """
                {"name":"structured-gemini-agent-003","runtimeConfig":{"version":1,"runtime":"gemini","model":{"kind":"custom","name":"gemini-pro"}}}
                """)
            }
            #expect(structured.status == .badRequest)
            #expect(try runtimeObject(structured)["error"] as? String == "Runtime is deprecated and cannot be selected: gemini")
        }
    }
}

@Test func agentPatchRejectsDeprecatedTransitionsButKeepsTheCurrentLegacyRuntime() async throws {
    let f = makeRuntimeValidationFixture("004")
    let accounts = f.accounts
    let active = accounts.oauth.createAgent(serverId: f.serverId, name: "active-codex-agent-004", runtime: "codex")
    let legacy = accounts.oauth.createAgent(serverId: f.serverId, name: "existing-kimi-agent-004", runtime: "kimi")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func patch(_ agentId: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: runtimeHeaders(f.token, f.serverId), to: URI(string: "/api/agents/\(agentId)")) { request in
                    request.body = .init(string: body)
                }
            }
            let legacyTransition = try await patch(active, "{\"runtime\":\"kimi\"}")
            #expect(legacyTransition.status == .badRequest)
            #expect(try runtimeObject(legacyTransition)["error"] as? String == "Runtime is deprecated and cannot be selected: kimi")

            let structuredTransition = try await patch(active, """
            {"runtimeConfig":{"version":1,"runtime":"gemini","model":{"kind":"custom","name":"gemini-pro"}}}
            """)
            #expect(structuredTransition.status == .badRequest)
            #expect(try runtimeObject(structuredTransition)["error"] as? String == "Runtime is deprecated and cannot be selected: gemini")
            #expect(accounts.oauth.agentRuntimeInfo(id: active)?.runtime == "codex")

            let sameLegacy = try await patch(legacy, """
            {"description":"keeps existing legacy runtime","runtimeConfig":{"version":1,"runtime":"kimi","model":{"kind":"custom","name":"kimi-k2"}}}
            """)
            #expect(sameLegacy.status == .ok)
            let body = try runtimeObject(sameLegacy)
            #expect(body["description"] as? String == "keeps existing legacy runtime")
            #expect(body["runtime"] as? String == "kimi")
            let model = ((body["runtimeConfig"] as? [String: Any])?["model"] as? [String: Any])
            #expect(model?["kind"] as? String == "custom")
            #expect(model?["name"] as? String == "kimi-k2")
        }
    }
}
