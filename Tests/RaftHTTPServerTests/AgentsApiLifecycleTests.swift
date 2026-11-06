import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AgentLifecycleFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let otherServerId: String
    let ownerId: String
    let memberId: String
    let guestId: String
    let ownerToken: String
    let memberToken: String
    let guestToken: String
}

private func makeAgentLifecycleFixture(_ suffix: String) -> AgentLifecycleFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001060\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001061\(suffix)"
    let guestId = "11111111-1111-4111-8111-000001062\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001060\(suffix)"
    let otherServerId = "33333333-3333-4333-8333-000001061\(suffix)"
    accounts.addAccount(id: ownerId, email: "lifecycle-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "lifecycle-member-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.addAccount(id: guestId, email: "lifecycle-guest-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "lifecycle-\(suffix)", name: "Lifecycle \(suffix)", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "lifecycle-other-\(suffix)", name: "Lifecycle Other \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    return AgentLifecycleFixture(
        accounts: accounts,
        serverId: serverId,
        otherServerId: otherServerId,
        ownerId: ownerId,
        memberId: memberId,
        guestId: guestId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        guestToken: accounts.mintAccessTokenForTesting(userId: guestId)
    )
}

private func lifecycleHeaders(_ token: String?, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    if let token {
        headers[.authorization] = "Bearer \(token)"
    }
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private final class LifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []
    func append(_ room: String, _ event: String, _ payload: String?) {
        lock.lock(); storage.append((room, event, payload)); lock.unlock()
    }
    var values: [(room: String, event: String, payload: String?)] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

private func lifecycleObject(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func lifecyclePost(
    _ client: any Client,
    _ path: String,
    token: String?,
    serverId: String,
    body: String? = nil
) async throws -> ClientResponse {
    try await client.send(.post, headers: lifecycleHeaders(token, serverId), to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func lifecycleDelete(
    _ client: any Client,
    _ path: String,
    token: String?,
    serverId: String,
    body: String? = nil
) async throws -> ClientResponse {
    try await client.send(.delete, headers: lifecycleHeaders(token, serverId), to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

@Test func agentDetailRejectsMalformedIdentifiersBeforeAnyLookup() async throws {
    let f = makeAgentLifecycleFixture("001")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.get(
                URI(string: "/api/agents/not-a-uuid"),
                headers: lifecycleHeaders(f.ownerToken, f.serverId)
            )
            #expect(response.status == .notFound)
            #expect(try lifecycleObject(response)["error"] as? String == "Agent not found")
        }
    }
}

@Test func agentDetailIsScopedToTheRequestServer() async throws {
    let f = makeAgentLifecycleFixture("002")
    let foreignAgent = f.accounts.oauth.createAgent(serverId: f.otherServerId, name: "foreign-agent-002", creatorUserId: f.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.get(
                URI(string: "/api/agents/\(foreignAgent)"),
                headers: lifecycleHeaders(f.ownerToken, f.serverId)
            )
            #expect(response.status == .notFound)
            #expect(try lifecycleObject(response)["error"] as? String == "Agent not found")

            let scoped = try await client.get(
                URI(string: "/api/agents/\(foreignAgent)"),
                headers: lifecycleHeaders(f.ownerToken, f.otherServerId)
            )
            #expect(scoped.status == .ok)
        }
    }
}

@Test func agentStartRequiresAnAssignedComputer() async throws {
    let f = makeAgentLifecycleFixture("003")
    let agent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "unassigned-agent-003", creatorUserId: f.ownerId, runtime: "codex")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await lifecyclePost(client, "/api/agents/\(agent)/start", token: f.ownerToken, serverId: f.serverId)
            #expect(response.status == .conflict)
            let body = try lifecycleObject(response)
            #expect(body["code"] as? String == "machine_unassigned")
            #expect(body["error"] as? String == "No machine assigned. Please assign a machine to this agent first.")
        }
    }
}

@Test func agentStartClassifiesAnOfflineComputerAndAcknowledgesAnOnlineOne() async throws {
    let f = makeAgentLifecycleFixture("004")
    let agent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "assigned-agent-004", creatorUserId: f.ownerId, runtime: "codex")
    let machine = f.accounts.registerMachine(serverId: f.serverId, userId: f.ownerId, name: "lifecycle-machine-004")
    f.accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    f.accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["codex"])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let offline = try await lifecyclePost(client, "/api/agents/\(agent)/start", token: f.ownerToken, serverId: f.serverId)
            #expect(offline.status == .conflict)
            let offlineBody = try lifecycleObject(offline)
            #expect(offlineBody["code"] as? String == "machine_offline")
            #expect(offlineBody["error"] as? String == "Machine is offline")

            f.accounts.setMachineOnline(machineId: machine, online: true)
            let online = try await lifecyclePost(client, "/api/agents/\(agent)/start", token: f.ownerToken, serverId: f.serverId)
            #expect(online.status == .ok)
            #expect(try lifecycleObject(online).count == 1)
            #expect(try lifecycleObject(online)["ok"] as? Bool == true)
        }
    }
}

