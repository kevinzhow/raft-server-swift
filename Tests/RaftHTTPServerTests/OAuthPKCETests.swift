import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func pkceBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func unsolicitedVerifierCannotDowngradeANonPKCECode() async throws {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111233"
    let serverId = "33333333-3333-4333-8333-333333333428"
    scene.auth.addAccount(id: ownerId, email: "pkce-233@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.oauth.addOwnedServer(id: serverId, slug: "pkce-233", name: "PKCE downgrade", ownerId: ownerId)
    let created = try scene.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "PKCE RP",
        clientId: "pkce-233",
        returnUrl: "https://rp.example.test/login/generic_oauth",
        allowedScopes: ["openid", "profile"]
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"pkce-233@slock.test\",\"password\":\"password123\"}")
            }
            let session = try pkceBody(login)["accessToken"] as? String ?? ""

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(session)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"pkce-233\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"https://rp.example.test/login/generic_oauth\",\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(authorize.status == .ok)
            let code = try pkceBody(authorize)["code"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"

            func exchange(path: String, verifierJSON: String?) async throws -> ClientResponse {
                let verifier = verifierJSON.map { ",\"code_verifier\":\($0)" } ?? ""
                let body = "{\"clientId\":\"pkce-233\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"\(verifier)}"
                return try await client.send(.post, headers: tokenHeaders, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }

            for path in ["/api/oauth/token", "/oidc/pkce-233/api/oauth/token"] {
                for verifier in ["\"rp-verifier-abcdefghijklmnopqrstuvwxyz-0123456789\"", "\"\"", "null", "[\"verifier\"]"] {
                    let response = try await exchange(path: path, verifierJSON: verifier)
                    #expect(response.status == .badRequest)
                    let body = try pkceBody(response)
                    #expect(body["error"] as? String == "invalid_grant")
                    #expect(body["access_token"] == nil)
                    #expect(body["id_token"] == nil)
                }
            }

            let legitimate = try await exchange(path: "/api/oauth/token", verifierJSON: nil)
            #expect(legitimate.status == .ok)
            #expect((try pkceBody(legitimate)["access_token"] as? String)?.isEmpty == false)

            let replay = try await exchange(path: "/api/oauth/token", verifierJSON: nil)
            #expect(replay.status == .conflict)
        }
    }
}
