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
    let accounts = EmailLoginDirectory()
    accounts.serverURL = "https://api.raft.test"
    accounts.appURL = "https://app.raft.test"
    let ownerId = "11111111-1111-4111-8111-111111111238"
    let serverId = "33333333-3333-4333-8333-333333333434"
    let slug = "scoped-oidc-238"
    accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Scoped OIDC Server", ownerId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
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
