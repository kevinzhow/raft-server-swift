import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func redirectBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func humanAuthorizationRejectsUnsafeOrMismatchedReturnUrls() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111234"
    let serverId = "33333333-3333-4333-8333-333333333429"
    let callback = "https://client.example.test/callback"
    accounts.addAccount(id: ownerId, email: "redirect-234@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "redirect-234", name: "Redirect", ownerId: ownerId)
    _ = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Registered callback",
        clientId: "redirect-registered-234",
        returnUrl: callback
    )
    let unregistered = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "No callback",
        clientId: "redirect-unregistered-234"
    )
    let legacy = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Legacy unsafe",
        clientId: "redirect-legacy-234"
    )
    accounts.oauth.setClientReturnUrl(clientRecordId: legacy.id, returnUrl: "javascript:window.auditExecuted=true//")

    var rejectedUnsafeRegistration = false
    do {
        _ = try accounts.oauth.createClient(
            serverId: serverId,
            createdByUserId: ownerId,
            name: "Unsafe registration",
            clientId: "redirect-unsafe-234",
            returnUrl: "javascript:alert(1)"
        )
    } catch {
        rejectedUnsafeRegistration = true
    }
    #expect(rejectedUnsafeRegistration)

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
                request.body = .init(string: "{\"email\":\"redirect-234@slock.test\",\"password\":\"password123\"}")
            }
            let session = try redirectBody(login)["accessToken"] as? String ?? ""

            func authorize(_ clientId: String, _ returnUrl: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(session)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"\(clientId)\",\"serverId\":\"\(serverId)\",\"returnUrl\":\"\(returnUrl)\",\"scopes\":[\"openid\",\"profile\"]}")
                }
            }

            let mismatch = try await authorize("redirect-registered-234", "https://attacker.example.test/callback")
            #expect(mismatch.status == .badRequest)
            #expect(try redirectBody(mismatch)["code"] == nil)

            let valid = try await authorize("redirect-registered-234", callback)
            #expect(valid.status == .ok)
            #expect((try redirectBody(valid)["code"] as? String)?.isEmpty == false)
            #expect(try redirectBody(valid)["returnUrl"] as? String == callback)

            let unregisteredResponse = try await authorize("redirect-unregistered-234", "https://attacker.example.test/callback")
            #expect(unregisteredResponse.status == .badRequest)
            #expect(try redirectBody(unregisteredResponse)["code"] == nil)
            _ = unregistered

            let legacyResponse = try await authorize("redirect-legacy-234", "javascript:window.auditExecuted=true//")
            #expect(legacyResponse.status == .badRequest)
            #expect(try redirectBody(legacyResponse)["code"] == nil)
        }
    }
}
