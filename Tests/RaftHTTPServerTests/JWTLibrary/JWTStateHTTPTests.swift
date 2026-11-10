import Crypto
import Foundation
import HTTPTypes
import JWTKit
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private let jwtHTTPSecret = "synthetic-JWT-library-state-secret-71-only"

private struct StateSignatureProbe: JWTPayload {
    let iss: String
    let aud: String
    let exp: ExpirationClaim
    func verify(using algorithm: some JWTAlgorithm) throws {
        guard algorithm.name == "HS256", iss == "slock-social-auth", aud == "social-auth-state" else {
            throw NSError(domain: "synthetic-jwt-test", code: 1)
        }
        try exp.verifyNotExpired()
    }
}

private func jwtTestBase64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func jwtTestForgery(original: String, headerAlgorithm: String, key: SymmetricKey) throws -> String {
    let parts = original.split(separator: ".", omittingEmptySubsequences: false)
    let header = jwtTestBase64(try JSONSerialization.data(withJSONObject: ["alg": headerAlgorithm, "typ": "JWT"]))
    let input = "\(header).\(parts[1])"
    return input + "." + jwtTestBase64(Data(HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: key)))
}

@Test func jwtLibraryPublishedStateUsesConfiguredKeyAndRejectsSourceDerivedForgery() async throws {
    let scene = AuthScene(signingSecret: jwtHTTPSecret)
    scene.auth.configureOAuthForTesting { $0.configuredSocialAuthProviders = ["google"] }
    scene.mobile.setWebProviderProfile(MobileProviderProfile(providerUserId: "synthetic-provider-71",
        email: "signed-state@example.com", displayName: "Synthetic Signed User", emailVerified: true))
    try await withApp { app in
        registerAuthScene(app, scene: scene)
        try await app.testing { client in
            let start = try await client.send(.get, to: "/api/auth/google/start")
            #expect(start.status == .found)
            let location = try #require(start.headers[.location])
            let state = try #require(URLComponents(string: location)?.queryItems?.first { $0.name == "state" }?.value)
            let cookie = String(try #require(start.headers[.setCookie]).split(separator: ";")[0])
            // Independently use the released SDK to verify production's token.
            // The role label is the explicit key separation contract.
            let roleKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(jwtHTTPSecret.utf8)),
                salt: Data(), info: Data("raft/social-auth-state/v1".utf8), outputByteCount: 32)
            let keys = await JWTKeyCollection().add(hmac: HMACKey(key: roleKey), digestAlgorithm: .sha256)
            _ = try await keys.verify(state, as: StateSignatureProbe.self)
            var headers = HTTPFields()
            headers[.contentType] = "application/x-www-form-urlencoded"
            headers[.cookie] = cookie
            // The old source-derived key is public; a correct nonce cannot make
            // a token signed with it authoritative under the configured key.
            let oldKey = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-social-auth-state".utf8))))
            let forged = try jwtTestForgery(original: state, headerAlgorithm: "HS256", key: oldKey)
            let denied = try await client.send(.post, headers: headers, to: "/api/auth/google/callback") {
                $0.body = .init(string: "code=synthetic-provider-code&state=\(forged)")
            }
            #expect(denied.status == .found)
            let deniedItems = URLComponents(string: denied.headers[.location] ?? "")?.queryItems ?? []
            #expect(!deniedItems.contains { $0.name == "code" })
            #expect(deniedItems.contains { $0.name == "error" })
            let confused = try jwtTestForgery(original: state, headerAlgorithm: "none", key: roleKey)
            let confusion = try await client.send(.post, headers: headers, to: "/api/auth/google/callback") {
                $0.body = .init(string: "code=synthetic-provider-code&state=\(confused)")
            }
            #expect(!(URLComponents(string: confusion.headers[.location] ?? "")?.queryItems ?? []).contains { $0.name == "code" })
            let accepted = try await client.send(.post, headers: headers, to: "/api/auth/google/callback") {
                $0.body = .init(string: "code=synthetic-provider-code&state=\(state)")
            }
            #expect(accepted.status == .found)
            #expect((URLComponents(string: accepted.headers[.location] ?? "")?.queryItems ?? []).contains { $0.name == "code" && $0.value?.isEmpty == false })
        }
    }
}
