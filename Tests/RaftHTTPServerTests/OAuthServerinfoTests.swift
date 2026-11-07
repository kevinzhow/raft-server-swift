import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func serverinfoObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func serverinfoReadsTheLiveServerBehindTheToken() async throws {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111207"
    let serverId = "33333333-3333-4333-8333-333333333400"
    let otherServerId = "33333333-3333-4333-8333-333333333401"
    scene.auth.addAccount(id: ownerId, email: "oauth-serverinfo-207@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.oauth.addOwnedServer(id: serverId, slug: "oauth-serverinfo-207", name: "OAuth Serverinfo", ownerId: ownerId)
    scene.oauth.addOwnedServer(id: otherServerId, slug: "oauth-serverinfo-other-207", name: "Other OAuth Serverinfo", ownerId: ownerId)
    let created = try scene.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Serverinfo Client",
        clientId: "oauth-serverinfo-207"
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"oauth-serverinfo-207@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let sessionToken = try serverinfoObject(login)["accessToken"] as? String ?? ""

            var authorizeHeaders = HTTPFields()
            authorizeHeaders[.authorization] = "Bearer \(sessionToken)"
            authorizeHeaders[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(authorize.status == .ok)
            let code = try serverinfoObject(authorize)["code"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try serverinfoObject(exchanged)["access_token"] as? String ?? ""

            let serverAvatarUrl = "/api/attachments/oauth-serverinfo-avatar.webp"
            scene.oauth.updateServer(id: serverId, name: "Renamed OAuth Serverinfo", avatarUrl: serverAvatarUrl)
            scene.oauth.updateServer(id: otherServerId, name: "Wrong OAuth Serverinfo", avatarUrl: "/api/attachments/wrong-server-avatar.webp")

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"
            let info = try await client.send(.get, headers: headers, to: "/api/oauth/serverinfo?server_id=\(otherServerId)")
            #expect(info.status == .ok)
            let body = try serverinfoObject(info)
            #expect(body["id"] as? String == serverId)
            #expect(body["slug"] as? String == "oauth-serverinfo-207")
            #expect(body["name"] as? String == "Renamed OAuth Serverinfo")
            #expect(body["avatar_url"] as? String == serverAvatarUrl)
            #expect(body["picture"] as? String == "http://localhost:3001\(serverAvatarUrl)")
        }
    }
}

@Test func serverinfoProjectsCoarsePaidTier() async throws {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111208"
    let serverId = "33333333-3333-4333-8333-333333333402"
    scene.auth.addAccount(id: ownerId, email: "oauth-tier-208@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.oauth.addOwnedServer(id: serverId, slug: "oauth-tier-208", name: "OAuth Tier Server", ownerId: ownerId)
    let created = try scene.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Tier Client",
        clientId: "oauth-tier-208"
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            let accessToken = try await mintAccessToken(
                client,
                email: "oauth-tier-208@slock.test",
                clientId: created.clientId,
                clientSecret: created.clientSecret,
                serverId: serverId
            )
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"

            let free = try await client.send(.get, headers: headers, to: "/api/oauth/serverinfo")
            #expect(free.status == .ok)
            #expect(try serverinfoObject(free)["is_paid"] as? Bool == false)
            #expect(try serverinfoObject(free)["plan_tier"] as? String == "free")

            for plan in ["pro", "founder", "partner"] {
                scene.oauth.setServerPlan(id: serverId, plan: plan)
                let paid = try await client.send(.get, headers: headers, to: "/api/oauth/serverinfo")
                #expect(paid.status == .ok)
                #expect(try serverinfoObject(paid)["is_paid"] as? Bool == true)
                #expect(try serverinfoObject(paid)["plan_tier"] as? String == "paid")
            }
        }
    }
}

@Test func serverinfoFailsClosedForADeletedServer() async throws {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111209"
    let serverId = "33333333-3333-4333-8333-333333333403"
    scene.auth.addAccount(id: ownerId, email: "oauth-tier-deleted-209@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.oauth.addOwnedServer(id: serverId, slug: "oauth-tier-deleted-209", name: "OAuth Tier Deleted", ownerId: ownerId)
    let created = try scene.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Tier Deleted Client",
        clientId: "oauth-tier-deleted-209"
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            let accessToken = try await mintAccessToken(
                client,
                email: "oauth-tier-deleted-209@slock.test",
                clientId: created.clientId,
                clientSecret: created.clientSecret,
                serverId: serverId
            )
            scene.oauth.setServerPlan(id: serverId, plan: "pro")
            scene.oauth.deleteServer(id: serverId)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"
            let info = try await client.send(.get, headers: headers, to: "/api/oauth/serverinfo")
            #expect(info.status == .unauthorized)
        }
    }
}

private func mintAccessToken(
    _ client: any Client,
    email: String,
    clientId: String,
    clientSecret: String,
    serverId: String
) async throws -> String {
    var loginHeaders = HTTPFields()
    loginHeaders[.contentType] = "application/json"
    let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    #expect(login.status == .ok)
    let sessionToken = try serverinfoObject(login)["accessToken"] as? String ?? ""

    var authorizeHeaders = HTTPFields()
    authorizeHeaders[.authorization] = "Bearer \(sessionToken)"
    authorizeHeaders[.contentType] = "application/json"
    let authorize = try await client.send(.post, headers: authorizeHeaders, to: "/api/oauth/authorize/human") { request in
        request.body = .init(string: "{\"clientId\":\"\(clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"]}")
    }
    #expect(authorize.status == .ok)
    let code = try serverinfoObject(authorize)["code"] as? String ?? ""

    var tokenHeaders = HTTPFields()
    tokenHeaders[.contentType] = "application/json"
    let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
        request.body = .init(string: "{\"clientId\":\"\(clientId)\",\"clientSecret\":\"\(clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}")
    }
    #expect(exchanged.status == .ok)
    return try serverinfoObject(exchanged)["access_token"] as? String ?? ""
}
