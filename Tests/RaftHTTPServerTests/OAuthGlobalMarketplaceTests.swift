import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func globalBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func globalMarketplaceAppAuthorizesOnlyAfterInstallation() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111219"
    let outsiderId = "11111111-1111-4111-8111-111111111220"
    let publisherServerId = "33333333-3333-4333-8333-333333333413"
    let contextServerId = "33333333-3333-4333-8333-333333333414"
    accounts.addAccount(id: ownerId, email: "oauth-global-owner-219@slock.test", password: "password123")
    accounts.addAccount(id: outsiderId, email: "oauth-global-outsider-220@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: publisherServerId, slug: "oauth-global-publisher-219", name: "Marketplace Publisher", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: contextServerId, slug: "oauth-global-context-219", name: "Customer Workspace", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: publisherServerId,
        createdByUserId: ownerId,
        name: "Marketplace Notes",
        clientId: "oauth-global-219",
        appType: "third_party_global",
        description: "Published Marketplace app",
        homepageUrl: "https://marketplace-notes.example.test",
        returnUrl: "https://marketplace-notes.example.test/login/slock/callback"
    )
    accounts.oauth.publishClient(clientRecordId: created.id, humanMarketplaceVisible: false)
    _ = accounts.oauth.installClient(
        serverId: contextServerId,
        clientRecordId: created.id,
        installedByUserId: ownerId,
        groups: []
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                #expect(response.status == .ok)
                return try globalBody(response)["accessToken"] as? String ?? ""
            }

            let ownerToken = try await login("oauth-global-owner-219@slock.test")
            let outsiderToken = try await login("oauth-global-outsider-220@slock.test")

            func lookup(_ token: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                return try await client.send(
                    .get,
                    headers: headers,
                    to: "/api/oauth/clients/lookup?client_id=oauth-global-219&server_id=\(contextServerId)"
                )
            }

            let found = try await lookup(ownerToken)
            #expect(found.status == .ok)
            let lookupBody = try globalBody(found)
            #expect(lookupBody["clientId"] as? String == "oauth-global-219")
            #expect(lookupBody["appType"] as? String == "third_party_global")
            #expect(lookupBody["name"] as? String == "Marketplace Notes")
            #expect(lookupBody["description"] as? String == "Published Marketplace app")
            #expect(lookupBody["returnUrl"] as? String == "https://marketplace-notes.example.test/login/slock/callback")

            #expect(try await lookup(outsiderToken).status == .notFound)

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(ownerToken)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"oauth-global-219\",\"serverId\":\"\(contextServerId)\",\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(authorize.status == .ok)
            let authorizeBody = try globalBody(authorize)
            #expect((authorizeBody["client"] as? [String: Any])?["appType"] as? String == "third_party_global")
            #expect((authorizeBody["server"] as? [String: Any])?["id"] as? String == contextServerId)
            let code = authorizeBody["code"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"oauth-global-219\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try globalBody(exchanged)["access_token"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"
            let userinfo = try await client.send(.get, headers: headers, to: "/api/oauth/userinfo")
            #expect(userinfo.status == .ok)
            let userinfoBody = try globalBody(userinfo)
            #expect(userinfoBody["type"] as? String == "human")
            #expect(userinfoBody["sub"] as? String == ownerId)
            #expect(userinfoBody["server_id"] as? String == contextServerId)
            #expect(userinfoBody["server_slug"] as? String == "oauth-global-context-219")
            #expect(userinfoBody["client_id"] as? String == "oauth-global-219")
            #expect(userinfoBody["preferred_username"] as? String == "oauth-global-owner-219")
            #expect(userinfoBody["name"] as? String == "oauth-global-owner-219")
            #expect(userinfoBody["description"] == nil || userinfoBody["description"] is NSNull)
        }
    }
}
