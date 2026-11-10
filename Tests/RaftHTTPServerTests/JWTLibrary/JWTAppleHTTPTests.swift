import Foundation
import HTTPTypes
import JWTKit
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func appleJWTJSON(_ client: any Client, path: String, values: [String: String]) async throws -> ClientResponse {
    var headers = HTTPFields(); headers[.contentType] = "application/json"
    let body = try JSONSerialization.data(withJSONObject: values)
    return try await client.send(.post, headers: headers, to: URI(string: path)) { $0.body = .init(data: body) }
}

private func appleJWTBody(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

@Test func jwtLibraryNativeAppleRequiresTrustedSignatureAndAcceptsSignedProofThroughHTTP() async throws {
    let scene = AuthScene()
    let challenge = "synthetic-apple-proof-challenge-71-0123456789"
    scene.auth.configureOAuthForTesting {
        $0.nativeAppleClientId = "build.raft.app"
        $0.nativeAppleClientSecret = "synthetic-code-exchange-client-secret"
        $0.nativeAppleStateSecret = "synthetic-native-state-signing-secret-71"
    }
    scene.mobile.allowAppleLogin(on: ["mobile"])
    let provider = try AuthAppleJWTFixture()
    let signed = try await provider.token(subject: "synthetic-apple-subject", nonce: challenge, email: "apple-proof@example.com")
    let header = try DefaultJWTParser().parse(Data(signed.utf8), as: AppleIdentityToken.self).header
    #expect(header.kid == "synthetic-apple-rsa-71")
    let authority = JWTKeyCollection()
    try await authority.add(jwksJSON: provider.jwksJSON)
    let verified = try await authority.verify(signed, as: AppleIdentityToken.self, expectedAudience: "build.raft.app")
    #expect(verified.nonce == challenge)
    scene.mobile.setNativeAppleCodeResponses(["synthetic-code": { signed }],
        clientId: "build.raft.app", clientSecret: "synthetic-code-exchange-client-secret")
    try await withApp { app in
        registerAuthScene(app, scene: scene)
        try await app.testing { client in
            for proof in ["forged", "unconfigured", "valid"] {
                let start = try await appleJWTJSON(client, path: "/api/auth/mobile/oauth/apple/native/start", values: [
                    "mode": "login", "platform": "ios", "appEnv": "production", "returnUri": "raft://oauth/callback",
                    "codeChallenge": challenge, "codeChallengeMethod": "S256",
                ])
                #expect(start.status == .created)
                let started = try appleJWTBody(start)
                let requestId = try #require(started["requestId"] as? String)
                let requestToken = try #require(started["requestToken"] as? String)
                scene.auth.configureOAuthForTesting { $0.nativeAppleTrustedJWKS = proof == "unconfigured" ? nil : provider.jwksJSON }
                let supplied: String
                if proof == "forged" {
                    let parts = signed.split(separator: ".")
                    supplied = "\(parts[0]).\(parts[1]).Ym9ndXM"
                } else { supplied = signed }
                let response = try await appleJWTJSON(client, path: "/api/auth/mobile/oauth/apple/native/authorize", values: [
                    "requestId": requestId, "requestToken": requestToken, "authorizationCode": "synthetic-code", "identityToken": supplied,
                ])
                let result = try appleJWTBody(response)
                if proof == "valid" {
                    #expect(result["code"] as? String == nil)
                    #expect(result["error"] as? String == nil)
                    #expect(response.status == .ok)
                    #expect((result["handoffCode"] as? String)?.isEmpty == false)
                } else {
                    #expect(response.status == .badRequest)
                    #expect(result["code"] as? String == "native_apple_invalid_credential")
                    #expect(result["handoffCode"] == nil)
                }
            }
        }
    }
}
