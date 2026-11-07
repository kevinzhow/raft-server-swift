import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The OAuth/OIDC slice must expose its upstream route pairs without the full
/// `configure(_:services:)` mount. This locks the collection's own registration
/// contract: every `api/oauth`, `oidc/:server` and root `.well-known` pair, and
/// nothing else. End-to-end behavior stays with the existing OAuth route tests
/// once the Lead mounts the collection.
@Suite
struct FeatureOAuthRoutesTests {
    /// Complete table of the 23 registrations extracted from
    /// `FallbackApplication.configure` at extraction time.
    private let expectedOAuthRoutes: [(HTTPRequest.Method, String)] = [
        (.put, "api/oauth/installations/:installationId/setup"),
        (.post, "api/oauth/authorize/human"),
        (.post, "api/oauth/installation-token"),
        (.post, "api/oauth/token"),
        (.get, "api/oauth/userinfo"),
        (.get, "api/oauth/agents"),
        (.get, "api/oauth/serverinfo"),
        (.post, "api/oauth/installations/lookup"),
        (.post, "api/oauth/requests/agent"),
        (.post, "api/oauth/agent-events"),
        (.get, "api/oauth/clients/lookup"),
        (.get, "api/oauth/jwks"),
        (.get, "api/oauth/authorize"),
        (.get, "api/oauth/.well-known/openid-configuration"),
        (.get, "oidc/:server/.well-known/openid-configuration"),
        (.get, "oidc/:server/api/oauth/.well-known/openid-configuration"),
        (.get, "oidc/:server/api/oauth/agents"),
        (.get, "oidc/:server/api/oauth/jwks"),
        (.get, "oidc/:server/api/oauth/userinfo"),
        (.get, "oidc/:server/api/oauth/serverinfo"),
        (.get, "oidc/:server/api/oauth/authorize"),
        (.post, "oidc/:server/api/oauth/token"),
        (.get, ".well-known/openid-configuration"),
    ]

    @Test func featureOAuthRoutesAreRegisteredOnABareApplication() async throws {
        let scene = OAuthScene()

        try await withApp { app in
            try await app.register(collection: OAuthFeature(
            oauthFlows: scene.services.identity.oauthFlows,
            issuerMetadata: scene.services.identity.issuerMetadata,
            authorization: scene.services.identity.authorization,
            principal: scene.services.identity.principal,
            apps: scene.services.integrations.apps
        ))

            let registered = Set(app.routes.all.map { "\($0.method.rawValue) \($0.path.string)" })
            let expected = Set(expectedOAuthRoutes.map { "\($0.0.rawValue) \($0.1)" })

            // The table is authoritative: reject an accidental duplicate or gap
            // in the table itself before comparing it to the router.
            #expect(expectedOAuthRoutes.count == 23)
            #expect(expected.count == 23)

            // One route per table entry, and no route outside the three
            // extracted families.
            #expect(app.routes.all.count == expected.count)
            #expect(registered == expected)
            #expect(app.routes.all.allSatisfy { route in
                let components = route.path.map { $0.description }
                if components.count >= 2, components[0] == "api", components[1] == "oauth" {
                    return true
                }
                if components.count >= 2, components[0] == "oidc", components[1] == ":server" {
                    return true
                }
                return components == [".well-known", "openid-configuration"]
            })
        }
    }
}
