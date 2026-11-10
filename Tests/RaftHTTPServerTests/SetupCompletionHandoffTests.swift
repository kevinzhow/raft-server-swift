import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

// Published-path regressions for the setup completion provenance, the personal
// post-setup projection and the primary-owner handoff. The fixtures seed real
// Store facts (accounts, server membership, a retained Computer and its
// connection) and then use only the HTTP routes. No query spies and no fabricated
// completion status: a completion is driven through POST setup-transition.

private func body(_ response: ClientResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
}

private func postSetup(_ response: [String: Any]) -> NSDictionary? {
    response["postSetup"] as? NSDictionary
}

private func snapshotBusiness(_ accounts: EmailLoginDirectory) throws -> [String: Any] {
    let data = try accounts.serversAndChannelsStore.exportPersistenceData()
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return root?["business"] as? [String: Any] ?? [:]
}

private func setupCompletionGroup(_ accounts: EmailLoginDirectory) throws -> [String: Any] {
    try snapshotBusiness(accounts)["setupCompletion"] as? [String: Any] ?? [:]
}

/// Makes the official onboarding agent (Cindy) actually usable for one server:
/// a retained Computer, an online daemon connection with the installed runtime,
/// Cindy's exact identity, the admin server role and the server's onboarding
/// pointer. Nothing here is a projection-only flag; the same Store facts the
/// production read path consumes are written.
private func seedUsableOnboardingAgent(
    accounts: EmailLoginDirectory,
    serverId: String,
    ownerId: String,
    runtime: String = "codex"
) -> String {
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "setup-machine")
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, attachedByUserId: ownerId)
    accounts.machinesAndComputersStore.storage.withLock { state in
        guard let index = state.machines.firstIndex(where: { $0.id == machine }) else { return }
        state.machines[index].runtimes = [runtime]
        state.machines[index].lastSeenAt = Date()
    }
    let cindy = accounts.oauth.createAgent(
        serverId: serverId, name: "Cindy", displayName: "Cindy", avatarUrl: "pixel:mug",
        description: "Onboarding Assistant", creatorUserId: ownerId, runtime: runtime
    )
    accounts.oauth.setAgentRole(serverId: serverId, agentId: cindy, role: "admin")
    accounts.addServerAgent(serverId: serverId, id: cindy, name: "Cindy", avatarUrl: "pixel:mug")
    accounts.setAgentMachineForTesting(agentId: cindy, machineId: machine)
    accounts.agentsRuntimeStore.withState { state in
        state.execution.connections[machine] = AgentExecutionConnection(
            serverId: serverId, connectionEpochId: "setup-completion-epoch", online: true, ready: true,
            daemonInstanceId: "setup-completion-daemon", runtimes: [runtime], capabilities: nil
        )
    }
    accounts.serversAndChannelsStore.bindOnboardingAgent(serverId: serverId, agentId: cindy)
    return cindy
}

