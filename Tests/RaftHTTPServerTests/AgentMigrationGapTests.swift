import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

// Coverage for the `internalComputer.agentMigration.api` groups the existing
// suite does not exercise: typed transport-lost reasons, post-flip source
// archive retry bookkeeping, idempotent flip/arrive callbacks, generation and
// holder guards, source-machine drive refusal, legacy completed-row
// reconciliation, and the post-flip cancellation outcome fence.

private final class MigrationGapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var events: [String] = []

    func increment(_ key: String) {
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key] ?? 0
    }

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class MigrationStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func signalEntered() {
        lock.lock()
        entered = true
        let continuation = enteredContinuation
        enteredContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func waitEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered {
                lock.unlock()
                continuation.resume()
            } else {
                enteredContinuation = continuation
                lock.unlock()
            }
        }
    }

    func waitRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            releaseContinuation = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let continuation = releaseContinuation
        releaseContinuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private struct MigrationStartTestError: Error {}

private struct MigrationGapFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let sourceMachineId: String
    let targetMachineId: String
    let sourceKey: String
    let targetKey: String
    let agentId: String
}

private func gapRef(_ suffix: Int, _ letter: Character) -> String {
    let digits = String(format: "%05d", suffix)
    let filler = String(repeating: String(letter), count: 17)
    return "mig_" + digits + filler
}

private func makeMigrationGapFixture(_ suffix: Int) -> MigrationGapFixture {
    let accounts = EmailLoginDirectory()
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 1_060_000 + suffix)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 1_060_000 + suffix)
    let ownerEmail = "migration-gap-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(
        id: serverId,
        slug: "migration-gap-\(suffix)",
        name: "Migration Gap \(suffix)",
        ownerId: ownerId
    )
    let source = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "gap-source-\(suffix)")
    let target = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "gap-target-\(suffix)")
    accounts.setMachineRuntimesForTesting(machineId: source, runtimes: ["codex"])
    accounts.setMachineRuntimesForTesting(machineId: target, runtimes: ["codex"])
    accounts.setMachineOnline(machineId: target, online: true)
    accounts.machineMigrationCapabilities[source] = ["migration/v3"]
    accounts.machineMigrationCapabilities[target] = ["migration/v3"]
    let agent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "gap-agent-\(suffix)",
        creatorUserId: ownerId,
        runtime: "codex"
    )
    accounts.setAgentMachineForTesting(agentId: agent, machineId: source)
    accounts.linkComputerForTesting(serverId: serverId, machineId: source, online: true)
    accounts.linkComputerForTesting(serverId: serverId, machineId: target, online: true)
    return MigrationGapFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        sourceMachineId: source,
        targetMachineId: target,
        sourceKey: accounts.computerAPIKeyForTesting(machineId: source) ?? "",
        targetKey: accounts.computerAPIKeyForTesting(machineId: target) ?? "",
        agentId: agent
    )
}

private func gapSeedMigration(
    _ fixture: MigrationGapFixture,
    ref: String,
    state: String = "ready",
    revision: Int = 1,
    generation: String = "gen-ready"
) {
    fixture.accounts.seedMachineMigrationForTesting(
        agentId: fixture.agentId,
        serverId: fixture.serverId,
        supportRef: ref,
        revision: revision,
        state: state,
        sourceMachineId: fixture.sourceMachineId,
        targetMachineId: fixture.targetMachineId,
        transportGeneration: generation
    )
}

