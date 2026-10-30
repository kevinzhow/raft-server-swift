import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func retiredBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func retiredBuiltInClientFailsClosedOnEveryOAuthSurface() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111216"
    let serverId = "33333333-3333-4333-8333-333333333410"
    accounts.addAccount(id: ownerId, email: "oauth-builtin-216@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-builtin-216", name: "Slock Builtin Apps", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Slock Survey",
        clientId: "oauth-builtin-216",
        description: "Built-in survey app",
        homepageUrl: "https://survey.slock.test",
        returnUrl: "https://survey.slock.test/login/slock/callback"
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
                request.body = .init(string: "{\"email\":\"oauth-builtin-216@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let sessionToken = try retiredBody(login)["accessToken"] as? String ?? ""

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(sessionToken)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(authorize.status == .ok)
            let code = try retiredBody(authorize)["code"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try retiredBody(exchanged)["access_token"] as? String ?? ""

            accounts.oauth.setClientAppType(clientRecordId: created.id, appType: "slock_builtin")

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(sessionToken)"
            let lookup = try await client.send(
                .get,
                headers: headers,
                to: "/api/oauth/clients/lookup?client_id=\(created.clientId)&server_id=\(serverId)"
            )
            #expect(lookup.status == .notFound)

            let retiredAuthorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(retiredAuthorize.status == .notFound)

            let retiredExchange = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
            }
            #expect(retiredExchange.status == .unauthorized)

            let installationToken = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/installation-token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"installationId\":\"\(UUID().uuidString.lowercased())\"}")
            }
            #expect(installationToken.status == .unauthorized)

            let installationLookup = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/installations/lookup") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverId\":\"\(serverId)\"}")
            }
            #expect(installationLookup.status == .unauthorized)

            var bearerHeaders = HTTPFields()
            bearerHeaders[.authorization] = "Bearer \(accessToken)"
            let userinfo = try await client.send(.get, headers: bearerHeaders, to: "/api/oauth/userinfo")
            #expect(userinfo.status == .unauthorized)
        }
    }
}
