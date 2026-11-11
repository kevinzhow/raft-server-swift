import TestSupport
import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func jsonString(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try! encoder.encode(value), as: UTF8.self)
}

private func oauthBytesObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

private func expectOAuthBytes(_ response: ClientResponse, _ expected: String, cache: String? = nil) {
    #expect(response.body.string == expected)
    #expect(response.headers[.contentType] == AppFallback.jsonContentType)
    #expect(response.headers[.contentLength] == String(expected.utf8.count))
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == AppFallback.robotsTag)
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == cache)
}

private func oauthDiscoveryBytes(issuer: String) -> String {
    "{\"issuer\":\(jsonString(issuer)),\"authorization_endpoint\":\(jsonString(issuer + "/api/oauth/authorize")),\"token_endpoint\":\(jsonString(issuer + "/api/oauth/token")),\"userinfo_endpoint\":\(jsonString(issuer + "/api/oauth/userinfo")),\"jwks_uri\":\(jsonString(issuer + "/api/oauth/jwks")),\"agents_endpoint\":\(jsonString(issuer + "/api/oauth/agents")),\"serverinfo_endpoint\":\(jsonString(issuer + "/api/oauth/serverinfo")),\"grant_types_supported\":[\"authorization_code\",\"urn:slock:grant-type:agent_request\"],\"scopes_supported\":[\"openid\",\"profile\",\"email\",\"identity\",\"agent:read\",\"agent:event:write\",\"agent:notification:write\"],\"response_types_supported\":[\"code\"],\"response_modes_supported\":[\"query\"],\"subject_types_supported\":[\"public\"],\"id_token_signing_alg_values_supported\":[\"ES256\"],\"token_endpoint_auth_methods_supported\":[\"client_secret_basic\",\"client_secret_post\"],\"code_challenge_methods_supported\":[\"S256\"],\"claims_supported\":[\"sub\",\"name\",\"preferred_username\",\"picture\",\"email\",\"email_verified\",\"type\",\"server_id\",\"server_slug\",\"server_role\"]}"
}

@Test func oauthLedgerDiscoveryAndJWKSPreserveBytesAndFailureCachePolicies() async throws {
    let scene = OAuthScene()
    scene.auth.configureOAuthForTesting { $0.serverURL = "https://api.raft.test/base/" }
    scene.oauth.addOwnedServer(id: UUID().uuidString.lowercased(), slug: "oauth-bytes", name: "Bytes", ownerId: "owner")
    try await withApp { app in
        try await app.register(collection: OAuthFeature(
            oauthFlows: scene.services.identity.oauthFlows,
            issuerMetadata: scene.services.identity.issuerMetadata,
            authorization: scene.services.identity.authorization,
            principal: scene.services.identity.principal,
            apps: scene.services.integrations.apps
        ))
        try await app.testing { client in
            for path in ["/.well-known/openid-configuration", "/api/oauth/.well-known/openid-configuration"] {
                let response = try await client.get(URI(string: path))
                #expect(response.status == .ok)
                expectOAuthBytes(response, oauthDiscoveryBytes(issuer: "https://api.raft.test"), cache: "public, max-age=300")
            }
            for path in ["/oidc/oauth-bytes/.well-known/openid-configuration", "/oidc/oauth-bytes/api/oauth/.well-known/openid-configuration"] {
                expectOAuthBytes(try await client.get(URI(string: path)), oauthDiscoveryBytes(issuer: "https://api.raft.test/oidc/oauth-bytes"), cache: "public, max-age=300")
            }
            let keys = try await client.get("/api/oauth/jwks")
            let key = try #require((try oauthBytesObject(keys)["keys"] as? [[String: Any]])?.first)
            let kid = try #require(key["kid"] as? String)
            let x = try #require(key["x"] as? String)
            let y = try #require(key["y"] as? String)
            let jwks = "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"use\":\"sig\",\"alg\":\"ES256\",\"kid\":\(jsonString(kid)),\"x\":\(jsonString(x)),\"y\":\(jsonString(y))}]}"
            expectOAuthBytes(keys, jwks, cache: "public, max-age=300")
            expectOAuthBytes(try await client.get("/oidc/oauth-bytes/api/oauth/jwks"), jwks, cache: "public, max-age=300")

            // Scope shape and existence are checked before authentication and
            // never inherit the success surface's cache header.
            for suffix in [".well-known/openid-configuration", "api/oauth/agents", "api/oauth/jwks", "api/oauth/userinfo"] {
                let malformed = try await client.get(URI(string: "/oidc/INVALID/\(suffix)"))
                #expect(malformed.status == .badRequest)
                expectOAuthBytes(malformed, "{\"error\":\"invalid_server_scope\"}")
                let missing = try await client.get(URI(string: "/oidc/not-found/\(suffix)"))
                #expect(missing.status == .notFound)
                expectOAuthBytes(missing, "{\"error\":\"Not found\"}")
            }
            scene.auth.configureOAuthForTesting { $0.serverURL = "https://live.raft.test:8443/new/base/" }
            let liveRoot = try await client.get("/.well-known/openid-configuration")
            #expect(liveRoot.status == .ok)
            expectOAuthBytes(liveRoot, oauthDiscoveryBytes(issuer: "https://live.raft.test:8443"), cache: "public, max-age=300")
            let liveScoped = try await client.get("/oidc/oauth-bytes/api/oauth/.well-known/openid-configuration")
            #expect(liveScoped.status == .ok)
            expectOAuthBytes(liveScoped, oauthDiscoveryBytes(issuer: "https://live.raft.test:8443/oidc/oauth-bytes"), cache: "public, max-age=300")
            scene.services.identity.oauthFlows.configureSigningSecret("")
            let unavailable = try await client.get("/api/oauth/jwks")
            #expect(unavailable.status == .serviceUnavailable)
            expectOAuthBytes(unavailable, "{\"error\":\"oidc_not_configured\"}")
            let independentDiscovery = try await client.get("/oidc/oauth-bytes/.well-known/openid-configuration")
            #expect(independentDiscovery.status == .ok)
            expectOAuthBytes(independentDiscovery, oauthDiscoveryBytes(issuer: "https://live.raft.test:8443/oidc/oauth-bytes"), cache: "public, max-age=300")
            for path in ["/.well-known/openid-configuration", "/api/oauth/.well-known/openid-configuration"] {
                let independentUnscoped = try await client.get(URI(string: path))
                #expect(independentUnscoped.status == .ok)
                expectOAuthBytes(independentUnscoped, oauthDiscoveryBytes(issuer: "https://live.raft.test:8443"), cache: "public, max-age=300")
            }
            scene.auth.configureOAuthForTesting { $0.serverURL = "invalid origin" }
            let discoveryUnavailable = try await client.get("/.well-known/openid-configuration")
            #expect(discoveryUnavailable.status == .serviceUnavailable)
            expectOAuthBytes(discoveryUnavailable, "{\"error\":\"oidc_not_configured\"}")
            let scopedUnavailable = try await client.get("/oidc/oauth-bytes/api/oauth/.well-known/openid-configuration")
            #expect(scopedUnavailable.status == .serviceUnavailable)
            expectOAuthBytes(scopedUnavailable, "{\"error\":\"oidc_not_configured\"}")
            scene.auth.configureOAuthForTesting { $0.serverURL = "https://recovered.raft.test/prefix/" }
            let recovered = try await client.get("/api/oauth/.well-known/openid-configuration")
            #expect(recovered.status == .ok)
            expectOAuthBytes(recovered, oauthDiscoveryBytes(issuer: "https://recovered.raft.test"), cache: "public, max-age=300")
        }
    }
}

