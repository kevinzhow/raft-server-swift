import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let scopedVerifier = "oidc-standard-verifier-abcdefghijklmnopqrstuvwxyz-0123456789"
private let scopedChallenge = "4lHxhn3RWN1r50LRPOPTsUXp-dh5hd_mKVHMGvXAufY"

private func scopedObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func scopedOIDCMountGuardsTheServerSegment() async throws {
    let scene = OAuthScene()
    scene.auth.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    scene.auth.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let ownerId = "11111111-1111-4111-8111-111111111237"
    let serverId = "33333333-3333-4333-8333-333333333432"
    let otherServerId = "33333333-3333-4333-8333-333333333433"
    let email = "oidc-owner-237@raft.test"
    let redirectURI = "https://open-webui.example.test/oauth/oidc/callback"
    scene.auth.addAccount(id: ownerId, email: email, password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.oauth.addOwnedServer(id: serverId, slug: "oidc-237", name: "OIDC Server", ownerId: ownerId)
    scene.oauth.addOwnedServer(id: otherServerId, slug: "other-oidc-237", name: "Other OIDC", ownerId: ownerId)
    let created = try scene.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Open WebUI",
        clientId: "oidc-client-237",
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
            let session = try scopedObject(login)["accessToken"] as? String ?? ""

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(session)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"oidc-client-237\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"\(redirectURI)\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true,\"nonce\":\"scoped-nonce\",\"codeChallenge\":\"\(scopedChallenge)\",\"codeChallengeMethod\":\"S256\"}")
            }
            let code = try scopedObject(authorize)["code"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/oidc/oidc-237/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"oidc-client-237\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\",\"redirect_uri\":\"\(redirectURI)\",\"code_verifier\":\"\(scopedVerifier)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try scopedObject(exchanged)["access_token"] as? String ?? ""
            let idToken = try scopedObject(exchanged)["id_token"] as? String ?? ""
            let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 3 {
                var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while payload.count % 4 != 0 { payload += "=" }
                if let data = Data(base64Encoded: payload),
                   let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    #expect(claims["iss"] as? String == "https://api.raft.test/oidc/oidc-237")
                    #expect(claims["server_id"] as? String == serverId)
                }
            }

            var bearerHeaders = HTTPFields()
            bearerHeaders[.authorization] = "Bearer \(accessToken)"
            func mintCode() async throws -> String {
                let response = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"oidc-client-237\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"\(redirectURI)\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true,\"nonce\":\"scoped-nonce\",\"codeChallenge\":\"\(scopedChallenge)\",\"codeChallengeMethod\":\"S256\"}")
                }
                return try scopedObject(response)["code"] as? String ?? ""
            }
            func exchangeAt(_ mount: String, code: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: URI(string: "\(mount)/api/oauth/token")) { request in
                    request.body = .init(string: "{\"clientId\":\"oidc-client-237\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\",\"redirect_uri\":\"\(redirectURI)\",\"code_verifier\":\"\(scopedVerifier)\"}")
                }
            }

            let foreignCode = try await mintCode()
            let foreign = try await exchangeAt("/oidc/other-oidc-237", code: foreignCode)
            #expect(foreign.status == .badRequest)
            #expect(try scopedObject(foreign)["error"] as? String == "invalid_grant")

            let idCode = try await mintCode()
            let byId = try await exchangeAt("/oidc/\(serverId)", code: idCode)
            #expect(byId.status == .ok)

            let userinfo = try await client.send(.get, headers: bearerHeaders, to: "/oidc/oidc-237/api/oauth/userinfo")
            #expect(userinfo.status == .ok)
            #expect(try scopedObject(userinfo)["sub"] as? String == ownerId)
            let crossUserinfo = try await client.send(.get, headers: bearerHeaders, to: "/oidc/other-oidc-237/api/oauth/userinfo")
            #expect(crossUserinfo.status == .unauthorized)

            let serverinfo = try await client.send(.get, headers: bearerHeaders, to: "/oidc/oidc-237/api/oauth/serverinfo")
            #expect(serverinfo.status == .ok)
            #expect(try scopedObject(serverinfo)["id"] as? String == serverId)
            let crossServerinfo = try await client.send(.get, headers: bearerHeaders, to: "/oidc/other-oidc-237/api/oauth/serverinfo")
            #expect(crossServerinfo.status == .unauthorized)

            let jwks = try await client.send(.get, headers: HTTPFields(), to: "/oidc/oidc-237/api/oauth/jwks")
            #expect(jwks.status == .ok)

            let badSegment = "not_a_valid_slug!"
            for path in [
                "/oidc/\(badSegment)/api/oauth/.well-known/openid-configuration",
                "/oidc/\(badSegment)/api/oauth/agents",
                "/oidc/\(badSegment)/api/oauth/jwks",
                "/oidc/\(badSegment)/api/oauth/userinfo",
                "/oidc/\(badSegment)/api/oauth/serverinfo",
                "/oidc/\(badSegment)/api/oauth/authorize",
            ] {
                let response = try await client.send(.get, headers: HTTPFields(), to: URI(string: path))
                #expect(response.status == .badRequest)
            }
            let badToken = try await client.send(.post, headers: tokenHeaders, to: "/oidc/\(badSegment)/api/oauth/token") { request in
                request.body = .init(string: "{}")
            }
            #expect(badToken.status == .badRequest)

            for path in [
                "/oidc/oidc-237/api/oauth/authorize/human",
                "/oidc/oidc-237/api/oauth/installation-token",
                "/oidc/oidc-237/api/oauth/clients/lookup",
                "/oidc/oidc-237/api/oauth/requests/agent",
            ] {
                let response = try await client.send(.get, headers: HTTPFields(), to: URI(string: path))
                #expect(response.status == .notFound)
            }
        }
    }
}