private func gapHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func gapBody(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func gapView(_ response: ClientResponse) -> [String: Any] {
    gapBody(response)["migration"] as? [String: Any] ?? [:]
}

private func gapPost(
    _ client: any TestClient,
    _ key: String,
    _ path: String,
    _ body: String = "{}"
) async throws -> ClientResponse {
    try await client.send(.post, headers: gapHeaders(key), to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func gapRead(_ client: any TestClient, _ key: String, _ ref: String) async throws -> [String: Any] {
    let response = try await client.get(
        URI(string: "/internal/computer/agent-migrations/by-id/\(ref)"),
        headers: gapHeaders(key)
    )
    return gapView(response)
}

private func gapArrivalBody(_ generation: String) -> String {
    "{\"migrationGeneration\":\"\(generation)\",\"reportPath\":\"migrations/arrival-report.json\",\"reportSha256\":\"sha256:arrival\"}"
}

/// Drives a seeded `ready` migration through `start-transfer` and
/// `flip-machine`, returning the generation a first arrival callback uses.
private func gapDriveToArriving(
    _ client: any TestClient,
    _ fixture: MigrationGapFixture,
    ref: String
) async throws -> String {
    let base = "/internal/computer/agent-migrations/by-id/\(ref)"
    let started = try await gapPost(client, fixture.targetKey, "\(base)/start-transfer", "{\"migrationGeneration\":\"gen-ready\"}")
    let startedGeneration = try #require(gapView(started)["migrationGeneration"] as? String)
    let flipped = try await gapPost(client, fixture.targetKey, "\(base)/flip-machine", "{\"migrationGeneration\":\"\(startedGeneration)\"}")
    return try #require(gapView(flipped)["migrationGeneration"] as? String)
}

private func withMigrationGapApp(
    _ fixture: MigrationGapFixture,
    _ body: (any TestClient) async throws -> Void
) async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            try await body(client)
        }
    }
}

// MARK: - Typed transport-lost reasons

@Test func migrationTransportLostPersistsTypedObjectStoreBundleReason() async throws {
    let fixture = makeMigrationGapFixture(2601)
    let ref = gapRef(2601, "a")
    gapSeedMigration(fixture, ref: ref)
    let message = "MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE:actualBytes=629145600:maxBytes=536870912:topEntries=.git%2F,314572800;archive.tar,209715200;media%2F,104857600"
    try await withMigrationGapApp(fixture) { client in
        let lost = try await gapPost(
            client,
            fixture.sourceKey,
            "/internal/computer/agent-migrations/by-id/\(ref)/transport-lost",
            "{\"code\":\"MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE\",\"message\":\"\(message)\"}"
        )
        #expect(lost.status == .ok)
        let view = gapView(lost)
        #expect(view["state"] as? String == "failed")
        #expect(view["failureReason"] as? String == "MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE")
        #expect(view["transportErrorCode"] as? String == "MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE")
        #expect(view["transportErrorMessage"] as? String == message)
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.state == "failed")
        #expect(snapshot.failureReason == "MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE")
        #expect(snapshot.transportErrorCode == "MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE")
        #expect(snapshot.transportErrorMessage == message)
    }
}

@Test func migrationTransportLostPersistsTypedManifestReason() async throws {
    let fixture = makeMigrationGapFixture(2602)
    let ref = gapRef(2602, "b")
    gapSeedMigration(fixture, ref: ref)
    let message = "MIGRATION_OBJECT_STORE_MANIFEST_TOO_LARGE:manifestBytes=73400320:maxBytes=67108864:entryCount=97079:topPaths=.git%2F,34214;src%2F,12877"
    try await withMigrationGapApp(fixture) { client in
        let lost = try await gapPost(
            client,
            fixture.sourceKey,
            "/internal/computer/agent-migrations/by-id/\(ref)/transport-lost",
            "{\"code\":\"MIGRATION_OBJECT_STORE_MANIFEST_TOO_LARGE\",\"message\":\"\(message)\"}"
        )
        #expect(lost.status == .ok)
        let view = gapView(lost)
        #expect(view["state"] as? String == "failed")
        #expect(view["failureReason"] as? String == "MIGRATION_OBJECT_STORE_MANIFEST_TOO_LARGE")
        #expect(view["transportErrorCode"] as? String == "MIGRATION_OBJECT_STORE_MANIFEST_TOO_LARGE")
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.failureReason == "MIGRATION_OBJECT_STORE_MANIFEST_TOO_LARGE")
        #expect(snapshot.transportErrorMessage == message)
    }
}

