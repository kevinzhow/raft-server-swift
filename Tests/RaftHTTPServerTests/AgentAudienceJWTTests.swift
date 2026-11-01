import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AgentJWTFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let agentId: String
    let agentName: String
    let apiKey: String
    let clientKey: String
    let clientRecordId: String
    let foreignClientKey: String
    let credentialKey: String
}

private func makeAgentJWTFixture(suffix: String) throws -> AgentJWTFixture {
    let accounts = EmailLoginDirectory()
    accounts.serverURL = "https://raft.example.test"
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 120_000 + number)
    let foreignId = String(format: "33333333-3333-4333-8333-%012d", 130_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 130_000 + number)
    accounts.addAccount(id: ownerId, email: "jwt-\(suffix)@raft.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    let slug = "jwt-\(suffix)"
    accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "JWT Server", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: foreignId, slug: "foreign-\(suffix)", name: "Foreign Server", ownerId: ownerId)
    let agentName = "JwtAgent-\(suffix)"
    let agent = accounts.oauth.createAgent(serverId: serverId, name: agentName, runtime: "external")
    let credential = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "jwt-test-\(suffix)")
    let local = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "JWT RP",
        clientId: "jwt-rp-\(suffix)",
        returnUrl: "https://rp.example.test/callback",
        allowedScopes: ["openid", "profile"]
    )
    let foreign = try accounts.oauth.createClient(
        serverId: foreignId,
        createdByUserId: ownerId,
        name: "Foreign RP",
        clientId: "foreign-rp-\(suffix)",
        allowedScopes: ["openid", "profile"]
    )
    return AgentJWTFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: slug,
        agentId: agent,
        agentName: agentName,
        apiKey: credential,
        clientKey: local.clientId,
        clientRecordId: local.id,
        foreignClientKey: foreign.clientId,
        credentialKey: credential
    )
}

private func jwtTokenRequest(_ client: any Client, key: String, body: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: "/internal/agent-api/integrations/token") { request in
        request.body = .init(string: body)
    }
}

private func jwtObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func jwtBase64URL(_ value: String) -> Data? {
    var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded += "=" }
    return Data(base64Encoded: encoded)
}

@Test func agentAudienceJWTIsBuiltInBoundToTheActorAndNeverCreatesARawCode() async throws {
    let fixture = try makeAgentJWTFixture(suffix: "791")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            func post(_ body: String = "{\"service\":\"\(fixture.clientKey)\"}", key: String? = nil) async throws -> ClientResponse {
                try await jwtTokenRequest(client, key: key ?? fixture.apiKey, body: body)
            }

            #expect(try await post(key: "invalid-agent-key").status == .unauthorized)
            #expect(try await post("{\"service\":\"\(fixture.foreignClientKey)\"}").status == .forbidden)
            for field in ["agentId", "serverId", "audience", "issuer", "expires_in", "scopes", "claims"] {
                let response = try await post("{\"service\":\"\(fixture.clientKey)\",\"\(field)\":\"override\"}")
                #expect(response.status == .badRequest)
            }

            let issued = try await post()
            #expect(issued.status == .ok)
            #expect(issued.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let body = try jwtObject(issued)
            #expect(body["audience"] as? String == fixture.clientKey)
            #expect(body["expires_in"] as? Int == 300)
            let token = try #require(body["access_token"] as? String)
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            #expect(parts.count == 3)
            let headerData = try #require(jwtBase64URL(String(parts[0])))
            let claimData = try #require(jwtBase64URL(String(parts[1])))
            let header = try #require((try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any])
            let claims = try #require((try? JSONSerialization.jsonObject(with: claimData)) as? [String: Any])
            #expect(header["typ"] as? String == "at+jwt")
            #expect(header["alg"] as? String == "ES256")

            let jwksResponse = try await client.get(URI(string: "/oidc/\(fixture.serverSlug)/api/oauth/jwks"))
            let keys = try jwtObject(jwksResponse)["keys"] as? [[String: Any]] ?? []
            let jwk = try #require(keys.first { $0["kid"] as? String == header["kid"] as? String })
            let x = try #require(jwtBase64URL(jwk["x"] as? String ?? ""))
            let y = try #require(jwtBase64URL(jwk["y"] as? String ?? ""))
            let signature = try #require(jwtBase64URL(String(parts[2])))
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
            let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            #expect(publicKey.isValidSignature(ecdsa, for: Data("\(parts[0]).\(parts[1])".utf8)))

            #expect(claims["iss"] as? String == "https://raft.example.test/oidc/\(fixture.serverSlug)")
            #expect(claims["aud"] as? String == fixture.clientKey)
            #expect(claims["sub"] as? String == fixture.agentId)
            #expect(claims["server_id"] as? String == fixture.serverId)
            #expect(claims["type"] as? String == "agent")
            #expect(claims["token_use"] as? String == "agent_access")
            #expect(claims["login"] as? String == "raft-agent-\(fixture.agentId)")
            #expect((claims["login"] as? String)?.count == 47)
            #expect(claims["preferred_username"] as? String == fixture.agentName)
            let issuedAt = try #require(claims["iat"] as? Int)
            let expiresAt = try #require(claims["exp"] as? Int)
            #expect(expiresAt - issuedAt == 300)
            #expect(claims["nbf"] as? Int == issuedAt)
            #expect(claims["email"] == nil)

            var bearer = HTTPFields()
            bearer[.authorization] = "Bearer \(token)"
            #expect(try await client.get("/api/oauth/userinfo", headers: bearer).status == .unauthorized)

            let second = try await post()
            let secondToken = try jwtObject(second)["access_token"] as? String ?? ""
            #expect(secondToken != token)

            fixture.accounts.setAgentAudienceStatusForTesting(agentId: fixture.agentId, status: "stopped")
            #expect(try await post().status == .forbidden)
            fixture.accounts.setAgentAudienceStatusForTesting(agentId: fixture.agentId, status: "active")

            fixture.accounts.oauth.setClientEnabled(clientRecordId: fixture.clientRecordId, enabled: false)
            #expect(try await post().status == .forbidden)
            fixture.accounts.oauth.setClientEnabled(clientRecordId: fixture.clientRecordId, enabled: true)

            fixture.accounts.oauth.setClientAllowedScopes(clientRecordId: fixture.clientRecordId, scopes: ["openid"])
            #expect(try await post().status == .forbidden)
            fixture.accounts.oauth.setClientAllowedScopes(clientRecordId: fixture.clientRecordId, scopes: ["openid", "profile"])

            fixture.accounts.oauth.setClientAppType(clientRecordId: fixture.clientRecordId, appType: "third_party_global")
            #expect(try await post().status == .forbidden)
            fixture.accounts.oauth.setClientAppType(clientRecordId: fixture.clientRecordId, appType: "server_local")

            fixture.accounts.oauth.removeAgentMember(serverId: fixture.serverId, agentId: fixture.agentId)
            #expect(try await post().status == .forbidden)
            fixture.accounts.oauth.setAgentRole(serverId: fixture.serverId, agentId: fixture.agentId, role: "member")
            #expect(try await post().status == .ok)

            fixture.accounts.revokeAgentIntegrationGrantForTesting(agentId: fixture.agentId, clientKey: fixture.clientKey)
            #expect(try await post().status == .forbidden)
            fixture.accounts.restoreAgentIntegrationGrantForTesting(agentId: fixture.agentId, clientKey: fixture.clientKey)
            #expect(try await post().status == .ok)

            fixture.accounts.revokeAgentCredentialForTesting(apiKey: fixture.credentialKey)
            #expect(try await post().status == .unauthorized)
        }
    }
}
