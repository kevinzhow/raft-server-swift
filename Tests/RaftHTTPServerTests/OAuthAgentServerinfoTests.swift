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

@Test func oauthPrincipalAgentSurfacesKeepRoleEnabledAndScopeRefusalsDistinct() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111647"
    let serverId = "33333333-3333-4333-8333-333333333673"
    let otherServerId = "33333333-3333-4333-8333-333333333674"
    accounts.addAccount(id: ownerId, email: "principal-agent-647@test.invalid", password: "password123")
    accounts.oauth.addOwnedServer(id: serverId, slug: "principal-agent-647", name: "Principal Agent", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "principal-other-647", name: "Other Principal", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "PrincipalAgent", creatorUserId: ownerId)
    let appClient = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId,
        name: "Principal Agent App", clientId: "principal-agent-client-647", allowedScopes: ["profile", "agent:read"])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func post(_ path: String, _ body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: URI(string: path)) { $0.body = .init(string: body) }
            }
            func mint(_ scopes: String) async throws -> String {
                let requested = try await post("/api/oauth/requests/agent", "{\"clientId\":\"\(appClient.clientId)\",\"clientSecret\":\"\(appClient.clientSecret)\",\"serverSlug\":\"principal-agent-647\",\"agentId\":\"\(agentId)\",\"scopes\":[\(scopes)]}")
                #expect(requested.status == .ok)
                #expect(try agentObject(requested)["status"] as? String == "approved")
                let requestId = try #require(try agentObject(requested)["requestId"] as? String)
                let token = try await post("/api/oauth/token", "{\"clientId\":\"\(appClient.clientId)\",\"clientSecret\":\"\(appClient.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
                #expect(token.status == .ok)
                return try #require(try agentObject(token)["access_token"] as? String)
            }
            func get(_ endpoint: String, _ token: String, mount: String = "") async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                return try await client.get(URI(string: "\(mount)/api/oauth/\(endpoint)"), headers: headers)
            }
            func refusal(_ response: ClientResponse, status: HTTPResponse.Status, message: String, cache: String? = nil) {
                #expect(response.status == status)
                #expect(response.body.string == "{\"error\":\"\(message)\"}")
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == cache)
            }
            let token = try await mint("\"profile\",\"agent:read\"")
            let identityOnly = try await mint("\"profile\"")
            let wrongMount = "/oidc/principal-other-647"
            for endpoint in ["userinfo", "serverinfo", "agents"] {
                let response = try await get(endpoint, token)
                #expect(response.status == .ok)
                let cache: String? = endpoint == "agents" ? "no-store" : nil
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == cache)
            }
            accounts.oauth.removeAgentMember(serverId: serverId, agentId: agentId)
            refusal(try await get("userinfo", token), status: .unauthorized, message: "Invalid or expired access token")
            #expect(try await get("serverinfo", token).status == .ok)
            refusal(try await get("agents", token), status: .unauthorized, message: "Invalid or expired access token", cache: "no-store")
            accounts.oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "")
            let emptyRole = try await get("userinfo", token)
            #expect(emptyRole.status == .ok)
            #expect(try agentObject(emptyRole)["server_role"] as? String == "")
            #expect(try await get("agents", token).status == .ok)
            refusal(try await get("agents", token, mount: wrongMount), status: .unauthorized,
                message: "Access token was issued for a different Server than this issuer", cache: "no-store")
            refusal(try await get("agents", identityOnly, mount: wrongMount), status: .forbidden,
                message: "agent:read permission is required from an enabled App", cache: "no-store")
            accounts.oauth.setClientEnabled(clientRecordId: appClient.id, enabled: false)
            for endpoint in ["userinfo", "serverinfo"] {
                #expect(try await get(endpoint, token).status == .ok)
                refusal(try await get(endpoint, token, mount: wrongMount), status: .unauthorized,
                    message: "Access token was issued for a different Server than this issuer")
            }
            for mount in ["", wrongMount] {
                refusal(try await get("agents", token, mount: mount), status: .forbidden,
                    message: "agent:read permission is required from an enabled App", cache: "no-store")
            }
            accounts.oauth.setClientEnabled(clientRecordId: appClient.id, enabled: true)
            accounts.oauth.deleteAgent(id: agentId)
            for endpoint in ["userinfo", "serverinfo", "agents"] {
                refusal(try await get(endpoint, token), status: .unauthorized, message: "Invalid or expired access token",
                    cache: endpoint == "agents" ? "no-store" : nil)
            }
        }
    }
}
