import Foundation
import Synchronization
import TestSupport
import Testing

@testable import RaftHTTP

/// Locks the typed migration services: published bodies keep their member order
/// (which `JSONEncoder` cannot do on Linux), the refusals keep their legacy key
/// order, the request decoders keep the retired `as?` tolerance, and every
/// read-modify-write the retired directory handlers ran under the directory lock
/// is one `AgentsRuntimeStore` critical section.

private let ownerId = "11111111-1111-4111-8111-111111111821"
private let serverId = "33333333-3333-4333-8333-333333333821"
private let computerKey = "ck_unit_computer_key"
private let sourceMachine = "00000000-0000-4000-8000-0000000000a1"
private let targetMachine = "00000000-0000-4000-8000-0000000000b1"
private let ref = "mig_" + String(repeating: "u", count: 22)
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private let fixedISO = "2023-11-14T22:13:20.000Z"

private func makeDirectory() -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: ownerId, email: "migration-unit@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "migration-unit", name: "Migration Unit", ownerId: ownerId)
    return accounts
}

private func bearer(_ accounts: EmailLoginDirectory) -> String {
    "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
}

/// The target Computer's credential, attached to `targetMachine`.
private let computerAuthorization = "Bearer \(computerKey)"

private func attachTargetComputer(_ accounts: EmailLoginDirectory, machineId: String = targetMachine) {
    accounts.machinesAndComputersStore.computers = [(
        id: "computer-1", serverId: serverId, name: "target", apiKey: computerKey,
        machineId: machineId, revokedAt: nil, online: true, version: nil
    )]
}

private func record(
    agentId: String = "agent-unit",
    state: String = "ready",
    revision: Int = 1,
    generation: String = "generation-1"
) -> MachineMigrationRecord {
    MachineMigrationRecord(
        agentId: agentId, serverId: serverId, supportRef: ref, revision: revision, state: state,
        sourceMachineId: sourceMachine, targetMachineId: targetMachine, transportGeneration: generation
    )
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func makeHostedService(
    _ accounts: EmailLoginDirectory,
    receipts: Counter = Counter(),
    generation: String = "generation-next"
) -> AgentHostedMigrationService {
    AgentHostedMigrationService(
        agents: accounts.agentsRuntimeStore,
        machines: accounts.machinesAndComputersStore,
        oauth: accounts.oauth,
        dependencies: AgentHostedMigrationDependencies(
            sessionUserId: { accounts.sessionUserId(authorization: $0) },
            emitRealtime: { _, _, _ in },
            mintAgentCredential: { agentId, scopes, name in
                accounts.mintAgentCredential(agentId: agentId, scopes: scopes, name: name)
            },
            createMigrationReceiptDm: { _, _, _ in receipts.increment() }
        ),
        now: { fixedNow },
        newGeneration: { generation }
    )
}

private func succeeded<T>(_ body: () async throws -> T) async -> Bool {
    (try? await body()) != nil
}

private func successes(_ count: Int, _ body: @escaping @Sendable () async -> Bool) async -> Int {
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<count { group.addTask { await body() } }
        var total = 0
        for await won in group where won { total += 1 }
        return total
    }
}

// MARK: - Byte-exact bodies

@Test func migrationBodiesKeepTheLegacyMemberOrder() {
    var migration = record(state: "in_transit", generation: "generation-7")
    migration.completedAt = fixedNow
    migration.failureReason = "auto_start_failed"
    #expect(MigrationTargetViewResponse(migration).jsonBody.render()
        == #"{"ok":true,"migration":{"migrationRef":"\#(ref)","agentId":"agent-unit","state":"in_transit","migrationGeneration":"generation-7","sourceMachineId":"\#(sourceMachine)","targetMachineId":"\#(targetMachine)","canDriveTargetImport":true,"failureReason":"auto_start_failed","transportErrorCode":null,"transportErrorMessage":null,"autoStartFailureStage":null,"autoStartFailureCode":null,"completedAt":"\#(fixedISO)"}}"#)
    #expect(MigrationChunkStatusResponse(chunks: [0, 1, 2], received: [0], missing: [1, 2]).jsonBody.render()
        == #"{"chunks":[0,1,2],"received":[0],"missing":[1,2]}"#)
    #expect(MigrationChunkReceiptResponse(chunkIndex: 3, sha256: "ab").jsonBody.render()
        == #"{"ok":true,"chunkIndex":3,"sha256":"ab"}"#)
    #expect(MigrationControlManifestResponse(manifest: #"{"a": 1}"#).jsonBody.render() == #"{"manifest":{"a": 1}}"#)
    #expect(MigrationControlManifestStoredResponse(manifest: "{}").jsonBody.render() == #"{"ok":true,"manifest":{}}"#)
    #expect(MigrationCancelAckResponse(MachineMigrationCancelAckView(
        supportRef: ref, state: "canceled_pre_flip", revision: 4, disposition: "pre_flip_source_authoritative"
    )).jsonBody.render()
        == #"{"ok":true,"migration":{"migrationRef":"\#(ref)","state":"canceled_pre_flip","revision":4,"disposition":"pre_flip_source_authoritative"}}"#)
    #expect(MigrationSourceQuiescedResponse(migrationGeneration: "g", leaseId: "l").jsonBody.render()
        == #"{"ok":true,"migrationGeneration":"g","leaseId":"l"}"#)
    #expect(MigrationSourceProgressResponse(prepDeadlineAt: fixedISO).jsonBody.render()
        == #"{"ok":true,"advanced":true,"prepDeadlineAt":"\#(fixedISO)"}"#)
    #expect(AgentCredentialIssuedResponse(credentialId: "c", apiKey: "k", agentId: "a", serverId: "s", scopes: ["read"]).jsonBody.render()
        == #"{"credentialId":"c","apiKey":"k","agentId":"a","serverId":"s","scopes":["read"]}"#)
    #expect(AgentCredentialListResponse(credentials: [AgentCredentialRow(
        id: "i", maskedToken: "sk_agent_abcde***", name: "n", scopes: ["a"], createdAt: fixedISO, lastUsedAt: nil, revokedAt: fixedISO
    )]).jsonBody.render()
        == #"{"credentials":[{"id":"i","maskedToken":"sk_agent_abcde***","name":"n","scopes":["a"],"createdAt":"\#(fixedISO)","lastUsedAt":null,"revokedAt":"\#(fixedISO)"}]}"#)
}