@Test func migrationTransportLostPersistsTypedTargetDiskReason() async throws {
    let fixture = makeMigrationGapFixture(2603)
    let ref = gapRef(2603, "c")
    gapSeedMigration(fixture, ref: ref)
    let message = "MIGRATION_OBJECT_STORE_INSUFFICIENT_DISK:requiredBytes=7516192768:availableBytes=4294967296:contentBytes=3489660928"
    try await withMigrationGapApp(fixture) { client in
        let lost = try await gapPost(
            client,
            fixture.targetKey,
            "/internal/computer/agent-migrations/by-id/\(ref)/transport-lost",
            "{\"code\":\"MIGRATION_OBJECT_STORE_INSUFFICIENT_DISK\",\"message\":\"\(message)\"}"
        )
        #expect(lost.status == .ok)
        let view = gapView(lost)
        #expect(view["state"] as? String == "failed")
        #expect(view["failureReason"] as? String == "MIGRATION_OBJECT_STORE_INSUFFICIENT_DISK")
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.transportErrorCode == "MIGRATION_OBJECT_STORE_INSUFFICIENT_DISK")
        #expect(snapshot.transportErrorMessage == message)
    }
}

@Test func migrationTransportLostPreservesSpecificWorkspaceConflictOverFallback() async throws {
    let fixture = makeMigrationGapFixture(2604)
    let ref = gapRef(2604, "d")
    gapSeedMigration(fixture, ref: ref, state: "provisioning")
    try await withMigrationGapApp(fixture) { client in
        let lost = try await gapPost(
            client,
            fixture.targetKey,
            "/internal/computer/agent-migrations/by-id/\(ref)/transport-lost",
            "{\"code\":\"MIGRATION_WORKSPACE_ALREADY_EXISTS\",\"message\":\"MIGRATION_WORKSPACE_ALREADY_EXISTS\"}"
        )
        #expect(lost.status == .ok)
        let view = gapView(lost)
        #expect(view["failureReason"] as? String == "MIGRATION_WORKSPACE_ALREADY_EXISTS")
        #expect(view["transportErrorCode"] as? String == "MIGRATION_WORKSPACE_ALREADY_EXISTS")
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.failureReason == "MIGRATION_WORKSPACE_ALREADY_EXISTS")
        #expect(snapshot.transportErrorMessage == "MIGRATION_WORKSPACE_ALREADY_EXISTS")
        // An unclassified code still collapses to the generic transport reason.
        let otherRef = gapRef(2605, "e")
        gapSeedMigration(fixture, ref: otherRef)
        let generic = try await gapPost(
            client,
            fixture.sourceKey,
            "/internal/computer/agent-migrations/by-id/\(otherRef)/transport-lost",
            "{\"code\":\"SOMETHING_UNCLASSIFIED\",\"message\":\"free text\"}"
        )
        let genericView = gapView(generic)
        #expect(genericView["failureReason"] as? String == "MIGRATION_TRANSPORT_LOST")
        #expect(genericView["transportErrorCode"] as? String == "MIGRATION_TRANSPORT_LOST")
        #expect(genericView["transportErrorMessage"] as? String == "free text")
    }
}

@Test func migrationTransportLostPreservesClassifiedEntryCountFailure() async throws {
    let fixture = makeMigrationGapFixture(2606)
    let ref = gapRef(2606, "f")
    gapSeedMigration(fixture, ref: ref, state: "provisioning")
    let message = "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED:entryCount=250001:maxEntries=250000:topPathCounts=src%2F,200000;.git%2F,50001"
    try await withMigrationGapApp(fixture) { client in
        let lost = try await gapPost(
            client,
            fixture.sourceKey,
            "/internal/computer/agent-migrations/by-id/\(ref)/transport-lost",
            "{\"role\":\"source\",\"transferKind\":\"upload\",\"code\":\"MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED\",\"message\":\"\(message)\"}"
        )
        #expect(lost.status == .ok)
        let view = gapView(lost)
        #expect(view["failureReason"] as? String == "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED")
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.failureReason == "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED")
        #expect(snapshot.transportErrorCode == "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED")
        #expect(snapshot.transportErrorMessage == message)
    }
}

