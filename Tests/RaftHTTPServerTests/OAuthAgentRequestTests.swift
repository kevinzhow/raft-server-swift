import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
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

@Test func queuedAgentEventRetryIsReclaimedAndKeepsItsId() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111226"
    let serverId = "33333333-3333-4333-8333-333333333420"
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-retry-226", name: "OAuth Event Retry", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "OauthRetryBot")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Retry Client",
        clientId: "oauth-retry-226",
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
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"oauth-retry-226\",\"agentName\":\"OauthRetryBot\",\"scopes\":[\"agent:event:write\"]}")
            }
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
            let accessToken = try agentRequestBody(exchanged)["access_token"] as? String ?? ""

            let eventId = accounts.oauth.seedQueuedAgentEvent(
                serverId: serverId,
                agentId: agentId,
                clientRecordId: created.id,
                externalEventId: "retry-build-226"
            )

            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.authorization] = "Bearer \(accessToken)"
            let retry = try await client.send(.post, headers: headers, to: "/api/oauth/agent-events") { request in
                request.body = .init(string: "{\"kind\":\"event\",\"summary\":\"Retry build\",\"externalEventId\":\"retry-build-226\",\"payload\":{\"retry\":true}}")
            }
            #expect(retry.status == .ok)
            let body = try agentRequestBody(retry)
            #expect(body["id"] as? String == eventId)
            #expect(body["status"] as? String == "queued")
            #expect(body["deduped"] as? Bool == true)
        }
    }
}

private struct AppAgentRequestBoundaryFixture: Sendable {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let serverId: String
    let foreignServerId: String
    let agentId: String
    let foreignAgentId: String
    let local: CreatedOAuthClient
    let global: CreatedOAuthClient

    init() throws {
        let accounts = EmailLoginDirectory()
        let ownerId = "11111111-1111-4111-8111-111111111643"
        let serverId = "33333333-3333-4333-8333-333333333668"
        let foreignServerId = "33333333-3333-4333-8333-333333333669"
        accounts.addAccount(id: ownerId, email: "g3-boundary-643@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "g3-request-boundary", name: "G3 Boundary", ownerId: ownerId)
        accounts.oauth.addOwnedServer(id: foreignServerId, slug: "g3-request-foreign", name: "G3 Foreign", ownerId: ownerId)
        let agentId = accounts.oauth.createAgent(serverId: serverId, name: "BoundaryBot", displayName: "显示 / Bot", creatorUserId: ownerId)
        let foreignAgentId = accounts.oauth.createAgent(serverId: foreignServerId, name: "ForeignBot", creatorUserId: ownerId)
        let local = try accounts.oauth.createClient(
            serverId: serverId, createdByUserId: ownerId, name: "请求 / App", clientId: "g3-local-boundary"
        )
        let global = try accounts.oauth.createClient(
            serverId: foreignServerId, createdByUserId: ownerId, name: "Global App", clientId: "g3-global-boundary", appType: "third_party_global"
        )
        self.accounts = accounts
        self.ownerId = ownerId
        self.serverId = serverId
        self.foreignServerId = foreignServerId
        self.agentId = agentId
        self.foreignAgentId = foreignAgentId
        self.local = local
        self.global = global
    }
}

private func appAgentBoundaryBody(
    _ app: CreatedOAuthClient, selector: String, scopes: String? = "[\"openid\"]",
    serverSlug: String = "g3-request-boundary", extra: String = ""
) -> String {
    let scopeField = scopes.map { ",\"scopes\":\($0)" } ?? ""
    return "{\"clientId\":\"\(app.clientId)\",\"clientSecret\":\"\(app.clientSecret)\",\"serverSlug\":\"\(serverSlug)\",\(selector)\(scopeField)\(extra)}"
}

private func postAppAgentBoundary(
    _ client: any Client, body: String, authorization: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.authorization] = authorization
    return try await client.send(.post, headers: headers, to: "/api/oauth/requests/agent") {
        $0.body = .init(string: body)
    }
}

private func expectAppAgentBoundaryWire(_ response: ClientResponse, status: HTTPResponse.Status, body: String) {
    #expect(response.status == status)
    #expect(response.body.string == body)
    #expect(response.headers[.contentType] == AppFallback.jsonContentType)
    #expect(response.headers[.contentLength] == String(body.utf8.count))
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == AppFallback.robotsTag)
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == nil)
}