@Test func controlBodiesKeepTheLegacyMemberOrder() {
    #expect(AgentMigrateResponse.hosted(HostedMigrationStartedResponse(
        migrationRef: ref, state: "preparing", sourceMachineId: sourceMachine, deadlineAt: fixedISO
    )).jsonBody.render()
        == #"{"migrationRef":"\#(ref)","state":"preparing","targetKind":"hosted","sourceMachineId":"\#(sourceMachine)","targetMachineId":null,"prepDeadlineAt":"\#(fixedISO)","transferDeadlineAt":"\#(fixedISO)","arrivalDeadlineAt":"\#(fixedISO)"}"#)
    #expect(AgentMigrateResponse.computer(MachineMigrationStartedResponse(
        migrationRef: ref, sourceMachineId: "s", targetMachineId: "t", deadlineAt: fixedISO
    )).jsonBody.render()
        == #"{"migrationRef":"\#(ref)","state":"provisioning","sourceMachineId":"s","targetMachineId":"t","targetKind":"computer","prepDeadlineAt":"\#(fixedISO)","transferDeadlineAt":"\#(fixedISO)","arrivalDeadlineAt":"\#(fixedISO)"}"#)
    #expect(AgentMigrateResponse.accepted.jsonBody.render() == #"{"ok":true,"status":"accepted"}"#)
    #expect(AgentMigrateResponse.accepted.status == 202)
    #expect(AgentScopesResponse(agentId: "a", mode: "default", scopes: ["x", "y"], revision: 0).jsonBody.render()
        == #"{"agentId":"a","mode":"default","scopes":["x","y"],"revision":0}"#)
    #expect(AgentArchiveResponse(archive: AgentArchiveView(
        agentId: "a", archivedAt: fixedISO, archivedByUserId: "u", machineId: "m", machineName: nil,
        workspaceState: "on_computer", pendingOp: "delete", waitingForComputer: true, lastErrorCode: nil, lastErrorAt: nil
    )).jsonBody.render()
        == #"{"archive":{"agentId":"a","archivedAt":"\#(fixedISO)","archivedByUserId":"u","machineId":"m","machineName":null,"workspaceState":"on_computer","pendingOp":"delete","waitingForComputer":true,"lastErrorCode":null,"lastErrorAt":null}}"#)
    #expect(AgentDirectMessagesResponse(rows: [AgentDirectMessageRow(id: "c", peerId: "p", peerName: "n", lastMessagePreview: nil)]).jsonBody.render()
        == #"[{"id":"c","peerId":"p","peerName":"n","lastMessagePreview":null}]"#)
    #expect(AgentChannelsResponse(rows: [AgentChannelRow(
        id: "c", name: "n", description: nil, type: "channel", createdAt: "t", activityMuted: true, muteFromSeq: 4
    )]).jsonBody.render()
        == #"[{"id":"c","name":"n","description":null,"type":"channel","createdAt":"t","archivedAt":null,"activityMuted":true,"muteFromSeq":4}]"#)
    #expect(AgentWorkspaceFilesResponse(files: "[]").jsonBody.render() == #"{"files":[]}"#)
}