@Test func migrationTransportLostRejectsSameServerNonParticipantComputer() async throws {
    let fixture = makeMigrationGapFixture(2607)
    let ref = gapRef(2607, "g")
    gapSeedMigration(fixture, ref: ref)
    let otherMachine = fixture.accounts.registerMachine(
        serverId: fixture.serverId,
        userId: fixture.ownerId,
        name: "gap-other-2607"
    )
    fixture.accounts.linkComputerForTesting(serverId: fixture.serverId, machineId: otherMachine, online: true)
    let otherKey = try #require(fixture.accounts.computerAPIKeyForTesting(machineId: otherMachine))
    try await withMigrationGapApp(fixture) { client in
        let lost = try await gapPost(
            client,
            otherKey,
            "/internal/computer/agent-migrations/by-id/\(ref)/transport-lost",
            "{\"message\":\"MIGRATION_OBJECT_STORE_DOWNLOAD_RETRY_EXHAUSTED:404\"}"
        )
        #expect(lost.status == .notFound)
        #expect(gapBody(lost)["code"] as? String == "migration_missing")
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.state == "ready")
        #expect(snapshot.failureReason == nil)
    }
}

// MARK: - Replayed callbacks, generation and holder guards

@Test func migrationFlipAndArriveReplaysAreIdempotent() async throws {
    let fixture = makeMigrationGapFixture(2610)
    let ref = gapRef(2610, "h")
    gapSeedMigration(fixture, ref: ref)
    fixture.accounts.machineMigrationArchiveSourceWorkspace = { _, _, _ in }
    fixture.accounts.machineMigrationStartAgent = { _ in .dispatched }
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        let started = try await gapPost(client, fixture.targetKey, "\(base)/start-transfer", "{\"migrationGeneration\":\"gen-ready\"}")
        let startedGeneration = try #require(gapView(started)["migrationGeneration"] as? String)

        async let firstFlip = gapPost(client, fixture.targetKey, "\(base)/flip-machine", "{\"migrationGeneration\":\"\(startedGeneration)\"}")
        async let replayedFlip = gapPost(client, fixture.targetKey, "\(base)/flip-machine", "{\"migrationGeneration\":\"\(startedGeneration)\"}")
        let (firstFlipResponse, replayedFlipResponse) = try await (firstFlip, replayedFlip)
        #expect(firstFlipResponse.status == .ok)
        #expect(replayedFlipResponse.status == .ok)
        #expect(gapView(firstFlipResponse)["state"] as? String == "arriving")
        #expect(gapView(replayedFlipResponse)["state"] as? String == "arriving")
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == fixture.targetMachineId)
        let flippedSnapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(flippedSnapshot.state == "arriving")
        #expect(flippedSnapshot.failureReason == nil)

        let flippedGeneration = try #require(gapView(replayedFlipResponse)["migrationGeneration"] as? String)
        let arrivalBody = gapArrivalBody(flippedGeneration)
        let firstArrive = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(firstArrive.status == .ok)
        #expect(gapView(firstArrive)["state"] as? String == "completed")
        let replayedArrive = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(replayedArrive.status == .ok)
        #expect(gapView(replayedArrive)["state"] as? String == "completed")
        let completedSnapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(completedSnapshot.state == "completed")
        #expect(completedSnapshot.completedAt != nil)
    }
}

@Test func migrationStaleFlipGenerationIsRejectedWithoutMutatingHolder() async throws {
    let fixture = makeMigrationGapFixture(2611)
    let ref = gapRef(2611, "i")
    gapSeedMigration(fixture, ref: ref)
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        _ = try await gapPost(client, fixture.targetKey, "\(base)/start-transfer", "{\"migrationGeneration\":\"gen-ready\"}")
        let staleFlip = try await gapPost(client, fixture.targetKey, "\(base)/flip-machine", "{\"migrationGeneration\":\"gen-ready\"}")
        #expect(staleFlip.status == .conflict)
        #expect(gapBody(staleFlip)["code"] as? String == "migration_generation_stale")
        let current = try await gapRead(client, fixture.targetKey, ref)
        #expect(current["state"] as? String == "in_transit")
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == fixture.sourceMachineId)
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.state == "in_transit")
    }
}

