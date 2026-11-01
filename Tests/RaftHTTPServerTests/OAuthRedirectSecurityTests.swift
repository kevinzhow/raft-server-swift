import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct RedirectFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let callback: String
}

private func makeRedirectFixture(suffix: String) -> RedirectFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 900_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 900_000 + number)
    let ownerEmail = "oauth-redirect-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-redirect-\(suffix)", name: "OAuth Redirect", ownerId: ownerId)
    return RedirectFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        callback: "https://client.example.test/callback"
    )
}

private func redirectLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func redirectObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func humanOAuthCallbackRejectsUnsafeAndUnregisteredRedirects() async throws {
    let fixture = makeRedirectFixture(suffix: "931")
    let accounts = fixture.accounts
    let unregistered = try accounts.oauth.createClient(
        serverId: fixture.serverId,
        createdByUserId: fixture.ownerId,
        name: "Unregistered callback",
        clientId: "redirect-unregistered-931"
    )
    let registered = try accounts.oauth.createClient(
        serverId: fixture.serverId,
        createdByUserId: fixture.ownerId,
        name: "Audit callback",
        clientId: "redirect-audit-931",
        returnUrl: fixture.callback
    )
    let legacy = try accounts.oauth.createClient(
        serverId: fixture.serverId,
        createdByUserId: fixture.ownerId,
        name: "Legacy callback",
        clientId: "redirect-legacy-931",
        returnUrl: fixture.callback
    )
    accounts.oauth.setClientReturnUrl(
        clientRecordId: legacy.id,
        returnUrl: "javascript:window.auditExecuted=true//"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await redirectLogin(client, email: fixture.ownerEmail)
            func authorize(clientKey: String, returnUrl: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"\(clientKey)\",\"serverId\":\"\(fixture.serverId)\",\"returnUrl\":\"\(returnUrl)\",\"scopes\":[\"openid\",\"profile\"]}")
                }
            }

            let unregisteredResponse = try await authorize(
                clientKey: unregistered.clientId,
                returnUrl: "https://attacker.example.test/callback"
            )
            #expect(unregisteredResponse.status == .badRequest)
            #expect(try redirectObject(unregisteredResponse)["code"] == nil)

            let legacyResponse = try await authorize(
                clientKey: legacy.clientId,
                returnUrl: "javascript:window.auditExecuted=true//"
            )
            #expect(legacyResponse.status == .badRequest)
            #expect(try redirectObject(legacyResponse)["code"] == nil)

            let mismatch = try await authorize(
                clientKey: registered.clientId,
                returnUrl: "https://attacker.example.test/callback"
            )
            #expect(mismatch.status == .badRequest)
            #expect(try redirectObject(mismatch)["code"] == nil)

            let valid = try await authorize(clientKey: registered.clientId, returnUrl: fixture.callback)
            #expect(valid.status == .ok)
            let validBody = try redirectObject(valid)
            #expect((validBody["code"] as? String)?.isEmpty == false)
            #expect(validBody["returnUrl"] as? String == fixture.callback)
        }
    }
}

@Test func oauthClientCreateAndUpdateRejectScriptReturnUrls() throws {
    let fixture = makeRedirectFixture(suffix: "932")
    #expect(throws: OAuthClientRejection.self) {
        _ = try fixture.accounts.oauth.createClient(
            serverId: fixture.serverId,
            createdByUserId: fixture.ownerId,
            name: "Audit registration",
            clientId: "redirect-script-932",
            returnUrl: "javascript:alert(1)"
        )
    }
    let created = try fixture.accounts.oauth.createClient(
        serverId: fixture.serverId,
        createdByUserId: fixture.ownerId,
        name: "Audit registration",
        clientId: "redirect-safe-932",
        returnUrl: fixture.callback
    )
    #expect(throws: OAuthClientRejection.self) {
        try fixture.accounts.oauth.updateClientReturnUrl(
            clientRecordId: created.id,
            returnUrl: "data:text/html,test"
        )
    }
}
