import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

@Test func jwksPublishesOneES256VerificationKeyWithoutThePrivateScalar() async throws {
    let scene = OAuthScene()

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            let response = try await client.send(.get, headers: HTTPFields(), to: "/api/oauth/jwks")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let keys = body?["keys"] as? [[String: Any]] ?? []
            #expect(keys.count == 1)
            let key = keys.first ?? [:]
            #expect(key["kty"] as? String == "EC")
            #expect(key["crv"] as? String == "P-256")
            #expect(key["use"] as? String == "sig")
            #expect(key["alg"] as? String == "ES256")
            #expect(key["d"] == nil)
            #expect((key["x"] as? String)?.isEmpty == false)
            #expect((key["y"] as? String)?.isEmpty == false)
        }
    }
}

@Test func jwksReadsLiveSecretAfterRegistrationIndependentlyOfDiscoveryOrigin() async throws {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111645"
    let serverId = "33333333-3333-4333-8333-333333333671"
    scene.oauth.addOwnedServer(id: serverId, slug: "jwks-live-645", name: "Live JWKS", ownerId: ownerId)
    scene.auth.configureOAuthForTesting { $0.serverURL = "invalid origin" }
    scene.services.identity.oauthFlows.configureSigningSecret("issuer-metadata-first-key")
    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            let initial = try await client.get("/api/oauth/jwks")
            #expect(initial.status == .ok)
            let initialObject = try #require(JSONSerialization.jsonObject(with: Data((initial.body.string ?? "").utf8)) as? [String: Any])
            let initialKey = try #require((initialObject["keys"] as? [[String: Any]])?.first)
            let initialKid = try #require(initialKey["kid"] as? String)
            let discovery = try await client.get("/.well-known/openid-configuration")
            #expect(discovery.status == .serviceUnavailable)
            scene.services.identity.oauthFlows.configureSigningSecret("issuer-metadata-second-key")
            let rotated = try await client.get("/api/oauth/jwks")
            #expect(rotated.status == .ok)
            let rotatedObject = try #require(JSONSerialization.jsonObject(with: Data((rotated.body.string ?? "").utf8)) as? [String: Any])
            let rotatedKey = try #require((rotatedObject["keys"] as? [[String: Any]])?.first)
            #expect(rotatedKey["kid"] as? String != initialKid)
            #expect(rotated.body.string != initial.body.string)
            for segment in ["jwks-live-645", serverId] {
                let scoped = try await client.get(URI(string: "/oidc/\(segment)/api/oauth/jwks"))
                #expect(scoped.status == .ok)
                #expect(scoped.body.string == rotated.body.string)
                #expect(scoped.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=300")
            }
            scene.services.identity.oauthFlows.configureSigningSecret("")
            for path in ["/api/oauth/jwks", "/oidc/jwks-live-645/api/oauth/jwks"] {
                let empty = try await client.get(URI(string: path))
                #expect(empty.status == .serviceUnavailable)
                #expect(empty.body.string == "{\"error\":\"oidc_not_configured\"}")
                #expect(empty.headers[HTTPField.Name("Cache-Control")!] == nil)
            }
            scene.services.identity.oauthFlows.configureSigningSecret(" ")
            let whitespaceKey = try await client.get("/api/oauth/jwks")
            #expect(whitespaceKey.status == .ok)
            #expect(whitespaceKey.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=300")
            scene.services.identity.oauthFlows.configureSigningSecret("issuer-metadata-first-key")
            let restored = try await client.get(URI(string: "/oidc/\(serverId)/api/oauth/jwks"))
            #expect(restored.status == .ok)
            #expect(restored.body.string == initial.body.string)
            #expect(restored.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=300")
        }
    }
}
