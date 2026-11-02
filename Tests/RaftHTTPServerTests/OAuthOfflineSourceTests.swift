import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func republishingRestoresOfflineHumanLoginWithoutRevivingRevokedCredentials() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001042001"
    let sourceId = "33333333-3333-4333-8333-000001042001"
    let externalId = "33333333-3333-4333-8333-000001042002"
    accounts.addAccount(id: ownerId, email: "offline-source@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: sourceId, slug: "offline-source", name: "Offline Source", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: externalId, slug: "offline-external", name: "Offline External", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: sourceId,
        createdByUserId: ownerId,
        name: "Synthetic Mail",
        clientId: "synthetic-mail",
        appType: "third_party_global",
        description: "A synthetic App for testing offline source access.",
        returnUrl: "https://offline.example.test/callback",
        allowedScopes: ["openid", "profile", "identity"]
    )
    // Historical approved-offline state: private App still listed in Settings,
    // no source installation, revoked credentials that must stay revoked.
    accounts.oauth.setClientPublishStatusForTesting(clientRecordId: created.id, status: "private")
    accounts.oauth.seedRevokedOAuthAccessTokenForTesting(
        serverId: sourceId,
        clientRecordId: created.id,
        userId: ownerId,
        rawToken: "revoked-synthetic-token"
    )
    let bearer = accounts.mintAccessTokenForTesting(userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(bearer)"
            headers[.contentType] = "application/json"
            var sourceHeaders = headers
            sourceHeaders[HTTPField.Name("X-Server-Id")!] = sourceId

            func lookup(_ serverId: String) async throws -> ClientResponse {
                try await client.get(
                    URI(string: "/api/oauth/clients/lookup?client_id=synthetic-mail&server_id=\(serverId)"),
                    headers: headers
                )
            }
            #expect(try await lookup(sourceId).status == .notFound)

            let listed = try await client.get(URI(string: "/api/integrations/clients"), headers: sourceHeaders)
            #expect(listed.status == .ok)
            let rows = (try JSONSerialization.jsonObject(with: Data((listed.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            #expect(rows.contains { $0["id"] as? String == created.id })

            accounts.oauth.setClientPublishStatusForTesting(clientRecordId: created.id, status: "publish_requested")
            #expect(try await lookup(sourceId).status == .notFound, "requesting republish alone does not restore access")
            #expect(accounts.oauth.reviewClientPublish(clientRecordId: created.id, status: "published"))
            #expect(try await lookup(sourceId).status == .ok)

            let authorized = try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\"synthetic-mail\",\"serverId\":\"\(sourceId)\",\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(authorized.status == .ok)
            let authorizedBody = (try JSONSerialization.jsonObject(with: Data((authorized.body.string ?? "").utf8))) as? [String: Any]
            let code = authorizedBody?["code"] as? String
            let exchange = try await client.send(.post, headers: headers, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"synthetic-mail\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code ?? "")\"}")
            }
            #expect(exchange.status == .ok)
            let exchangeBody = (try JSONSerialization.jsonObject(with: Data((exchange.body.string ?? "").utf8))) as? [String: Any]
            let accessToken = exchangeBody?["access_token"] as? String
            var tokenHeaders = HTTPFields()
            tokenHeaders[.authorization] = "Bearer \(accessToken ?? "")"
            let identity = try await client.get(URI(string: "/api/oauth/userinfo"), headers: tokenHeaders)
            #expect(identity.status == .ok)

            var revokedHeaders = HTTPFields()
            revokedHeaders[.authorization] = "Bearer revoked-synthetic-token"
            let revokedIdentity = try await client.get(URI(string: "/api/oauth/userinfo"), headers: revokedHeaders)
            #expect(revokedIdentity.status == .unauthorized)
            #expect(accounts.oauth.revokedOAuthTokenCountForTesting(clientRecordId: created.id) == 1)

            // Even when the published source was manually uninstalled, returning
            // it to private restores basic source access without installation grants.
            accounts.oauth.removeInstallationsForTesting(clientRecordId: created.id)
            accounts.oauth.setClientPublishStatusForTesting(clientRecordId: created.id, status: "unpublish_requested")
            #expect(accounts.oauth.reviewClientPublish(clientRecordId: created.id, status: "private"))
            #expect(try await lookup(sourceId).status == .ok)
            #expect(try await lookup(externalId).status == .notFound)
            #expect(accounts.oauth.installationGroupsForTesting(clientRecordId: created.id, serverId: sourceId)?.isEmpty == true)
        }
    }
}