@Test func refusalsKeepTheirPublishedKeyOrder() {
    #expect(AgentMigrationControlError.transportTokenInvalid.publishedErrorBody.render()
        == #"{"code":"migration_transport_token_invalid","error":"Migration transport token is invalid"}"#)
    #expect(AgentMigrationControlError.chunksMissing([2, 5]).publishedErrorBody.render()
        == #"{"code":"migration_chunks_missing","error":"Migration chunks are still missing","missing":[2,5]}"#)
    #expect(AgentMigrationControlError.chunksMissing([2, 5]).status == 409)
    #expect(AgentMigrationControlError.manifestTooLarge.status == 413)
    #expect(AgentMigrationControlError.unauthorized.publishedErrorBody.render() == #"{"error":"Unauthorized"}"#)
    #expect(AgentMigrationControlError.agentMissing.publishedErrorBody.render()
        == #"{"code":"agent_missing","error":"Agent not found"}"#)
    #expect(AgentMigrationControlError.hostedTargetDisabled.publishedErrorBody.render()
        == #"{"error":"Moving agents to the cloud is not enabled on this server","code":"HOSTED_TARGET_UNAVAILABLE","details":{"failureReason":"HOSTED_TARGET_UNAVAILABLE"}}"#)
    #expect(AgentMigrationControlError.archivedAgentNotFound.publishedErrorBody.render()
        == #"{"error":"Archived agent not found","code":"agent_not_archived"}"#)
    #expect(AgentMigrationControlError.startMachineOffline.publishedErrorBody.render()
        == #"{"error":"Machine is offline","code":"machine_offline","machineAffinityRoute":"owner_missing"}"#)
    #expect(AgentMigrationControlError.invalidReplicaReplaySignature.publishedErrorBody.render()
        == #"{"code":"invalid_replica_replay_signature","machineAffinityRoute":"owner_not_local","error":"Invalid internal replay signature"}"#)
    #expect(AgentMigrationControlError.machineOffline(action: "Activity log").publishedErrorBody.render()
        == #"{"code":"machine_offline","error":"Failed to send Activity log request to daemon"}"#)
    #expect(AgentMigrationControlError.resumableCapabilityRequired(side: "both").publishedErrorBody.render()
        == #"{"error":"Both source and target computers must run a Raft Computer that supports migration/v3; upgrade the source and target computer","code":"MIGRATION_RESUMABLE_CAPABILITY_REQUIRED","details":{"side":"both","reason":"capability_missing","failureReason":"MIGRATION_RESUMABLE_CAPABILITY_REQUIRED"}}"#)
    #expect(AgentMigrationControlError.computerCapabilityInsufficient(failures: [
        .init(side: .source, reasonRuntimeUnconfirmed: true, runtime: "codex"),
        .init(side: .target, reasonRuntimeUnconfirmed: false, runtime: "codex"),
    ]).publishedErrorBody.render()
        == #"{"error":"Both source and target computers must support the agent's runtime","code":"COMPUTER_CAPABILITY_INSUFFICIENT","details":{"failureReason":"COMPUTER_CAPABILITY_INSUFFICIENT","failures":[{"side":"source","reason":"runtime_unconfirmed","runtime":"codex"},{"side":"target","reason":"runtime_missing","runtime":"codex"}]}}"#)
}

// MARK: - Request tolerance

