import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ArchiveFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let otherServerId: String
    let ownerId: String
    let memberId: String
    let guestId: String
    let ownerToken: String
    let memberToken: String
    let guestToken: String
    let machineId: String
    let agentId: String
}

private func makeArchiveFixture(_ suffix: String) -> ArchiveFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001070\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001071\(suffix)"
    let guestId = "11111111-1111-4111-8111-000001072\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001070\(suffix)"
    let otherServerId = "33333333-3333-4333-8333-000001071\(suffix)"
    accounts.addAccount(id: ownerId, email: "archive-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "archive-member-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.addAccount(id: guestId, email: "archive-guest-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archive-\(suffix)", name: "Archive \(suffix)", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "archive-other-\(suffix)", name: "Archive Other \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "archive-machine-\(suffix)")
    let agentId = accounts.oauth.createAgent(
        serverId: serverId,
        name: "archive-agent-\(suffix)",
        creatorUserId: ownerId,
        runtime: "codex"
    )
    accounts.setAgentMachineForTesting(agentId: agentId, machineId: machineId)
    return ArchiveFixture(
        accounts: accounts,
        serverId: serverId,
        otherServerId: otherServerId,
        ownerId: ownerId,
        memberId: memberId,
        guestId: guestId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        guestToken: accounts.mintAccessTokenForTesting(userId: guestId),
        machineId: machineId,
        agentId: agentId
    )
}

private func archiveHeaders(_ token: String?, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    if let token {
        headers[.authorization] = "Bearer \(token)"
    }
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func archiveObject(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func archiveRaw(_ response: ClientResponse) throws -> Any {
    try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))
}

private func archiveAgent(
    _ client: any Client,
    _ fixture: ArchiveFixture,
    agentId: String? = nil,
    workspace: String? = nil
) async throws -> ClientResponse {
    let id = agentId ?? fixture.agentId
    return try await client.send(.delete, headers: archiveHeaders(fixture.ownerToken, fixture.serverId), to: URI(string: "/api/agents/\(id)")) { request in
        if let workspace {
            request.body = .init(string: "{\"workspace\":\"\(workspace)\"}")
        }
    }
}

private func archiveRecord(_ client: any Client, _ fixture: ArchiveFixture, agentId: String? = nil) async throws -> [String: Any] {
    let id = agentId ?? fixture.agentId
    let response = try await client.get(
        URI(string: "/api/agents/\(id)/archive"),
        headers: archiveHeaders(fixture.ownerToken, fixture.serverId)
    )
    #expect(response.status == .ok)
    return (try archiveObject(response)["archive"] as? [String: Any]) ?? [:]
}

@Test func archivingKeepsTheWorkspaceAndCancelsScheduledReminders() async throws {
    let f = makeArchiveFixture("001")
    f.accounts.addReminder(serverId: f.serverId, ownerAgentId: f.agentId, title: "later", fireAt: Date().addingTimeInterval(3_600))
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let scheduled = try await client.get(URI(string: "/api/reminders"), headers: archiveHeaders(f.ownerToken, f.serverId))
            #expect(((try archiveObject(scheduled)["reminders"]) as? [[String: Any]])?.count == 1)

            let archived = try await archiveAgent(client, f)
            #expect(archived.status == .ok)
            #expect(try archiveObject(archived)["ok"] as? Bool == true)

            let record = try await archiveRecord(client, f)
            #expect(record["agentId"] as? String == f.agentId)
            #expect(record["machineId"] as? String == f.machineId)
            #expect(record["machineName"] as? String == "archive-machine-001")
            #expect(record["workspaceState"] as? String == "on_computer")
            #expect(record["pendingOp"] is NSNull)
            #expect(record["waitingForComputer"] as? Bool == false)
            #expect(record["lastErrorCode"] is NSNull)
            #expect(record["lastErrorAt"] is NSNull)
            #expect(record["archivedByUserId"] as? String == f.ownerId)
            #expect(record["archivedAt"] as? String != nil)

            let reminders = try await client.get(URI(string: "/api/reminders"), headers: archiveHeaders(f.ownerToken, f.serverId))
            #expect(((try archiveObject(reminders)["reminders"]) as? [[String: Any]])?.isEmpty == true, "archiving cancels the agent's reminders")

            let gone = try await client.get(URI(string: "/api/agents/\(f.agentId)"), headers: archiveHeaders(f.ownerToken, f.serverId))
            #expect(gone.status == .notFound)
        }
    }
}

