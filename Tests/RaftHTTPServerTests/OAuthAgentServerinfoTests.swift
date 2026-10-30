import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func agentObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func agentOAuthServerinfoUsesTheServerScopedToken() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111210"
    let serverId = "33333333-3333-4333-8333-333333333404"
    accounts.addAccount(id: ownerId, email: "oauth-agent-serverinfo-210@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-agent-serverinfo-210", name: "OAuth Agent Serverinfo", ownerId: ownerId)
    _ = accounts.oauth.createAgent(serverId: serverId, name: "OauthAgentServerinfoBot")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Agent Serverinfo Client",
        clientId: "oauth-as-210"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var requestHeaders = HTTPFields()
            requestHeaders[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: requestHeaders, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"oauth-agent-serverinfo-210\",\"agentName\":\"OauthAgentServerinfoBot\",\"scopes\":[\"openid\",\"profile\",\"identity\"]}")
            }
            #expect(requested.status == .ok)
            let requestId = try agentObject(requested)["requestId"] as? String ?? ""

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let exchanged = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
            }
            #expect(exchanged.status == .ok)
            let accessToken = try agentObject(exchanged)["access_token"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"
            let info = try await client.send(.get, headers: headers, to: "/api/oauth/serverinfo")
            #expect(info.status == .ok)
            let body = try agentObject(info)
            #expect(body["id"] as? String == serverId)
            #expect(body["slug"] as? String == "oauth-agent-serverinfo-210")
            #expect(body["name"] as? String == "OAuth Agent Serverinfo")
            #expect(body["avatar_url"] == nil || body["avatar_url"] is NSNull)
            #expect(body["picture"] == nil || body["picture"] is NSNull)
        }
    }
}