@Test func requestsKeepTheRetiredPerFieldCasts() throws {
    let decoder = JSONDecoder()
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }
    #expect(try decode(MigrationGenerationRequest.self, "[1]").migrationGeneration == nil)
    #expect(try decode(MigrationGenerationRequest.self, #"{"migrationGeneration":4}"#).migrationGeneration == nil)
    let arrival = try decode(MigrationArrivalRequest.self, #"{"migrationGeneration":"g","reportPath":"","reportSha256":null}"#)
    #expect(arrival.reportPath == .invalid && arrival.reportSha256 == .absent)
    #expect(try decode(MigrationArrivalRequest.self, #"{"reportPath":"p"}"#).reportPath == .value("p"))
    #expect(try decode(AgentAssignMachineRequest.self, "{}").machineId == .missing)
    #expect(try decode(AgentAssignMachineRequest.self, #"{"machineId":null}"#).machineId == .unassign)
    #expect(try decode(AgentAssignMachineRequest.self, #"{"machineId":""}"#).machineId == .invalid)
    #expect(try decode(AgentAssignMachineRequest.self, #"{"machineId":5}"#).machineId == .invalid)
    #expect(try decode(AgentAssignMachineRequest.self, #"{"machineId":"m"}"#).machineId == .machine("m"))
    #expect(try decode(AgentCredentialIssueRequest.self, #"{"scopes":["a",1,"b"]}"#).scopes == ["a", "b"])
    #expect(try decode(AgentCredentialIssueRequest.self, #"{"scopes":"a"}"#).scopes == [])
    // Foundation bridged a JSON boolean to Int and a JSON 0/1 to Bool.
    #expect(try decode(AgentResetRequest.self, #"{"clearWorkspace":1,"mode":"full"}"#) == AgentResetRequest(mode: "full", clearWorkspace: true))
    #expect(try decode(AgentResetRequest.self, #"{"clearWorkspace":2}"#).clearWorkspace == nil)
    let chunks = try decode(MigrationControlManifestRequest.self, #"{"bundle":{"chunks":[{"index":true,"sizeBytes":2.0,"sha256":"x"},{"index":"1"}]}}"#).chunks
    #expect(chunks?.map(\.index) == [1, nil])
    #expect(chunks?.map(\.sizeBytes) == [2, nil])
    let migrate = try decode(AgentMigrateRequest.self, #"{"target":{"kind":"hosted","provider":7,"hostedModel":null},"targetComputer":"m"}"#)
    #expect(migrate.hostedTarget == HostedMigrationTarget(provider: nil, hostedModel: .invalid))
    #expect(migrate.targetComputer == "m")
    #expect(try decode(AgentMigrateRequest.self, #"{"target":{"kind":"computer"}}"#).hostedTarget == nil)
}

// MARK: - Service flows

@Test func controlManifestIsValidatedStoredAndEchoedVerbatim() throws {
    let accounts = makeDirectory()
    attachTargetComputer(accounts)
    accounts.agentsRuntimeStore.machineMigrations = [ref: record()]
    let service = makeHostedService(accounts)
    let sha = String(repeating: "A", count: 64)
    let body = #"{ "bundle": {"chunks":[{"index":0,"sizeBytes":4,"sha256":"\#(sha)"},{"index":1,"sizeBytes":4,"sha256":"\#(sha)"}]} }"#

    #expect(throws: AgentMigrationControlError.transportTokenInvalid) {
        try service.putMigrationControlManifest(authorization: "Bearer nope", migrationRef: ref, body: body)
    }
    #expect(throws: AgentMigrationControlError.manifestInvalid) {
        try service.putMigrationControlManifest(authorization: computerAuthorization, migrationRef: ref, body: "[]")
    }
    #expect(throws: AgentMigrationControlError.manifestInvalid) {
        try service.putMigrationControlManifest(
            authorization: computerAuthorization, migrationRef: ref,
            body: #"{"bundle":{"chunks":[{"index":0,"sizeBytes":1,"sha256":"x"}]}}"#
        )
    }
    let stored = try service.putMigrationControlManifest(authorization: computerAuthorization, migrationRef: ref, body: body)
    #expect(stored.jsonBody.render() == #"{"ok":true,"manifest":\#(body)}"#)
    #expect(throws: AgentMigrationControlError.manifestConflict) {
        try service.putMigrationControlManifest(authorization: computerAuthorization, migrationRef: ref, body: body + " ")
    }
    #expect(throws: AgentMigrationControlError.chunksMissing([0, 1])) {
        try service.completeMigrationUpload(authorization: computerAuthorization, migrationRef: ref)
    }
    #expect(throws: AgentMigrationControlError.chunkReceiptMismatch) {
        try service.putMigrationChunkReceipt(
            authorization: computerAuthorization, migrationRef: ref, chunkIndex: 0,
            request: MigrationChunkReceiptRequest(sha256: String(repeating: "b", count: 64))
        )
    }
    let receipt = try service.putMigrationChunkReceipt(
        authorization: computerAuthorization, migrationRef: ref, chunkIndex: 0,
        request: MigrationChunkReceiptRequest(sha256: sha)
    )
    #expect(receipt.jsonBody.render() == #"{"ok":true,"chunkIndex":0,"sha256":"\#(sha.lowercased())"}"#)
    #expect(try service.migrationChunkStatus(authorization: computerAuthorization, migrationRef: ref).jsonBody.render()
        == #"{"chunks":[0,1],"received":[0],"missing":[1]}"#)
}

@Test func concurrentChunkReceiptsAreNeverLost() async throws {
    let accounts = makeDirectory()
    attachTargetComputer(accounts)
    let sha = String(repeating: "c", count: 64)
    var migration = record()
    for index in 0..<32 { migration.manifestChunks[index] = (sha, 8) }
    migration.manifestJSON = "{}"
    accounts.agentsRuntimeStore.machineMigrations = [ref: migration]
    let store = accounts.agentsRuntimeStore
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<32 {
            group.addTask { _ = store.recordChunkReceipt(ref: ref, chunkIndex: index, sha256: sha) }
        }
    }
    #expect(store.machineMigrations[ref]?.chunkReceipts.count == 32)
    let service = makeHostedService(accounts)
    #expect(try service.completeMigrationUpload(authorization: computerAuthorization, migrationRef: ref) == MigrationUploadCompleteResponse())
    #expect(store.machineMigrations[ref]?.state == "transfer_complete")
    #expect(store.machineMigrations[ref]?.revision == 2)
}

