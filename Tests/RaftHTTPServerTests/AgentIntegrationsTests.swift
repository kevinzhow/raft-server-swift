import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentIntegrationsDiscoverAndLogInWithTheBoundIdentity() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001031001"
    let ownerId = "11111111-1111-4111-8111-000001031001"
    accounts.addAccount(id: ownerId, email: "integration-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "integration", name: "Integration", ownerId: ownerId)
    let createdClient = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Example Daily",
        clientId: "example-daily-demo",
        description: "Demo app",
        homepageUrl: "https://demo.example.test",
        returnUrl: "https://demo.example.test/login/callback",
        agentManifestUrl: "https://demo.example.test/.well-known/slock-agent-manifest.json"
    )
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "IntegrationBot", runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "integration")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            func list() async throws -> [String: Any] {
                let response = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: headers)
                #expect(response.status == .ok)
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            func login() async throws -> [String: Any] {
                let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/integrations/login") { request in
                    request.body = .init(string: "{\"service\":\"example-daily-demo\"}")
                }
                #expect(response.status == .ok)
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            let before = try await list()
            let services = try #require(before["services"] as? [[String: Any]])
            #expect(services.count == 1)
            #expect(services[0]["id"] as? String == createdClient.id)
            #expect(services[0]["clientId"] as? String == "example-daily-demo")
            #expect(services[0]["agentManifestUrl"] as? String == "https://demo.example.test/.well-known/slock-agent-manifest.json")
            #expect(services[0]["agentManifestUrlSource"] as? String == "explicit")
            #expect((before["activeLogins"] as? [[String: Any]])?.isEmpty == true)

            let loggedIn = try await login()
            #expect(loggedIn["status"] as? String == "logged_in")
            #expect((loggedIn["service"] as? [String: Any])?["id"] as? String == createdClient.id)
            #expect(loggedIn["scopes"] as? [String] == ["identity", "openid", "profile"])

            let after = try await list()
            let active = try #require(after["activeLogins"] as? [[String: Any]])
            #expect(active.map { $0["clientId"] as? String } == ["example-daily-demo"])
            #expect(active.map { $0["agentManifestUrl"] as? String } == ["https://demo.example.test/.well-known/slock-agent-manifest.json"])
            #expect(active.map { $0["agentManifestUrlSource"] as? String } == ["explicit"])

            let repeatLogin = try await login()
            #expect(repeatLogin["status"] as? String == "already_logged_in")
        }
    }
}

@Test func agentIntegrationLoginUsesServiceAwareDefaultScopes() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001031002"
    let ownerId = "11111111-1111-4111-8111-000001031002"
    accounts.addAccount(id: ownerId, email: "integration-scope-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "integration-scope", name: "Integration Scope", ownerId: ownerId)
    _ = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Scoped App",
        clientId: "scoped-app",
        appType: "server_local",
        allowedScopes: ["openid", "profile", "identity"]
    )
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ScopeBot", runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "scope")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            func login(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/internal/agent-api/integrations/login") { request in
                    request.body = .init(string: body)
                }
            }
            let defaultLogin = try await login("{\"service\":\"scoped-app\"}")
            #expect(defaultLogin.status == .ok)
            let defaultBody = (try JSONSerialization.jsonObject(with: Data((defaultLogin.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(defaultBody["scopes"] as? [String] == ["openid"])

            let invalid = try await login("{\"service\":\"scoped-app\",\"scopes\":[\"profile\"]}")
            #expect(invalid.status == .badRequest)
            let invalidBody = (try JSONSerialization.jsonObject(with: Data((invalid.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(invalidBody["errorCode"] as? String == "INVALID_SCOPE")

            let explicit = try await login("{\"service\":\"scoped-app\",\"scopes\":[\"openid\"]}")
            #expect(explicit.status == .ok)
            #expect(((try JSONSerialization.jsonObject(with: Data((explicit.body.string ?? "").utf8))) as? [String: Any])?["scopes"] as? [String] == ["openid"])
        }
    }
}