@Test func migrationFlipRejectsWhenHolderMovedToAnotherMachine() async throws {
    let fixture = makeMigrationGapFixture(2612)
    let ref = gapRef(2612, "j")
    gapSeedMigration(fixture, ref: ref)
    let otherMachine = fixture.accounts.registerMachine(
        serverId: fixture.serverId,
        userId: fixture.ownerId,
        name: "gap-other-2612"
    )
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        let started = try await gapPost(client, fixture.targetKey, "\(base)/start-transfer", "{\"migrationGeneration\":\"gen-ready\"}")
        let startedGeneration = try #require(gapView(started)["migrationGeneration"] as? String)
        fixture.accounts.setAgentMachineForTesting(agentId: fixture.agentId, machineId: otherMachine)

        let mismatchedFlip = try await gapPost(
            client,
            fixture.targetKey,
            "\(base)/flip-machine",
            "{\"migrationGeneration\":\"\(startedGeneration)\"}"
        )
        #expect(mismatchedFlip.status == .conflict)
        #expect(gapBody(mismatchedFlip)["code"] as? String == "migration_source_machine_mismatch")
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == otherMachine)
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.state == "in_transit")
    }
}

@Test func migrationSourceMachineComputerCannotDriveTargetImport() async throws {
    let fixture = makeMigrationGapFixture(2613)
    let ref = gapRef(2613, "k")
    gapSeedMigration(fixture, ref: ref)
    try await withMigrationGapApp(fixture) { client in
        let sourceAttempt = try await client.get(
            URI(string: "/internal/computer/agent-migrations/by-id/\(ref)"),
            headers: gapHeaders(fixture.sourceKey)
        )
        #expect(sourceAttempt.status == .notFound)
        #expect(gapBody(sourceAttempt)["code"] as? String == "migration_missing")
        let targetView = try await gapRead(client, fixture.targetKey, ref)
        #expect(targetView["state"] as? String == "ready")
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == fixture.sourceMachineId)
    }
}

// MARK: - Archive receipt and target auto-start

@Test func migrationTargetImportDriveConfirmsSourceArchiveBeforeStart() async throws {
    let fixture = makeMigrationGapFixture(2620)
    let ref = gapRef(2620, "l")
    gapSeedMigration(fixture, ref: ref)
    let recorder = MigrationGapRecorder()
    fixture.accounts.machineMigrationArchiveSourceWorkspace = { machineId, migrationRef, agentId in
        let state = fixture.accounts.machineMigrationStateForTesting(migrationRef: migrationRef)?.state ?? "missing"
        recorder.record("archive|\(machineId)|\(migrationRef)|\(agentId)|\(state)")
    }
    fixture.accounts.machineMigrationStartAgent = { agentId in
        let archived = fixture.accounts.machineMigrationStateForTesting(migrationRef: ref)?.sourceWorkspaceArchivedAt
        recorder.record("start|\(agentId)|archived=\(archived != nil)")
        return .dispatched
    }
    try await withMigrationGapApp(fixture) { client in
        let flippedGeneration = try await gapDriveToArriving(client, fixture, ref: ref)
        let arrived = try await gapPost(
            client,
            fixture.targetKey,
            "/internal/computer/agent-migrations/by-id/\(ref)/arrived",
            gapArrivalBody(flippedGeneration)
        )
        #expect(arrived.status == .ok)
        #expect(gapView(arrived)["state"] as? String == "completed")
        #expect(recorder.recorded == [
            "archive|\(fixture.sourceMachineId)|\(ref)|\(fixture.agentId)|arriving",
            "start|\(fixture.agentId)|archived=true",
        ])
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == fixture.targetMachineId)
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.state == "completed")
        #expect(snapshot.sourceWorkspaceArchivedAt != nil)
        #expect(snapshot.completedAt != nil)
    }
}