@Test func startTransferConsumesTheGenerationOnce() async {
    let accounts = makeDirectory()
    attachTargetComputer(accounts)
    accounts.agentsRuntimeStore.machineMigrations = [ref: record()]
    let service = makeHostedService(accounts, generation: "generation-after")
    let won = await successes(16) {
        await succeeded {
            try service.startMigrationTransfer(
                authorization: computerAuthorization, migrationRef: ref,
                request: MigrationGenerationRequest(migrationGeneration: "generation-1")
            )
        }
    }
    #expect(won == 1)
    let stored = accounts.agentsRuntimeStore.machineMigrations[ref]
    #expect(stored?.state == "in_transit" && stored?.revision == 2)
    #expect(stored?.transportGeneration == "generation-after")
    #expect(stored?.previousTransportGeneration == "generation-1")
}

@Test func flipMovesTheMachineBindingWithTheRowAndReplaysAreIdempotent() async throws {
    let accounts = makeDirectory()
    attachTargetComputer(accounts)
    accounts.agentsRuntimeStore.machineMigrations = [ref: record(state: "in_transit")]
    accounts.agentsRuntimeStore.agentMachineIds = ["agent-unit": sourceMachine]
    let service = makeHostedService(accounts, generation: "generation-after")
    let outcomes = await successes(16) {
        await succeeded {
            try service.flipMigrationMachine(
                authorization: computerAuthorization, migrationRef: ref,
                request: MigrationGenerationRequest(migrationGeneration: "generation-1")
            )
        }
    }
    // The first flip succeeds; a replay that raced behind it observes the
    // flipped row, a replay that raced ahead of it is stale.
    #expect(outcomes >= 1)
    let stored = try #require(accounts.agentsRuntimeStore.machineMigrations[ref])
    #expect(stored.state == "arriving" && stored.revision == 2 && stored.flippedAt == fixedNow)
    #expect(accounts.agentsRuntimeStore.agentMachineIds["agent-unit"] == targetMachine)

    accounts.agentsRuntimeStore.agentMachineIds = ["agent-unit": "somewhere-else"]
    accounts.agentsRuntimeStore.machineMigrations = [ref: record(state: "in_transit")]
    #expect(throws: AgentMigrationControlError.sourceMachineMismatch) {
        try service.flipMigrationMachine(
            authorization: computerAuthorization, migrationRef: ref,
            request: MigrationGenerationRequest(migrationGeneration: "generation-1")
        )
    }
    #expect(accounts.agentsRuntimeStore.machineMigrations[ref]?.state == "in_transit")
}

@Test func arrivalTransitionDispatchesExactlyOnce() async {
    let accounts = makeDirectory()
    accounts.agentsRuntimeStore.machineMigrations = [ref: record(state: "arriving")]
    accounts.agentsRuntimeStore.agentMachineIds = ["agent-unit": targetMachine]
    let store = accounts.agentsRuntimeStore
    let dispatched = await successes(16) {
        guard case .success(.dispatch) = store.arrivalTransition(
            machineId: targetMachine, ref: ref, generation: "generation-1",
            reportPath: "/r", reportSha256: "s", now: fixedNow
        ) else { return false }
        return true
    }
    #expect(dispatched == 1)
    let stored = store.machineMigrations[ref]
    #expect(stored?.state == "starting" && stored?.revision == 2)
    #expect(stored?.arrivalReportPath == "/r")
}

@Test func autoStartCompletionPostsTheReceiptOnce() async {
    let accounts = makeDirectory()
    attachTargetComputer(accounts)
    accounts.agentsRuntimeStore.machineMigrations = [ref: record(state: "arriving")]
    accounts.agentsRuntimeStore.agentMachineIds = ["agent-unit": targetMachine]
    let receipts = Counter()
    let service = makeHostedService(accounts, receipts: receipts, generation: "generation-done")
    let completed = await successes(12) {
        await succeeded {
            try await service.completeMigrationArrival(
                authorization: computerAuthorization, migrationRef: ref,
                request: MigrationArrivalRequest(migrationGeneration: "generation-1")
            )
        }
    }
    #expect(completed >= 1)
    #expect(receipts.count == 1)
    let stored = accounts.agentsRuntimeStore.machineMigrations[ref]
    #expect(stored?.state == "completed" && stored?.completedAt == fixedNow)
    #expect(stored?.transportGeneration == "generation-done")
    #expect(accounts.agentsRuntimeStore.agentMachineIds["agent-unit"] == targetMachine)
}

@Test func arrivalFailureOfTheStartKeepsTheArrivalRetryable() async throws {
    let accounts = makeDirectory()
    attachTargetComputer(accounts)
    accounts.agentsRuntimeStore.machineMigrations = [ref: record(state: "arriving")]
    accounts.agentsRuntimeStore.agentMachineIds = ["agent-unit": targetMachine]
    accounts.machinesAndComputersStore.machineMigrationStartAgent = { _ in .skipped("wake lock") }
    let service = makeHostedService(accounts)
    let view = try await service.completeMigrationArrival(
        authorization: computerAuthorization, migrationRef: ref,
        request: MigrationArrivalRequest(migrationGeneration: "generation-1")
    )
    #expect(view.migration.state == "starting")
    #expect(view.migration.failureReason == "auto_start_failed")
    #expect(view.migration.autoStartFailureStage == "start_agent")
    #expect(view.migration.autoStartFailureCode == "start_not_dispatched")
}

