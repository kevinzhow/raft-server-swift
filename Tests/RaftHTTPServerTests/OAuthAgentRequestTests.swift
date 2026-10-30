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

            let picturePath = (body["picture"] as? String ?? "")
                .replacingOccurrences(of: "http://localhost:3001", with: "")
            let picture = try await client.send(.get, headers: HTTPFields(), to: "\(picturePath)")
            #expect(picture.status == .ok)
            #expect((picture.headers[HTTPField.Name("Content-Type")!] ?? "").hasPrefix("image/svg+xml"))
            #expect(picture.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=31536000, immutable")
            let svg = picture.body.string ?? ""
            #expect(svg.hasPrefix("<svg "))
            #expect(svg.contains("shape-rendering=\"crispEdges\""))

            let namedKey = OAuthLedger.pixelAvatarKey("pixel:cat")
            let named = try await client.send(
                .get,
                headers: HTTPFields(),
                to: "/api/avatars/pixel/\(namedKey).svg"
            )
            #expect(named.status == .ok)

            accounts.oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "admin")
            #expect(try agentRequestBody(try await client.send(.get, headers: userinfoHeaders, to: "/api/oauth/userinfo"))["server_role"] as? String == "admin")
            accounts.oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "member")
            #expect(try agentRequestBody(try await client.send(.get, headers: userinfoHeaders, to: "/api/oauth/userinfo"))["server_role"] as? String == "member")

            accounts.oauth.removeAgentMember(serverId: serverId, agentId: agentId)
            #expect(try await client.send(.get, headers: userinfoHeaders, to: "/api/oauth/userinfo").status == .unauthorized)
        }
    }
}

@Test func agentRequestRejectsUnknownScopesAndRetiredClients() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111222"
    let serverId = "33333333-3333-4333-8333-333333333416"
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-agent-scope-222", name: "OAuth Agent Scope Contract", ownerId: ownerId)
    _ = accounts.oauth.createAgent(serverId: serverId, name: "OauthAgentScopeBot")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Agent Scope Client",
        clientId: "oauth-agent-scope-222"
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
            let rejected = try await client.send(.post, headers: headers, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"oauth-agent-scope-222\",\"agentName\":\"OauthAgentScopeBot\",\"scopes\":[\"identity\",\"unknown:scope\"]}")
            }
            #expect(rejected.status == .badRequest)
            #expect(try agentRequestBody(rejected)["error"] as? String == "invalid_scope")

            accounts.oauth.setClientAppType(clientRecordId: created.id, appType: "slock_builtin")
            let retired = try await client.send(.post, headers: headers, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"oauth-agent-scope-222\",\"agentName\":\"OauthAgentScopeBot\",\"scopes\":[\"openid\",\"profile\",\"identity\"]}")
            }
            #expect(retired.status == .unauthorized)
        }
    }
}

@Test func agentInboundScopeNeedsAnExplicitClientDeclaration() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111223"
    let serverId = "33333333-3333-4333-8333-333333333417"
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-inbound-223", name: "OAuth Inbound Scope", ownerId: ownerId)
    _ = accounts.oauth.createAgent(serverId: serverId, name: "OauthInboundScopeBot")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Inbound Client",
        clientId: "oauth-inbound-223"
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
            func request() async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/oauth/requests/agent") { request in
                    request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"oauth-inbound-223\",\"agentName\":\"OauthInboundScopeBot\",\"scopes\":[\"openid\",\"agent:event:write\"]}")
                }
            }

            let rejected = try await request()
            #expect(rejected.status == .badRequest)
            #expect(try agentRequestBody(rejected)["error"] as? String == "invalid_scope")

            accounts.oauth.setClientAllowedScopes(
                clientRecordId: created.id,
                scopes: ["openid", "profile", "identity", "agent:event:write"]
            )
            let accepted = try await request()
            #expect(accepted.status == .ok)
            #expect(try agentRequestBody(accepted)["scopes"] as? [String] == ["agent:event:write", "openid"])
        }
    }
}