@Test func migrationArrivalObservationRechecksArchiveWhileStartInProgress() async throws {
    let fixture = makeMigrationGapFixture(2621)
    let ref = gapRef(2621, "m")
    gapSeedMigration(fixture, ref: ref)
    let recorder = MigrationGapRecorder()
    let gate = MigrationStartGate()
    fixture.accounts.machineMigrationArchiveSourceWorkspace = { _, _, _ in
        recorder.increment("archive")
    }
    fixture.accounts.machineMigrationStartAgent = { agentId in
        recorder.increment("start")
        recorder.record("start|\(agentId)")
        gate.signalEntered()
        await gate.waitRelease()
        throw MigrationStartTestError()
    }
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        let flippedGeneration = try await gapDriveToArriving(client, fixture, ref: ref)
        let arrivalBody = gapArrivalBody(flippedGeneration)

        async let firstArrival = gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        await gate.waitEntered()
        let observed = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(observed.status == .ok)
        #expect(gapView(observed)["state"] as? String == "starting")
        #expect(recorder.count("archive") == 2, "each arrival observation confirms the idempotent archive receipt")

        gate.release()
        let firstResponse = try await firstArrival
        #expect(firstResponse.status == .ok)
        #expect(gapView(firstResponse)["state"] as? String == "starting")
        #expect(recorder.count("start") == 1)
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.state == "starting")
        #expect(snapshot.sourceWorkspaceArchivedAt != nil)
    }
}

@Test func migrationAutoStartFailureKeepsArrivalRetryable() async throws {
    let fixture = makeMigrationGapFixture(2622)
    let ref = gapRef(2622, "n")
    gapSeedMigration(fixture, ref: ref)
    let recorder = MigrationGapRecorder()
    fixture.accounts.machineMigrationArchiveSourceWorkspace = { _, _, _ in
        recorder.increment("archive")
    }
    fixture.accounts.machineMigrationStartAgent = { agentId in
        recorder.increment("start")
        if recorder.count("start") == 1 {
            throw MigrationStartTestError()
        }
        recorder.record("retry|\(agentId)")
        return .dispatched
    }
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        let flippedGeneration = try await gapDriveToArriving(client, fixture, ref: ref)
        let arrivalBody = gapArrivalBody(flippedGeneration)

        let first = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(first.status == .ok)
        #expect(gapView(first)["state"] as? String == "starting")
        let failed = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(failed.state == "starting")
        #expect(failed.failureReason == "auto_start_failed")
        #expect(failed.autoStartFailureStage == "start_agent")
        #expect(failed.autoStartFailureCode == "start_threw")
        #expect(failed.completedAt == nil)
        #expect(recorder.count("archive") == 1)
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == fixture.targetMachineId)

        let retried = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(retried.status == .ok)
        #expect(gapView(retried)["state"] as? String == "completed")
        #expect(recorder.count("archive") == 2)
        #expect(recorder.recorded.contains("retry|\(fixture.agentId)"))
        let completed = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(completed.state == "completed")
    }
}

@Test func migrationFailedSourceArchiveAfterFlipStillCompletes() async throws {
    let fixture = makeMigrationGapFixture(2623)
    let ref = gapRef(2623, "o")
    gapSeedMigration(fixture, ref: ref)
    let recorder = MigrationGapRecorder()
    fixture.accounts.machineMigrationArchiveSourceWorkspace = { _, _, _ in
        recorder.increment("archive")
        if recorder.count("archive") == 1 {
            throw MachineMigrationArchiveFailure(code: "NODE_EXDEV")
        }
    }
    fixture.accounts.machineMigrationStartAgent = { _ in
        recorder.increment("start")
        return .dispatched
    }
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        let flippedGeneration = try await gapDriveToArriving(client, fixture, ref: ref)
        let arrivalBody = gapArrivalBody(flippedGeneration)

        let arrived = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(arrived.status == .ok)
        #expect(gapView(arrived)["state"] as? String == "completed")
        #expect(recorder.count("start") == 1, "the agent starts without waiting for source cleanup")
        let completed = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(completed.state == "completed")
        #expect(completed.sourceWorkspaceArchivedAt == nil, "an unconfirmed archive is not forged as done")
        #expect(completed.sourceWorkspaceArchiveAttempts == 1)
        #expect(completed.sourceWorkspaceArchiveLastError == "NODE_EXDEV")
        #expect(completed.sourceWorkspaceArchiveRetryAt != nil)
        #expect(completed.canceledAt == nil)

        // A replay with the pre-arrival generation is stale: it must not trigger
        // another archive or start request.
        let replayed = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(replayed.status == .conflict)
        #expect(gapBody(replayed)["code"] as? String == "migration_generation_stale")
        #expect(recorder.count("archive") == 1)
        #expect(recorder.count("start") == 1)
    }
}

