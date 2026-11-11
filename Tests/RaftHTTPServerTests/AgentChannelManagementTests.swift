import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ChannelManagementFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let ownerToken: String
    let agentId: String
    let agentName: String
    let machineId: String
    let machineName: String
    let machineKey: String
    let agentKey: String
    let joinedChannel: String
    let joinOnlyChannel: String
    let privateMemberChannel: String
    let privateOutsiderChannel: String
    let archivedChannel: String
}

private func makeChannelManagementFixture(_ suffix: String) -> ChannelManagementFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001210\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001210\(suffix)"
    accounts.addAccount(id: ownerId, email: "channel-mgmt-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-mgmt-\(suffix)", name: "Channel Mgmt \(suffix)", ownerId: ownerId)
    func channel(_ name: String, type: String = "channel", withOwner: Bool = true) -> String {
        let id = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId, type: type)
        accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: ownerId, kind: type, name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: ownerId)
        if !withOwner {
            accounts.removeChannelMemberForTesting(channelId: id, userId: ownerId)
        }
        return id
    }
    let joinedChannel = channel("focus-room")
    let joinOnlyChannel = channel("join-public")
    let privateMemberChannel = channel("agent-private-member", type: "private", withOwner: false)
    let privateOutsiderChannel = channel("agent-private-outsider", type: "private", withOwner: false)
    let archivedChannel = channel("archived-agent-list")
    let agentName = "ChannelMgmtBot\(suffix)"
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: agentName, creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: joinedChannel, agentId: agentId)
    accounts.oauth.addChannelAgent(channelId: privateMemberChannel, agentId: agentId)
    accounts.oauth.addChannelAgent(channelId: archivedChannel, agentId: agentId)
    accounts.oauth.setChannelArchived(id: archivedChannel, archivedAt: Date())
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "channel-mgmt-machine-\(suffix)")
    accounts.assignAgentMachineForTesting(agentId: agentId, machineId: machineId)
    return ChannelManagementFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: "channel-mgmt-\(suffix)",
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        agentId: agentId,
        agentName: agentName,
        machineId: machineId,
        machineName: "channel-mgmt-machine-\(suffix)",
        machineKey: accounts.machineAPIKey(machineId: machineId) ?? "",
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "channels", "server"], name: "channel-mgmt-\(suffix)"),
        joinedChannel: joinedChannel,
        joinOnlyChannel: joinOnlyChannel,
        privateMemberChannel: privateMemberChannel,
        privateOutsiderChannel: privateOutsiderChannel,
        archivedChannel: archivedChannel
    )
}

