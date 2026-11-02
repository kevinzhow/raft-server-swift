import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentMarketplaceExposesOnlyPublicVisibleAppsAndLiteralQueries() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001032001"
    let ownerId = "11111111-1111-4111-8111-000001032001"
    accounts.addAccount(id: ownerId, email: "marketplace-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "marketplace", name: "Marketplace", ownerId: ownerId)

    func app(_ clientId: String, _ name: String, _ description: String) throws -> String {
        let created = try accounts.oauth.createClient(
            serverId: serverId,
            createdByUserId: ownerId,
            name: name,
            clientId: clientId,
            description: description,
            homepageUrl: "https://\(clientId).example.test",
            returnUrl: "https://\(clientId).example.test/callback",
            allowedScopes: ["openid", "profile"]
        )
        accounts.oauth.setClientAppType(clientRecordId: created.id, appType: "third_party_global")
        return created.id
    }
    let publicApp = try app("me-build-homepage", "Me.Build Homepage", "Publish a personal homepage for an Agent")
    accounts.oauth.publishClient(clientRecordId: publicApp, humanMarketplaceVisible: true)
    let hiddenApp = try app("hidden-homepage", "Hidden Homepage", "A hidden homepage publisher")
    accounts.oauth.publishClient(clientRecordId: hiddenApp, humanMarketplaceVisible: false)
    let disabledApp = try app("disabled-homepage", "Disabled Homepage", "A disabled homepage publisher")
    accounts.oauth.publishClient(clientRecordId: disabledApp, humanMarketplaceVisible: true)
    accounts.oauth.setClientEnabled(clientRecordId: disabledApp, enabled: false)
    _ = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Private Homepage",
        clientId: "private-homepage",
        description: "A private homepage publisher"
    )

    let agent = accounts.oauth.createAgent(serverId: serverId, name: "MarketBot", runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "market")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            func search(_ query: String) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
                let response = try await client.get(URI(string: "/internal/agent-api/integrations/marketplace?\(query)"), headers: headers)
                return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }

            let searchResult = try await search("query=me.build%20homepage&limit=10")
            #expect(searchResult.status == .ok)
            #expect(searchResult.body["surface"] as? String == "public_marketplace")
            #expect(searchResult.body["metadataTrust"] as? String == "untrusted_app_supplied")
            #expect(searchResult.body["query"] as? String == "me.build homepage")
            let apps = searchResult.body["apps"] as? [[String: Any]] ?? []
            #expect(apps.map { $0["clientId"] as? String } == ["me-build-homepage"])
            #expect(apps[0]["allowedScopes"] as? [String] == ["openid", "profile"])
            #expect(apps[0]["installedOnServer"] as? Bool == false)

            let list = try await search("limit=50")
            #expect((list.body["apps"] as? [[String: Any]] ?? []).map { $0["clientId"] as? String } == ["me-build-homepage"])

            for literal in ["%25", "_", "%5C"] {
                let wildcard = try await search("query=\(literal)&limit=10")
                #expect(wildcard.status == .ok)
                #expect((wildcard.body["apps"] as? [[String: Any]] ?? []).isEmpty)
            }

            _ = accounts.oauth.installClient(serverId: serverId, clientRecordId: publicApp, installedByUserId: ownerId, groups: [])
            let installed = try await search("query=me.build")
            #expect((installed.body["apps"] as? [[String: Any]])?.first?["installedOnServer"] as? Bool == true)

            #expect(try await search("limit=51").status == .badRequest)
        }
    }
}
