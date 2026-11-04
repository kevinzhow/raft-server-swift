import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentIntegrationsProjectTargetSetupAndAppUpdateAdvancesTheDeclaration() async throws {
    let accounts = EmailLoginDirectory()
    let publisherId = "33333333-3333-4333-8333-000001079001"
    let targetId = "33333333-3333-4333-8333-000001079002"
    let ownerId = "11111111-1111-4111-8111-000001079001"
    accounts.addAccount(id: ownerId, email: "setup-agent@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: publisherId, slug: "publisher", name: "Publisher", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: targetId, slug: "target", name: "Target", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: publisherId, createdByUserId: ownerId, name: "Setup App", clientId: "setup-agent-app",
        returnUrl: "https://setup.example.test/callback",
        setupUrl: "https://setup.example.test/configure", setupDescription: "Choose a repository"
    )
    accounts.oauth.setClientAppType(clientRecordId: created.id, appType: "third_party_global")
    accounts.oauth.publishClient(clientRecordId: created.id, humanMarketplaceVisible: true)
    let publisherInstall = accounts.oauth.installClient(
        serverId: publisherId, clientRecordId: created.id, installedByUserId: ownerId, groups: []
    )
    _ = try accounts.oauth.updateAppInstallationSetup(
        clientRecordId: created.id, installationId: publisherInstall, revision: 1, status: "complete"
    )
    let targetInstall = accounts.oauth.installClient(
        serverId: targetId, clientRecordId: created.id, installedByUserId: ownerId, groups: []
    )
    let targetAgent = accounts.oauth.createAgent(serverId: targetId, name: "TargetReader", runtime: "external")
    let targetKey = accounts.mintAgentCredential(agentId: targetAgent, scopes: ["read"], name: "setup-read")
    let publisherAgent = accounts.oauth.createAgent(serverId: publisherId, name: "PublisherOwner", runtime: "external")
    accounts.oauth.setAgentRole(serverId: publisherId, agentId: publisherAgent, role: "admin")
    let publisherKey = accounts.mintAgentCredential(agentId: publisherAgent, scopes: ["read", "send"], name: "setup-owner")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var targetHeaders = HTTPFields()
            targetHeaders[.authorization] = "Bearer \(targetKey)"
            let list = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: targetHeaders)
            #expect(list.status == .ok)
            let listBody = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let services = listBody["services"] as? [[String: Any]] ?? []
            let item = try #require(services.first { $0["id"] as? String == created.id })
            let setup = try #require(item["setup"] as? [String: Any])
            #expect(setup["status"] as? String == "pending", "completion in the publisher Server is not completion here")
            let url = try #require(setup["url"] as? String)
            #expect(url.contains("installation_id=\(targetInstall)"))
            #expect(url.contains("server_id=\(targetId)"))

            var publisherHeaders = HTTPFields()
            publisherHeaders[.authorization] = "Bearer \(publisherKey)"
            publisherHeaders[.contentType] = "application/json"
            let update = try await client.send(.post, headers: publisherHeaders, to: "/internal/agent-api/integrations/app/update") { request in
                request.body = .init(string: "{\"clientKey\":\"setup-agent-app\",\"setupUrl\":\"https://setup.example.test/agent-edited\",\"setupDescription\":\"Connect your account\"}")
            }
            #expect(update.status == .ok)
            let status = try await client.get(URI(string: "/internal/agent-api/integrations/app/status?client=setup-agent-app"), headers: publisherHeaders)
            #expect(status.status == .ok)
            let statusBody = try JSONSerialization.jsonObject(with: Data((status.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let app = try #require(statusBody["app"] as? [String: Any])
            #expect(app["setupUrl"] as? String == "https://setup.example.test/agent-edited")
            let appSetup = try #require(app["setup"] as? [String: Any])
            #expect(appSetup["status"] as? String == "pending")
            #expect(appSetup["revision"] as? Int == 2)

            let invalid = try await client.send(.post, headers: publisherHeaders, to: "/internal/agent-api/integrations/app/update") { request in
                request.body = .init(string: "{\"clientKey\":\"setup-agent-app\",\"setupUrl\":\"http://example.test/insecure\"}")
            }
            #expect(invalid.status == .badRequest)
        }
    }
}