@Test func agentStartServesMembersAndRefusesGuests() async throws {
    let f = makeAgentLifecycleFixture("005")
    let agent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "member-start-agent-005", creatorUserId: f.ownerId, runtime: "codex")
    let machine = f.accounts.registerMachine(serverId: f.serverId, userId: f.ownerId, name: "lifecycle-machine-005")
    f.accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    f.accounts.setMachineOnline(machineId: machine, online: true)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let member = try await lifecyclePost(client, "/api/agents/\(agent)/start", token: f.memberToken, serverId: f.serverId)
            #expect(member.status == .ok)

            let guest = try await lifecyclePost(client, "/api/agents/\(agent)/start", token: f.guestToken, serverId: f.serverId)
            #expect(guest.status == .forbidden)
            #expect(try lifecycleObject(guest)["error"] as? String == "The `controlAgentRuntime` capability or human creator authority is required to control agents")

            let anonymous = try await lifecyclePost(client, "/api/agents/\(agent)/start", token: nil, serverId: f.serverId)
            #expect(anonymous.status == .unauthorized)
        }
    }
}

@Test func agentStartRefusesAnAgentFromAnotherServer() async throws {
    let f = makeAgentLifecycleFixture("006")
    let foreignAgent = f.accounts.oauth.createAgent(serverId: f.otherServerId, name: "foreign-start-agent-006", creatorUserId: f.ownerId, runtime: "codex")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await lifecyclePost(client, "/api/agents/\(foreignAgent)/start", token: f.ownerToken, serverId: f.serverId)
            #expect(response.status == .notFound)
            #expect(try lifecycleObject(response)["error"] as? String == "Agent not found")
        }
    }
}

@Test func agentDeleteRefusesUnavailableAndInvalidWorkspaceChoices() async throws {
    let f = makeAgentLifecycleFixture("007")
    let noComputer = f.accounts.oauth.createAgent(serverId: f.serverId, name: "no-workspace-agent-007", creatorUserId: f.ownerId, runtime: "codex")
    let survivor = f.accounts.oauth.createAgent(serverId: f.serverId, name: "survivor-agent-007", creatorUserId: f.ownerId, runtime: "codex")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let unavailable = try await lifecycleDelete(
                client,
                "/api/agents/\(noComputer)",
                token: f.ownerToken,
                serverId: f.serverId,
                body: "{\"workspace\":\"delete\"}"
            )
            #expect(unavailable.status == .conflict)
            let unavailableBody = try lifecycleObject(unavailable)
            #expect(unavailableBody["code"] as? String == "archive_workspace_unavailable")
            #expect(unavailableBody["error"] as? String == "This agent has no workspace on a Computer.")

            let invalid = try await lifecycleDelete(
                client,
                "/api/agents/\(survivor)",
                token: f.ownerToken,
                serverId: f.serverId,
                body: "{\"workspace\":\"wipe\"}"
            )
            #expect(invalid.status == .badRequest)
            let invalidBody = try lifecycleObject(invalid)
            #expect(invalidBody["code"] as? String == "archive_workspace_choice_invalid")
            #expect(invalidBody["error"] as? String == "workspace must be keep or delete")

            let stillThere = try await client.get(
                URI(string: "/api/agents/\(survivor)"),
                headers: lifecycleHeaders(f.ownerToken, f.serverId)
            )
            #expect(stillThere.status == .ok)
        }
    }
}