private func channelMgmtRequest(
    _ client: any Client,
    f: ChannelManagementFixture,
    path: String,
    method: HTTPRequest.Method = .post,
    body: String? = nil,
    legacy: Bool = true
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(legacy ? f.machineKey : f.agentKey)"
    if body != nil { headers[.contentType] = "application/json" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

private func channelMgmtServerInfo(
    _ client: any Client,
    f: ChannelManagementFixture,
    legacy: Bool = true
) async throws -> [String: Any] {
    let path = legacy ? "/internal/agent/\(f.agentId)/server" : "/internal/agent-api/server"
    let response = try await channelMgmtRequest(client, f: f, path: path, method: .get, legacy: legacy)
    return response.body
}

@Test func legacyServerInfoProjectsMachineContextAndTypedChannels() async throws {
    let f = makeChannelManagementFixture("901")
    f.accounts.setAgentMachineForTesting(agentId: f.agentId, machineId: f.machineId)
    f.accounts.setMachineDescriptionForTesting(machineId: f.machineId, description: "Runs local UI previews.")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let body = try await channelMgmtServerInfo(client, f: f)
            let runtime = try #require(body["runtimeContext"] as? [String: Any])
            #expect(runtime["agentId"] as? String == f.agentId)
            #expect(runtime["serverId"] as? String == f.serverId)
            #expect(runtime["machineId"] as? String == f.machineId)
            #expect(runtime["machineName"] as? String == f.machineName)
            #expect(runtime["machineDescription"] as? String == "Runs local UI previews.")
            #expect(runtime["machineHostname"] == nil || runtime["machineHostname"] is NSNull)
            #expect(runtime["machineOs"] == nil || runtime["machineOs"] is NSNull)
            #expect(runtime["daemonVersion"] == nil || runtime["daemonVersion"] is NSNull)
            #expect(runtime["workspacePath"] == nil || runtime["workspacePath"] is NSNull)
            #expect(body["serverRole"] as? String == "member")

            let channels = try #require(body["channels"] as? [[String: Any]])
            let byName = Dictionary(uniqueKeysWithValues: channels.compactMap { row -> (String, [String: Any])? in
                guard let name = row["name"] as? String else { return nil }
                return (name, row)
            })
            #expect(byName["focus-room"]?["type"] as? String == "channel")
            #expect(byName["focus-room"]?["joined"] as? Bool == true)
            #expect(byName["join-public"]?["type"] as? String == "channel")
            #expect(byName["join-public"]?["joined"] as? Bool == false)
            #expect(byName["agent-private-member"]?["type"] as? String == "private")
            #expect(byName["agent-private-member"]?["joined"] as? Bool == true)
            #expect(byName["agent-private-outsider"] == nil)
            #expect(byName["archived-agent-list"] == nil)

            let agents = try #require(body["agents"] as? [[String: Any]])
            let own = try #require(agents.first { $0["id"] as? String == f.agentId })
            #expect(own["role"] as? String == "member")
            // The stored agent status, not a hard-coded "active".
            #expect(own["status"] as? String == "inactive")
            #expect(own["activity"] as? String == "offline")
            #expect(own["activityDetail"] as? String == "")
        }
    }
}

@Test func memberAgentCreatesChannelWithDescriptionAndJoinsIt() async throws {
    let f = makeChannelManagementFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let create = try await channelMgmtRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/channels",
                body: "{\"name\":\"#agent-admin-room\",\"description\":\"Created by an agent admin\",\"visibility\":\"public\"}"
            )
            #expect(create.status == .ok)
            #expect(create.body["name"] as? String == "agent-admin-room")
            #expect(create.body["type"] as? String == "channel")
            #expect(create.body["joined"] as? Bool == true)
            #expect(create.body["description"] as? String == "Created by an agent admin")
            #expect(create.body["createdByAgentId"] as? String == f.agentId)
            let createdId = try #require(create.body["id"] as? String)
            #expect(f.accounts.oauth.channelAgentIds(channelId: createdId).contains(f.agentId))

            let info = try await channelMgmtServerInfo(client, f: f)
            #expect((info["channels"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == createdId && $0["joined"] as? Bool == true })
        }
    }
}

@Test func channelCreateDenialNamesTheMissingCapability() async throws {
    let f = makeChannelManagementFixture("903")
    f.accounts.oauth.removeAgentMember(serverId: f.serverId, agentId: f.agentId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let create = try await channelMgmtRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/channels",
                body: "{\"name\":\"agent-without-server-membership\"}"
            )
            #expect(create.status == .forbidden)
            #expect(create.body["error"] as? String == "Agent requires createChannels capability to create channels")
            #expect(create.body["code"] as? String == "server_role_required")
            #expect((create.body["suggestedNextAction"] as? String)?.contains("member role on this server") == true)
            #expect(create.body["requiredCapabilities"] as? [String] == ["createChannels"])
            #expect(create.body["requiredRole"] as? String == "member")
        }
    }
}