@Test func cancelAcknowledgementIsStampedOnce() async throws {
    let accounts = makeDirectory()
    var canceled = record(state: "canceled_pre_flip", revision: 5)
    canceled.cancelGeneration = "cancel-1"
    canceled.cancelTransportGeneration = "generation-1"
    canceled.cancelDisposition = "pre_flip_source_authoritative"
    accounts.agentsRuntimeStore.machineMigrations = [ref: canceled]
    let store = accounts.agentsRuntimeStore
    let ack = MachineMigrationCancelAck(
        supportRef: ref, transportGeneration: "generation-1", cancelGeneration: "cancel-1",
        role: "source", outcome: "cleaned"
    )
    let applied = await successes(16) {
        if case .success = store.acknowledgeCancel(machineId: sourceMachine, ref: ref, ack: ack, now: fixedNow) { return true }
        return false
    }
    #expect(applied == 16)
    let stored = try #require(store.machineMigrations[ref])
    #expect(stored.revision == 6)
    #expect(stored.cancelSourceAck == "cleaned")
    if case .failure(let failure) = store.acknowledgeCancel(
        machineId: sourceMachine, ref: ref,
        ack: MachineMigrationCancelAck(
            supportRef: ref, transportGeneration: "generation-1", cancelGeneration: "cancel-1",
            role: "source", outcome: "stopped"
        ),
        now: fixedNow
    ) {
        #expect(failure == .cancelOutcomeMismatch)
    } else {
        Issue.record("a mismatched outcome must refuse")
    }
}

@Test func transportLostFailsTheRowOnceAndReplaysReturnTheView() async {
    let accounts = makeDirectory()
    accounts.agentsRuntimeStore.machineMigrations = [ref: record(state: "in_transit")]
    let store = accounts.agentsRuntimeStore
    let applied = await successes(16) {
        if case .success = store.markTransportLost(
            machineId: sourceMachine, ref: ref, code: "MIGRATION_TRANSPORT_LOST", message: "m",
            detailCode: nil, reportedGeneration: nil, now: fixedNow
        ) { return true }
        return false
    }
    #expect(applied == 16)
    let stored = store.machineMigrations[ref]
    #expect(stored?.state == "failed" && stored?.revision == 2)
    #expect(stored?.transportErrorCode == "MIGRATION_TRANSPORT_LOST")
}

@Test func machineAssignmentRefusesWhileAMigrationIsActive() async {
    let accounts = makeDirectory()
    let store = accounts.agentsRuntimeStore
    store.hostedMigrations = ["agent-hosted": HostedMigrationRecord(
        agentId: "agent-hosted", serverId: serverId, supportRef: ref, revision: 1, state: "preparing", sourceMachineId: nil
    )]
    #expect(store.assignMachine(agentId: "agent-hosted", machineId: "m") == false)
    #expect(store.agentMachineIds["agent-hosted"] == nil)
    #expect(store.assignMachine(agentId: "agent-free", machineId: "m"))
    #expect(store.assignMachine(agentId: "agent-free", machineId: nil))
    #expect(store.agentMachineIds["agent-free"] == nil)

    // A Computer migration that is already terminal does not block the write.
    store.machineMigrations = [ref: record(agentId: "agent-done", state: "completed")]
    #expect(store.assignMachine(agentId: "agent-done", machineId: "n"))
}

@Test func insertsOfOneAgentsMigrationAdmitExactlyOne() async {
    let accounts = makeDirectory()
    let store = accounts.agentsRuntimeStore
    let machineInserted = await successes(16) {
        store.insertMachineMigrationIfIdle(record(agentId: "agent-m"))
    }
    #expect(machineInserted == 1)
    let hostedInserted = await successes(16) {
        store.insertHostedMigrationIfIdle(HostedMigrationRecord(
            agentId: "agent-h", serverId: serverId, supportRef: ref, revision: 1, state: "preparing", sourceMachineId: sourceMachine
        ))
    }
    #expect(hostedInserted == 1)
}

@Test func hostedConfirmationAppliesOnceAndMovesBothRows() async {
    let accounts = makeDirectory()
    let store = accounts.agentsRuntimeStore
    store.hostedMigrations = ["agent-h": HostedMigrationRecord(
        agentId: "agent-h", serverId: serverId, supportRef: ref, revision: 3, state: "in_transit", sourceMachineId: sourceMachine
    )]
    store.agentMachineIds = ["agent-h": sourceMachine]
    let confirmed = await successes(16) {
        if case .success = store.confirmHostedMigration(
            agentId: "agent-h", serverId: serverId, migrationRef: ref, expectedRevision: 3, now: fixedNow
        ) { return true }
        return false
    }
    #expect(confirmed == 1)
    #expect(store.hostedMigrations["agent-h"]?.state == "arriving")
    #expect(store.hostedMigrations["agent-h"]?.revision == 4)
    #expect(store.hostedRuntimes["agent-h"]?.state == "provisioning")
}