@Test func oauthLedgerTokenAndIdentityBodiesKeepOrderNullsAndEscaping() async throws {
    let scene = OAuthScene()
    scene.auth.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    let serverId = UUID().uuidString.lowercased()
    let ownerId = UUID().uuidString.lowercased()
    let name = "用户/\n\"name"
    let clientName = "App/\t\"客户端"
    scene.oauth.addOwnedServer(id: serverId, slug: "oauth-identity-bytes", name: name, ownerId: ownerId)
    let created = try scene.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: clientName,
        clientId: "oauth-identity-bytes", allowedScopes: ["openid", "profile", "email"])
    let authorization = try scene.services.identity.authorization.issueHumanAuthorization(
        session: .user(OAuthHuman(id: ownerId, email: "bytes@raft.test", name: name)),
        body: "{\"clientId\":\"oauth-identity-bytes\",\"serverId\":\(jsonString(serverId)),\"scopes\":[\"email\",\"profile\",\"openid\"]}"
    )
    #expect(authorization.jsonBody.render() == "{\"code\":\(jsonString(authorization.code)),\"client\":{\"clientId\":\"oauth-identity-bytes\",\"appType\":\"server_local\",\"name\":\(jsonString(clientName)),\"description\":null,\"homepageUrl\":null},\"server\":{\"id\":\(jsonString(serverId)),\"slug\":\"oauth-identity-bytes\",\"role\":\"owner\"},\"scopes\":[\"email\",\"openid\",\"profile\"],\"returnUrl\":null}")
    try await withApp { app in
        try await app.register(collection: OAuthFeature(
            oauthFlows: scene.services.identity.oauthFlows,
            issuerMetadata: scene.services.identity.issuerMetadata,
            authorization: scene.services.identity.authorization,
            principal: scene.services.identity.principal,
            apps: scene.services.integrations.apps
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let requestBody = "{\"clientId\":\"oauth-identity-bytes\",\"clientSecret\":\"invalid-first-value\",\"clientSecret\":\(jsonString(created.clientSecret)),\"grantType\":\"authorization_code\",\"code\":\(jsonString(authorization.code))}"
            let token = try await client.send(.post, headers: headers, to: "/api/oauth/token") { $0.body = .init(string: requestBody) }
            #expect(token.status == .ok)
            let object = try oauthBytesObject(token)
            let access = try #require(object["access_token"] as? String)
            let idToken = try #require(object["id_token"] as? String)
            expectOAuthBytes(token, "{\"access_token\":\(jsonString(access)),\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"email openid profile\",\"id_token\":\(jsonString(idToken))}", cache: "no-store")
            let parts = idToken.split(separator: ".")
            func decoded(_ part: Substring) throws -> String {
                var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                return String(decoding: try #require(Data(base64Encoded: base64)), as: UTF8.self)
            }
            let rawHeader = try decoded(parts[0])
            let rawClaims = try decoded(parts[1])
            let header = try #require(JSONSerialization.jsonObject(with: Data(rawHeader.utf8)) as? [String: Any])
            let claims = try #require(JSONSerialization.jsonObject(with: Data(rawClaims.utf8)) as? [String: Any])
            let kid = try #require(header["kid"] as? String)
            let issued = try #require(claims["iat"] as? Int)
            let expires = try #require(claims["exp"] as? Int)
            #expect(rawHeader == "{\"alg\":\"ES256\",\"typ\":\"JWT\",\"kid\":\(jsonString(kid))}")
            #expect(rawClaims == "{\"iss\":\"https://api.raft.test\",\"sub\":\(jsonString(ownerId)),\"aud\":\"oauth-identity-bytes\",\"iat\":\(issued),\"exp\":\(expires),\"name\":\(jsonString(name)),\"preferred_username\":\(jsonString(name)),\"email\":\"bytes@raft.test\",\"email_verified\":true,\"type\":\"human\",\"server_id\":\(jsonString(serverId)),\"server_slug\":\"oauth-identity-bytes\",\"server_role\":\"owner\"}")
            #expect(expires - issued == 3600)
            var bearer = HTTPFields()
            bearer[.authorization] = "Bearer \(access)"
            expectOAuthBytes(try await client.get("/api/oauth/userinfo", headers: bearer), "{\"scope\":\"email openid profile\",\"client_id\":\"oauth-identity-bytes\",\"client_name\":\(jsonString(clientName)),\"server_id\":\(jsonString(serverId)),\"server_slug\":\"oauth-identity-bytes\",\"sub\":\(jsonString(ownerId)),\"type\":\"human\",\"server_role\":\"owner\",\"preferred_username\":\(jsonString(name)),\"name\":\(jsonString(name)),\"avatar_url\":null,\"picture\":null,\"description\":null,\"email\":\"bytes@raft.test\",\"email_verified\":false}")
            expectOAuthBytes(try await client.get("/api/oauth/serverinfo", headers: bearer), "{\"id\":\(jsonString(serverId)),\"slug\":\"oauth-identity-bytes\",\"name\":\(jsonString(name)),\"avatar_url\":null,\"picture\":null,\"is_paid\":false,\"plan_tier\":\"free\"}")
            let replay = try await client.send(.post, headers: headers, to: "/api/oauth/token") { $0.body = .init(string: requestBody) }
            #expect(replay.status == .conflict)
            expectOAuthBytes(replay, "{\"error\":\"request_already_consumed\",\"error_description\":\"This Login with Raft request is one-time and has already been exchanged. Discard it and obtain a fresh request before retrying.\",\"next_action\":\"obtain_fresh_request\"}")
        }
    }
}

@Test func oauthLedgerRefusalsKeepTheirDistinctCacheHeaders() async throws {
    let scene = OAuthScene()
    try await withApp { app in
        try await app.register(collection: OAuthFeature(
            oauthFlows: scene.services.identity.oauthFlows,
            issuerMetadata: scene.services.identity.issuerMetadata,
            authorization: scene.services.identity.authorization,
            principal: scene.services.identity.principal,
            apps: scene.services.integrations.apps
        ))
        try await app.register(collection: IntegrationsFeature(
            controlPlane: scene.services.integrations.control,
            identities: scene.services.identity.identities,
            apps: scene.services.integrations.apps,
            appManagement: scene.services.integrations.appManagement,
            cardPrepare: scene.services.integrations.prepare,
            agentsLifecycle: scene.services.agents.lifecycle,
            providerConnections: scene.services.integrations.providers,
            actionCards: scene.services.integrations.cards
        ))
        try await app.testing { client in
            let cases: [(HTTPRequest.Method, String, String, String?)] = [
                (.get, "/api/oauth/userinfo", "{\"error\":\"Missing bearer token\"}", nil),
                (.get, "/api/oauth/serverinfo", "{\"error\":\"Missing bearer token\"}", nil),
                (.get, "/api/oauth/agents", "{\"error\":\"Missing bearer token\"}", "no-store"),
                (.post, "/api/oauth/token", "{\"error\":\"Client credentials are required\"}", nil),
                (.post, "/api/oauth/installation-token", "{\"error\":\"Client credentials are required\"}", "private, no-store"),
                (.post, "/api/oauth/authorize/human", "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}", nil),
                (.get, "/api/app-installation/server", "{\"error\":\"Installation bearer token is required\"}", nil),
                (.get, "/api/app-installation/channels", "{\"error\":\"Installation bearer token is required\"}", nil),
            ]
            for (method, path, body, cache) in cases {
                let response = try await client.send(method, headers: HTTPFields(), to: URI(string: path))
                #expect(response.status == .unauthorized)
                expectOAuthBytes(response, body, cache: cache)
            }
        }
    }
}

@Test func oauthLedgerAgentEventArrayPayloadKeepsLegacyHashAndDeduplicationBytes() async throws {
    let scene = OAuthScene()
    let serverId = UUID().uuidString.lowercased()
    scene.oauth.addOwnedServer(id: serverId, slug: "oauth-event-bytes", name: "Events", ownerId: "owner")
    let agentId = scene.oauth.createAgent(serverId: serverId, name: "Bot", creatorUserId: "owner")
    let created = try scene.oauth.createClient(serverId: serverId, createdByUserId: "unrelated", name: "Event App",
        clientId: "oauth-event-bytes", allowedScopes: ["agent:event:write"])
    try await withApp { app in
        try await app.register(collection: OAuthFeature(
            oauthFlows: scene.services.identity.oauthFlows,
            issuerMetadata: scene.services.identity.issuerMetadata,
            authorization: scene.services.identity.authorization,
            principal: scene.services.identity.principal,
            apps: scene.services.integrations.apps
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: headers, to: "/api/oauth/requests/agent") {
                $0.body = .init(string: "{\"clientId\":\"oauth-event-bytes\",\"clientSecret\":\(jsonString(created.clientSecret)),\"serverSlug\":\"oauth-event-bytes\",\"agentId\":\(jsonString(agentId)),\"scopes\":[\"agent:event:write\"],\"initiatedByAgent\":1}")
            }
            #expect(requested.status == .ok)
            let requestedBody = try oauthBytesObject(requested)
            #expect(requestedBody["status"] as? String == "approved")
            let requestId = try #require(requestedBody["requestId"] as? String)
            let exchanged = try await client.send(.post, headers: headers, to: "/api/oauth/token") {
                $0.body = .init(string: "{\"clientId\":\"oauth-event-bytes\",\"clientSecret\":\(jsonString(created.clientSecret)),\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\(jsonString(requestId)),\"resource\":\"urn:raft:server:\(serverId):agent-inbound\"}")
            }
            let access = try #require(try oauthBytesObject(exchanged)["access_token"] as? String)
            headers[.authorization] = "Bearer \(access)"
            let payload = "[{\"z\":\"https://raft.test/用户\",\"a\":0,\"a\":1.5,\"a2\":1.0,\"large\":18446744073709551615},true,null]"
            let sorted = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(payload.utf8)), options: [.sortedKeys])
            let hash = SHA256.hash(data: sorted).map { String(format: "%02x", $0) }.joined()
            let eventBody = "{\"kind\":\"invalid\",\"kind\":\"event\",\"summary\":\" Summary \",\"payload\":\(payload),\"external_event_id\":\" external-bytes \"}"
            let first = try await client.send(.post, headers: headers, to: "/api/oauth/agent-events") { $0.body = .init(string: eventBody) }
            #expect(first.status == .accepted)
            let event = try oauthBytesObject(first)
            let id = try #require(event["id"] as? String)
            let expires = try #require(event["expiresAt"] as? String)
            expectOAuthBytes(first, "{\"id\":\(jsonString(id)),\"status\":\"queued\",\"deduped\":false,\"expiresAt\":\(jsonString(expires)),\"payloadHash\":\(jsonString(hash))}")
            let replay = try await client.send(.post, headers: headers, to: "/api/oauth/agent-events") { $0.body = .init(string: eventBody) }
            #expect(replay.status == .ok)
            expectOAuthBytes(replay, "{\"id\":\(jsonString(id)),\"status\":\"duplicate\",\"deduped\":true,\"expiresAt\":\(jsonString(expires)),\"payloadHash\":\(jsonString(hash))}")
            for scalar in ["null", "1", "true", "\"text\""] {
                let refused = try await client.send(.post, headers: headers, to: "/api/oauth/agent-events") {
                    $0.body = .init(string: "{\"kind\":\"event\",\"summary\":\"Summary\",\"payload\":\(scalar)}")
                }
                #expect(refused.status == .badRequest)
                expectOAuthBytes(refused, "{\"error\":\"payload must be an object\"}")
            }
        }
    }
}