@Test func newCompletionRecordsNormalProvenanceAndOwesOwnerSurveyAndHandoffSeparately() async throws {
    let accounts = EmailLoginDirectory()
    let owner = "11111111-1111-4111-8111-111111111720"
    let serverA = "33333333-3333-4333-8333-333333333725"
    let serverB = "33333333-3333-4333-8333-333333333726"
    accounts.addAccount(id: owner, email: "setup-completion-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: owner)
    accounts.oauth.addOwnedServer(id: serverA, slug: "setup-completion-a", name: "Setup Completion A", ownerId: owner)
    accounts.oauth.addOwnedServer(id: serverB, slug: "setup-completion-b", name: "Setup Completion B", ownerId: owner)
    _ = seedUsableOnboardingAgent(accounts: accounts, serverId: serverA, ownerId: owner)
    _ = seedUsableOnboardingAgent(accounts: accounts, serverId: serverB, ownerId: owner)
    let token = accounts.mintAccessTokenForTesting(userId: owner)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func headers() -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                return fields
            }
            func projection(_ serverId: String) async throws -> ClientResponse {
                var fields = headers()
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.get, headers: fields, to: "/api/servers/\(serverId)/setup-projection")
            }
            func transition(_ serverId: String, _ action: String) async throws -> ClientResponse {
                var fields = headers()
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: fields, to: "/api/servers/\(serverId)/setup-transition") { request in
                    request.body = .init(string: "{\"action\":\"\(action)\"}")
                }
            }
            func handoff(_ serverId: String) async throws -> ClientResponse {
                var fields = headers()
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: fields, to: "/api/servers/\(serverId)/setup-handoff")
            }
            let owed: NSDictionary = ["surveyPending": true, "handoffPending": true]
            let none: NSDictionary = ["surveyPending": false, "handoffPending": false]
            let surveyOnly: NSDictionary = ["surveyPending": true, "handoffPending": false]

            // Before any real completion nothing personal is owed, even though
            // the official agent is already usable.
            let before = try await projection(serverA)
            #expect(before.status == .ok)
            let beforeBody = try body(before)
            #expect(beforeBody["surface"] as? String == "create_agent")
            #expect(beforeBody["gateReason"] as? String == "completion_pending")
            #expect(postSetup(beforeBody) == none)
            #expect(try setupCompletionGroup(accounts)["completionReasons"] as? [String: String] == [:])

            // The actual completion writes phase + `normal` in one mutation.
            let completed = try await transition(serverA, "complete")
            #expect(completed.status == .ok)
            let completedBody = try body(completed)
            #expect(completedBody["surface"] as? String == "complete")
            #expect(completedBody["phase"] as? String == "complete")
            #expect(completedBody["gateReason"] as? String == "setup_complete")
            #expect(completedBody["blocksChat"] as? Bool == false)
            #expect(postSetup(completedBody) == owed)
            let reasons = try setupCompletionGroup(accounts)["completionReasons"] as? [String: String]
            #expect(reasons?["\(serverA)\n\(owner)"] == "normal")
            #expect(reasons?["\(serverB)\n\(owner)"] == nil)

            // A terminal retry changes neither the reason nor the projection.
            let retained = try accounts.serversAndChannelsStore.exportPersistenceData()
            for _ in 0..<2 {
                let retry = try await transition(serverA, "complete")
                #expect(retry.status == .ok)
                #expect(postSetup(try body(retry)) == owed)
            }
            #expect(try accounts.serversAndChannelsStore.exportPersistenceData() == retained,
                "a terminal retry must not rewrite the completion reason")

            // Each server's handoff is independent: B still owes both screens.
            #expect(postSetup(try body(try await projection(serverB))) == none)
            #expect(try await transition(serverB, "complete").status == .ok)
            #expect(postSetup(try body(try await projection(serverB))) == owed)

            // "Let's Go" on A acknowledges only A's handoff.
            let ackA = try await handoff(serverA)
            #expect(ackA.status == .ok)
            #expect(postSetup(try body(ackA)) == surveyOnly)
            #expect(postSetup(try body(try await projection(serverA))) == surveyOnly)
            #expect(postSetup(try body(try await projection(serverB))) == owed)
            let ackB = try await handoff(serverB)
            #expect(ackB.status == .ok)
            #expect(postSetup(try body(ackB)) == surveyOnly)

            let receipts = try setupCompletionGroup(accounts)["handoffReceipts"] as? [String: Any]
            #expect(receipts?.count == 2)
            for serverId in [serverA, serverB] {
                let receipt = try #require(receipts?["\(serverId)\n\(owner)"] as? [String: Any])
                #expect(receipt["serverId"] as? String == serverId)
                #expect(receipt["originalOwnerId"] as? String == owner)
                #expect((receipt["acknowledgedAt"] as? String)?.count == 16)
            }
            // The legacy subjectless marker is never produced by the new command.
            #expect(try snapshotBusiness(accounts)["setupHandoffs"] as? [String] == [])
        }
    }
}