@Test func credentialRevocationKeepsTheFirstStamp() async throws {
    let accounts = makeDirectory()
    let store = accounts.agentsRuntimeStore
    let key = accounts.mintAgentCredential(agentId: "agent-c", scopes: ["read"], name: "n")
    let id = try #require(store.credentialId(token: key))
    let earlier = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 2_000)
    #expect(store.revokeCredential(agentId: "agent-c", credentialId: id, now: earlier))
    let revoked = await successes(12) { store.revokeCredential(agentId: "agent-c", credentialId: id, now: later) }
    #expect(revoked == 12)
    #expect(store.agentCredentials[key]?.revokedAt == earlier)
    #expect(store.revokeCredential(agentId: "other-agent", credentialId: id, now: later) == false)
    #expect(store.revokeCredential(agentId: "agent-c", credentialId: "missing", now: later) == false)
}

@Test func archiveWorkspaceDeleteIsQueuedOnce() async {
    let accounts = makeDirectory()
    let store = accounts.agentsRuntimeStore
    store.agentArchiveRecords = ["agent-a": AgentArchiveRecord(
        serverId: serverId, machineId: sourceMachine, machineName: "box", archivedAt: fixedNow,
        archivedByUserId: ownerId, workspaceState: "on_computer", pendingOp: nil, lastErrorCode: "x", lastErrorAt: fixedNow
    )]
    let queued = await successes(16) {
        if case .success = store.requestArchiveWorkspaceDelete(agentId: "agent-a") { return true }
        return false
    }
    #expect(queued == 1)
    #expect(store.agentArchiveRecords["agent-a"]?.pendingOp == "delete")
    #expect(store.agentArchiveRecords["agent-a"]?.lastErrorCode == nil)
    if case .failure(let failure) = store.requestArchiveWorkspaceDelete(agentId: "agent-a") {
        #expect(failure == .pending)
    } else {
        Issue.record("a second request must be refused while one is pending")
    }
    if case .failure(let failure) = store.requestArchiveWorkspaceDelete(agentId: "agent-none") {
        #expect(failure == .missing)
    } else {
        Issue.record("an unknown agent must be refused")
    }
}

// MARK: - Control service

private func makeControlService(_ accounts: EmailLoginDirectory) -> AgentMachineMigrationControlService {
    AgentMachineMigrationControlService(
        agents: accounts.agentsRuntimeStore,
        machines: accounts.machinesAndComputersStore,
        channels: accounts.serversAndChannelsStore,
        messages: accounts.messagesAndThreadsStore,
        tasks: accounts.tasksAndRemindersStore,
        oauth: accounts.oauth,
        dependencies: AgentMachineMigrationControlDependencies(
            sessionUserId: { accounts.sessionUserId(authorization: $0) },
            emitRealtime: { _, _, _ in }
        ),
        now: { fixedNow }
    )
}

@Test func concurrentHostedMigrationStartsAdmitExactlyOne() async throws {
    let accounts = makeDirectory()
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "cloud-unit", runtime: "codex")
    accounts.agentsRuntimeStore.agentMachineIds = [agent: sourceMachine]
    accounts.enableHostedMigrationForTesting(serverId: serverId)
    accounts.enableHostedRuntimeForTesting(serverId: serverId)
    let service = makeControlService(accounts)
    let authorization = bearer(accounts)
    let started = await successes(16) {
        await succeeded {
            try service.migrateAgent(
                authorization: authorization, agentId: agent, serverId: serverId,
                request: AgentMigrateRequest(hostedTarget: HostedMigrationTarget())
            )
        }
    }
    #expect(started == 1)
    let row = try #require(accounts.agentsRuntimeStore.hostedMigrations[agent])
    #expect(row.state == "preparing" && row.sourceMachineId == sourceMachine)
}

