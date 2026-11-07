import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func issuerObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func scopedIssuerReplacesTheServerQueryParameter() async throws {
    let scene = OAuthScene()
    scene.auth.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    scene.auth.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let ownerId = "11111111-1111-4111-8111-111111111238"
    let serverId = "33333333-3333-4333-8333-333333333434"
    let slug = "scoped-oidc-238"
    scene.oauth.addOwnedServer(id: serverId, slug: slug, name: "Scoped OIDC Server", ownerId: ownerId)

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            let scoped = try await client.send(.get, headers: HTTPFields(), to: "/oidc/\(slug)/.well-known/openid-configuration")
            #expect(scoped.status == .ok)
            let scopedDoc = try issuerObject(scoped)
            #expect(scopedDoc["issuer"] as? String == "https://api.raft.test/oidc/\(slug)")
            #expect(scopedDoc["authorization_endpoint"] as? String == "https://api.raft.test/oidc/\(slug)/api/oauth/authorize")
            #expect(scopedDoc["token_endpoint"] as? String == "https://api.raft.test/oidc/\(slug)/api/oauth/token")
            #expect(scopedDoc["jwks_uri"] as? String == "https://api.raft.test/oidc/\(slug)/api/oauth/jwks")
            #expect((scopedDoc["issuer"] as? String)?.contains("{") == false)

            let byId = try await client.send(.get, headers: HTTPFields(), to: "/oidc/\(serverId)/.well-known/openid-configuration")
            #expect(byId.status == .ok)
            #expect(try issuerObject(byId)["issuer"] as? String == "https://api.raft.test/oidc/\(serverId)")

            let unscoped = try await client.send(.get, headers: HTTPFields(), to: "/.well-known/openid-configuration")
            #expect(unscoped.status == .ok)
            let unscopedDoc = try issuerObject(unscoped)
            #expect(unscopedDoc["issuer"] as? String == "https://api.raft.test")
            #expect(unscopedDoc["authorization_endpoint"] as? String == "https://api.raft.test/api/oauth/authorize")
            #expect(unscopedDoc["issuer"] as? String != scopedDoc["issuer"] as? String)

            let bad = try await client.send(.get, headers: HTTPFields(), to: "/oidc/not_a_valid_slug!/.well-known/openid-configuration")
            #expect(bad.status == .badRequest)

            func authorizeQuery(withServer: Bool) -> String {
                var components = URLComponents()
                var items = [
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "client_id", value: "any-client"),
                    URLQueryItem(name: "redirect_uri", value: "https://client.example.test/cb"),
                    URLQueryItem(name: "scope", value: "openid profile"),
                ]
                if withServer { items.append(URLQueryItem(name: "server", value: slug)) }
                components.queryItems = items
                return components.percentEncodedQuery ?? ""
            }

            let rejected = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/api/oauth/authorize?\(authorizeQuery(withServer: true))"))
            #expect(rejected.status == .badRequest)
            let rejectedBody = try issuerObject(rejected)
            #expect(rejectedBody["error"] as? String == "invalid_request")
            #expect(((rejectedBody["error_description"] as? String) ?? "").contains("no longer supported"))

            let acceptedQuery = authorizeQuery(withServer: false)
            let accepted = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/api/oauth/authorize?\(acceptedQuery)"))
            #expect(accepted.status == .found)

            let scopedAuthorize = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/oidc/\(slug)/api/oauth/authorize?\(acceptedQuery)"))
            #expect(scopedAuthorize.status == .found)
            guard let location = scopedAuthorize.headers[HTTPField.Name("Location")!],
                  let components = URLComponents(string: location) else {
                Issue.record("missing scoped Location")
                return
            }
            let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(params["server"] == slug)
        }
    }
}

private func expectIssuerScopeFailure(_ response: ClientResponse, status: HTTPResponse.Status, message: String) {
    let expected = "{\"error\":\"\(message)\"}"
    #expect(response.status == status)
    #expect(response.body.string == expected)
    #expect(response.headers[.contentType] == AppFallback.jsonContentType)
    #expect(response.headers[.contentLength] == String(expected.utf8.count))
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == AppFallback.robotsTag)
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == nil)
    #expect(response.headers[HTTPField.Name("Location")!] == nil)
}

@Test func scopedIssuerFailuresPrecedeConfigAuthenticationBodyAndSuccessCachePolicy() async throws {
    let scene = OAuthScene()
    scene.auth.configureOAuthForTesting { $0.serverURL = "invalid origin" }
    scene.services.identity.oauthFlows.configureSigningSecret("")
    scene.oauth.addOwnedServer(
        id: "33333333-3333-4333-8333-333333333671", slug: "issuer-live-645", name: "Issuer Scope",
        ownerId: "11111111-1111-4111-8111-111111111645"
    )
    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            let routes: [(HTTPRequest.Method, String)] = [
                (.get, ".well-known/openid-configuration"),
                (.get, "api/oauth/.well-known/openid-configuration"),
                (.get, "api/oauth/agents"), (.get, "api/oauth/jwks"),
                (.get, "api/oauth/userinfo"), (.get, "api/oauth/serverinfo"),
                (.get, "api/oauth/authorize"), (.post, "api/oauth/token"),
            ]
            var headers = HTTPFields()
            headers[.authorization] = "Bearer invalid"
            headers[.contentType] = "application/json"
            for (segment, status, message) in [
                ("INVALID", HTTPResponse.Status.badRequest, "invalid_server_scope"),
                ("missing-metadata-scope", .notFound, "Not found"),
                (String(repeating: "a", count: 64), .notFound, "Not found"),
                (String(repeating: "a", count: 65), .badRequest, "invalid_server_scope"),
            ] {
                for (method, suffix) in routes {
                    let response = try await client.send(method, headers: headers, to: URI(string: "/oidc/\(segment)/\(suffix)")) { request in
                        if method == .post { request.body = .init(string: "{") }
                    }
                    expectIssuerScopeFailure(response, status: status, message: message)
                }
            }
            let configuredScope = try await client.get("/oidc/issuer-live-645/.well-known/openid-configuration")
            #expect(configuredScope.status == .serviceUnavailable)
            #expect(configuredScope.body.string == "{\"error\":\"oidc_not_configured\"}")
            #expect(configuredScope.headers[HTTPField.Name("Cache-Control")!] == nil)
            let authenticatedScope = try await client.get("/oidc/issuer-live-645/api/oauth/userinfo", headers: headers)
            #expect(authenticatedScope.status == .unauthorized)
            #expect(authenticatedScope.body.string == "{\"error\":\"Invalid or expired access token\"}")
            let tokenScope = try await client.send(.post, headers: headers, to: "/oidc/issuer-live-645/api/oauth/token") {
                $0.body = .init(string: "{")
            }
            #expect(tokenScope.status == .unauthorized)
            #expect(tokenScope.body.string == "{\"error\":\"Client credentials are required\"}")
            #expect(tokenScope.headers[HTTPField.Name("Cache-Control")!] == nil)
        }
    }
}