private struct AgentEventIngressFixture: Sendable {
    let scene: OAuthScene
    let ownerId: String
    let serverId: String
    let agentId: String
    let app: CreatedOAuthClient

    init() throws {
        let scene = OAuthScene()
        let ownerId = "11111111-1111-4111-8111-111111111644"
        let serverId = "33333333-3333-4333-8333-333333333670"
        scene.auth.addAccount(id: ownerId, email: "g4-ingress-644@test.invalid", password: "password123")
        scene.auth.markEmailVerified(userId: ownerId)
        scene.oauth.addOwnedServer(id: serverId, slug: "g4-event-ingress", name: "G4 Events", ownerId: ownerId)
        let agentId = scene.oauth.createAgent(serverId: serverId, name: "IngressBot", creatorUserId: ownerId)
        let app = try scene.oauth.createClient(
            serverId: serverId, createdByUserId: ownerId, name: "Ingress App", clientId: "g4-event-ingress",
            allowedScopes: ["openid", "profile", "agent:event:write", "agent:notification:write"]
        )
        self.scene = scene
        self.ownerId = ownerId
        self.serverId = serverId
        self.agentId = agentId
        self.app = app
    }

    func agentToken(_ client: any Client, scopes: [String], bound: Bool = true) async throws -> String {
        let requested = try await agentEventIngressPost(client,
            body: "{\"clientId\":\"\(app.clientId)\",\"clientSecret\":\"\(app.clientSecret)\",\"serverSlug\":\"g4-event-ingress\",\"agentId\":\"\(agentId)\",\"scopes\":[\(scopes.map(jsonString).joined(separator: ","))]}",
            path: "/api/oauth/requests/agent")
        #expect(requested.status == .ok)
        let requestId = try #require(try oauthBytesObject(requested)["requestId"] as? String)
        let resource = bound ? ",\"resource\":\"urn:raft:server:\(serverId):agent-inbound\"" : ""
        let exchanged = try await agentEventIngressPost(client,
            body: "{\"clientId\":\"\(app.clientId)\",\"clientSecret\":\"\(app.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"\(resource)}",
            path: "/api/oauth/token")
        #expect(exchanged.status == .ok)
        return try #require(try oauthBytesObject(exchanged)["access_token"] as? String)
    }

    func humanToken(_ client: any Client) async throws -> String {
        let session = scene.auth.mintAccessTokenForTesting(userId: ownerId)
        let authorized = try await agentEventIngressPost(client,
            body: "{\"clientId\":\"\(app.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\"]}",
            token: session, path: "/api/oauth/authorize/human")
        #expect(authorized.status == .ok)
        let code = try #require(try oauthBytesObject(authorized)["code"] as? String)
        let exchanged = try await agentEventIngressPost(client,
            body: "{\"clientId\":\"\(app.clientId)\",\"clientSecret\":\"\(app.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}",
            path: "/api/oauth/token")
        #expect(exchanged.status == .ok)
        return try #require(try oauthBytesObject(exchanged)["access_token"] as? String)
    }
}

