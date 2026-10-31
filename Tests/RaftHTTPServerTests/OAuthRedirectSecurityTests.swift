import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func humanOAuthAuthorizationRejectsUnsafeReturnURLs() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111396"
    let serverId = "33333333-3333-4333-8333-333333333532"
    accounts.addAccount(id: ownerId, email: "oauth-redirect@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-redirect", name: "OAuth Redirect", ownerId: ownerId)
    let callback = "https://client.example.test/callback"
    let unregistered = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: "Unregistered", clientId: "audit-unregistered")
    let legacy = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: "Legacy", clientId: "audit-legacy", returnUrl: callback)
    accounts.oauth.setClientReturnUrlForTesting(id: legacy.id, returnUrl: "javascript:window.auditExecuted=true//")
    let mismatched = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: "Mismatch", clientId: "audit-mismatch", returnUrl: callback)
    let valid = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: "Valid", clientId: "audit-valid", returnUrl: callback)

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
                request.body = .init(string: "{\"email\":\"oauth-redirect@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            func authorize(_ clientId: String, _ returnUrl: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"\(clientId)\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"\(returnUrl)\",\"scopes\":[\"openid\",\"profile\"]}")
                }
            }
            func body(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let unregisteredResponse = try await authorize(unregistered.clientId, callback)
            #expect(unregisteredResponse.status == .badRequest)
            #expect(try body(unregisteredResponse)["code"] == nil)

            let legacyResponse = try await authorize(legacy.clientId, "javascript:window.auditExecuted=true//")
            #expect(legacyResponse.status == .badRequest)
            #expect(try body(legacyResponse)["code"] == nil)

            let mismatchResponse = try await authorize(mismatched.clientId, "https://attacker.example.test/callback")
            #expect(mismatchResponse.status == .badRequest)
            #expect(try body(mismatchResponse)["code"] == nil)

            let validResponse = try await authorize(valid.clientId, callback)
            #expect(validResponse.status == .ok)
            let validBody = try body(validResponse)
            #expect((validBody["code"] as? String)?.isEmpty == false)
            #expect(validBody["returnUrl"] as? String == callback)
        }
    }
}