@Test func scopedIssuerReadsLiveRowsAndKeepsRouteSegmentsSeparateFromPrincipalServerIds() async throws {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111645"
    let serverId = "33333333-3333-4333-8333-333333333671"
    let originalSlug = "issuer-live-645"
    let renamedSlug = "issuer-renamed-645"
    scene.auth.configureOAuthForTesting { $0.serverURL = "https://scope-live.raft.test/base/" }
    scene.auth.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    scene.auth.addAccount(id: ownerId, email: "issuer-live-645@test.invalid", password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.oauth.addOwnedServer(id: serverId, slug: originalSlug, name: "Live Issuer", ownerId: ownerId)
    let agentId = scene.oauth.createAgent(serverId: serverId, name: "MetadataBot", creatorUserId: ownerId)
    let created = try scene.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: "Metadata Client", clientId: "issuer-live-645")
    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: headers, to: "/api/oauth/requests/agent") {
                $0.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"\(originalSlug)\",\"agentId\":\"\(agentId)\",\"scopes\":[\"openid\"]}")
            }
            #expect(requested.status == .ok)
            let requestId = try #require(try issuerObject(requested)["requestId"] as? String)
            let exchanged = try await client.send(.post, headers: headers, to: URI(string: "/oidc/\(originalSlug)/api/oauth/token")) {
                $0.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try #require(try issuerObject(exchanged)["access_token"] as? String)
            var bearer = HTTPFields()
            bearer[.authorization] = "Bearer \(accessToken)"
            let missingBeforeSeed = try await client.get(URI(string: "/oidc/\(renamedSlug)/.well-known/openid-configuration"))
            expectIssuerScopeFailure(missingBeforeSeed, status: .notFound, message: "Not found")
            // This existing seed replaces the whole server row, refreshes owner
            // membership and appends an all-channel. Only scope/principal
            // metadata is observed here; this is not a pure rename operation.
            scene.oauth.addOwnedServer(id: serverId, slug: renamedSlug, name: "Renamed Issuer", ownerId: ownerId)
            let oldDiscovery = try await client.get(URI(string: "/oidc/\(originalSlug)/.well-known/openid-configuration"))
            expectIssuerScopeFailure(oldDiscovery, status: .notFound, message: "Not found")
            let oldPrincipal = try await client.get(URI(string: "/oidc/\(originalSlug)/api/oauth/userinfo"), headers: bearer)
            expectIssuerScopeFailure(oldPrincipal, status: .notFound, message: "Not found")
            scene.auth.configureOAuthForTesting { $0.appURL = "https://moved-app.raft.test/base" }
            for segment in [renamedSlug, serverId] {
                let discovery = try await client.get(URI(string: "/oidc/\(segment)/.well-known/openid-configuration"))
                #expect(discovery.status == .ok)
                #expect(try issuerObject(discovery)["issuer"] as? String == "https://scope-live.raft.test/oidc/\(segment)")
                let principal = try await client.get(URI(string: "/oidc/\(segment)/api/oauth/userinfo"), headers: bearer)
                #expect(principal.status == .ok)
                #expect(try issuerObject(principal)["server_id"] as? String == serverId)
                #expect(try issuerObject(principal)["server_slug"] as? String == renamedSlug)
                let query = "response_type=code&client_id=issuer-live-645&redirect_uri=https%3A%2F%2Fclient.example.test%2Fcb&scope=openid"
                let authorize = try await client.get(URI(string: "/oidc/\(segment)/api/oauth/authorize?\(query)"))
                #expect(authorize.status == .found)
                let location = try #require(authorize.headers[HTTPField.Name("Location")!])
                let components = try #require(URLComponents(string: location))
                #expect(components.host == "moved-app.raft.test")
                #expect(components.path == "/base/login-with-raft/setup")
                let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                #expect(params["server"] == segment)
            }
            scene.oauth.deleteServer(id: serverId)
            for path in ["/oidc/\(serverId)/.well-known/openid-configuration", "/oidc/\(renamedSlug)/api/oauth/jwks"] {
                expectIssuerScopeFailure(try await client.get(URI(string: path)), status: .notFound, message: "Not found")
            }
            #expect(try await client.get("/.well-known/openid-configuration").status == .ok)
            #expect(try await client.get("/api/oauth/jwks").status == .ok)
        }
    }
}