@Test func agentAdminUpdatesChannelNameDescriptionAndVisibility() async throws {
    let f = makeChannelManagementFixture("904")
    f.accounts.oauth.setAgentRole(serverId: f.serverId, agentId: f.agentId, role: "admin")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let update = try await channelMgmtRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/channels/\(f.joinedChannel)",
                method: .patch,
                body: "{\"name\":\"#renamed-focus\",\"description\":\"Renamed by agent admin\",\"visibility\":\"private\"}"
            )
            #expect(update.status == .ok)
            #expect(update.body["id"] as? String == f.joinedChannel)
            #expect(update.body["name"] as? String == "renamed-focus")
            #expect(update.body["description"] as? String == "Renamed by agent admin")
            #expect(update.body["type"] as? String == "private")

            let info = try await channelMgmtServerInfo(client, f: f)
            let renamed = (info["channels"] as? [[String: Any]] ?? []).first { $0["id"] as? String == f.joinedChannel }
            #expect(renamed?["name"] as? String == "renamed-focus")
            #expect(renamed?["type"] as? String == "private")
        }
    }
}

@Test func memberAgentAddsAHumanByHandleWithABornReadNotice() async throws {
    let f = makeChannelManagementFixture("905")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let add = try await channelMgmtRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/channels/\(f.privateMemberChannel)/members",
                body: "{\"user\":\"@\(f.ownerName)\"}"
            )
            #expect(add.status == .ok)
            #expect(add.body["ok"] as? Bool == true)
            #expect(add.body["alreadyMember"] as? Bool == false)
            let member = try #require(add.body["member"] as? [String: Any])
            #expect(member["type"] as? String == "human")
            #expect(member["name"] as? String == f.ownerName)
            #expect(f.accounts.oauth.channelHumanIds(channelId: f.privateMemberChannel).contains(f.ownerId))

            // The acting agent reads the notice back as history, but its event
            // pull never returns it: the membership notice is born-read for it.
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(f.agentKey)"
            let history = try await client.get(
                URI(string: "/internal/agent-api/history?channel=\(f.privateMemberChannel.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")&limit=10&consume=false"),
                headers: agentHeaders
            )
            let historyBody = (try? JSONSerialization.jsonObject(with: Data((history.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let notices = (historyBody["messages"] as? [[String: Any]] ?? []).filter {
                ($0["content"] as? String) == "@\(f.ownerName) was added to this channel."
            }
            #expect(notices.count == 1)
            let events = try await client.get(URI(string: "/internal/agent-api/events"), headers: agentHeaders)
            let eventsBody = (try? JSONSerialization.jsonObject(with: Data((events.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(!((eventsBody["events"] as? [[String: Any]] ?? []).contains {
                ($0["content"] as? String) == "@\(f.ownerName) was added to this channel."
            }))
        }
    }
}

@Test func agentAdminRemovesAHumanMember() async throws {
    let f = makeChannelManagementFixture("906")
    f.accounts.oauth.setAgentRole(serverId: f.serverId, agentId: f.agentId, role: "admin")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let remove = try await channelMgmtRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/channels/\(f.joinedChannel)/members",
                method: .delete,
                body: "{\"user\":\"\(f.ownerName)\"}"
            )
            #expect(remove.status == .ok)
            #expect(remove.body["ok"] as? Bool == true)
            #expect(remove.body["wasMember"] as? Bool == true)
            #expect(!f.accounts.oauth.channelHumanIds(channelId: f.joinedChannel).contains(f.ownerId))
        }
    }
}

@Test func agentAdminRenamesTheServerProfile() async throws {
    let f = makeChannelManagementFixture("907")
    f.accounts.oauth.setAgentRole(serverId: f.serverId, agentId: f.agentId, role: "admin")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let update = try await channelMgmtRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/server",
                method: .patch,
                body: "{\"name\":\"Renamed Server\"}"
            )
            #expect(update.status == .ok)
            #expect(update.body["id"] as? String == f.serverId)
            #expect(update.body["name"] as? String == "Renamed Server")
            let info = try await channelMgmtServerInfo(client, f: f)
            #expect(info["name"] as? String == "Renamed Server")
        }
    }
}
