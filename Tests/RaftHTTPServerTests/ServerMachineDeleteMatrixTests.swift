import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct MachineDeleteFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let sourceMachineId: String
    let targetMachineId: String
    let agentId: String
}

private func makeMachineDeleteFixture(suffix: String) -> MachineDeleteFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 700_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 700_000 + number)
    let ownerEmail = "machine-delete-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "machine-delete-\(suffix)", name: "Machine Delete", ownerId: ownerId)
    let source = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "source-\(suffix)")
    let target = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "target-\(suffix)")
    let agent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "delete-agent-\(suffix)",
        creatorUserId: ownerId,
        runtime: "codex"
    )
    accounts.setAgentMachineForTesting(agentId: agent, machineId: target)
    return MachineDeleteFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        sourceMachineId: source,
        targetMachineId: target,
        agentId: agent
    )
}

private func machineDeleteLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func machineDeleteHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func machineDeleteObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func activeRuntimeProfileBody() -> NSDictionary {
    [
        "error": "Cannot delete computer while runtime profiles still reference active agents. Remove or migrate related agents first.",
        "code": "MACHINE_HAS_ACTIVE_RUNTIME_PROFILE",
    ]
}

@Test func machineDeletePreservesTerminalMigrationHistory() async throws {
    let fixture = makeMachineDeleteFixture(suffix: "1002")
    fixture.accounts.addAgentMigrationForTesting(
        id: "33333333-4444-4555-8666-777777778002",
        agentId: fixture.agentId,
        sourceMachineId: fixture.sourceMachineId,
        targetMachineId: fixture.targetMachineId,
        state: "aborted"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await machineDeleteLogin(client, email: fixture.ownerEmail)
            let response = try await client.send(
                .delete,
                headers: machineDeleteHeaders(token, fixture.serverId),
                to: URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.sourceMachineId)")
            )
            #expect(response.status == .ok)
            #expect(fixture.accounts.agentMigrationCountForTesting() == 1)
            #expect(fixture.accounts.agentMigrationStateForTesting(id: "33333333-4444-4555-8666-777777778002") == "aborted")
        }
    }
}

@Test func machineDeleteReleasesOnlyTheHistoricalPendingBeforeReference() async throws {
    let fixture = makeMachineDeleteFixture(suffix: "1003")
    fixture.accounts.addAgentMigrationForTesting(
        id: "33333333-4444-4555-8666-777777778003",
        agentId: fixture.agentId,
        sourceMachineId: fixture.sourceMachineId,
        targetMachineId: fixture.targetMachineId,
        state: "completed"
    )
    fixture.accounts.setAgentRuntimeProfileForTesting(
        agentId: fixture.agentId,
        machineId: fixture.targetMachineId,
        baselineMachineId: fixture.targetMachineId,
        pendingBeforeMachineId: fixture.sourceMachineId,
        pendingAfterMachineId: fixture.targetMachineId,
        migrationStatus: "pending",
        pendingKind: "daemon_release_notice"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await machineDeleteLogin(client, email: fixture.ownerEmail)
            let response = try await client.send(
                .delete,
                headers: machineDeleteHeaders(token, fixture.serverId),
                to: URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.sourceMachineId)")
            )
            #expect(response.status == .ok)
            let profile = try #require(fixture.accounts.agentRuntimeProfileForTesting(agentId: fixture.agentId))
            #expect(profile.machineId == fixture.targetMachineId)
            #expect(profile.baselineMachineId == fixture.targetMachineId)
            #expect(profile.pendingBeforeMachineId == nil)
            #expect(profile.pendingAfterMachineId == fixture.targetMachineId)
            #expect(profile.pendingKind == "daemon_release_notice")
        }
    }
}

