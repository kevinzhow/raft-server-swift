import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func userinfoBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func humanUserinfoCarriesTheMemberAndStopsAfterRemoval() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111203"
    let memberId = "11111111-1111-4111-8111-111111111204"
    let serverId = "33333333-3333-4333-8333-333333333398"
    let memberAvatarUrl = "/api/avatars/users/0123456789abcdef0123456789abcdef.webp"
    accounts.addAccount(
        id: memberId,
        email: "oauth-userinfo-204@slock.test",
        password: "password123",
        avatarUrl: memberAvatarUrl
    )
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-userinfo-204", name: "OAuth Member Boundary", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Boundary Client",
        clientId: "oauth-boundary-204"
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
                request.body = .init(string: "{\"email\":\"oauth-userinfo-204@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let sessionToken = try userinfoBody(login)["accessToken"] as? String ?? ""

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(sessionToken)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(authorize.status == .ok)
            let code = try userinfoBody(authorize)["code"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try userinfoBody(exchanged)["access_token"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"
            let before = try await client.send(.get, headers: headers, to: "/api/oauth/userinfo")
            #expect(before.status == .ok)
            let body = try userinfoBody(before)
            #expect(body["type"] as? String == "human")
            #expect(body["sub"] as? String == memberId)
            #expect(body["server_role"] as? String == "member")
            #expect(body["preferred_username"] as? String == "oauth-userinfo-204")
            #expect(body["name"] as? String == "oauth-userinfo-204")
            #expect(body["avatar_url"] as? String == memberAvatarUrl)
            #expect(body["picture"] as? String == "http://localhost:3001\(memberAvatarUrl)")
            #expect(body["description"] == nil || body["description"] is NSNull)

            accounts.oauth.removeMember(serverId: serverId, userId: memberId)
            let after = try await client.send(.get, headers: headers, to: "/api/oauth/userinfo")
            #expect(after.status == .unauthorized)
        }
    }
}

@Test func humanUserinfoPictureOnlyUsesRaftUploadedAvatars() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111205"
    let memberId = "11111111-1111-4111-8111-111111111206"
    let serverId = "33333333-3333-4333-8333-333333333399"
    let providerAvatarUrl = "https://lh3.googleusercontent.com/a/provider-default=s96-c"
    accounts.addAccount(
        id: memberId,
        email: "oauth-provider-avatar-206@slock.test",
        password: "password123",
        avatarUrl: providerAvatarUrl
    )
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-provider-avatar-206", name: "OAuth Provider Avatar", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Provider Avatar Client",
        clientId: "oauth-provider-avatar-206"
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
                request.body = .init(string: "{\"email\":\"oauth-provider-avatar-206@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let sessionToken = try userinfoBody(login)["accessToken"] as? String ?? ""

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(sessionToken)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(authorize.status == .ok)
            let code = try userinfoBody(authorize)["code"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try userinfoBody(exchanged)["access_token"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"
            let userinfo = try await client.send(.get, headers: headers, to: "/api/oauth/userinfo")
            #expect(userinfo.status == .ok)
            let body = try userinfoBody(userinfo)
            #expect(body["avatar_url"] as? String == providerAvatarUrl)
            #expect(body["picture"] == nil || body["picture"] is NSNull)
        }
    }
}