@Test func appAgentRequestRefusalsKeepClientServerAgentInstallationScopeOrder() async throws {
    let f = try AppAgentRequestBoundaryFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let badSelector = "\"agentId\":\"invalid\",\"agentName\":\"BoundaryBot\""
            let cases: [(String, HTTPResponse.Status, String)] = [
                ("{\"serverSlug\":\"missing\",\"agentId\":\"invalid\",\"scopes\":[7]}", .unauthorized, "Client credentials are required"),
                ("{\"clientId\":\"wrong\",\"clientSecret\":\"wrong\",\"serverSlug\":\"missing\",\"agentId\":\"invalid\",\"scopes\":[7]}", .unauthorized, "Invalid client credentials"),
                (appAgentBoundaryBody(f.local, selector: badSelector, scopes: "[7]", serverSlug: "missing"), .notFound, "Server not found"),
                (appAgentBoundaryBody(f.local, selector: badSelector, scopes: "[7]"), .notFound, "Agent not found"),
                (appAgentBoundaryBody(f.global, selector: "\"agentId\":\"\(f.foreignAgentId)\"", scopes: "[7]"), .notFound, "Agent not found"),
                (appAgentBoundaryBody(f.global, selector: "\"agentId\":\"\(f.agentId)\"", scopes: "[7]"), .notFound, "OAuth client not found for server"),
                (appAgentBoundaryBody(f.local, selector: "\"agentId\":\"\(f.agentId)\"", scopes: "[7]"), .badRequest, "invalid_scope"),
            ]
            for (body, status, message) in cases {
                expectAppAgentBoundaryWire(try await postAppAgentBoundary(client, body: body), status: status, body: "{\"error\":\"\(message)\"}")
            }
            // Basic authenticates independently, but this endpoint never parses form fields.
            let basic = Data("\(f.local.clientId):\(f.local.clientSecret)".utf8).base64EncodedString()
            let form = "serverSlug=g3-request-boundary&agentName=BoundaryBot&scopes=openid"
            expectAppAgentBoundaryWire(try await postAppAgentBoundary(client, body: form, authorization: "Basic \(basic)"),
                status: .notFound, body: "{\"error\":\"Server not found\"}")
        }
    }
}

@Test func appAgentRequestCredentialsSelectorsAndDisabledAppsKeepTheirAcceptanceSets() async throws {
    let f = try AppAgentRequestBoundaryFixture()
    f.accounts.oauth.setClientEnabled(clientRecordId: f.local.id, enabled: false)
    _ = f.accounts.oauth.installClient(serverId: f.serverId, clientRecordId: f.global.id, installedByUserId: f.ownerId, groups: [])
    f.accounts.oauth.setClientEnabled(clientRecordId: f.global.id, enabled: false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let body = appAgentBoundaryBody(f.local, selector: "\"agentName\":\" BoundaryBot \"", serverSlug: " g3-request-boundary ")
            let basic = Data("\(f.local.clientId):\(f.local.clientSecret)".utf8).base64EncodedString()
            let wrongBodyCredentials = body.replacingOccurrences(of: f.local.clientId, with: "wrong-app").replacingOccurrences(of: f.local.clientSecret, with: "wrong-secret")
            for (authorization, payload) in [
                ("Basic \(basic)", wrongBodyCredentials),
                ("Basic invalid", body),
                ("", appAgentBoundaryBody(f.local, selector: "\"agentId\":\"\(f.agentId.uppercased())\",\"agentName\":\"wrong\"")),
                ("", appAgentBoundaryBody(f.local, selector: "\"agentId\":\"\",\"agentName\":\" BoundaryBot \"")),
                ("", appAgentBoundaryBody(f.local, selector: "\"agentId\":7,\"agentName\":\"BoundaryBot\"")),
            ] {
                let response = try await postAppAgentBoundary(client, body: payload, authorization: authorization.isEmpty ? nil : authorization)
                #expect(response.status == .ok)
                #expect(try agentRequestBody(response)["status"] as? String == "approved")
            }
            let whitespaceId = appAgentBoundaryBody(f.local, selector: "\"agentId\":\" \(f.agentId) \",\"agentName\":\"BoundaryBot\"")
            expectAppAgentBoundaryWire(try await postAppAgentBoundary(client, body: whitespaceId), status: .notFound, body: "{\"error\":\"Agent not found\"}")
            let emptyBasicSecret = Data("\(f.local.clientId):".utf8).base64EncodedString()
            expectAppAgentBoundaryWire(try await postAppAgentBoundary(client, body: body, authorization: "Basic \(emptyBasicSecret)"),
                status: .unauthorized, body: "{\"error\":\"Invalid client credentials\"}")
            let emptySnakeId = body.replacingOccurrences(of: "{", with: "{\"client_id\":\"\",")
            expectAppAgentBoundaryWire(try await postAppAgentBoundary(client, body: emptySnakeId), status: .unauthorized,
                body: "{\"error\":\"Client credentials are required\"}")
            let globalBody = appAgentBoundaryBody(f.global, selector: "\"agentId\":\"\(f.agentId)\"")
            expectAppAgentBoundaryWire(try await postAppAgentBoundary(client, body: globalBody), status: .unauthorized,
                body: "{\"error\":\"Invalid client credentials\"}")
            f.accounts.oauth.setClientEnabled(clientRecordId: f.global.id, enabled: true)
            #expect(try await postAppAgentBoundary(client, body: globalBody).status == .ok)
        }
    }
}

