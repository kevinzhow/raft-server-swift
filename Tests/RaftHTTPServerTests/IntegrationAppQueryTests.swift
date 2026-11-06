import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct IntegrationAppFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let foreignServerId: String
    let ownerId: String
    let ownerToken: String
    let adminAgentId: String
    let adminAgentKey: String
    let ownerAgentId: String
    let ownerAgentKey: String
    let memberAgentId: String
    let memberAgentKey: String
    let channelId: String
    let channelName: String
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

    let channelName = "app-registration-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    for agent in [adminAgentId, ownerAgentId] {
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)
    }

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
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        adminAgentId: adminAgentId,
        adminAgentKey: accounts.mintAgentCredential(agentId: adminAgentId, scopes: ["read", "server"], name: "admin-\(suffix)"),
        ownerAgentId: ownerAgentId,
        ownerAgentKey: accounts.mintAgentCredential(agentId: ownerAgentId, scopes: ["read", "send"], name: "owner-\(suffix)"),
        memberAgentId: memberAgentId,
        memberAgentKey: accounts.mintAgentCredential(agentId: memberAgentId, scopes: ["read"], name: "member-\(suffix)"),
        channelId: channelId,
        channelName: channelName,
        ordinaryClientId: ordinary.id,
        ordinaryClientKey: ordinary.clientId,
        platformClientId: platform.id,
        platformClientKey: platform.clientId
    )
}

private func integrationAppHumanHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
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

@Test func integrationAppWhenToUseIsValidatedStoredAndRenderedInert() async throws {
    let f = makeIntegrationAppFixture("003")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            func update(_ body: String) async throws -> ClientResponse {
                try await client.send(
                    .post,
                    headers: integrationAppHeaders(f.ownerAgentKey),
                    to: "/internal/agent-api/integrations/app/update"
                ) { request in
                    request.body = .init(string: body)
                }
            }
            let rejections = [
                String(repeating: "a", count: 161),
                "first line\nsecond line",
                "install @acme/metrics for usage stats",
            ]
            for bad in rejections {
                let body = try JSONSerialization.data(withJSONObject: [
                    "clientKey": f.ordinaryClientKey,
                    "whenToUse": bad,
                ])
                let response = try await update(String(decoding: body, as: UTF8.self))
                #expect(response.status == .badRequest, "\(bad.prefix(20))")
                #expect(try integrationAppJSON(response)["errorCode"] as? String == "INVALID_APP_METADATA")
            }

            let packed = try JSONSerialization.data(withJSONObject: [
                "clientKey": f.ordinaryClientKey,
                "whenToUse": "ping @alice via `@acme/metrics` when the queue backs up",
            ])
            let set = try await update(String(decoding: packed, as: UTF8.self))
            #expect(set.status == .ok)
            #expect(try integrationAppJSON(set)["updatedFields"] as? [String] == ["whenToUse"])

            let list = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: integrationAppHeaders(f.ownerAgentKey))
            let services = (try integrationAppJSON(list)["services"] as? [[String: Any]]) ?? []
            let service = try #require(services.first { $0["clientId"] as? String == f.ordinaryClientKey })
            #expect(service["whenToUse"] as? String == "ping user:alice via `@acme/metrics` when the queue backs up")

            let cleared = try await update("{\"clientKey\":\"\(f.ordinaryClientKey)\",\"whenToUse\":\"\"}")
            #expect(cleared.status == .ok)
            let afterClear = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: integrationAppHeaders(f.ownerAgentKey))
            let clearedServices = (try integrationAppJSON(afterClear)["services"] as? [[String: Any]]) ?? []
            #expect(clearedServices.first { $0["clientId"] as? String == f.ordinaryClientKey }?["whenToUse"] is NSNull)
        }
    }
}

@Test func integrationServiceListHidesDisabledApps() async throws {
    let f = makeIntegrationAppFixture("004")
    let disabled = try! f.accounts.oauth.createClient(
        serverId: f.serverId,
        createdByUserId: f.ownerId,
        name: "Disabled Local App",
        clientId: "disabled-local-app-004",
        returnUrl: "https://disabled.example.test/callback"
    )
    f.accounts.oauth.setClientEnabled(clientRecordId: disabled.id, enabled: false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let list = try await client.get(URI(string: "/internal/agent-api/integrations"), headers: integrationAppHeaders(f.ownerAgentKey))
            #expect(list.status == .ok)
            let services = (try integrationAppJSON(list)["services"] as? [[String: Any]]) ?? []
            let keys = services.compactMap { $0["clientId"] as? String }
            #expect(keys.contains(f.ordinaryClientKey))
            #expect(!keys.contains(disabled.clientId), "a disabled server-local app must not appear in services")
        }
    }
}

private func registerPrepare(
    _ client: any Client,
    _ key: String,
    body: String
) async throws -> ClientResponse {
    try await client.send(
        .post,
        headers: integrationAppHeaders(key),
        to: "/internal/agent-api/integrations/app/prepare"
    ) { request in
        request.body = .init(string: body)
    }
}