@Test func setupHandoffIsBoundToPrimaryOwnerAndRetainsTheFirstAcknowledgment() async throws {
    let accounts = EmailLoginDirectory()
    let owner = "11111111-1111-4111-8111-111111111721"
    let coowner = "11111111-1111-4111-8111-111111111722"
    let admin = "11111111-1111-4111-8111-111111111723"
    let member = "11111111-1111-4111-8111-111111111724"
    let guest = "11111111-1111-4111-8111-111111111725"
    let serverId = "33333333-3333-4333-8333-333333333727"
    for (id, email) in [
        (owner, "handoff-owner@slock.test"), (coowner, "handoff-coowner@slock.test"),
        (admin, "handoff-admin@slock.test"), (member, "handoff-member@slock.test"),
        (guest, "handoff-guest@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "handoff", name: "Handoff", ownerId: owner)
    accounts.oauth.addMember(serverId: serverId, userId: coowner, role: "owner")
    accounts.oauth.addMember(serverId: serverId, userId: admin, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: member, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guest, role: "guest")
    // A retained real-flow completion; the handoff command itself is under test.
    accounts.serversAndChannelsStore.completeSetup(serverId: serverId, userId: owner)
    let tokens = [
        owner: accounts.mintAccessTokenForTesting(userId: owner),
        coowner: accounts.mintAccessTokenForTesting(userId: coowner),
        admin: accounts.mintAccessTokenForTesting(userId: admin),
        member: accounts.mintAccessTokenForTesting(userId: member),
        guest: accounts.mintAccessTokenForTesting(userId: guest),
    ]

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func handoff(_ actor: String, bearer: Bool = true) async throws -> ClientResponse {
                var fields = HTTPFields()
                if bearer, let token = tokens[actor] { fields[.authorization] = "Bearer \(token)" }
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: fields, to: "/api/servers/\(serverId)/setup-handoff")
            }
            let surveyOnly: NSDictionary = ["surveyPending": true, "handoffPending": false]
            let before = try accounts.serversAndChannelsStore.exportPersistenceData()
            // role `owner` is not enough: a co-owner cannot accept the primary
            // owner's handoff. Admin/member/guest are refused the same way, and a
            // rejection writes nothing.
            for actor in [coowner, admin, member, guest] {
                let denied = try await handoff(actor)
                #expect(denied.status == .forbidden)
                #expect(try body(denied)["error"] as? String == "INSUFFICIENT_PERMISSION")
            }
            #expect(try await handoff(owner, bearer: false).status == .unauthorized)
            #expect(try accounts.serversAndChannelsStore.exportPersistenceData() == before,
                "a refused handoff must not write a receipt")

            let acknowledged = try await handoff(owner)
            #expect(acknowledged.status == .ok)
            let acknowledgedBody = try body(acknowledged)
            #expect(acknowledgedBody["surface"] as? String == "complete")
            #expect(postSetup(acknowledgedBody) == ["surveyPending": true, "handoffPending": false])
            let retained = try accounts.serversAndChannelsStore.exportPersistenceData()
            let receipts = try setupCompletionGroup(accounts)["handoffReceipts"] as? [String: Any]
            let receipt = try #require(receipts?["\(serverId)\n\(owner)"] as? [String: Any])
            #expect(receipt["originalOwnerId"] as? String == owner)

            // Pressing again (or retrying a dropped response) keeps the first
            // acknowledgment: the retained bytes do not move.
            for _ in 0..<2 {
                let retry = try await handoff(owner)
                #expect(retry.status == .ok)
                #expect(postSetup(try body(retry)) == surveyOnly)
            }
            #expect(try accounts.serversAndChannelsStore.exportPersistenceData() == retained,
                "a retried handoff must retain the first acknowledgment time")
        }
    }
}

@Test func legacyInheritedAndOfflineCompletionsNeverCreateOrRewritePersonalTasks() async throws {
    let accounts = EmailLoginDirectory()
    let owner = "11111111-1111-4111-8111-111111111726"
    let coowner = "11111111-1111-4111-8111-111111111727"
    let legacyServer = "33333333-3333-4333-8333-333333333728"
    let inheritedServer = "33333333-3333-4333-8333-333333333729"
    let terminalServer = "33333333-3333-4333-8333-333333333730"
    for (id, email) in [(owner, "legacy-owner@slock.test"), (coowner, "legacy-coowner@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: legacyServer, slug: "legacy-setup", name: "Legacy Setup", ownerId: owner)
    accounts.oauth.addOwnedServer(id: inheritedServer, slug: "inherited-setup", name: "Inherited Setup", ownerId: owner)
    accounts.oauth.addMember(serverId: inheritedServer, userId: coowner, role: "owner")
    accounts.oauth.addOwnedServer(id: terminalServer, slug: "terminal-setup", name: "Terminal Setup", ownerId: owner)
    // An old build's completion: a `complete` phase with no recorded reason.
    _ = accounts.serversAndChannelsStore.setSetupPhase(serverId: legacyServer, userId: owner, phase: "complete")
    // The legacy subjectless marker must not become the new receipt.
    _ = accounts.serversAndChannelsStore.mutex.withLock { state in
        state.setupHandoffs.insert(legacyServer)
    }
    // Cross-owner inherited completion: the primary owner completed, the
    // co-owner's own row never did.
    accounts.serversAndChannelsStore.completeSetup(serverId: inheritedServer, userId: owner)
    let machine = seedUsableOnboardingAgent(accounts: accounts, serverId: terminalServer, ownerId: owner)
    _ = accounts.serversAndChannelsStore.completeSetup(serverId: terminalServer, userId: owner)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: owner)
    let coownerToken = accounts.mintAccessTokenForTesting(userId: coowner)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func request(_ method: HTTPRequest.Method, _ token: String, _ serverId: String,
                         action: String? = nil) async throws -> ClientResponse {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                let path = action == nil ? "/api/servers/\(serverId)/setup-projection" : "/api/servers/\(serverId)/setup-transition"
                return try await client.send(method, headers: fields, to: URI(string: path)) { message in
                    if let action { message.body = .init(string: "{\"action\":\"\(action)\"}") }
                }
            }
            let none: NSDictionary = ["surveyPending": false, "handoffPending": false]
            let owed: NSDictionary = ["surveyPending": true, "handoffPending": true]

            // Unknown legacy reason: no survey, no handoff, and no backfill on a
            // terminal retry.
            let legacy = try await request(.get, ownerToken, legacyServer)
            #expect(try body(legacy)["surface"] as? String == "complete")
            #expect(postSetup(try body(legacy)) == none)
            let legacySnapshot = try accounts.serversAndChannelsStore.exportPersistenceData()
            let legacyRetry = try await request(.post, ownerToken, legacyServer, action: "complete")
            #expect(legacyRetry.status == .ok)
            #expect(postSetup(try body(legacyRetry)) == none)
            #expect(try accounts.serversAndChannelsStore.exportPersistenceData() == legacySnapshot,
                "an old complete without a reason stays unknown; never backfill normal")
            let completionReasons = try setupCompletionGroup(accounts)["completionReasons"] as? [String: String]
            #expect(completionReasons?["\(legacyServer)\n\(owner)"] == nil)
            // The retained legacy marker is not promoted into a receipt.
            let receipts = try setupCompletionGroup(accounts)["handoffReceipts"] as? [String: Any]
            #expect(receipts?.isEmpty ?? true)

            // Inherited completion is grandfathered for the co-owner: complete
            // surface, no personal survey or handoff.
            let inheritedOwner = try await request(.get, ownerToken, inheritedServer)
            #expect(postSetup(try body(inheritedOwner)) == owed)
            let inheritedCoowner = try await request(.get, coownerToken, inheritedServer)
            #expect(try body(inheritedCoowner)["surface"] as? String == "complete")
            #expect(postSetup(try body(inheritedCoowner)) == none)

            // A Computer going offline does not revoke a real completion.
            let terminal = try await request(.get, ownerToken, terminalServer)
            #expect(postSetup(try body(terminal)) == owed)
            accounts.agentsRuntimeStore.withState { state in
                state.execution.connections[machine]?.online = false
            }
            let offline = try await request(.get, ownerToken, terminalServer)
            #expect(try body(offline)["surface"] as? String == "complete")
            #expect(postSetup(try body(offline)) == owed)
            let retained = try accounts.serversAndChannelsStore.exportPersistenceData()
            #expect(try await request(.post, ownerToken, terminalServer, action: "complete").status == .ok)
            #expect(try accounts.serversAndChannelsStore.exportPersistenceData() == retained,
                "a terminal retry after the Computer went offline must not reopen setup")
        }
    }
}