@Test func onlyKeepAndDeleteAreWorkspaceChoicesAndTheyLeaveTheAgentAlone() async throws {
    let f = makeArchiveFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for workspace in ["backup", "shred"] {
                let refused = try await archiveAgent(client, f, workspace: workspace)
                #expect(refused.status == .badRequest, "\(workspace)")
                #expect(try archiveObject(refused)["code"] as? String == "archive_workspace_choice_invalid")
            }
            let alive = try await client.get(URI(string: "/api/agents/\(f.agentId)"), headers: archiveHeaders(f.ownerToken, f.serverId))
            #expect(alive.status == .ok)
            let missingArchive = try await client.get(
                URI(string: "/api/agents/\(f.agentId)/archive"),
                headers: archiveHeaders(f.ownerToken, f.serverId)
            )
            #expect(missingArchive.status == .notFound)
            #expect(try archiveObject(missingArchive)["code"] as? String == "agent_not_archived")
        }
    }
}

@Test func archivingWithDeleteQueuesTheWorkspaceOpForTheComputer() async throws {
    let f = makeArchiveFixture("003")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let archived = try await archiveAgent(client, f, workspace: "delete")
            #expect(archived.status == .ok)
            let record = try await archiveRecord(client, f)
            #expect(record["workspaceState"] as? String == "on_computer")
            #expect(record["pendingOp"] as? String == "delete")
            #expect(record["waitingForComputer"] as? Bool == true)
            #expect(record["machineId"] as? String == f.machineId)
        }
    }
}

@Test func archivedWorkspaceDeletionNeedsOneDeleteAtATimeAndAnAvailableWorkspace() async throws {
    let f = makeArchiveFixture("004")
    let noComputer = f.accounts.oauth.createAgent(
        serverId: f.serverId,
        name: "no-computer-agent-004",
        creatorUserId: f.ownerId,
        runtime: "codex"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            #expect(try await archiveAgent(client, f).status == .ok)
            #expect(try await archiveAgent(client, f, agentId: noComputer).status == .ok)

            func request(_ agentId: String, action: String) async throws -> ClientResponse {
                try await client.send(.post, headers: archiveHeaders(f.ownerToken, f.serverId), to: URI(string: "/api/agents/\(agentId)/archive/workspace")) { request in
                    request.body = .init(string: "{\"action\":\"\(action)\"}")
                }
            }

            let invalid = try await request(f.agentId, action: "backup")
            #expect(invalid.status == .badRequest)
            let invalidBody = try archiveObject(invalid)
            #expect(invalidBody["error"] as? String == "action must be delete")
            #expect(invalidBody["code"] as? String == "archive_workspace_action_invalid")

            let requested = try await request(f.agentId, action: "delete")
            #expect(requested.status == .ok)
            let requestedArchive = (try archiveObject(requested)["archive"] as? [String: Any]) ?? [:]
            #expect(requestedArchive["workspaceState"] as? String == "on_computer")
            #expect(requestedArchive["pendingOp"] as? String == "delete")
            #expect(requestedArchive["waitingForComputer"] as? Bool == true)

            let second = try await request(f.agentId, action: "delete")
            #expect(second.status == .conflict)
            let secondBody = try archiveObject(second)
            #expect(secondBody["code"] as? String == "archive_op_pending")
            #expect(secondBody["error"] as? String == "Another workspace operation is still running.")

            let unavailable = try await request(noComputer, action: "delete")
            #expect(unavailable.status == .conflict)
            let unavailableBody = try archiveObject(unavailable)
            #expect(unavailableBody["code"] as? String == "archive_workspace_unavailable")
            #expect(unavailableBody["error"] as? String == "The workspace is not on a Computer.")

            let liveAgent = f.accounts.oauth.createAgent(
                serverId: f.serverId,
                name: "live-agent-004",
                creatorUserId: f.ownerId,
                runtime: "codex"
            )
            let notArchived = try await request(liveAgent, action: "delete")
            #expect(notArchived.status == .notFound)
            let notArchivedBody = try archiveObject(notArchived)
            #expect(notArchivedBody["code"] as? String == "agent_not_archived")
            #expect(notArchivedBody["error"] as? String == "Archived agent not found")
        }
    }
}

