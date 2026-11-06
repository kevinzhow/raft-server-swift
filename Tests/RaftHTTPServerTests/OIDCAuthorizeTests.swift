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
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    accounts.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let ownerId = "11111111-1111-4111-8111-111111111235"
    let serverId = "33333333-3333-4333-8333-333333333430"
    let redirectURI = "https://open-webui.example.test/oauth/oidc/callback"
    accounts.oauth.addOwnedServer(id: serverId, slug: "oidc-235", name: "OIDC Server", ownerId: ownerId)
    _ = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Open WebUI",
        clientId: "oidc-client-235",
        returnUrl: redirectURI,
        allowedScopes: ["openid", "profile", "email"]
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
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