private func agentEventIngressPost(
    _ client: any Client, body: String, token: String? = nil, path: String = "/api/oauth/agent-events"
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { $0.body = .init(string: body) }
}

@Test func agentEventIngressRefusalsKeepPrincipalResourceKindScopeTargetSummaryPayloadOrder() async throws {
    let f = try AgentEventIngressFixture()
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let bound = try await f.agentToken(client, scopes: ["agent:event:write"])
            let unbound = try await f.agentToken(client, scopes: ["openid"], bound: false)
            let human = try await f.humanToken(client)
            let cases: [(String?, String, HTTPResponse.Status, String)] = [
                (nil, "{}", .unauthorized, "{\"error\":\"Missing bearer token\"}"),
                ("invalid", "{}", .unauthorized, "{\"error\":\"Invalid or expired access token\"}"),
                (human, "{}", .forbidden, "{\"error\":\"agent token required\"}"),
                (unbound, "{}", .forbidden, "{\"error\":\"resource-bound token required\",\"resource\":\"urn:raft:server:\(f.serverId):agent-inbound\"}"),
                (bound, "{\"kind\":\" Event \"}", .badRequest, "{\"error\":\"kind must be event or notification\"}"),
                (bound, "{\"kind\":\"notification\",\"agentId\":\"other\",\"summary\":\"\",\"payload\":null}", .forbidden, "{\"error\":\"insufficient_scope\",\"required_scope\":\"agent:notification:write\"}"),
                (bound, "{\"kind\":\"event\",\"agentId\":\"other\",\"summary\":\"\",\"payload\":null}", .forbidden, "{\"error\":\"token cannot target a different agent\"}"),
                (bound, "{\"kind\":\"event\",\"summary\":\"  \",\"payload\":null}", .badRequest, "{\"error\":\"summary is required\"}"),
                (bound, "{\"kind\":\"event\",\"summary\":\"Valid\",\"payload\":null}", .badRequest, "{\"error\":\"payload must be an object\"}"),
            ]
            for (token, body, status, expected) in cases {
                let response = try await agentEventIngressPost(client, body: body, token: token)
                #expect(response.status == status)
                expectOAuthBytes(response, expected)
            }
        }
    }
}