@Test func migrationWakeLockSkippedStartNeverCompletes() async throws {
    let fixture = makeMigrationGapFixture(2624)
    let ref = gapRef(2624, "p")
    gapSeedMigration(fixture, ref: ref)
    let recorder = MigrationGapRecorder()
    let gate = MigrationStartGate()
    fixture.accounts.machineMigrationArchiveSourceWorkspace = { _, _, _ in
        recorder.increment("archive")
    }
    fixture.accounts.machineMigrationStartAgent = { _ in
        recorder.increment("start")
        if recorder.count("start") == 1 {
            gate.signalEntered()
            await gate.waitRelease()
            throw MigrationStartTestError()
        }
        return .skipped("wake_lock_held")
    }
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        let flippedGeneration = try await gapDriveToArriving(client, fixture, ref: ref)
        let arrivalBody = gapArrivalBody(flippedGeneration)

        async let originalArrival = gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        await gate.waitEntered()
        // Mirror the upstream direct row update that lets the dispatch lease expire.
        fixture.accounts.setMachineMigrationUpdatedAtForTesting(
            migrationRef: ref,
            date: Date(timeIntervalSince1970: 946_684_800)
        )

        let reclaimed = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(reclaimed.status == .ok)
        #expect(gapView(reclaimed)["state"] as? String == "starting")
        #expect(recorder.count("start") == 2)
        #expect(recorder.count("archive") == 2)

        gate.release()
        let originalResponse = try await originalArrival
        #expect(originalResponse.status == .ok)
        #expect(gapView(originalResponse)["state"] as? String == "starting")

        let persisted = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(persisted.state == "starting")
        #expect(persisted.failureReason == "auto_start_failed")
        #expect(persisted.autoStartFailureStage == "start_agent")
        #expect(persisted.autoStartFailureCode == "start_threw")
        #expect(persisted.completedAt == nil)
    }
}

// MARK: - Legacy completed-row reconciliation

@Test func migrationLegacyCompletedRowReconcilesAuthoritativeArchive() async throws {
    let fixture = makeMigrationGapFixture(2630)
    let ref = gapRef(2630, "q")
    gapSeedMigration(fixture, ref: ref)
    let recorder = MigrationGapRecorder()
    fixture.accounts.machineMigrationArchiveSourceWorkspace = { machineId, migrationRef, agentId in
        recorder.record("archive|\(machineId)|\(migrationRef)|\(agentId)")
    }
    fixture.accounts.machineMigrationStartAgent = { _ in .dispatched }
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        let flippedGeneration = try await gapDriveToArriving(client, fixture, ref: ref)
        let arrivalBody = gapArrivalBody(flippedGeneration)
        let completed = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(gapView(completed)["state"] as? String == "completed")
        #expect(recorder.recorded.count == 1)

        // The authoritative archive receipt is lost (legacy row).
        fixture.accounts.setMachineMigrationArchiveStateForTesting(migrationRef: ref, archivedAt: nil)

        let staleReconciliation = try await gapPost(client, fixture.targetKey, "\(base)/arrived", arrivalBody)
        #expect(staleReconciliation.status == .conflict)
        #expect(gapBody(staleReconciliation)["code"] as? String == "migration_generation_stale")
        #expect(recorder.recorded.count == 1, "stale recovery authority must fail before another source archive request")

        let legacyView = try await gapRead(client, fixture.targetKey, ref)
        #expect(legacyView["state"] as? String == "completed")
        let currentGeneration = try #require(legacyView["migrationGeneration"] as? String)
        let reconciled = try await gapPost(
            client,
            fixture.targetKey,
            "\(base)/arrived",
            gapArrivalBody(currentGeneration)
        )
        #expect(reconciled.status == .ok)
        #expect(gapView(reconciled)["state"] as? String == "completed")
        #expect(recorder.recorded == ["archive|\(fixture.sourceMachineId)|\(ref)|\(fixture.agentId)", "archive|\(fixture.sourceMachineId)|\(ref)|\(fixture.agentId)"])
        let persisted = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(persisted.sourceWorkspaceArchivedAt != nil)
        #expect(persisted.state == "completed")
    }
}