@Test func agentDeleteNeedsDeleterAuthorityAndArchivesTheAgent() async throws {
    let f = makeAgentLifecycleFixture("008")
    let agent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "archive-agent-008", creatorUserId: f.ownerId, runtime: "codex")
    let byMember = f.accounts.oauth.createAgent(serverId: f.serverId, name: "member-target-agent-008", creatorUserId: f.ownerId, runtime: "codex")
    let byCreator = f.accounts.oauth.createAgent(serverId: f.serverId, name: "creator-target-agent-008", creatorUserId: f.memberId, runtime: "codex")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let denied = try await lifecycleDelete(client, "/api/agents/\(byMember)", token: f.memberToken, serverId: f.serverId)
            #expect(denied.status == .forbidden)
            #expect(try lifecycleObject(denied)["error"] as? String == "The `deleteAgents` capability or human creator authority is required to delete agents")

            let created = try await lifecycleDelete(client, "/api/agents/\(byCreator)", token: f.memberToken, serverId: f.serverId)
            #expect(created.status == .ok)
            #expect(try lifecycleObject(created)["ok"] as? Bool == true)

            let gone = try await client.get(
                URI(string: "/api/agents/\(byCreator)"),
                headers: lifecycleHeaders(f.ownerToken, f.serverId)
            )
            #expect(gone.status == .notFound)

            let archived = try await client.get(
                URI(string: "/api/agents/archived"),
                headers: lifecycleHeaders(f.ownerToken, f.serverId)
            )
            #expect(archived.status == .ok)
            let rows = (try lifecycleObject(archived)["agents"] as? [[String: Any]] ?? [])
            let row = try #require(rows.first { $0["agentId"] as? String == byCreator })
            #expect(row["workspaceState"] as? String == "deleted")
            #expect(row["machineName"] is NSNull)
            #expect(!rows.contains { $0["agentId"] as? String == agent })
        }
    }
}

@Test func agentDeleteAnnouncesTheRemovalToTheServerRoom() async throws {
    let f = makeAgentLifecycleFixture("009")
    let agent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "broadcast-agent-009", creatorUserId: f.ownerId, runtime: "codex")
    let events = LifecycleEvents()
    f.accounts.realtimeRelay.install { room, event, payload in events.append(room, event, payload) }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await lifecycleDelete(client, "/api/agents/\(agent)", token: f.ownerToken, serverId: f.serverId)
            #expect(response.status == .ok)
            let emitted = try #require(events.values.first { $0.event == "agent:deleted" })
            #expect(emitted.room == "server:\(f.serverId)")
            let payload = try JSONSerialization.jsonObject(with: Data((emitted.payload ?? "").utf8)) as? [String: Any]
            #expect(payload?["agentId"] as? String == agent)
        }
    }
}

@Test func agentResetUsesLegacyWorkspaceModeAndFallsBackToSession() async throws {
    let f = makeAgentLifecycleFixture("010")
    let agent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "reset-mode-agent-010", creatorUserId: f.ownerId, runtime: "codex")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let unknown = try await lifecyclePost(
                client,
                "/api/agents/\(agent)/reset",
                token: f.memberToken,
                serverId: f.serverId,
                body: "{\"mode\":\"bogus\"}"
            )
            #expect(unknown.status.code == 202)
            #expect(try lifecycleObject(unknown)["status"] as? String == "accepted")

            let legacyFull = try await lifecyclePost(
                client,
                "/api/agents/\(agent)/reset",
                token: f.memberToken,
                serverId: f.serverId,
                body: "{\"clearWorkspace\":true}"
            )
            #expect(legacyFull.status == .forbidden)
            #expect((try lifecycleObject(legacyFull)["error"] as? String ?? "").contains("resetAgentWorkspace"))

            let ownerLegacyFull = try await lifecyclePost(
                client,
                "/api/agents/\(agent)/reset",
                token: f.ownerToken,
                serverId: f.serverId,
                body: "{\"clearWorkspace\":true}"
            )
            #expect(ownerLegacyFull.status.code == 202)

            let unauthenticated = try await lifecyclePost(
                client,
                "/api/agents/\(agent)/reset",
                token: nil,
                serverId: f.serverId,
                body: "{\"mode\":\"session\"}"
            )
            #expect(unauthenticated.status == .unauthorized)
        }
    }
}