private struct AgentEventIngressReply: Sendable {
    let status: Int
    let body: String
}

@Test func agentEventIngressQueuedRetriesClaimOnceAndKeepTheOriginalEventBody() async throws {
    let f = try AgentEventIngressFixture()
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let token = try await f.agentToken(client, scopes: ["agent:event:write", "agent:notification:write"])
            let eventId = f.scene.oauth.seedQueuedAgentEvent(
                serverId: f.serverId, agentId: f.agentId, clientRecordId: f.app.id, externalEventId: "g4-queued-claim"
            )
            let replies = try await withThrowingTaskGroup(of: AgentEventIngressReply.self) { group in
                for index in 0..<32 {
                    group.addTask {
                        let response = try await agentEventIngressPost(client,
                            body: "{\"kind\":\"notification\",\"summary\":\"Replacement \(index)\",\"externalEventId\":\" g4-queued-claim \",\"payload\":{\"replacement\":\(index)}}", token: token)
                        return AgentEventIngressReply(status: response.status.code, body: response.body.string ?? "")
                    }
                }
                var result: [AgentEventIngressReply] = []
                for try await reply in group { result.append(reply) }
                return result
            }
            #expect(replies.allSatisfy { $0.status == 200 })
            let objects = try replies.map { reply in
                try #require(JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any])
            }
            #expect(objects.filter { $0["status"] as? String == "queued" }.count == 1)
            #expect(objects.filter { $0["status"] as? String == "duplicate" }.count == 31)
            #expect(objects.allSatisfy { $0["id"] as? String == eventId && $0["deduped"] as? Bool == true })
            #expect(objects.allSatisfy { $0["payloadHash"] as? String == String(repeating: "0", count: 64) })
            let expiries = try objects.map { try #require($0["expiresAt"] as? String) }
            #expect(Set(expiries).count == 1)
            var human = HTTPFields()
            human[.authorization] = "Bearer \(f.scene.auth.mintAccessTokenForTesting(userId: f.ownerId))"
            let detail = try await client.get(URI(string: "/api/integrations/agents/\(f.agentId)/events/\(eventId)"), headers: human)
            #expect(detail.status == .ok)
            let stored = try oauthBytesObject(detail)
            #expect(stored["kind"] as? String == "event")
            #expect(stored["summary"] as? String == "Queued before delivery failed")
            #expect((stored["payload"] as? [String: Any])?.isEmpty == true)
            #expect(stored["expiresAt"] as? String == expiries.first)
            #expect(stored["externalEventId"] as? String == "g4-queued-claim")
            let list = try await client.get(URI(string: "/api/integrations/agents/\(f.agentId)/events"), headers: human)
            #expect((try oauthBytesObject(list)["events"] as? [[String: Any]])?.count == 1)
        }
    }
}

