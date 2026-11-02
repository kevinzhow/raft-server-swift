import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct IntegrationAppFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let foreignServerId: String
    let ownerId: String
    let adminAgentId: String
    let adminAgentKey: String
    let ownerAgentId: String
    let ownerAgentKey: String
    let memberAgentId: String
    let memberAgentKey: String
    let ordinaryClientId: String
    let ordinaryClientKey: String
    let platformClientId: String
    let platformClientKey: String
}

private func makeIntegrationAppFixture(_ suffix: String) -> IntegrationAppFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001110\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001110\(suffix)"
    let foreignServerId = "33333333-3333-4333-8333-000001111\(suffix)"
    accounts.addAccount(id: ownerId, email: "integration-app-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "integration-app-\(suffix)", name: "Integration App \(suffix)", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: foreignServerId, slug: "integration-app-foreign-\(suffix)", name: "Integration App Foreign \(suffix)", ownerId: ownerId)

    let adminAgentId = accounts.oauth.createAgent(serverId: serverId, name: "AdminQueryAgent\(suffix)", creatorUserId: ownerId, runtime: "external")
    accounts.oauth.setAgentRole(serverId: serverId, agentId: adminAgentId, role: "admin")
    let ownerAgentId = accounts.oauth.createAgent(serverId: serverId, name: "OwnerQueryAgent\(suffix)", creatorUserId: ownerId, runtime: "external")
    let memberAgentId = accounts.oauth.createAgent(serverId: serverId, name: "MemberQueryAgent\(suffix)", creatorUserId: ownerId, runtime: "external")

    let ordinary = try! accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Ordinary Agent Query",
        clientId: "ordinary-agent-query-\(suffix)",
        returnUrl: "https://ordinary-query.example.test/callback"
    )
    accounts.oauth.setClientAppType(clientRecordId: ordinary.id, appType: "third_party_global")
    let platform = try! accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Platform Hidden Agent Query",
        clientId: "platform-agent-query-\(suffix)",
        returnUrl: "https://platform-query.example.test/callback"
    )
    accounts.oauth.setClientAppType(clientRecordId: platform.id, appType: "third_party_global")
    accounts.oauth.registerExternalApp(clientRecordId: platform.id, provider: "slack", state: "active")

    accounts.oauth.addClientMaintainer(clientRecordId: ordinary.id, agentId: ownerAgentId)
    accounts.oauth.addClientMaintainer(clientRecordId: platform.id, agentId: ownerAgentId)

    return IntegrationAppFixture(
        accounts: accounts,
        serverId: serverId,
        foreignServerId: foreignServerId,
        ownerId: ownerId,
        adminAgentId: adminAgentId,
        adminAgentKey: accounts.mintAgentCredential(agentId: adminAgentId, scopes: ["read", "server"], name: "admin-\(suffix)"),
        ownerAgentId: ownerAgentId,
        ownerAgentKey: accounts.mintAgentCredential(agentId: ownerAgentId, scopes: ["read"], name: "owner-\(suffix)"),
        memberAgentId: memberAgentId,
        memberAgentKey: accounts.mintAgentCredential(agentId: memberAgentId, scopes: ["read"], name: "member-\(suffix)"),
        ordinaryClientId: ordinary.id,
        ordinaryClientKey: ordinary.clientId,
        platformClientId: platform.id,
        platformClientKey: platform.clientId
    )
}

private func integrationAppHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    return headers
}

private func integrationAppJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func integrationAppList(
    _ client: any Client,
    _ key: String
) async throws -> (status: HTTPResponse.Status, apps: [[String: Any]]) {
    let response = try await client.get(URI(string: "/internal/agent-api/integrations/app"), headers: integrationAppHeaders(key))
    let apps = (try integrationAppJSON(response)["apps"] as? [[String: Any]]) ?? []
    return (response.status, apps)
}

private func integrationAppStatus(
    _ client: any Client,
    _ key: String,
    clientKey: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let response = try await client.get(
        URI(string: "/internal/agent-api/integrations/app/status?client=\(clientKey)"),
        headers: integrationAppHeaders(key)
    )
    return (response.status, try integrationAppJSON(response))
}

