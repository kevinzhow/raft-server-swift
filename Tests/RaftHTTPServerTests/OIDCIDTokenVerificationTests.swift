import TestSupport
import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func verifyObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func decodeBase64URL(_ value: String) -> Data? {
    var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded += "=" }
    return Data(base64Encoded: encoded)
}

@Test func idTokenSignatureVerifiesWithThePublishedJWKS() async throws {
    let scene = OAuthScene()
    scene.auth.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    scene.auth.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let ownerId = "11111111-1111-4111-8111-111111111240"
    let serverId = "33333333-3333-4333-8333-333333333436"
    let email = "oidc-owner-240@raft.test"
    let redirectURI = "https://open-webui.example.test/oauth/oidc/callback"
    let verifier = "oidc-standard-verifier-abcdefghijklmnopqrstuvwxyz-0123456789"
    let challenge = "4lHxhn3RWN1r50LRPOPTsUXp-dh5hd_mKVHMGvXAufY"
    scene.auth.addAccount(id: ownerId, email: email, password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.oauth.addOwnedServer(id: serverId, slug: "oidc-240", name: "OIDC Verification", ownerId: ownerId)
    let created = try scene.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Open WebUI",
        clientId: "oidc-client-240",
        returnUrl: redirectURI,
        allowedScopes: ["openid", "profile", "email"]
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
            }
            let session = try verifyObject(login)["accessToken"] as? String ?? ""

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(session)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"oidc-client-240\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"\(redirectURI)\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true,\"nonce\":\"verify-nonce\",\"codeChallenge\":\"\(challenge)\",\"codeChallengeMethod\":\"S256\"}")
            }
            let code = try verifyObject(authorize)["code"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"oidc-client-240\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\",\"redirect_uri\":\"\(redirectURI)\",\"code_verifier\":\"\(verifier)\"}")
            }
            #expect(exchanged.status == .ok)
            let idToken = try verifyObject(exchanged)["id_token"] as? String ?? ""

            let jwks = try await client.send(.get, headers: HTTPFields(), to: "/api/oauth/jwks")
            let keys = try verifyObject(jwks)["keys"] as? [[String: Any]] ?? []
            let key = keys.first ?? [:]
            let x = try #require(decodeBase64URL(key["x"] as? String ?? ""))
            let y = try #require(decodeBase64URL(key["y"] as? String ?? ""))
            #expect(x.count == 32)
            #expect(y.count == 32)
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)

            let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
            #expect(parts.count == 3)
            let header = try #require(decodeBase64URL(String(parts[0])))
            let headerObject = try #require((try JSONSerialization.jsonObject(with: header)) as? [String: Any])
            #expect(headerObject["alg"] as? String == "ES256")
            #expect(headerObject["kid"] as? String == key["kid"] as? String)
            let signature = try #require(decodeBase64URL(String(parts[2])))
            let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
            #expect(publicKey.isValidSignature(ecdsa, for: signingInput))
        }
    }
}