@Test func agentEventIngressKeepsFieldPrecedenceUnicodeLimitsAndItsExistingLiveGates() async throws {
    let f = try AgentEventIngressFixture()
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let token = try await f.agentToken(client, scopes: ["agent:event:write"])
            let family = "👨‍👩‍👧‍👦"
            let summary = String(repeating: family, count: 500)
            let accepted = try await agentEventIngressPost(client,
                body: "{\"kind\":\"event\",\"agentId\":\"\(f.agentId.uppercased())\",\"agent_id\":\"other\",\"summary\":\(jsonString(summary)),\"payload\":{}}", token: token)
            #expect(accepted.status == .accepted)
            let tooLong = try await agentEventIngressPost(client,
                body: "{\"kind\":\"event\",\"summary\":\(jsonString(summary + family)),\"payload\":null}", token: token)
            #expect(tooLong.status == .badRequest)
            expectOAuthBytes(tooLong, "{\"error\":\"summary is required\"}")
            for target in ["\"agentId\":\"\",\"agent_id\":\"\(f.agentId)\"", "\"agentId\":\" \(f.agentId) \",\"agent_id\":\"\(f.agentId)\""] {
                let response = try await agentEventIngressPost(client, body: "{\"kind\":\"event\",\(target),\"summary\":\"Target\",\"payload\":{}}", token: token)
                #expect(response.status == .forbidden)
                expectOAuthBytes(response, "{\"error\":\"token cannot target a different agent\"}")
            }
            let fallback = try await agentEventIngressPost(client,
                body: "{\"kind\":\"event\",\"agentId\":7,\"agent_id\":\"\(f.agentId.uppercased())\",\"summary\":\"Target\",\"payload\":{}}", token: token)
            #expect(fallback.status == .accepted)
            let emptyExternalBody = "{\"kind\":\"event\",\"summary\":\"External\",\"payload\":{},\"externalEventId\":\"\",\"external_event_id\":\"ignored\"}"
            let emptyOne = try await agentEventIngressPost(client, body: emptyExternalBody, token: token)
            let emptyTwo = try await agentEventIngressPost(client, body: emptyExternalBody, token: token)
            #expect(emptyOne.status == .accepted && emptyTwo.status == .accepted)
            let emptyId = try #require(try oauthBytesObject(emptyOne)["id"] as? String)
            #expect(try oauthBytesObject(emptyTwo)["id"] as? String != emptyId)
            let missing = try await agentEventIngressPost(client, body: "{\"kind\":\"event\",\"summary\":\"External\",\"payload\":{}}", token: token)
            let missingId = try #require(try oauthBytesObject(missing)["id"] as? String)
            let snakeExternalBody = "{\"kind\":\"event\",\"summary\":\"External\",\"payload\":{},\"externalEventId\":7,\"external_event_id\":\" Case-Key \"}"
            let snakeOne = try await agentEventIngressPost(client, body: snakeExternalBody, token: token)
            let snakeTwo = try await agentEventIngressPost(client, body: snakeExternalBody, token: token)
            #expect(snakeOne.status == .accepted && snakeTwo.status == .ok)
            let snakeId = try #require(try oauthBytesObject(snakeOne)["id"] as? String)
            #expect(try oauthBytesObject(snakeTwo)["id"] as? String == snakeId)
            var human = HTTPFields()
            human[.authorization] = "Bearer \(f.scene.auth.mintAccessTokenForTesting(userId: f.ownerId))"
            let emptyDetail = try await client.get(URI(string: "/api/integrations/agents/\(f.agentId)/events/\(emptyId)"), headers: human)
            let missingDetail = try await client.get(URI(string: "/api/integrations/agents/\(f.agentId)/events/\(missingId)"), headers: human)
            #expect(try oauthBytesObject(emptyDetail)["externalEventId"] as? String == "")
            #expect(try oauthBytesObject(missingDetail)["externalEventId"] is NSNull)
            let snakeDetail = try await client.get(URI(string: "/api/integrations/agents/\(f.agentId)/events/\(snakeId)"), headers: human)
            #expect(try oauthBytesObject(snakeDetail)["externalEventId"] as? String == "Case-Key")
            // These current-state changes do not invalidate this token surface.
            let mutations: [@Sendable () -> Void] = [
                { f.scene.oauth.setClientEnabled(clientRecordId: f.app.id, enabled: false) },
                { f.scene.oauth.removeAgentMember(serverId: f.serverId, agentId: f.agentId) },
                { f.scene.oauth.deleteAgent(id: f.agentId) },
                { f.scene.oauth.deleteServer(id: f.serverId) },
            ]
            for mutate in mutations {
                mutate()
                #expect(try await agentEventIngressPost(client, body: "{\"kind\":\"event\",\"summary\":\"Still valid\",\"payload\":{}}", token: token).status == .accepted)
            }
        }
    }
}

private func authorizationProtocolPost(
    _ client: any Client, path: String, body: String, authorization: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.authorization] = authorization
    return try await client.send(.post, headers: headers, to: URI(string: path)) {
        $0.body = .init(string: body)
    }
}

private struct AuthorizationProtocolFixture: Sendable {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-111111111646"
    let serverId = "33333333-3333-4333-8333-333333333672"
    let app: CreatedOAuthClient
    let session: String