@Test func restoredSnapshotGivesIdenticalPublicSetupProjection() async throws {
    let owner = "11111111-1111-4111-8111-111111111728"
    let serverId = "33333333-3333-4333-8333-333333333731"
    let source = EmailLoginDirectory()
    source.addAccount(id: owner, email: "setup-snapshot-owner@slock.test", password: "password123")
    source.markEmailVerified(userId: owner)
    source.oauth.addOwnedServer(id: serverId, slug: "setup-snapshot", name: "Setup Snapshot", ownerId: owner)
    _ = source.serversAndChannelsStore.completeSetup(serverId: serverId, userId: owner)
    _ = source.serversAndChannelsStore.acknowledgeSetupHandoff(
        serverId: serverId, originalOwnerId: owner,
        at: Date(timeIntervalSinceReferenceDate: 812_345_678.25)
    )
    let persistence = try source.serversAndChannelsStore.exportPersistenceData()
    let sourceToken = source.mintAccessTokenForTesting(userId: owner)

    func projectionBody(_ accounts: EmailLoginDirectory, _ token: String) async throws -> Data {
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts
            ))
            return try await app.testing { client in
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                let response = try await client.send(.get, headers: fields, to: "/api/servers/\(serverId)/setup-projection")
                #expect(response.status == .ok)
                return Data((response.body.string ?? "").utf8)
            }
        }
    }

    // The source app reports the retained completion and the retained receipt.
    let expected = try await projectionBody(source, sourceToken)
    let expectedBody = try JSONSerialization.jsonObject(with: expected) as? [String: Any]
    #expect(expectedBody?["surface"] as? String == "complete")
    #expect(expectedBody?["phase"] as? String == "complete")
    let surveyOnly: NSDictionary = ["surveyPending": true, "handoffPending": false]
    #expect(postSetup(expectedBody ?? [:]) == surveyOnly)

    // A fresh directory with the same accounts/owner but only the snapshot
    // restored must publish byte-identical setup state.
    let restored = EmailLoginDirectory()
    restored.addAccount(id: owner, email: "setup-snapshot-owner@slock.test", password: "password123")
    restored.markEmailVerified(userId: owner)
    restored.oauth.addOwnedServer(id: serverId, slug: "setup-snapshot", name: "Setup Snapshot", ownerId: owner)
    try restored.serversAndChannelsStore.restorePersistenceData(persistence)
    let restoredToken = restored.mintAccessTokenForTesting(userId: owner)
    #expect(try await projectionBody(restored, restoredToken) == expected)
}
