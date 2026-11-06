import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct BuiltInJWTFixture {
    let accounts: EmailLoginDirectory
    let sourceServerId: String
    let targetServerId: String
    let ownerId: String
    let ownerEmail: String
    let memberId: String
    let memberEmail: String
    let installerId: String
    let installerEmail: String
    let clientId: String
    let clientRecordId: String
    let sourceKey: String
    let targetKey: String
}

private func makeBuiltInJWTFixture(suffix: String) throws -> BuiltInJWTFixture {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.serverURL = "https://raft.example.test" }
    let number = Int(suffix) ?? 0
    let sourceServerId = String(format: "33333333-3333-4333-8333-%012d", 300_000 + number)
    let targetServerId = String(format: "33333333-3333-4333-8333-%012d", 400_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 300_000 + number)
    let memberId = String(format: "11111111-1111-4111-8111-%012d", 310_000 + number)
    let installerId = String(format: "11111111-1111-4111-8111-%012d", 320_000 + number)
    let ownerEmail = "jwt-built-in-owner-\(suffix)@raft.test"
    let memberEmail = "jwt-built-in-member-\(suffix)@raft.test"
    let installerEmail = "jwt-built-in-installer-\(suffix)@raft.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail), (installerId, installerEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: sourceServerId, slug: "jwt-source-\(suffix)", name: "Publisher", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: targetServerId, slug: "jwt-target-\(suffix)", name: "Installer", ownerId: installerId)
    accounts.oauth.addMember(serverId: sourceServerId, userId: memberId, role: "member")

    let clientKey = "jwt-app-\(suffix)"
    let created = try accounts.oauth.createClient(
        serverId: sourceServerId,
        createdByUserId: ownerId,
        name: "Audience app",
        clientId: clientKey,
        allowedScopes: ["openid", "profile"]
    )
    let sourceAgent = accounts.oauth.createAgent(serverId: sourceServerId, name: "SourceAgent-\(suffix)", runtime: "external")
    let targetAgent = accounts.oauth.createAgent(serverId: targetServerId, name: "TargetAgent-\(suffix)", runtime: "external")
    let sourceKey = accounts.mintAgentCredential(agentId: sourceAgent, scopes: ["read"], name: "source-\(suffix)")
    let targetKey = accounts.mintAgentCredential(agentId: targetAgent, scopes: ["read"], name: "target-\(suffix)")

    return BuiltInJWTFixture(
        accounts: accounts,
        sourceServerId: sourceServerId,
        targetServerId: targetServerId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        memberId: memberId,
        memberEmail: memberEmail,
        installerId: installerId,
        installerEmail: installerEmail,
        clientId: created.clientId,
        clientRecordId: created.id,
        sourceKey: sourceKey,
        targetKey: targetKey
    )
}

private func builtInLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func builtInIssue(_ client: any Client, key: String, service: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: "/internal/agent-api/integrations/token") { request in
        request.body = .init(string: "{\"service\":\"\(service)\"}")
    }
}

private func builtInObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func builtInClaims(_ token: String) throws -> [String: Any] {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return [:] }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded += "=" }
    guard let data = Data(base64Encoded: encoded) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func builtInSettingsHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

