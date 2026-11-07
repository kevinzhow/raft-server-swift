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

@Test func oauthPrincipalHumanUsesGrantIdentityAndLiveRoleServerAndRawURL() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111647"
    let serverId = "33333333-3333-4333-8333-333333333673"
    let email = "principal-user-647@test.invalid"
    let grantAvatar = "/API/AVATARS/USERS/ABC123.WEBP"
    accounts.addAccount(id: ownerId, email: email, password: "password123", avatarUrl: grantAvatar)
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "Grant Identity")
    accounts.oauth.addOwnedServer(id: serverId, slug: "principal-user-647", name: "Before Mint", ownerId: ownerId)
    let appClient = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId,
        name: "Principal User App", clientId: "principal-user-client-647", allowedScopes: ["email"])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func post(_ path: String, _ body: String, authorization: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                headers[.authorization] = authorization
                return try await client.send(.post, headers: headers, to: URI(string: path)) { $0.body = .init(string: body) }
            }
            let login = try await post("/api/auth/login", "{\"email\":\"\(email)\",\"password\":\"password123\"}")
            #expect(login.status == .ok)
            let session = try #require(try userinfoBody(login)["accessToken"] as? String)
            let issued = try await post("/api/oauth/authorize/human", "{\"clientId\":\"\(appClient.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"email\"]}", authorization: "Bearer \(session)")
            #expect(issued.status == .ok)
            let code = try #require(try userinfoBody(issued)["code"] as? String)
            let minted = try await post("/api/oauth/token", "{\"clientId\":\"\(appClient.clientId)\",\"clientSecret\":\"\(appClient.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
            #expect(minted.status == .ok)
            let token = try #require(try userinfoBody(minted)["access_token"] as? String)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            let principalHeaders = headers
            // Existing real profile fixture writes replace the current account;
            // the already issued grant must retain its earlier identity fields.
            accounts.addAccount(id: ownerId, email: email, password: "password123", avatarUrl: "/api/avatars/users/def456.webp")
            accounts.setAccountProfileForTesting(id: ownerId, name: "Current Identity")
            var sessionHeaders = HTTPFields()
            sessionHeaders[.authorization] = "Bearer \(session)"
            let current = try await client.get("/api/auth/me", headers: sessionHeaders)
            #expect(current.status == .ok)
            let currentUser = try userinfoBody(current)
            #expect(currentUser["name"] as? String == "Current Identity")
            #expect(currentUser["avatarUrl"] as? String == "/api/avatars/users/def456.webp")
            #expect(currentUser["emailVerified"] as? Bool == false)
            accounts.oauth.addMember(serverId: serverId, userId: ownerId, role: "admin")
            accounts.oauth.updateServer(id: serverId, name: "After Mint", avatarUrl: "/server.svg")
            accounts.oauth.setServerPlan(id: serverId, plan: "partner")
            accounts.oauth.jwtSecret = ""
            let bases = [
                ("https://live.profile.test/deep///", "https://live.profile.test/deep///API/AVATARS/USERS/ABC123.WEBP", "https://live.profile.test/deep///server.svg"),
                (" invalid origin///", " invalid origin///API/AVATARS/USERS/ABC123.WEBP", " invalid origin///server.svg"),
            ]
            for (base, humanPicture, serverPicture) in bases {
                accounts.oauthFlows.configureDeployment(.init(serverURL: base))
                for mount in ["", "/oidc/principal-user-647"] {
                    let user = try await client.get(URI(string: "\(mount)/api/oauth/userinfo"), headers: principalHeaders)
                    #expect(user.status == .ok)
                    #expect(user.headers[HTTPField.Name("Cache-Control")!] == nil)
                    #expect(user.body.string == "{\"scope\":\"email\",\"client_id\":\"\(appClient.clientId)\",\"client_name\":\"Principal User App\",\"server_id\":\"\(serverId)\",\"server_slug\":\"principal-user-647\",\"sub\":\"\(ownerId)\",\"type\":\"human\",\"server_role\":\"admin\",\"preferred_username\":\"Grant Identity\",\"name\":\"Grant Identity\",\"avatar_url\":\"\(grantAvatar)\",\"picture\":\"\(humanPicture)\",\"description\":null,\"email\":\"\(email)\",\"email_verified\":true}")
                    let server = try await client.get(URI(string: "\(mount)/api/oauth/serverinfo"), headers: principalHeaders)
                    #expect(server.status == .ok)
                    #expect(server.headers[HTTPField.Name("Cache-Control")!] == nil)
                    #expect(server.body.string == "{\"id\":\"\(serverId)\",\"slug\":\"principal-user-647\",\"name\":\"After Mint\",\"avatar_url\":\"/server.svg\",\"picture\":\"\(serverPicture)\",\"is_paid\":true,\"plan_tier\":\"paid\"}")
                }
            }
            accounts.oauth.removeAuthorizationCodeForTesting(id: code)
            for mount in ["", "/oidc/principal-user-647"] {
                let user = try await client.get(URI(string: "\(mount)/api/oauth/userinfo"), headers: principalHeaders)
                #expect(user.status == .unauthorized)
                #expect(user.body.string == "{\"error\":\"Invalid or expired access token\"}")
                #expect(user.headers[HTTPField.Name("Cache-Control")!] == nil)
                let server = try await client.get(URI(string: "\(mount)/api/oauth/serverinfo"), headers: principalHeaders)
                #expect(server.status == .ok)
                #expect(server.headers[HTTPField.Name("Cache-Control")!] == nil)
            }
        }
    }
}