@Test func appAgentRequestStrictScopesKeepBytesLegacyExceptionsAndNarrowExistingGrants() async throws {
    let f = try AppAgentRequestBoundaryFixture()
    let legacy = try f.accounts.oauth.createClient(
        serverId: f.serverId, createdByUserId: f.ownerId, name: "Legacy App", clientId: "local-collabdoc-1", allowedScopes: []
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let selector = "\"agentId\":\"\(f.agentId)\""
            let invalidScopes: [String?] = [nil, "null", "\"openid\"", "[]", "[\" \",\"\"]", "[\"openid\",7]"]
            for scopes in invalidScopes {
                expectAppAgentBoundaryWire(try await postAppAgentBoundary(client, body: appAgentBoundaryBody(f.local, selector: selector, scopes: scopes)),
                    status: .badRequest, body: "{\"error\":\"invalid_scope\"}")
            }
            let first = try await postAppAgentBoundary(client, body: appAgentBoundaryBody(f.local, selector: selector))
            #expect(first.status == .ok)
            let firstRequest = try #require(try agentRequestBody(first)["requestId"] as? String)
            let repeated = try await postAppAgentBoundary(client, body: appAgentBoundaryBody(f.local, selector: selector, scopes: "[\" profile \",\"openid\",\"profile\",\"\"]"))
            let nextRequest = try #require(try agentRequestBody(repeated)["requestId"] as? String)
            #expect(firstRequest != nextRequest)
            expectAppAgentBoundaryWire(repeated, status: .ok,
                body: "{\"requestId\":\"\(nextRequest)\",\"status\":\"approved\",\"client\":{\"clientId\":\"g3-local-boundary\",\"appType\":\"server_local\",\"name\":\"请求 / App\",\"description\":null,\"homepageUrl\":null},\"agent\":{\"id\":\"\(f.agentId)\",\"name\":\"BoundaryBot\",\"displayName\":\"显示 / Bot\",\"serverId\":\"\(f.serverId)\",\"serverSlug\":\"g3-request-boundary\"},\"scopes\":[\"openid\",\"profile\"]}")
            var human = HTTPFields()
            human[.authorization] = "Bearer \(f.accounts.mintAccessTokenForTesting(userId: f.ownerId))"
            let grantList = try await client.get(URI(string: "/api/integrations/agents/\(f.agentId)/grants"), headers: human)
            #expect(grantList.status == .ok)
            let grants = try #require(JSONSerialization.jsonObject(with: Data((grantList.body.string ?? "").utf8)) as? [[String: Any]])
            #expect(grants.count == 1)
            #expect(grants.first?["scopes"] as? [String] == ["openid"])
            let legacyRequest = try await postAppAgentBoundary(client, body: appAgentBoundaryBody(legacy, selector: selector, scopes: "[\"owner\",\"creator\"]"))
            #expect(legacyRequest.status == .ok)
            #expect(try agentRequestBody(legacyRequest)["scopes"] as? [String] == ["creator", "owner"])
            expectAppAgentBoundaryWire(try await postAppAgentBoundary(client, body: appAgentBoundaryBody(f.local, selector: selector, scopes: "[\"owner\"]")),
                status: .badRequest, body: "{\"error\":\"invalid_scope\"}")
        }
    }
}

@Test(arguments: ["0", "1", "2", "true", "\"true\""])
func appAgentRequestInitiatedByAgentKeepsBooleanAndNumericCompatibility(value: String) async throws {
    let f = try AppAgentRequestBoundaryFixture()
    let loginApp = try f.accounts.oauth.createClient(
        serverId: f.serverId, createdByUserId: "unrelated-user", name: "Agent Login", clientId: "g3-agent-login"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await postAppAgentBoundary(client, body: appAgentBoundaryBody(
                loginApp, selector: "\"agentId\":\"\(f.agentId)\"", extra: ",\"initiatedByAgent\":\(value)"
            ))
            #expect(response.status == .ok)
            #expect(try agentRequestBody(response)["status"] as? String == (value == "1" || value == "true" ? "approved" : "pending"))
        }
    }
}