@Test func archiveRoutesRefuseMembersGuestsAndForeignServers() async throws {
    let f = makeArchiveFixture("005")
    let creatorAgent = f.accounts.oauth.createAgent(
        serverId: f.serverId,
        name: "member-created-agent-005",
        creatorUserId: f.memberId,
        runtime: "codex"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let otherFixtureAgent = f.agentId
            #expect(try await archiveAgent(client, f).status == .ok)
            #expect(try await archiveAgent(client, f, agentId: creatorAgent).status == .ok)

            let url = "/api/agents/\(otherFixtureAgent)"
            let routes: [(HTTPRequest.Method, String, String?)] = [
                (.get, "\(url)/archive", nil),
                (.get, "\(url)/workspace-files", nil),
                (.get, "\(url)/workspace-files/read?path=MEMORY.md", nil),
                (.post, "\(url)/archive/workspace", "{\"action\":\"delete\"}"),
            ]
            for (method, path, body) in routes {
                let member = try await client.send(method, headers: archiveHeaders(f.memberToken, f.serverId), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                #expect(member.status == .forbidden, "member \(method) \(path)")

                let guest = try await client.send(method, headers: archiveHeaders(f.guestToken, f.serverId), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                #expect([403, 404].contains(guest.status.code), "guest \(method) \(path) -> \(guest.status.code)")

                let foreign = try await client.send(method, headers: archiveHeaders(f.ownerToken, f.otherServerId), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                #expect(foreign.status == .notFound, "foreign \(method) \(path)")
            }

            let record = try await archiveRecord(client, f)
            #expect(record["pendingOp"] is NSNull, "refused requests never queue an op")

            let creatorView = try await client.get(
                URI(string: "/api/agents/\(creatorAgent)/archive"),
                headers: archiveHeaders(f.memberToken, f.serverId)
            )
            #expect(creatorView.status == .ok)

            let creatorFiles = try await client.get(
                URI(string: "/api/agents/\(creatorAgent)/workspace-files"),
                headers: archiveHeaders(f.memberToken, f.serverId)
            )
            #expect([409, 503].contains(creatorFiles.status.code))
        }
    }
}

@Test func anAgentBeingMigratedCannotBeArchived() async throws {
    let f = makeArchiveFixture("006")
    let otherMachine = f.accounts.registerMachine(serverId: f.serverId, userId: f.ownerId, name: "archive-target-machine-006")
    f.accounts.enableAgentMigrationForTesting(serverId: f.serverId)
    f.accounts.addAgentMigrationForTesting(
        id: "mig_archive_006",
        agentId: f.agentId,
        sourceMachineId: f.machineId,
        targetMachineId: otherMachine,
        state: "preparing"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let refused = try await archiveAgent(client, f, workspace: "delete")
            #expect(refused.status == .conflict)
            #expect(try archiveObject(refused)["code"] as? String == "archive_migration_active")
            let alive = try await client.get(URI(string: "/api/agents/\(f.agentId)"), headers: archiveHeaders(f.ownerToken, f.serverId))
            #expect(alive.status == .ok)
            let missing = try await client.get(
                URI(string: "/api/agents/\(f.agentId)/archive"),
                headers: archiveHeaders(f.ownerToken, f.serverId)
            )
            #expect(missing.status == .notFound)
        }
    }
}

@Test func archivedAgentsAreListedForMembersButNotGuests() async throws {
    let f = makeArchiveFixture("007")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            #expect(try await archiveAgent(client, f).status == .ok)
            let member = try await client.get(URI(string: "/api/agents/archived"), headers: archiveHeaders(f.memberToken, f.serverId))
            #expect(member.status == .ok)
            let rows = (try archiveObject(member)["agents"] as? [[String: Any]]) ?? []
            #expect(rows.count == 1)
            #expect(rows.first?["agentId"] as? String == f.agentId)
            #expect(rows.first?["machineName"] as? String == "archive-machine-007")
            #expect(rows.first?["workspaceState"] as? String == "on_computer")

            let guest = try await client.get(URI(string: "/api/agents/archived"), headers: archiveHeaders(f.guestToken, f.serverId))
            #expect(guest.status == .forbidden)
        }
    }
}