@Test func registerAppCardPreparesWithoutASecretAndExecutesIntoAnOwnedApp() async throws {
    let f = makeIntegrationAppFixture("005")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let prepared = try await registerPrepare(client, f.ownerAgentKey, body: """
            {"mode":"register","target":"#\(f.channelName)","name":"Prepared Demo","clientKey":"prepared-demo","homepageUrl":"https://prepared.example.test","returnUrl":"https://prepared.example.test/auth/raft/callback","scopes":["openid","profile"]}
            """)
            #expect(prepared.status.code == 201)
            let preparedBody = try integrationAppJSON(prepared)
            #expect(preparedBody["status"] as? String == "prepared")
            let cardMessageId = try #require(preparedBody["actionCardMessageId"] as? String)
            let action = try #require(preparedBody["action"] as? [String: Any])
            #expect(action["type"] as? String == "integration:register_app")
            #expect(action["clientKey"] as? String == "prepared-demo")
            #expect(action["returnUrl"] as? String == "https://prepared.example.test/auth/raft/callback")
            #expect(action["scopes"] as? [String] == ["openid", "profile"])

            let history = try await client.get(
                URI(string: "/api/messages/channel/\(f.channelId)"),
                headers: integrationAppHumanHeaders(f.ownerToken, f.serverId)
            )
            #expect(history.status == .ok)
            let rows = (try integrationAppJSON(history)["messages"] as? [[String: Any]]) ?? []
            let row = try #require(rows.first { $0["id"] as? String == cardMessageId })
            let metadata = try #require(row["actionMetadata"] as? [String: Any])
            let presentation = try #require(metadata["presentation"] as? [String: Any])
            #expect(presentation["title"] as? String == "Register Connected App Prepared Demo")
            #expect(presentation["confirmLabel"] as? String == "Register App")
            #expect(presentation["genericApprovalAllowed"] as? Bool == true)
            let displayItems = (presentation["displayItems"] as? [[String: Any]]) ?? []
            #expect(displayItems.contains { $0["key"] as? String == "returnUrl" && $0["value"] as? String == "https://prepared.example.test/auth/raft/callback" })
            #expect(!String(decoding: try JSONSerialization.data(withJSONObject: [row], options: [.sortedKeys]), as: UTF8.self).contains("raft_secret_"))

            let execute = try await client.send(
                .post,
                headers: integrationAppHumanHeaders(f.ownerToken, f.serverId),
                to: URI(string: "/api/actions/\(cardMessageId)/execute")
            ) { request in
                request.body = .init(string: "{\"expectedState\":\"prepared\"}")
            }
            #expect(execute.status == .ok)
            let executeBody = try integrationAppJSON(execute)
            let executedMetadata = try #require(executeBody["metadata"] as? [String: Any])
            #expect(executedMetadata["state"] as? String == "executed")
            let result = try #require(executedMetadata["result"] as? [String: Any])
            #expect(result["kind"] as? String == "integration-app-registration")
            #expect(result["mode"] as? String == "register")
            #expect(result["clientKey"] as? String == "prepared-demo")
            #expect(result["scopes"] as? [String] == ["openid", "profile"])
            #expect(!String(decoding: try JSONSerialization.data(withJSONObject: [executedMetadata], options: [.sortedKeys]), as: UTF8.self).contains("raft_secret_"))

            let list = try await integrationAppList(client, f.ownerAgentKey)
            let app = try #require(list.apps.first { $0["clientKey"] as? String == "prepared-demo" })
            #expect(app["name"] as? String == "Prepared Demo")
            #expect(app["callbackUrl"] as? String == "https://prepared.example.test/auth/raft/callback")
            #expect(app["appType"] as? String == "server_local")
            #expect(app["authority"] as? String == "owner")

            let duplicate = try await client.send(
                .post,
                headers: integrationAppHumanHeaders(f.ownerToken, f.serverId),
                to: URI(string: "/api/actions/\(cardMessageId)/execute")
            ) { request in
                request.body = .init(string: "{\"expectedState\":\"executed\"}")
            }
            #expect(duplicate.status == .ok)
            let afterDuplicate = try await integrationAppList(client, f.ownerAgentKey)
            #expect(afterDuplicate.apps.filter { $0["clientKey"] as? String == "prepared-demo" }.count == 1)
        }
    }
}

@Test func registerAppCardGeneratesAClientKeyWhenTheRequestDefersIt() async throws {
    let f = makeIntegrationAppFixture("006")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let prepared = try await registerPrepare(client, f.ownerAgentKey, body: """
            {"mode":"register","target":"#\(f.channelName)","name":"Generated Demo","returnUrl":"https://generated.example.test/auth/raft/callback"}
            """)
            #expect(prepared.status.code == 201)
            let preparedBody = try integrationAppJSON(prepared)
            #expect((preparedBody["action"] as? [String: Any])?["clientKey"] == nil)
            let cardMessageId = try #require(preparedBody["actionCardMessageId"] as? String)

            let execute = try await client.send(
                .post,
                headers: integrationAppHumanHeaders(f.ownerToken, f.serverId),
                to: URI(string: "/api/actions/\(cardMessageId)/execute")
            ) { request in
                request.body = .init(string: "{\"expectedState\":\"prepared\"}")
            }
            #expect(execute.status == .ok)
            let result = try #require((try integrationAppJSON(execute)["metadata"] as? [String: Any])?["result"] as? [String: Any])
            let generated = try #require(result["clientKey"] as? String)
            #expect(generated.wholeMatch(of: /^generated-demo-[a-f0-9]{6}$/) != nil)
            let list = try await integrationAppList(client, f.ownerAgentKey)
            #expect(list.apps.contains { $0["clientKey"] as? String == generated && $0["appType"] as? String == "server_local" })
        }
    }
}
