import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func boundaryObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func boundaryJWT(_ token: String) -> [String: Any] {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return [:] }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded += "=" }
    guard let data = Data(base64Encoded: encoded) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@Test func oidcWithoutEmailOmitsEmailAndKeepsMembershipBound() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    accounts.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let ownerId = "11111111-1111-4111-8111-111111111239"
    let serverId = "33333333-3333-4333-8333-333333333435"
    let email = "oidc-owner-239@raft.test"
    let redirectURI = "https://open-webui.example.test/oauth/oidc/callback"
    accounts.addAccount(id: ownerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oidc-239", name: "OIDC Boundary", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Open WebUI",
        clientId: "oidc-client-239",
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
            let session = try boundaryObject(login)["accessToken"] as? String ?? ""

            func authorize(scopes: String, challenge: Bool = false) async throws -> String {
                let challengeFields = challenge ? ",\"codeChallenge\":\"4lHxhn3RWN1r50LRPOPTsUXp-dh5hd_mKVHMGvXAufY\",\"codeChallengeMethod\":\"S256\"" : ""
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(session)"
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"oidc-client-239\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"\(redirectURI)\",\"scopes\":[\(scopes)],\"oidc\":true,\"nonce\":\"boundary-nonce\"\(challengeFields)}")
                }
                #expect(response.status == .ok)
                return try boundaryObject(response)["code"] as? String ?? ""
            }

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            func exchange(_ code: String) async throws -> ClientResponse {
                try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                    request.body = .init(string: "{\"clientId\":\"oidc-client-239\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\",\"redirect_uri\":\"\(redirectURI)\"}")
                }
            }

            let code = try await authorize(scopes: "\"openid\",\"profile\"")
            let exchanged = try await exchange(code)
            #expect(exchanged.status == .ok)
            let tokenBody = try boundaryObject(exchanged)
            let claims = boundaryJWT(tokenBody["id_token"] as? String ?? "")
            #expect(claims["email"] == nil)
            #expect(claims["email_verified"] == nil)
            #expect(claims["nonce"] as? String == "boundary-nonce")

            var bearerHeaders = HTTPFields()
            bearerHeaders[.authorization] = "Bearer \(tokenBody["access_token"] as? String ?? "")"
            let userinfo = try await client.send(.get, headers: bearerHeaders, to: "/api/oauth/userinfo")
            #expect(userinfo.status == .ok)
            #expect(try boundaryObject(userinfo)["email"] == nil)

            let expiredCode = try await authorize(scopes: "\"openid\",\"profile\"")
            accounts.oauth.expireAuthorizationCode(id: expiredCode)
            let expired = try await exchange(expiredCode)
            #expect(expired.status == .badRequest)
            #expect(try boundaryObject(expired)["error"] as? String == "invalid_grant")
            #expect(try boundaryObject(expired)["next_action"] == nil)

            let boundCode = try await authorize(scopes: "\"openid\",\"profile\"")
            accounts.oauth.removeMember(serverId: serverId, userId: ownerId)
            let removed = try await exchange(boundCode)
            #expect(removed.status == .badRequest)
            #expect(try boundaryObject(removed)["error"] as? String == "invalid_grant")
            accounts.oauth.addMember(serverId: serverId, userId: ownerId, role: "owner")
            let restored = try await exchange(boundCode)
            #expect(restored.status == .ok)
        }
    }
}