@Test func agentAudienceJWTIsBuiltInAndSharesTheAgentLoginBoundary() async throws {
    let fixture = try makeBuiltInJWTFixture(suffix: "871")
    let accounts = fixture.accounts
    #expect(accounts.oauth.clientAgentJWTEnabled(clientRecordId: fixture.clientRecordId) == false)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerToken = try await builtInLogin(client, email: fixture.ownerEmail)
            let memberToken = try await builtInLogin(client, email: fixture.memberEmail)

            let first = try await builtInIssue(client, key: fixture.sourceKey, service: fixture.clientId)
            #expect(first.status == .ok)
            let firstBody = try builtInObject(first)
            let claims = try builtInClaims(try #require(firstBody["access_token"] as? String))
            #expect(claims["aud"] as? String == fixture.clientId)
            #expect(claims["server_id"] as? String == fixture.sourceServerId)
            #expect(firstBody["expires_in"] as? Int == 300)

            for legacy in [nil, true] as [Bool?] {
                accounts.oauth.setClientAgentJWTEnabledForTesting(clientRecordId: fixture.clientRecordId, enabled: legacy)
                #expect(try await builtInIssue(client, key: fixture.sourceKey, service: fixture.clientId).status == .ok)
            }
            accounts.oauth.setClientAgentJWTEnabledForTesting(clientRecordId: fixture.clientRecordId, enabled: false)

            let unknown = try await builtInIssue(client, key: fixture.targetKey, service: "unknown-private-app")
            let privateIssue = try await builtInIssue(client, key: fixture.targetKey, service: fixture.clientId)
            #expect(privateIssue.status == unknown.status)
            #expect(try builtInObject(privateIssue)["errorCode"] as? String == (try builtInObject(unknown)["errorCode"] as? String))

            let shareToken = try #require(
                accounts.oauth.convertClientToPrivateShareForTesting(
                    clientRecordId: fixture.clientRecordId,
                    installedByUserId: fixture.ownerId
                )
            )
            #expect(shareToken.hasPrefix("raft_share_"))
            #expect(try await builtInIssue(client, key: fixture.sourceKey, service: fixture.clientId).status == .ok)
            #expect(try await builtInIssue(client, key: fixture.targetKey, service: fixture.clientId).status == .forbidden)
            accounts.oauth.installSharedClientForTesting(
                clientRecordId: fixture.clientRecordId,
                serverId: fixture.targetServerId,
                installedByUserId: fixture.installerId
            )
            #expect(accounts.oauth.installationAgentJWTEnabled(
                clientRecordId: fixture.clientRecordId,
                serverId: fixture.targetServerId
            ) == false)
            let targetIssued = try await builtInIssue(client, key: fixture.targetKey, service: fixture.clientId)
            #expect(targetIssued.status == .ok)
            let targetClaims = try builtInClaims(try #require(try builtInObject(targetIssued)["access_token"] as? String))
            #expect(targetClaims["server_id"] as? String == fixture.targetServerId)
            #expect(targetClaims["aud"] as? String == fixture.clientId)

            accounts.oauth.setInstallationStatusForTesting(
                clientRecordId: fixture.clientRecordId,
                serverId: fixture.targetServerId,
                status: "suspended"
            )
            #expect(try await builtInIssue(client, key: fixture.targetKey, service: fixture.clientId).status == .forbidden)
            accounts.oauth.setInstallationStatusForTesting(
                clientRecordId: fixture.clientRecordId,
                serverId: fixture.targetServerId,
                status: "active"
            )
            accounts.oauth.setClientEnabled(clientRecordId: fixture.clientRecordId, enabled: false)
            #expect(try await builtInIssue(client, key: fixture.targetKey, service: fixture.clientId).status == .forbidden)
            accounts.oauth.setClientEnabled(clientRecordId: fixture.clientRecordId, enabled: true)
            accounts.oauth.setClientAllowedScopes(clientRecordId: fixture.clientRecordId, scopes: ["openid"])
            #expect(try await builtInIssue(client, key: fixture.targetKey, service: fixture.clientId).status == .forbidden)
            accounts.oauth.setClientAllowedScopes(clientRecordId: fixture.clientRecordId, scopes: ["openid", "profile"])
            accounts.oauth.removeInstallationForTesting(
                clientRecordId: fixture.clientRecordId,
                serverId: fixture.targetServerId
            )
            #expect(try await builtInIssue(client, key: fixture.targetKey, service: fixture.clientId).status == .forbidden)

            let deniedSettings = try await client.get(
                URI(string: "/api/integrations/clients/\(fixture.clientRecordId)/agent-jwt"),
                headers: builtInSettingsHeaders(memberToken, fixture.sourceServerId)
            )
            #expect(deniedSettings.status == .forbidden)
            #expect(try builtInObject(deniedSettings)["error"] as? String == "Only server owners and admins can read Agent JWT access")
            #expect(deniedSettings.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")

            let ownerSettingsHeaders = builtInSettingsHeaders(ownerToken, fixture.sourceServerId)
            let compat = try await client.get(
                URI(string: "/api/integrations/clients/\(fixture.clientRecordId)/agent-jwt"),
                headers: ownerSettingsHeaders
            )
            #expect(compat.status == .ok)
            #expect(compat.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            #expect(try builtInObject(compat) as NSDictionary == [
                "scope": "app",
                "enabled": true,
                "appEnabled": true,
                "effectiveEnabled": true,
                "canEnable": false,
                "audience": fixture.clientId,
                "expiresIn": 300,
            ] as NSDictionary)

            let write = try await client.send(.put, headers: ownerSettingsHeaders, to: "/api/integrations/clients/\(fixture.clientRecordId)/agent-jwt") { request in
                request.body = .init(string: "{\"enabled\":false}")
            }
            #expect(write.status == HTTPResponse.Status(code: 410, reasonPhrase: "Gone"))
            #expect(try builtInObject(write)["error"] as? String == "Agent JWT is built in for every App; there is no setting to change")
            #expect(accounts.oauth.clientAgentJWTEnabled(clientRecordId: fixture.clientRecordId) == false)
            #expect(try await builtInIssue(client, key: fixture.sourceKey, service: fixture.clientId).status == .ok)
        }
    }
}
