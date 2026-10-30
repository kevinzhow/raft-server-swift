import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func marketplaceBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func marketplaceLookupFindsAPublishedAppButNotAPrivateOne() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111217"
    let memberId = "11111111-1111-4111-8111-111111111218"
    let publisherServerId = "33333333-3333-4333-8333-333333333411"
    let contextServerId = "33333333-3333-4333-8333-333333333412"
    accounts.addAccount(id: ownerId, email: "oauth-market-217@slock.test", password: "password123")
    accounts.addAccount(id: memberId, email: "oauth-market-member-218@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: publisherServerId, slug: "oauth-market-publisher-217", name: "Marketplace Publisher", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: contextServerId, slug: "oauth-market-context-217", name: "Customer Workspace", ownerId: ownerId)
    accounts.oauth.addMember(serverId: contextServerId, userId: memberId, role: "member")
    let published = try accounts.oauth.createClient(
        serverId: publisherServerId,
        createdByUserId: ownerId,
        name: "Marketplace Install Guide",
        clientId: "oauth-install-217",
        appType: "third_party_global",
        description: "Published but not installed",
        returnUrl: "https://marketplace-install.example.test/callback"
    )
    accounts.oauth.publishClient(clientRecordId: published.id)
    _ = try accounts.oauth.createClient(
        serverId: publisherServerId,
        createdByUserId: ownerId,
        name: "Private Install Guide",
        clientId: "oauth-private-217",
        appType: "third_party_global",
        returnUrl: "https://private-install.example.test/callback"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                #expect(response.status == .ok)
                return try marketplaceBody(response)["accessToken"] as? String ?? ""
            }
            func lookup(_ token: String, _ clientId: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                return try await client.send(
                    .get,
                    headers: headers,
                    to: "/api/oauth/clients/lookup?client_id=\(clientId)&server_id=\(contextServerId)"
                )
            }

            let ownerToken = try await login("oauth-market-217@slock.test")
            let memberToken = try await login("oauth-market-member-218@slock.test")

            let ownerLookup = try await lookup(ownerToken, published.clientId)
            #expect(ownerLookup.status == .ok)
            let body = try marketplaceBody(ownerLookup)
            #expect(body["id"] as? String == published.id)
            #expect(body["clientId"] as? String == published.clientId)
            #expect(body["appType"] as? String == "third_party_global")
            #expect(body["name"] as? String == "Marketplace Install Guide")
            #expect(body["description"] as? String == "Published but not installed")
            #expect(body["homepageUrl"] == nil || body["homepageUrl"] is NSNull)
            #expect(body["returnUrl"] as? String == "https://marketplace-install.example.test/callback")
            #expect(body["logoUrl"] == nil || body["logoUrl"] is NSNull)
            #expect(body["allowedScopes"] == nil || body["allowedScopes"] is NSNull)
            #expect(body["marketplace"] as? Bool == true)
            #expect(body["availability"] as? String == "install_required")
            #expect(body["setupUrl"] == nil || body["setupUrl"] is NSNull)
            #expect(body["setupDescription"] == nil || body["setupDescription"] is NSNull)
            let installation = body["installation"] as? [String: Any]
            #expect(installation?["serverId"] as? String == contextServerId)
            #expect(installation?["canInstall"] as? Bool == true)

            let memberLookup = try await lookup(memberToken, published.clientId)
            #expect(memberLookup.status == .ok)
            #expect((try marketplaceBody(memberLookup)["installation"] as? [String: Any])?["canInstall"] as? Bool == false)

            for hiddenId in ["oauth-private-217", "unknown-217"] {
                let hidden = try await lookup(ownerToken, hiddenId)
                #expect(hidden.status == .notFound)
                #expect(try marketplaceBody(hidden)["error"] as? String == "OAuth client not found for server")
            }

            _ = accounts.oauth.installClient(
                serverId: contextServerId,
                clientRecordId: published.id,
                installedByUserId: ownerId,
                groups: []
            )
            let ready = try await lookup(ownerToken, published.clientId)
            #expect(ready.status == .ok)
            let readyBody = try marketplaceBody(ready)
            #expect(readyBody["marketplace"] as? Bool == true)
            #expect(readyBody["availability"] as? String == "ready")
            #expect(readyBody["installation"] == nil)
        }
    }
}
