import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func agentRequestBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func agentRequestGrantsImmediatelyAndTracksTheLiveRole() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111221"
    let serverId = "33333333-3333-4333-8333-333333333415"
    let avatarUrl = "pixel:random:oauth-agent-bot"
    accounts.addAccount(id: ownerId, email: "oauth-agent-221@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-agent-login-221", name: "OAuth Agent Login", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "OauthAgentBot", avatarUrl: avatarUrl)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Agent Client",
        clientId: "oauth-agent-221"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: headers, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"oauth-agent-login-221\",\"agentName\":\"OauthAgentBot\",\"scopes\":[\"openid\",\"profile\",\"identity\"]}")
            }
            #expect(requested.status == .ok)
            let requestBody = try agentRequestBody(requested)
            #expect(requestBody["status"] as? String == "approved")
            #expect(requestBody["scopes"] as? [String] == ["identity", "openid", "profile"])
            let requestId = requestBody["requestId"] as? String ?? ""

            let exchanged = try await client.send(.post, headers: headers, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try agentRequestBody(exchanged)["access_token"] as? String ?? ""

            let replay = try await client.send(.post, headers: headers, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
            }
            #expect(replay.status == .conflict)
            let replayBody = try agentRequestBody(replay)
            #expect(replayBody["error"] as? String == "request_already_consumed")
            #expect(replayBody["error_description"] as? String == "This Login with Raft request is one-time and has already been exchanged. Discard it and obtain a fresh request before retrying.")
            #expect(replayBody["next_action"] as? String == "obtain_fresh_request")

            var userinfoHeaders = HTTPFields()
            userinfoHeaders[.authorization] = "Bearer \(accessToken)"
            let userinfo = try await client.send(.get, headers: userinfoHeaders, to: "/api/oauth/userinfo")
            #expect(userinfo.status == .ok)
            let body = try agentRequestBody(userinfo)
            #expect(body["type"] as? String == "agent")
            #expect(body["sub"] as? String == agentId)
            #expect(body["server_role"] as? String == "member")
            #expect(body["preferred_username"] as? String == "OauthAgentBot")
            #expect(body["name"] as? String == "OauthAgentBot")
            #expect(body["avatar_url"] as? String == avatarUrl)
            #expect(body["picture"] as? String == "http://localhost:3001/api/avatars/pixel/\(OAuthLedger.pixelAvatarKey(avatarUrl)).svg")
            #expect(body["description"] == nil || body["description"] is NSNull)

            accounts.oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "admin")
            #expect(try agentRequestBody(try await client.send(.get, headers: userinfoHeaders, to: "/api/oauth/userinfo"))["server_role"] as? String == "admin")
            accounts.oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "member")
            #expect(try agentRequestBody(try await client.send(.get, headers: userinfoHeaders, to: "/api/oauth/userinfo"))["server_role"] as? String == "member")

            accounts.oauth.removeAgentMember(serverId: serverId, agentId: agentId)
            #expect(try await client.send(.get, headers: userinfoHeaders, to: "/api/oauth/userinfo").status == .unauthorized)
        }
    }
}