@Test func integrationAppListHidesExternalRegistrationAndFollowsMaintainersAndAdmins() async throws {
    let f = makeIntegrationAppFixture("001")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let admin = try await integrationAppList(client, f.adminAgentKey)
            #expect(admin.status == .ok)
            let adminKeys = admin.apps.compactMap { $0["clientKey"] as? String }
            #expect(adminKeys.contains(f.ordinaryClientKey))
            #expect(!adminKeys.contains(f.platformClientKey), "platform-bound apps stay hidden from admins")

            let hiddenStatus = try await integrationAppStatus(client, f.adminAgentKey, clientKey: f.platformClientKey)
            #expect(hiddenStatus.status == .notFound)
            let ordinaryStatus = try await integrationAppStatus(client, f.adminAgentKey, clientKey: f.ordinaryClientKey)
            #expect(ordinaryStatus.status == .ok)
            #expect((ordinaryStatus.body["app"] as? [String: Any])?["clientKey"] as? String == f.ordinaryClientKey)

            let owner = try await integrationAppList(client, f.ownerAgentKey)
            #expect(owner.status == .ok)
            let ownerKeys = owner.apps.compactMap { $0["clientKey"] as? String }
            #expect(ownerKeys.contains(f.ordinaryClientKey))
            #expect(!ownerKeys.contains(f.platformClientKey))
            #expect((owner.apps.first { $0["clientKey"] as? String == f.ordinaryClientKey })?["authority"] as? String == "owner")
            let ownerHidden = try await integrationAppStatus(client, f.ownerAgentKey, clientKey: f.platformClientKey)
            #expect(ownerHidden.status == .notFound)

            let member = try await integrationAppList(client, f.memberAgentKey)
            #expect(member.status == .ok)
            #expect(member.apps.isEmpty, "an agent that maintains no app and is not an admin sees none")
            let memberStatus = try await integrationAppStatus(client, f.memberAgentKey, clientKey: f.ordinaryClientKey)
            #expect(memberStatus.status == .notFound)

            let bothParams = try await client.get(
                URI(string: "/internal/agent-api/integrations/app/status?client=\(f.ordinaryClientKey)&card=abc"),
                headers: integrationAppHeaders(f.adminAgentKey)
            )
            #expect(bothParams.status == .badRequest)
        }
    }
}

@Test func integrationAppInstallationIdIsScopedToTheRequestServer() async throws {
    let f = makeIntegrationAppFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let uninstalled = try await integrationAppStatus(client, f.ownerAgentKey, clientKey: f.ordinaryClientKey)
            #expect(uninstalled.status == .ok)
            #expect((uninstalled.body["app"] as? [String: Any])?["installationId"] is NSNull)
            let uninstalledList = try await integrationAppList(client, f.ownerAgentKey)
            #expect(uninstalledList.apps.first { $0["clientKey"] as? String == f.ordinaryClientKey }?["installationId"] is NSNull)

            let foreignInstall = f.accounts.oauth.installClient(
                serverId: f.foreignServerId,
                clientRecordId: f.ordinaryClientId,
                installedByUserId: f.ownerId,
                groups: []
            )
            let foreignStatus = try await integrationAppStatus(client, f.ownerAgentKey, clientKey: f.ordinaryClientKey)
            #expect(foreignStatus.status == .ok)
            #expect((foreignStatus.body["app"] as? [String: Any])?["installationId"] is NSNull, "a foreign installation id must not leak")

            let currentInstall = f.accounts.oauth.installClient(
                serverId: f.serverId,
                clientRecordId: f.ordinaryClientId,
                installedByUserId: f.ownerId,
                groups: []
            )
            #expect(currentInstall != foreignInstall)
            let installedStatus = try await integrationAppStatus(client, f.ownerAgentKey, clientKey: f.ordinaryClientKey)
            #expect((installedStatus.body["app"] as? [String: Any])?["installationId"] as? String == currentInstall)
            let installedList = try await integrationAppList(client, f.ownerAgentKey)
            #expect(installedList.apps.first { $0["clientKey"] as? String == f.ordinaryClientKey }?["installationId"] as? String == currentInstall)

            let admin = try await integrationAppStatus(client, f.adminAgentKey, clientKey: f.ordinaryClientKey)
            #expect((admin.body["app"] as? [String: Any])?["installationId"] as? String == currentInstall)
            let adminList = try await integrationAppList(client, f.adminAgentKey)
            #expect(adminList.apps.first { $0["clientKey"] as? String == f.ordinaryClientKey }?["installationId"] as? String == currentInstall)
        }
    }
}