    init(allowedScopes: [String]? = nil) throws {
        scene.auth.addAccount(id: ownerId, email: "protocol-646@test.invalid", password: "password123")
        scene.auth.configureOAuthForTesting { $0.serverURL = "https://protocol.raft.test" }
        scene.oauth.addOwnedServer(id: serverId, slug: "protocol-646", name: "Protocol 646", ownerId: ownerId)
        app = try scene.oauth.createClient(
            serverId: serverId, createdByUserId: ownerId, name: "Protocol App", clientId: "protocol-client-646",
            returnUrl: "https://rp.test/callback", allowedScopes: allowedScopes
        )
        session = scene.auth.mintAccessTokenForTesting(userId: ownerId)
    }

    func humanBody(_ fields: String) -> String {
        "{\"clientId\":\"\(app.clientId)\",\"serverId\":\"\(serverId)\"\(fields)}"
    }

    func issue(_ client: any Client, fields: String) async throws -> String {
        let response = try await authorizationProtocolPost(client, path: "/api/oauth/authorize/human",
            body: humanBody(fields), authorization: "Bearer \(session)")
        #expect(response.status == .ok)
        return try #require(try oauthBytesObject(response)["code"] as? String)
    }

    func exchange(_ client: any Client, code: String, path: String = "/api/oauth/token") async throws -> ClientResponse {
        try await authorizationProtocolPost(client, path: path,
            body: "{\"clientId\":\"\(app.clientId)\",\"clientSecret\":\"\(app.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\",\"redirect_uri\":\"https://rp.test/callback\"}")
    }
}

@Test func oauthProtocolSpecializedSessionsKeepUnverifiedRevokedAndEmptyBearerSemantics() async throws {
    let f = try AuthorizationProtocolFixture()
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let lookup = URI(string: "/api/oauth/clients/lookup?client_id=\(f.app.clientId)&server_id=\(f.serverId)")
            // HTTPFields strips edge SP/HTAB before the Feature sees the
            // header. The second space after Bearer remains inside its value.
            let refusals: [(String?, String)] = [
                (nil, "Missing or invalid Authorization header"),
                ("bearer \(f.session)", "Missing or invalid Authorization header"),
                ("Bearer ", "Missing or invalid Authorization header"),
                ("Bearer unknown-token", "Invalid or expired token"),
                ("Bearer  \(f.session)", "Invalid or expired token"),
            ]
            for (authorization, message) in refusals {
                let human = try await authorizationProtocolPost(client, path: "/api/oauth/authorize/human", body: "{", authorization: authorization)
                #expect(human.status == .unauthorized)
                expectOAuthBytes(human, "{\"error\":\(jsonString(message)),\"code\":\"auth_required\"}")
                var headers = HTTPFields()
                headers[.authorization] = authorization
                let consent = try await client.get(lookup, headers: headers)
                #expect(consent.status == .unauthorized)
                expectOAuthBytes(consent, "{\"error\":\(jsonString(message)),\"code\":\"auth_required\"}")
            }
            // The account is deliberately unverified. Revocation marks the
            // existing real family without removing its access-token mapping.
            for revoked in [false, true] {
                if revoked { f.scene.auth.revokeSessionFamilies(userId: f.ownerId) }
                for authorization in ["Bearer \(f.session)", "Bearer \(f.session) "] {
                    var headers = HTTPFields()
                    headers[.authorization] = authorization
                    let consent = try await client.get(lookup, headers: headers)
                    #expect(consent.status == .ok)
                    #expect(try oauthBytesObject(consent)["availability"] as? String == "ready")
                    let malformed = try await authorizationProtocolPost(client, path: "/api/oauth/authorize/human", body: "{", authorization: authorization)
                    #expect(malformed.status == .badRequest)
                    expectOAuthBytes(malformed, "{\"error\":\"clientId is required\"}")
                }
                let code = try await f.issue(client, fields: ",\"scopes\":[\"profile\"]")
                #expect(!code.isEmpty)
            }
        }
    }
}

