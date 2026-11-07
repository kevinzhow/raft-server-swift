import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func authorizeQuery(
    clientId: String,
    redirectURI: String,
    challenge: String = String(repeating: "c", count: 43),
    nonce: String = "open-webui-nonce",
    state: String = "open-webui-state",
    scope: String = "openid profile email"
) -> String {
    var components = URLComponents()
    components.queryItems = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: clientId),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
        URLQueryItem(name: "scope", value: scope),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "nonce", value: nonce),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    return components.percentEncodedQuery ?? ""
}

@Test func browserAuthorizeHandsOffToTheSetupPage() async throws {
    let scene = OAuthScene()
    scene.auth.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    scene.auth.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let ownerId = "11111111-1111-4111-8111-111111111235"
    let serverId = "33333333-3333-4333-8333-333333333430"
    let redirectURI = "https://open-webui.example.test/oauth/oidc/callback"
    scene.oauth.addOwnedServer(id: serverId, slug: "oidc-235", name: "OIDC Server", ownerId: ownerId)
    _ = try scene.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Open WebUI",
        clientId: "oidc-client-235",
        returnUrl: redirectURI,
        allowedScopes: ["openid", "profile", "email"]
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            let query = authorizeQuery(clientId: "oidc-client-235", redirectURI: redirectURI)
            let response = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/api/oauth/authorize?\(query)"))
            #expect(response.status == .found)
            guard let location = response.headers[HTTPField.Name("Location")!],
                  let url = URLComponents(string: location) else {
                Issue.record("missing Location")
                return
            }
            let origin = "\(url.scheme ?? "")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
            #expect(origin == "https://app.raft.test")
            #expect(url.path == "/login-with-raft/setup")
            let params = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(params["flow"] == "oidc")
            #expect(params["client_id"] == "oidc-client-235")
            #expect(params["return_to"] == redirectURI)
            #expect(params["scope"] == "openid profile email")
            #expect(params["state"] == "open-webui-state")
            #expect(params["nonce"] == "open-webui-nonce")
            #expect(params["code_challenge"] == String(repeating: "c", count: 43))
            #expect(params["code_challenge_method"] == "S256")
            #expect(params["server"] == nil)

            let fragmentQuery = authorizeQuery(clientId: "oidc-client-235", redirectURI: "\(redirectURI)#fragment")
            let fragment = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/api/oauth/authorize?\(fragmentQuery)"))
            #expect(fragment.status == .badRequest)
            #expect(try JSONSerialization.jsonObject(with: Data((fragment.body.string ?? "").utf8)) as? [String: Any] != nil)

            let malformedQuery = authorizeQuery(clientId: "oidc-client-235", redirectURI: redirectURI, challenge: "not-a-sha256-challenge")
            let malformed = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/api/oauth/authorize?\(malformedQuery)"))
            #expect(malformed.status == .badRequest)

            let oversizedQuery = authorizeQuery(clientId: "oidc-client-235", redirectURI: redirectURI, nonce: String(repeating: "n", count: 513))
            let oversized = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/api/oauth/authorize?\(oversizedQuery)"))
            #expect(oversized.status == .badRequest)
        }
    }
}

@Test func oauthProtocolBrowserAndConsentKeepDifferentQueryDialects() async throws {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111646"
    let serverId = "33333333-3333-4333-8333-333333333672"
    scene.auth.addAccount(id: ownerId, email: "query-646@test.invalid", password: "password123")
    scene.auth.configureOAuthForTesting { $0.appURL = "https://query-app.raft.test/base" }
    scene.oauth.addOwnedServer(id: serverId, slug: "query-646", name: "Query Protocol", ownerId: ownerId)
    let registered = try scene.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: "Query App", clientId: "query-client-646")
    let session = scene.auth.mintAccessTokenForTesting(userId: ownerId)
    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            let query = "response_type=bad&response_type=code&client_id=first&client_id=second&%63lient_id=decoded+client&redirect_uri=https%3A%2F%2Frp.test%2Fcb&scope=openid+profile&state=old&state=C%2BD"
            let browser = try await client.get(URI(string: "/api/oauth/authorize?\(query)"))
            #expect(browser.status == .found)
            let location = try #require(browser.headers[HTTPField.Name("Location")!])
            let components = try #require(URLComponents(string: location))
            #expect(components.host == "query-app.raft.test")
            #expect(components.path == "/base/login-with-raft/setup")
            let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(params["client_id"] == "decoded client")
            #expect(params["return_to"] == "https://rp.test/cb")
            #expect(params["scope"] == "openid profile")
            #expect(params["state"] == "C+D")
            #expect(params["server"] == nil)
            var lookupHeaders = HTTPFields()
            lookupHeaders[.authorization] = "Bearer \(session)"
            let headers = lookupHeaders
            func lookup(_ query: String) async throws -> ClientResponse {
                try await client.get(URI(string: "/api/oauth/clients/lookup?\(query)"), headers: headers)
            }
            func object(_ response: ClientResponse) throws -> [String: Any] {
                try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
            }
            let first = try await lookup("%63lient_id=ignored&client_id=\(registered.clientId)&client_id=wrong&clientId=wrong&server_id=\(serverId)&server_id=wrong&scope=openid+profile&scope=openid%20profile")
            #expect(first.status == .ok)
            let firstBody = try object(first)
            #expect(firstBody["clientId"] as? String == registered.clientId)
            let validation = try #require(firstBody["scopeValidation"] as? [String: Any])
            #expect(validation["allowed"] as? Bool == false)
            #expect(validation["reason"] as? String == "unsupported")
            #expect(validation["disallowedScopes"] as? [String] == ["openid+profile"])
            let spaced = try await lookup("client_id=\(registered.clientId)&server_id=\(serverId)&scope=openid%20profile")
            #expect(spaced.status == .ok)
            #expect((try object(spaced)["scopeValidation"] as? [String: Any])?["allowed"] as? Bool == true)
            for bad in [
                "%63lient_id=\(registered.clientId)&server_id=\(serverId)",
                "client_id=&clientId=\(registered.clientId)&server_id=\(serverId)",
                "client_id=\(registered.clientId)&server_id=&serverId=\(serverId)",
            ] {
                let refused = try await lookup(bad)
                #expect(refused.status == .notFound)
                #expect(refused.body.string == "{\"error\":\"OAuth client not found for server\"}")
                #expect(refused.headers[HTTPField.Name("Cache-Control")!] == nil)
            }
            // Consent's member/client lookup does not add the live-server or
            // enabled gates used by other OAuth use cases.
            scene.oauth.setClientEnabled(clientRecordId: registered.id, enabled: false)
            scene.oauth.deleteServer(id: serverId)
            let retained = try await lookup("client_id=\(registered.clientId)&server_id=\(serverId)")
            #expect(retained.status == .ok)
            #expect(try object(retained)["availability"] as? String == "ready")
        }
    }
}
