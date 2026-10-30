import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func scopeBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func authorizeKeepsExactLegacyScopeTuples() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111213"
    let serverId = "33333333-3333-4333-8333-333333333407"
    accounts.addAccount(id: ownerId, email: "oauth-scope-213@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-scope-213", name: "OAuth Scope Contract", ownerId: ownerId)
    _ = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Grandfathered Winbox",
        clientId: "winbox"
    )
    let other = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Not Winbox",
        clientId: "not-winbox-213"
    )
    _ = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Internal App Admin",
        clientId: "slock-internal-app-admin"
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
                request.body = .init(string: "{\"email\":\"oauth-scope-213@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let sessionToken = try scopeBody(login)["accessToken"] as? String ?? ""

            func authorize(_ clientId: String, _ scopes: [String]) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(sessionToken)"
                headers[.contentType] = "application/json"
                let scopeJSON = scopes.map { "\"\($0)\"" }.joined(separator: ",")
                return try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"\(clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\(scopeJSON)]}")
                }
            }

            let grandfathered = try await authorize("winbox", ["openid", "winbox:opencli:twitter"])
            #expect(grandfathered.status == .ok)
            #expect(try scopeBody(grandfathered)["scopes"] as? [String] == ["openid", "winbox:opencli:twitter"])

            let sameScopeNewClient = try await authorize(other.clientId, ["openid", "winbox:opencli:twitter"])
            #expect(sameScopeNewClient.status == .badRequest)
            let newClientBody = try scopeBody(sameScopeNewClient)
            #expect(newClientBody["errorCode"] as? String == "OAUTH_SCOPE_UNSUPPORTED")
            #expect(newClientBody["disallowedScopes"] as? [String] == ["winbox:opencli:twitter"])
            #expect(newClientBody["error_description"] as? String == "Raft does not support the requested OAuth scope: winbox:opencli:twitter. Update the requested scopes and try again.")

            let newScopeOldClient = try await authorize("winbox", ["openid", "winbox:opencli:new"])
            #expect(newScopeOldClient.status == .badRequest)
            #expect(try scopeBody(newScopeOldClient)["disallowedScopes"] as? [String] == ["winbox:opencli:new"])

            let deprecated = try await authorize("slock-internal-app-admin", ["openid", "profile", "app_admin"])
            #expect(deprecated.status == .badRequest)
            #expect(try scopeBody(deprecated)["disallowedScopes"] as? [String] == ["app_admin"])
        }
    }
}