@Test func oauthProtocolHumanDefaultsAndRefusalsKeepTheirOriginalOrder() async throws {
    let f = try AuthorizationProtocolFixture(allowedScopes: ["email"])
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            func human(_ fields: String) async throws -> ClientResponse {
                try await authorizationProtocolPost(client, path: "/api/oauth/authorize/human", body: f.humanBody(fields), authorization: "Bearer \(f.session)")
            }
            for fields in ["", ",\"scopes\":null"] {
                let defaults = try await human(fields)
                #expect(defaults.status == .ok)
                #expect(try oauthBytesObject(defaults)["scopes"] as? [String] == ["openid", "profile"])
            }
            let explicit = try await human(",\"scopes\":[\"openid\",\"profile\"]")
            #expect(explicit.status == .badRequest)
            expectOAuthBytes(explicit, "{\"error\":\"invalid_scope\",\"errorCode\":\"OAUTH_SCOPE_NOT_ALLOWED\",\"error_description\":\"This OAuth client is not allowed to request: openid, profile. Update the client's allowed scopes and try again.\",\"disallowedScopes\":[\"openid\",\"profile\"]}")
            let oversized = jsonString(String(repeating: "é", count: 257))
            let badFields = ",\"oidc\":1,\"nonce\":\(oversized),\"scopes\":[\"unsupported\"],\"returnUrl\":\"https://wrong.test/callback\""
            let missingClient = try await authorizationProtocolPost(client, path: "/api/oauth/authorize/human",
                body: "{\"clientId\":\"missing-client\",\"serverId\":\"\(f.serverId)\"\(badFields)}", authorization: "Bearer \(f.session)")
            #expect(missingClient.status == .notFound)
            expectOAuthBytes(missingClient, "{\"error\":\"OAuth client not found for server\"}")
            let nonceFirst = try await human(badFields)
            #expect(nonceFirst.status == .badRequest)
            expectOAuthBytes(nonceFirst, "{\"error\":\"invalid_request\"}")
            let boundary = try await human(",\"oidc\":1,\"nonce\":\(jsonString(String(repeating: "é", count: 256))),\"scopes\":[\"email\"]")
            #expect(boundary.status == .ok)
            #expect((try oauthBytesObject(boundary)["code"] as? String)?.hasPrefix("raft_oidc_") == true)
            f.scene.oauth.removeMember(serverId: f.serverId, userId: f.ownerId)
            let ordered: [(String, HTTPResponse.Status, String)] = [
                (",\"scopes\":[\"unsupported\"],\"returnUrl\":\"https://wrong.test/callback\"", .badRequest,
                 "{\"error\":\"invalid_scope\",\"errorCode\":\"OAUTH_SCOPE_UNSUPPORTED\",\"error_description\":\"Raft does not support the requested OAuth scope: unsupported. Update the requested scopes and try again.\",\"disallowedScopes\":[\"unsupported\"]}"),
                (",\"scopes\":[\"email\"],\"returnUrl\":\"https://wrong.test/callback\"", .badRequest, "{\"error\":\"returnUrl is not allowed\"}"),
                (",\"scopes\":[\"email\"]", .notFound, "{\"error\":\"User is not a member of this server\"}"),
            ]
            for (fields, status, bytes) in ordered {
                let response = try await human(fields)
                #expect(response.status == status)
                expectOAuthBytes(response, bytes)
            }
        }
    }
}

@Test func oauthProtocolSigningFailureConsumesCodesAndInvalidOriginStillIssuesTokens() async throws {
    let f = try AuthorizationProtocolFixture()
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            f.scene.services.identity.oauthFlows.configureSigningSecret("")
            for oidc in [false, true] {
                let code = try await f.issue(client, fields: ",\"scopes\":[\"openid\"],\"oidc\":\(oidc)")
                let failure = try await f.exchange(client, code: code)
                #expect(failure.status == .internalServerError)
                expectOAuthBytes(failure, "{\"error\":\"Failed to issue access token\"}")
                let replay = try await f.exchange(client, code: code)
                #expect(replay.status == (oidc ? .badRequest : .conflict))
                expectOAuthBytes(replay, oidc
                    ? "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}"
                    : "{\"error\":\"request_already_consumed\",\"error_description\":\"This Login with Raft request is one-time and has already been exchanged. Discard it and obtain a fresh request before retrying.\",\"next_action\":\"obtain_fresh_request\"}")
            }
            let profileCode = try await f.issue(client, fields: ",\"scopes\":[\"profile\"]")
            let profile = try await f.exchange(client, code: profileCode)
            #expect(profile.status == .ok)
            let profileToken = try #require(try oauthBytesObject(profile)["access_token"] as? String)
            expectOAuthBytes(profile, "{\"access_token\":\(jsonString(profileToken)),\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"profile\"}", cache: "no-store")
            let agentId = f.scene.oauth.createAgent(serverId: f.serverId, name: "ProtocolBot", creatorUserId: f.ownerId)
            let requested = try await authorizationProtocolPost(client, path: "/api/oauth/requests/agent",
                body: "{\"clientId\":\"\(f.app.clientId)\",\"clientSecret\":\"\(f.app.clientSecret)\",\"serverSlug\":\"protocol-646\",\"agentId\":\"\(agentId)\",\"scopes\":[\"openid\"]}")
            #expect(requested.status == .ok)
            #expect(try oauthBytesObject(requested)["status"] as? String == "approved")
            let requestId = try #require(try oauthBytesObject(requested)["requestId"] as? String)
            let agent = try await authorizationProtocolPost(client, path: "/api/oauth/token",
                body: "{\"clientId\":\"\(f.app.clientId)\",\"clientSecret\":\"\(f.app.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
            #expect(agent.status == .ok)
            let agentToken = try #require(try oauthBytesObject(agent)["access_token"] as? String)
            expectOAuthBytes(agent, "{\"access_token\":\(jsonString(agentToken)),\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"openid\"}", cache: "no-store")
            f.scene.services.identity.oauthFlows.configureSigningSecret("protocol-restored-key")
            f.scene.auth.configureOAuthForTesting { $0.serverURL = "invalid origin" }
            for (path, issuer) in [("/api/oauth/token", ""), ("/oidc/protocol-646/api/oauth/token", "/oidc/protocol-646")] {
                let code = try await f.issue(client, fields: ",\"scopes\":[\"openid\"]")
                let response = try await f.exchange(client, code: code, path: path)
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
                let jwt = try #require(try oauthBytesObject(response)["id_token"] as? String)
                let parts = jwt.split(separator: ".")
                #expect(parts.count == 3)
                var encoded = String(try #require(parts.dropFirst().first)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while encoded.count % 4 != 0 { encoded += "=" }
                let payload = try #require(Data(base64Encoded: encoded))
                let claims = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                #expect(claims["iss"] as? String == issuer)
            }
        }
    }
}