@Test func inboundAgentTokenRequiresTheServerResource() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111224"
    let serverId = "33333333-3333-4333-8333-333333333418"
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-resource-224", name: "OAuth Resource Binding", ownerId: ownerId)
    _ = accounts.oauth.createAgent(serverId: serverId, name: "OauthResourceBot")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Resource Client",
        clientId: "oauth-resource-224",
        allowedScopes: ["openid", "profile", "identity", "agent:event:write"]
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

            func request(_ scopes: String) async throws -> String {
                let response = try await client.send(.post, headers: headers, to: "/api/oauth/requests/agent") { request in
                    request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"oauth-resource-224\",\"agentName\":\"OauthResourceBot\",\"scopes\":[\(scopes)]}")
                }
                #expect(response.status == .ok)
                return try agentRequestBody(response)["requestId"] as? String ?? ""
            }

            func exchange(_ requestId: String, resource: String? = nil) async throws -> ClientResponse {
                let extra = resource.map { ",\"resource\":\"\($0)\"" } ?? ""
                return try await client.send(.post, headers: headers, to: "/api/oauth/token") { request in
                    request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"\(extra)}")
                }
            }

            let identityRequest = try await request("\"openid\",\"profile\"")
            let identityToken = try await exchange(identityRequest)
            #expect(identityToken.status == .ok)
            #expect(try agentRequestBody(identityToken)["resource"] == nil)

            let inboundRequest = try await request("\"agent:event:write\"")
            let missingResource = try await exchange(inboundRequest)
            #expect(missingResource.status == .badRequest)
            #expect(try agentRequestBody(missingResource)["error"] as? String == "resource is required for requested scopes")

            let resource = "urn:raft:server:\(serverId):agent-inbound"
            let resourceToken = try await exchange(inboundRequest, resource: resource)
            #expect(resourceToken.status == .ok)
            #expect(try agentRequestBody(resourceToken)["resource"] as? String == resource)
        }
    }
}

@Test func agentEventPostQueuesOncePerExternalId() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111225"
    let serverId = "33333333-3333-4333-8333-333333333419"
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-events-225", name: "OAuth Agent Events", ownerId: ownerId)
    _ = accounts.oauth.createAgent(serverId: serverId, name: "OauthEventBot")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Event Client",
        clientId: "oauth-events-225",
        allowedScopes: ["openid", "agent:event:write"]
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var jsonHeaders = HTTPFields()
            jsonHeaders[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: jsonHeaders, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"oauth-events-225\",\"agentName\":\"OauthEventBot\",\"scopes\":[\"agent:event:write\"]}")
            }
            #expect(requested.status == .ok)
            let requestId = try agentRequestBody(requested)["requestId"] as? String ?? ""

            let tokenBody: [String: Any] = [
                "clientId": created.clientId,
                "clientSecret": created.clientSecret,
                "grantType": "urn:slock:grant-type:agent_request",
                "requestId": requestId,
                "resource": "urn:raft:server:\(serverId):agent-inbound",
            ]
            let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
            let exchanged = try await client.send(.post, headers: jsonHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: String(decoding: tokenData, as: UTF8.self))
            }
            #expect(exchanged.status == .ok)
            let accessToken = try agentRequestBody(exchanged)["access_token"] as? String ?? ""

            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.authorization] = "Bearer \(accessToken)"
            let eventBody = "{\"kind\":\"event\",\"summary\":\"New build is ready\",\"externalEventId\":\"build-225\",\"payload\":{\"url\":\"https://example.test/build/225\",\"nested\":{\"reviewer\":\"@Ray\"}}}"
            let posted = try await client.send(.post, headers: headers, to: "/api/oauth/agent-events") { request in
                request.body = .init(string: eventBody)
            }
            #expect(posted.status == .accepted)
            let postedBody = try agentRequestBody(posted)
            #expect(postedBody["status"] as? String == "queued")
            #expect((postedBody["id"] as? String)?.isEmpty == false)
            #expect((postedBody["payloadHash"] as? String)?.wholeMatch(of: /^[0-9a-f]{64}$/) != nil)
            let eventId = postedBody["id"] as? String ?? ""

            let duplicate = try await client.send(.post, headers: headers, to: "/api/oauth/agent-events") { request in
                request.body = .init(string: "{\"kind\":\"event\",\"summary\":\"Duplicate build\",\"externalEventId\":\"build-225\",\"payload\":{\"duplicate\":true}}")
            }
            #expect(duplicate.status == .ok)
            let duplicateBody = try agentRequestBody(duplicate)
            #expect(duplicateBody["id"] as? String == eventId)
            #expect(duplicateBody["deduped"] as? Bool == true)
        }
    }
}