@Test func hostedStartRefusalsKeepTheirOrder() throws {
    let accounts = makeDirectory()
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "order-unit", runtime: "codex")
    let service = makeControlService(accounts)
    let authorization = bearer(accounts)
    func start(_ target: HostedMigrationTarget = HostedMigrationTarget()) throws -> AgentMigrateResponse {
        try service.migrateAgent(
            authorization: authorization, agentId: agent, serverId: serverId,
            request: AgentMigrateRequest(hostedTarget: target)
        )
    }
    #expect(throws: AgentMigrationControlError.hostedTargetDisabled) { try start() }
    accounts.enableHostedMigrationForTesting(serverId: serverId)
    #expect(throws: AgentMigrationControlError.hostedRuntimeDisabled) { try start() }
    accounts.enableHostedRuntimeForTesting(serverId: serverId)
    #expect(throws: AgentMigrationControlError.hostedUnknownProvider) { try start(HostedMigrationTarget(provider: "other")) }
    #expect(throws: AgentMigrationControlError.hostedModelInvalid) {
        try start(HostedMigrationTarget(hostedModel: .value("  ")))
    }
    #expect(throws: AgentMigrationControlError.agentHasNoSourceMachine) { try start() }
    accounts.agentsRuntimeStore.agentMachineIds = [agent: sourceMachine]
    #expect(throws: AgentMigrationControlError.hostedModelPickerDisabled) {
        try start(HostedMigrationTarget(hostedModel: .value("some-other-model")))
    }
    #expect(try start(HostedMigrationTarget(hostedModel: .value(EmailLoginDirectory.hostedDefaultModel))).status == 200)
}

@Test func deleteArchivesTheAgentAndReleasesItsWork() throws {
    let accounts = makeDirectory()
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "delete-unit", runtime: "codex")
    let service = makeControlService(accounts)
    #expect(throws: AgentMigrationControlError.archiveWorkspaceChoiceInvalid) {
        try service.deleteAgent(
            authorization: bearer(accounts), agentId: agent, serverId: serverId,
            request: AgentDeleteRequest(workspace: "maybe")
        )
    }
    #expect(throws: AgentMigrationControlError.agentHasNoWorkspace) {
        try service.deleteAgent(
            authorization: bearer(accounts), agentId: agent, serverId: serverId,
            request: AgentDeleteRequest(workspace: "delete")
        )
    }
    #expect(try service.deleteAgent(
        authorization: bearer(accounts), agentId: agent, serverId: serverId, request: AgentDeleteRequest()
    ) == OkResponse())
    let archive = accounts.agentsRuntimeStore.agentArchiveRecords[agent]
    #expect(archive?.workspaceState == "deleted" && archive?.archivedAt == fixedNow)
    #expect(throws: AgentMigrationControlError.agentNotFound) {
        try service.deleteAgent(
            authorization: bearer(accounts), agentId: agent, serverId: serverId, request: AgentDeleteRequest()
        )
    }
}

@Test func summariesRedactTheSourceOfAnUnseenTrigger() throws {
    let accounts = makeDirectory()
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "summary-unit", runtime: "codex")
    accounts.agentsRuntimeStore.agentActivitySummariesProvider = { _, _, _, _ in
        .ok(#"{"summaries":[{"id":"1","trigger":{"channelId":"dm-1","target":"dm:@x","text":"secret/path"}},{"id":"2","trigger":{"channelId":"unknown","target":"chan"}},{"id":"3","note":"a/b"}],"next":null}"#)
    }
    let service = makeControlService(accounts)
    let body = try service.agentActivitySummaries(
        authorization: bearer(accounts), serverId: serverId, agentId: agent, query: nil
    ).body
    #expect(body == #"{"next":null,"summaries":[{"id":"1","trigger":{"hidden":"dm"}},{"id":"2","trigger":{"hidden":"private_channel"}},{"id":"3","note":"a\/b"}]}"#, "\(body)")
}

@Test func credentialsAreIssuedListedAndRevokedForExternalAgents() throws {
    let accounts = makeDirectory()
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "cred-unit", runtime: "external")
    let service = makeHostedService(accounts)
    let authorization = bearer(accounts)
    let issued = try service.issueAgentCredential(
        authorization: authorization, agentId: agent,
        request: AgentCredentialIssueRequest(scopes: ["send", "read", "send"])
    )
    #expect(issued.scopes == ["read", "send"] && issued.serverId == serverId)
    #expect(issued.apiKey.hasPrefix("sk_agent_") && !issued.credentialId.isEmpty)
    let listed = try service.listAgentCredentials(authorization: authorization, agentId: agent)
    #expect(listed.credentials.count == 1)
    #expect(listed.credentials[0].maskedToken == String(issued.apiKey.prefix(14)) + "***")
    #expect(listed.credentials[0].revokedAt == nil)
    #expect(try service.revokeAgentCredential(
        authorization: authorization, agentId: agent, credentialId: issued.credentialId
    ) == NoContentResponse())
    #expect(try service.listAgentCredentials(authorization: authorization, agentId: agent).credentials[0].revokedAt == fixedISO)
    #expect(throws: AgentMigrationControlError.credentialNotFound) {
        try service.revokeAgentCredential(authorization: authorization, agentId: agent, credentialId: "missing")
    }
    let managed = accounts.oauth.createAgent(serverId: serverId, name: "managed-unit", runtime: "codex")
    #expect(throws: AgentMigrationControlError.agentNotExternal) {
        try service.issueAgentCredential(authorization: authorization, agentId: managed, request: AgentCredentialIssueRequest())
    }
}
