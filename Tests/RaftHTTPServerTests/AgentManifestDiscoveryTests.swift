import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func manifestHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    return headers
}

private func manifestJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func integrationDiscoveryFallsBackToTheWellKnownManifestURL() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001120001"
    let serverId = "33333333-3333-4333-8333-000001120001"
    accounts.addAccount(id: ownerId, email: "manifest-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "manifest", name: "Manifest", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ManifestBot", creatorUserId: ownerId, runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send"], name: "manifest")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Well Known Demo",
        clientId: "well-known-demo",
        homepageUrl: "https://manifest-demo.example.test/app",
        returnUrl: "https://callback.example.test/oauth/callback"
    )
    let expectedManifestUrl = "https://manifest-demo.example.test/.well-known/raft-agent-manifest.json"

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let list = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: manifestHeaders(key))
            #expect(list.status == .ok)
            let listBody = try manifestJSON(list)
            let services = (listBody["services"] as? [[String: Any]]) ?? []
            #expect(services.count == 1)
            #expect(services.first?["id"] as? String == created.id)
            #expect(services.first?["clientId"] as? String == "well-known-demo")
            #expect(services.first?["agentManifestUrl"] as? String == expectedManifestUrl)
            #expect(services.first?["agentManifestUrlSource"] as? String == "well_known")
            #expect((listBody["activeLogins"] as? [[String: Any]])?.isEmpty == true)

            let login = try await client.send(.post, headers: manifestHeaders(key), to: "/internal/agent-api/integrations/login") { request in
                request.body = .init(string: "{\"service\":\"well-known-demo\"}")
            }
            #expect(login.status == .ok)
            let service = try #require(try manifestJSON(login)["service"] as? [String: Any])
            #expect(service["id"] as? String == created.id)
            #expect(service["agentManifestUrl"] as? String == expectedManifestUrl)
            #expect(service["agentManifestUrlSource"] as? String == "well_known")

            let afterLogin = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: manifestHeaders(key))
            let active = (try manifestJSON(afterLogin)["activeLogins"] as? [[String: Any]]) ?? []
            #expect(active.map { $0["clientId"] as? String } == ["well-known-demo"])
            #expect(active.map { $0["agentManifestUrl"] as? String } == [expectedManifestUrl])
            #expect(active.map { $0["agentManifestUrlSource"] as? String } == ["well_known"])
        }
    }
}

@Test func explicitManifestURLKeepsItsExplicitSource() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001120002"
    let serverId = "33333333-3333-4333-8333-000001120002"
    accounts.addAccount(id: ownerId, email: "manifest-explicit-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "manifest-explicit", name: "Manifest Explicit", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ExplicitBot", creatorUserId: ownerId, runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "manifest-explicit")
    _ = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Explicit Manifest",
        clientId: "explicit-manifest-demo",
        homepageUrl: "https://explicit.example.test/app",
        returnUrl: "https://explicit.example.test/callback",
        agentManifestUrl: "https://explicit.example.test/custom/manifest.json"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let list = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: manifestHeaders(key))
            let service = try #require(((try manifestJSON(list)["services"] as? [[String: Any]]) ?? []).first)
            #expect(service["agentManifestUrl"] as? String == "https://explicit.example.test/custom/manifest.json")
            #expect(service["agentManifestUrlSource"] as? String == "explicit")
        }
    }
}
