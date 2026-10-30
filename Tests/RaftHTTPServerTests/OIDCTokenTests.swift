import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let oidcVerifier = "oidc-standard-verifier-abcdefghijklmnopqrstuvwxyz-0123456789"
private let oidcChallenge = "4lHxhn3RWN1r50LRPOPTsUXp-dh5hd_mKVHMGvXAufY"

private func oidcObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func jwtPayload(_ token: String) throws -> [String: Any] {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return [:] }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded += "=" }
    guard let data = Data(base64Encoded: encoded) else { return [:] }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func oidcAuthorizationCodeRequiresPKCEAndCarriesTheNonce() async throws {
    let accounts = EmailLoginDirectory()
    accounts.serverURL = "https://api.raft.test"
    accounts.appURL = "https://app.raft.test"
    let ownerId = "11111111-1111-4111-8111-111111111236"
    let serverId = "33333333-3333-4333-8333-333333333431"
    let email = "oidc-owner-236@raft.test"
    let redirectURI = "https://open-webui.example.test/oauth/oidc/callback"
    accounts.addAccount(id: ownerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oidc-236", name: "OIDC Server", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Open WebUI",
        clientId: "oidc-client-236",
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
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
            }
            let session = try oidcObject(login)["accessToken"] as? String ?? ""

            func authorize(_ extra: String = "") async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(session)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"oidc-client-236\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"\(redirectURI)\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true,\"nonce\":\"open-webui-nonce\",\"codeChallenge\":\"\(oidcChallenge)\",\"codeChallengeMethod\":\"S256\"\(extra)}")
                }
            }

            let mismatched = try await authorize(",\"server\":\"other-server\"")
            #expect(mismatched.status == .badRequest)
            #expect(try oidcObject(mismatched)["error"] as? String == "server does not match the selected Server")

            let issued = try await authorize(",\"server\":\"oidc-236\"")
            #expect(issued.status == .ok)
            let code = try oidcObject(issued)["code"] as? String ?? ""
            #expect(code.hasPrefix("raft_oidc_"))

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            func exchange(code: String, verifier: String?, redirect: String = redirectURI) async throws -> ClientResponse {
                let verifierPart = verifier.map { ",\"code_verifier\":\"\($0)\"" } ?? ""
                let body = "{\"clientId\":\"oidc-client-236\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\",\"redirect_uri\":\"\(redirect)\"\(verifierPart)}"
                return try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                    request.body = .init(string: body)
                }
            }

            let missingVerifier = try await exchange(code: code, verifier: nil)
            #expect(missingVerifier.status == .badRequest)
            let wrongVerifier = try await exchange(code: code, verifier: "\(oidcVerifier)x")
            #expect(wrongVerifier.status == .badRequest)
            let wrongRedirect = try await exchange(code: code, verifier: oidcVerifier, redirect: "https://attacker.example.test/callback")
            #expect(wrongRedirect.status == .badRequest)

            let tokenResponse = try await exchange(code: code, verifier: oidcVerifier)
            #expect(tokenResponse.status == .ok)
            let tokenBody = try oidcObject(tokenResponse)
            #expect(tokenBody["token_type"] as? String == "Bearer")
            let scopes = (tokenBody["scope"] as? String ?? "").split(separator: " ").map(String.init)
            #expect(scopes == ["email", "openid", "profile"])
            let idToken = tokenBody["id_token"] as? String ?? ""
            #expect(idToken.isEmpty == false)
            let claims = try jwtPayload(idToken)
            #expect(claims["iss"] as? String == "https://api.raft.test")
            #expect(claims["sub"] as? String == ownerId)
            #expect(claims["aud"] as? String == "oidc-client-236")
            #expect(claims["nonce"] as? String == "open-webui-nonce")
            #expect(claims["name"] as? String == "oidc-owner-236")
            #expect(claims["preferred_username"] as? String == "oidc-owner-236")
            #expect(claims["email"] as? String == email)
            #expect(claims["email_verified"] as? Bool == true)
            #expect(claims["server_id"] as? String == serverId)

            let replay = try await exchange(code: code, verifier: oidcVerifier)
            #expect(replay.status == .conflict)
        }
    }
}