@Test func machineDeletePreservesAPendingReleaseNoticeOnAStaleSourceProfile() async throws {
    let fixture = makeMachineDeleteFixture(suffix: "1004")
    let noticeURL = "https://example.com/daemon-release-notes"
    fixture.accounts.addAgentMigrationForTesting(
        id: "33333333-4444-4555-8666-777777778004",
        agentId: fixture.agentId,
        sourceMachineId: fixture.sourceMachineId,
        targetMachineId: fixture.targetMachineId,
        state: "completed"
    )
    fixture.accounts.setAgentRuntimeProfileForTesting(
        agentId: fixture.agentId,
        machineId: fixture.sourceMachineId,
        pendingBeforeMachineId: fixture.sourceMachineId,
        pendingAfterMachineId: fixture.targetMachineId,
        migrationStatus: "pending",
        pendingKind: "daemon_release_notice",
        pendingReleaseNotesUrl: noticeURL
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await machineDeleteLogin(client, email: fixture.ownerEmail)
            let response = try await client.send(
                .delete,
                headers: machineDeleteHeaders(token, fixture.serverId),
                to: URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.sourceMachineId)")
            )
            #expect(response.status == .conflict)
            let profile = try #require(fixture.accounts.agentRuntimeProfileForTesting(agentId: fixture.agentId))
            #expect(profile.machineId == fixture.sourceMachineId)
            #expect(profile.pendingKind == "daemon_release_notice")
            #expect(profile.pendingReleaseNotesUrl == noticeURL)
        }
    }
}

@Test func machineDeleteKeepsCrossMachineProfilesFailClosedWithoutCompletedProof() async throws {
    let fixture = makeMachineDeleteFixture(suffix: "1005")
    fixture.accounts.addAgentMigrationForTesting(
        id: "33333333-4444-4555-8666-777777778005",
        agentId: fixture.agentId,
        sourceMachineId: fixture.sourceMachineId,
        targetMachineId: fixture.targetMachineId,
        state: "aborted"
    )
    fixture.accounts.setAgentRuntimeProfileForTesting(
        agentId: fixture.agentId,
        machineId: fixture.sourceMachineId
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await machineDeleteLogin(client, email: fixture.ownerEmail)
            let response = try await client.send(
                .delete,
                headers: machineDeleteHeaders(token, fixture.serverId),
                to: URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.sourceMachineId)")
            )
            #expect(response.status == .conflict)
            #expect(try machineDeleteObject(response) as NSDictionary == activeRuntimeProfileBody())
            #expect(fixture.accounts.agentRuntimeProfileForTesting(agentId: fixture.agentId)?.machineId == fixture.sourceMachineId)
        }
    }
}

@Test func machineDeleteKeepsStaleProfilesFailClosedWhenTheCompletedTargetNoLongerMatches() async throws {
    let fixture = makeMachineDeleteFixture(suffix: "1006")
    let laterMachine = fixture.accounts.registerMachine(serverId: fixture.serverId, userId: fixture.ownerId, name: "later-1006")
    fixture.accounts.addAgentMigrationForTesting(
        id: "33333333-4444-4555-8666-777777778006",
        agentId: fixture.agentId,
        sourceMachineId: fixture.sourceMachineId,
        targetMachineId: fixture.targetMachineId,
        state: "completed"
    )
    fixture.accounts.setAgentMachineForTesting(agentId: fixture.agentId, machineId: laterMachine)
    fixture.accounts.setAgentRuntimeProfileForTesting(
        agentId: fixture.agentId,
        machineId: fixture.sourceMachineId
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await machineDeleteLogin(client, email: fixture.ownerEmail)
            let response = try await client.send(
                .delete,
                headers: machineDeleteHeaders(token, fixture.serverId),
                to: URI(string: "/api/servers/\(fixture.serverId)/machines/\(fixture.sourceMachineId)")
            )
            #expect(response.status == .conflict)
            #expect(try machineDeleteObject(response) as NSDictionary == activeRuntimeProfileBody())
            #expect(fixture.accounts.agentRuntimeProfileForTesting(agentId: fixture.agentId)?.machineId == fixture.sourceMachineId)
        }
    }
}