// MARK: - Post-flip cancellation disposition

@Test func migrationPostFlipCancelCleanedDoesNotTerminalize() async throws {
    let fixture = makeMigrationGapFixture(2640)
    let ref = gapRef(2640, "r")
    gapSeedMigration(fixture, ref: ref)
    fixture.accounts.machineMigrationArchiveSourceWorkspace = { _, _, _ in }
    fixture.accounts.machineMigrationStartAgent = { _ in .dispatched }
    try await withMigrationGapApp(fixture) { client in
        let base = "/internal/computer/agent-migrations/by-id/\(ref)"
        _ = try await gapDriveToArriving(client, fixture, ref: ref)

        // Human cancellation after the flip freezes the target-authoritative disposition.
        var loginHeaders = HTTPFields()
        loginHeaders[.contentType] = "application/json"
        let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
            request.body = .init(string: "{\"email\":\"\(fixture.ownerEmail)\",\"password\":\"password123\"}")
        }
        let ownerToken = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
        var ownerHeaders = HTTPFields()
        ownerHeaders[.authorization] = "Bearer \(ownerToken)"
        ownerHeaders[.contentType] = "application/json"
        ownerHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
        let statusResponse = try await client.get(
            URI(string: "/api/agents/\(fixture.agentId)/migration"),
            headers: ownerHeaders
        )
        let statusMigration = try #require(gapBody(statusResponse)["migration"] as? [String: Any])
        let revision = try #require(statusMigration["revision"] as? Int)
        #expect(statusMigration["state"] as? String == "arriving")

        let canceled = try await client.send(
            .post,
            headers: ownerHeaders,
            to: URI(string: "/api/agents/\(fixture.agentId)/migration/cancel")
        ) { request in
            request.body = .init(string: "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":\(revision),\"reason\":\"owner_cancel_after_flip\"}")
        }
        #expect(canceled.status == .ok)
        let canceledMigration = try #require(gapBody(canceled)["migration"] as? [String: Any])
        #expect(canceledMigration["state"] as? String == "canceled_post_flip")
        let cancelRevision = try #require(canceledMigration["revision"] as? Int)
        let generations = try #require(fixture.accounts.machineMigrationCancelGenerationsForTesting(migrationRef: ref))

        let rejected = try await gapPost(
            client,
            fixture.targetKey,
            "\(base)/cancel-ack",
            "{\"migrationRef\":\"\(ref)\",\"transportGeneration\":\"\(generations.transport)\",\"cancelGeneration\":\"\(generations.cancel)\",\"role\":\"target\",\"outcome\":\"cleaned\"}"
        )
        #expect(rejected.status == .conflict)
        #expect(gapBody(rejected)["code"] as? String == "migration_cancel_outcome_mismatch")

        let afterRejected = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(afterRejected.state == "canceled_post_flip")
        #expect(afterRejected.cancelDisposition == "post_flip_target_authoritative")
        #expect(afterRejected.cancelTargetAck == nil)
        #expect(afterRejected.cancelTargetAckAt == nil)
        #expect(afterRejected.canceledAt != nil)
        #expect(afterRejected.transportTeardownAt != nil)
        #expect(afterRejected.revision == cancelRevision)
    }
}
