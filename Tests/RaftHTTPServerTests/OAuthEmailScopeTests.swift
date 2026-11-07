import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func scopeObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func clientLookupAndAuthorizationReportDisallowedEmailScope() async throws {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111212"
    let serverId = "33333333-3333-4333-8333-333333333406"
    scene.auth.addAccount(id: ownerId, email: "oauth-email-212@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.oauth.addOwnedServer(id: serverId, slug: "oauth-email-212", name: "OAuth Email Scope", ownerId: ownerId)
    let created = try scene.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OIDC Email Client",
        clientId: "oauth-email-212"
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"oauth-email-212@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let sessionToken = try scopeObject(login)["accessToken"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(sessionToken)"
            let lookup = try await client.send(
                .get,
                headers: headers,
                to: "/api/oauth/clients/lookup?client_id=\(created.clientId)&server_id=\(serverId)&scope=openid%20profile%20email"
            )
            #expect(lookup.status == .ok)
            let validation = try scopeObject(lookup)["scopeValidation"] as? [String: Any]
            #expect(validation?["allowed"] as? Bool == false)
            #expect(validation?["reason"] as? String == "not_allowed")
            #expect(validation?["disallowedScopes"] as? [String] == ["email"])

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(sessionToken)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"https://oidc-email.example.test/callback\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true}")
            }
            #expect(authorize.status == .badRequest)
            let body = try scopeObject(authorize)
            #expect(body["error"] as? String == "invalid_scope")
            #expect(body["errorCode"] as? String == "OAUTH_SCOPE_NOT_ALLOWED")
            #expect(body["error_description"] as? String == "This OAuth client is not allowed to request: email. Update the client's allowed scopes and try again.")
            #expect(body["disallowedScopes"] as? [String] == ["email"])
        }
    }
}
