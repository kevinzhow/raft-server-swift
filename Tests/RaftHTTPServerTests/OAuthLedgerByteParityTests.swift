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
    let accounts = EmailLoginDirectory()
    accounts.serverURL = "https://api.raft.test/base/"
    accounts.oauth.addOwnedServer(id: UUID().uuidString.lowercased(), slug: "oauth-bytes", name: "Bytes", ownerId: "owner")
    try await withApp { app in
        try await app.register(collection: OAuthFeature(services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        )))
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
            accounts.oauth.jwtSecret = ""
            let unavailable = try await client.get("/api/oauth/jwks")
            #expect(unavailable.status == .serviceUnavailable)
            expectOAuthBytes(unavailable, "{\"error\":\"oidc_not_configured\"}")
            accounts.serverURL = "invalid origin"
            let discoveryUnavailable = try await client.get("/.well-known/openid-configuration")
            #expect(discoveryUnavailable.status == .serviceUnavailable)
            expectOAuthBytes(discoveryUnavailable, "{\"error\":\"oidc_not_configured\"}")
        }
    }
}

@Test func oauthLedgerTokenAndIdentityBodiesKeepOrderNullsAndEscaping() async throws {
    let accounts = EmailLoginDirectory()
    accounts.serverURL = "https://api.raft.test"
    let serverId = UUID().uuidString.lowercased()
    let ownerId = UUID().uuidString.lowercased()
    let name = "用户/\n\"name"
    let clientName = "App/\t\"客户端"
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-identity-bytes", name: name, ownerId: ownerId)
    let created = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: clientName,
        clientId: "oauth-identity-bytes", allowedScopes: ["openid", "profile", "email"])
    let authorization = try accounts.oauth.issueHumanAuthorization(
        session: .user(OAuthHuman(id: ownerId, email: "bytes@raft.test", name: name)),
        body: "{\"clientId\":\"oauth-identity-bytes\",\"serverId\":\(jsonString(serverId)),\"scopes\":[\"email\",\"profile\",\"openid\"]}"
    )
    #expect(authorization.jsonBody.render() == "{\"code\":\(jsonString(authorization.code)),\"client\":{\"clientId\":\"oauth-identity-bytes\",\"appType\":\"server_local\",\"name\":\(jsonString(clientName)),\"description\":null,\"homepageUrl\":null},\"server\":{\"id\":\(jsonString(serverId)),\"slug\":\"oauth-identity-bytes\",\"role\":\"owner\"},\"scopes\":[\"email\",\"openid\",\"profile\"],\"returnUrl\":null}")
    try await withApp { app in
        try await app.register(collection: OAuthFeature(services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        )))
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
    let services = FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {})
    try await withApp { app in
        try await app.register(collection: OAuthFeature(services: services))
        try await app.register(collection: IntegrationsFeature(services: services))
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
    let accounts = EmailLoginDirectory()
    let serverId = UUID().uuidString.lowercased()
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-event-bytes", name: "Events", ownerId: "owner")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "Bot", creatorUserId: "owner")
    let created = try accounts.oauth.createClient(serverId: serverId, createdByUserId: "unrelated", name: "Event App",
        clientId: "oauth-event-bytes", allowedScopes: ["agent:event:write"])
    try await withApp { app in
        try await app.register(collection: OAuthFeature(services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        )))
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
            let payload = "[{\"z\":\"https://raft.test/用户\",\"a\":1.5,\"a2\":1.0,\"large\":18446744073709551615},true,null]"
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
