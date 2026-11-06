import Foundation
import RaftShared

/// The not-yet-migrated domains the migration transport still needs: the human
/// session lookup, the realtime emitter, the agent credential mint and the
/// migration-receipt DM that lives in the message-send domain.
public struct AgentHostedMigrationDependencies: Sendable {
    public var sessionUserId: @Sendable (String?) -> String?
    public var emitRealtime: @Sendable (_ room: String, _ event: String, _ payload: String?) -> Void
    /// Mints one `sk_agent_*` credential and returns its raw key.
    public var mintAgentCredential: @Sendable (_ agentId: String, _ scopes: [String], _ name: String) -> String
    public var createMigrationReceiptDm: @Sendable (_ agentId: String, _ serverId: String, _ supportRef: String) -> Void

    /// Keeps credential projection and receipt delivery in the migration domain.
    init(
        auth: AuthCoreService,
        agents: AgentsRuntimeStore,
        realtime: RealtimeRelayService,
        messageSend: MessageSendService
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            emitRealtime: realtime.emit,
            mintAgentCredential: { agentId, scopes, name in
                agents.mintAgentCredential(agentId: agentId, scopes: scopes, name: name).apiKey
            },
            createMigrationReceiptDm: { agentId, serverId, supportRef in
                messageSend.createMigrationReceiptDm(agentId: agentId, serverId: serverId, supportRef: supportRef)
            }
        )
    }

    public init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        emitRealtime: @escaping @Sendable (String, String, String?) -> Void,
        mintAgentCredential: @escaping @Sendable (String, [String], String) -> String,
        createMigrationReceiptDm: @escaping @Sendable (String, String, String) -> Void
    ) {
        self.sessionUserId = sessionUserId
        self.emitRealtime = emitRealtime
        self.mintAgentCredential = mintAgentCredential
        self.createMigrationReceiptDm = createMigrationReceiptDm
    }
}

/// Machine-migration transport and agent machine/credential administration:
/// the Computer callbacks (control manifest, chunk receipts, target view, start
/// transfer, flip, arrival, transport lost, cancel acknowledgement, source
/// quiesce and progress), agent machine assignment and agent credentials.
///
/// The service owns authorization and projection and returns typed DTOs or
/// throws `AgentMigrationControlError`. Every row decision is one critical
/// section of `AgentsRuntimeStore`, which owns the Computer migration rows next
/// to the agent-to-machine binding the flip and the auto-start completion move
/// together with them.
public struct AgentHostedMigrationService: Sendable {
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let oauth: OAuthLedger
    private let dependencies: AgentHostedMigrationDependencies
    private let now: @Sendable () -> Date
    private let newGeneration: @Sendable () -> String

    init(
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        oauth: OAuthLedger,
        dependencies: AgentHostedMigrationDependencies,
        now: @escaping @Sendable () -> Date = { Date() },
        newGeneration: @escaping @Sendable () -> String = { "generation-" + UUID().uuidString.lowercased() }
    ) {
        self.agents = agents
        self.machines = machines
        self.oauth = oauth
        self.dependencies = dependencies
        self.now = now
        self.newGeneration = newGeneration
    }

    // MARK: - Authorization

    private static func bearer(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    /// Any live Computer credential.
    private func requireComputer(_ authorization: String?) throws {
        guard let token = Self.bearer(authorization), machines.computerCredentialIsLive(token: token) else {
            throw AgentMigrationControlError.transportTokenInvalid
        }
    }

    /// The machine a live Computer credential is attached to.
    private func requireComputerMachine(_ authorization: String?) throws -> String {
        guard let token = Self.bearer(authorization), let machineId = machines.attachedMachineId(computerKey: token)
        else { throw AgentMigrationControlError.transportTokenInvalid }
        return machineId
    }

    private static func error(_ failure: MachineMigrationTransportFailure) -> AgentMigrationControlError {
        switch failure {
        case .migrationMissing: .migrationMissing
        case .controlManifestMissing: .controlManifestMissing
        case .chunkInvalid: .streamedChunkInvalid
        case .chunkReceiptMismatch: .chunkReceiptMismatch
        case .chunksMissing(let missing): .chunksMissing(missing)
        case .generationStale: .generationStale
        case .notReady: .notReady
        case .notFlippable: .notFlippable
        case .sourceMachineMismatch: .sourceMachineMismatch
        case .notArriving: .notArriving
        case .notActive: .notActive
        case .cancelGenerationStale: .cancelGenerationStale
        case .cancelNotRequested: .cancelNotRequested
        case .cancelOutcomeMismatch: .cancelOutcomeMismatch
        case .manifestConflict: .manifestConflict
        }
    }

    private func unwrap<T>(_ result: Result<T, MachineMigrationTransportFailure>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let failure): throw Self.error(failure)
        }
    }

    // MARK: - Control manifest and chunks

    /// `PUT`-style registration of the resumable control manifest. The manifest
    /// is published back as the text the Computer sent, so the route passes the
    /// raw body.
    public func putMigrationControlManifest(
        authorization: String?,
        migrationRef: String,
        body: String
    ) throws -> MigrationControlManifestStoredResponse {
        try requireComputer(authorization)
        // The manifest budget is 512 KB of manifest, not of transport padding: the
        // request envelope allows 64 KB headroom on top of it.
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 512 * 1024 else {
            throw AgentMigrationControlError.manifestTooLarge
        }
        guard let manifest = try? JSONDecoder().decode(MigrationControlManifestRequest.self, from: Data(body.utf8)),
              let chunks = manifest.chunks
        else { throw AgentMigrationControlError.manifestInvalid }
        var parsed: [Int: (sha256: String, sizeBytes: Int)] = [:]
        for chunk in chunks {
            guard let index = chunk.index, index >= 0,
                  let size = chunk.sizeBytes, size > 0,
                  let sha = chunk.sha256,
                  sha.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
                  parsed[index] == nil
            else { throw AgentMigrationControlError.manifestInvalid }
            parsed[index] = (sha.lowercased(), size)
        }
        try unwrap(agents.putControlManifest(ref: migrationRef, body: body, chunks: parsed))
        return MigrationControlManifestStoredResponse(manifest: body)
    }

    /// `GET …/resumable/control`.
    public func getMigrationControlManifest(
        authorization: String?,
        migrationRef: String
    ) throws -> MigrationControlManifestResponse {
        try requireComputer(authorization)
        guard let record = agents.machineMigration(ref: migrationRef) else {
            throw AgentMigrationControlError.migrationMissing
        }
        guard let manifest = record.manifestJSON else { throw AgentMigrationControlError.controlManifestMissing }
        return MigrationControlManifestResponse(manifest: manifest)
    }

    /// `POST …/resumable/chunks/:index/receipt`.
    public func putMigrationChunkReceipt(
        authorization: String?,
        migrationRef: String,
        chunkIndex: Int,
        request: MigrationChunkReceiptRequest
    ) throws -> MigrationChunkReceiptResponse {
        try requireComputer(authorization)
        guard let sha = request.sha256 else { throw AgentMigrationControlError.streamedChunkInvalid }
        let lowered = sha.lowercased()
        try unwrap(agents.recordChunkReceipt(ref: migrationRef, chunkIndex: chunkIndex, sha256: lowered))
        return MigrationChunkReceiptResponse(chunkIndex: chunkIndex, sha256: lowered)
    }

    /// `GET …/resumable/chunks`.
    public func migrationChunkStatus(
        authorization: String?,
        migrationRef: String
    ) throws -> MigrationChunkStatusResponse {
        try requireComputer(authorization)
        guard let record = agents.machineMigration(ref: migrationRef) else {
            throw AgentMigrationControlError.migrationMissing
        }
        guard !record.manifestChunks.isEmpty else { throw AgentMigrationControlError.controlManifestMissing }
        let all = record.manifestChunks.keys.sorted()
        return MigrationChunkStatusResponse(
            chunks: all,
            received: all.filter { record.chunkReceipts[$0] != nil },
            missing: all.filter { record.chunkReceipts[$0] == nil }
        )
    }

    /// `POST …/resumable/upload-complete`.
    public func completeMigrationUpload(
        authorization: String?,
        migrationRef: String
    ) throws -> MigrationUploadCompleteResponse {
        try requireComputer(authorization)
        try unwrap(agents.completeUpload(ref: migrationRef))
        return MigrationUploadCompleteResponse()
    }

    // MARK: - Target callbacks

    /// `GET /internal/computer/agent-migrations/by-id/:id`.
    public func getMigrationTargetView(
        authorization: String?,
        migrationRef: String
    ) throws -> MigrationTargetViewResponse {
        let machineId = try requireComputerMachine(authorization)
        return MigrationTargetViewResponse(try unwrap(agents.targetMigration(ref: migrationRef, machineId: machineId)))
    }

    private func generation(_ request: MigrationGenerationRequest) throws -> String {
        guard let generation = request.migrationGeneration, !generation.isEmpty else {
            throw AgentMigrationControlError.generationRequired
        }
        return generation
    }

    /// `POST …/start-transfer`.
    public func startMigrationTransfer(
        authorization: String?,
        migrationRef: String,
        request: MigrationGenerationRequest
    ) throws -> MigrationTargetViewResponse {
        let machineId = try requireComputerMachine(authorization)
        let generation = try generation(request)
        return MigrationTargetViewResponse(try unwrap(agents.startTransfer(
            ref: migrationRef,
            machineId: machineId,
            generation: generation,
            nextGeneration: newGeneration(),
            now: now()
        )))
    }

    /// `POST …/flip-machine`. A flip replayed after it already succeeded returns
    /// the current view: the generation it consumed is no longer current, but the
    /// callback is not a second transition.
    public func flipMigrationMachine(
        authorization: String?,
        migrationRef: String,
        request: MigrationGenerationRequest
    ) throws -> MigrationTargetViewResponse {
        let machineId = try requireComputerMachine(authorization)
        let generation = try generation(request)
        return MigrationTargetViewResponse(try unwrap(agents.flipMachine(
            ref: migrationRef,
            machineId: machineId,
            generation: generation,
            nextGeneration: newGeneration(),
            now: now()
        )))
    }

    /// `POST …/arrived`: confirm the idempotent source archive, move the row to
    /// `starting`, then dispatch the target start. An archive failure after the
    /// flip is recorded for the background retry and does not fail the
    /// migration; a failed or suppressed start keeps the arrival retryable.
    public func completeMigrationArrival(
        authorization: String?,
        migrationRef: String,
        request: MigrationArrivalRequest
    ) async throws -> MigrationTargetViewResponse {
        let machineId = try requireComputerMachine(authorization)
        guard let generation = request.migrationGeneration, !generation.isEmpty else {
            throw AgentMigrationControlError.generationRequired
        }
        var reportPath: String?
        switch request.reportPath {
        case .absent: break
        case .value(let value): reportPath = value
        case .invalid: throw AgentMigrationControlError.reportPathInvalid
        }
        var reportSha256: String?
        switch request.reportSha256 {
        case .absent: break
        case .value(let value): reportSha256 = value
        case .invalid: throw AgentMigrationControlError.reportSha256Invalid
        }

        let context = try unwrap(agents.arrivalContext(
            machineId: machineId,
            ref: migrationRef,
            generation: generation
        ))

        // Ask the source Computer to archive; a failure is retried in the
        // background and never terminalizes the post-flip migration.
        if let archiveCallback = machines.machineMigrationArchiveSourceWorkspace {
            do {
                try await archiveCallback(context.sourceMachineId, context.supportRef, context.agentId)
                agents.confirmSourceArchive(ref: context.supportRef, now: now())
            } catch {
                agents.recordSourceArchiveFailure(
                    ref: context.supportRef,
                    rawCode: MachineMigrationPolicy.migrationArchiveFailureCode(error),
                    now: now()
                )
            }
        } else {
            agents.recordSourceArchiveFailure(
                ref: context.supportRef,
                rawCode: "MIGRATION_SOURCE_WORKSPACE_ARCHIVE_UNAVAILABLE",
                now: now()
            )
        }

        let transition = try unwrap(agents.arrivalTransition(
            machineId: machineId,
            ref: migrationRef,
            generation: generation,
            reportPath: reportPath,
            reportSha256: reportSha256,
            now: now()
        ))
        let arrived: MachineMigrationRecord
        switch transition {
        case .settled(let record):
            return MigrationTargetViewResponse(record)
        case .dispatch(let record):
            arrived = record
        }
        // No configured orchestrator: the in-memory ledger has no daemon to
        // dispatch to, so arrival completes as it did before target start
        // dispatch became observable.
        guard let startCallback = machines.machineMigrationStartAgent else {
            return try completeAutoStart(ref: migrationRef)
        }
        let outcome: MachineMigrationAgentStartOutcome
        do {
            outcome = try await startCallback(arrived.agentId)
        } catch {
            return try recordAutoStartFailure(ref: migrationRef, code: "start_threw")
        }
        guard case .dispatched = outcome else {
            return try recordAutoStartFailure(ref: migrationRef, code: "start_not_dispatched")
        }
        return try completeAutoStart(ref: migrationRef)
    }

    private func recordAutoStartFailure(ref: String, code: String) throws -> MigrationTargetViewResponse {
        MigrationTargetViewResponse(try unwrap(agents.recordAutoStartFailure(
            ref: ref, stage: "start_agent", code: code, now: now()
        )))
    }

    /// Completion means the agent runs on the target. Source cleanup is tracked
    /// separately and never gates this transition.
    private func completeAutoStart(ref: String) throws -> MigrationTargetViewResponse {
        switch try unwrap(agents.completeAutoStart(ref: ref, nextGeneration: newGeneration(), now: now())) {
        case .unchanged(let record):
            return MigrationTargetViewResponse(record)
        case .completed(let record):
            dependencies.createMigrationReceiptDm(record.agentId, record.serverId, record.supportRef)
            return MigrationTargetViewResponse(record)
        }
    }

    /// `POST …/transport-lost`.
    public func markMigrationTransportLostFromComputer(
        authorization: String?,
        migrationRef: String,
        request: MigrationTransportLostRequest
    ) throws -> MigrationTargetViewResponse {
        let machineId = try requireComputerMachine(authorization)
        let code = request.code.flatMap {
            MachineMigrationPolicy.migrationTerminalFailureCodes.contains($0) ? $0 : nil
        } ?? "MIGRATION_TRANSPORT_LOST"
        let message = request.message.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        let detailCode = request.detailCode.flatMap { value in
            value.range(of: "^[A-Za-z0-9_:.-]{1,160}$", options: .regularExpression) != nil ? value : nil
        }
        let reportedGeneration = request.transportGeneration.flatMap { value in
            !value.isEmpty && value.count <= 200 ? value : nil
        }
        return MigrationTargetViewResponse(try unwrap(agents.markTransportLost(
            machineId: machineId,
            ref: migrationRef,
            code: code,
            message: message,
            detailCode: detailCode,
            reportedGeneration: reportedGeneration,
            now: now()
        )))
    }

    /// `POST …/cancel-ack`.
    public func acknowledgeMigrationCancellation(
        authorization: String?,
        migrationRef: String,
        request: MigrationCancelAckRequest
    ) throws -> MigrationCancelAckResponse {
        let machineId = try requireComputerMachine(authorization)
        guard let ref = request.migrationRef, !ref.isEmpty,
              let transportGeneration = request.transportGeneration, !transportGeneration.isEmpty,
              let cancelGeneration = request.cancelGeneration, !cancelGeneration.isEmpty,
              let role = request.role, role == "source" || role == "target",
              let outcome = request.outcome, ["cleaned", "stopped", "needs_attention"].contains(outcome)
        else { throw AgentMigrationControlError.cancelAckInputRequired }
        let view = try unwrap(agents.acknowledgeCancel(
            machineId: machineId,
            ref: migrationRef,
            ack: MachineMigrationCancelAck(
                supportRef: ref,
                transportGeneration: transportGeneration,
                cancelGeneration: cancelGeneration,
                role: role,
                outcome: outcome
            ),
            now: now()
        ))
        return MigrationCancelAckResponse(view)
    }

    /// `POST …/resumable/source-quiesced`.
    public func recordMigrationSourceQuiesced(
        authorization: String?,
        migrationRef: String,
        request: MigrationSourceQuiescedRequest
    ) throws -> MigrationSourceQuiescedResponse {
        let machineId = try requireComputerMachine(authorization)
        guard let receipt = request.receipt else { throw AgentMigrationControlError.sourceQuiesceReceiptRequired }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let receiptJSON = (try? encoder.encode(JSONValue.object(receipt)))
            .flatMap { String(data: $0, encoding: .utf8) }
        let view = try unwrap(agents.recordSourceQuiesced(
            machineId: machineId, ref: migrationRef, receiptJSON: receiptJSON
        ))
        return MigrationSourceQuiescedResponse(
            migrationGeneration: view.transportGeneration,
            leaseId: view.transportSessionId
        )
    }

    /// `POST …/resumable/source-progress`. The progress body is stored as sent.
    public func recordMigrationSourceProgress(
        authorization: String?,
        migrationRef: String,
        body: String
    ) throws -> MigrationSourceProgressResponse {
        let machineId = try requireComputerMachine(authorization)
        try unwrap(agents.recordSourceProgress(machineId: machineId, ref: migrationRef, body: body))
        let deadline = AgentMigrationTimestamps.string(now().addingTimeInterval(3600)) ?? ""
        return MigrationSourceProgressResponse(prepDeadlineAt: deadline)
    }

    // MARK: - Machine assignment

    /// `POST /api/agents/:id/assign-machine`.
    public func assignAgentMachine(
        authorization: String?,
        agentId: String,
        request: AgentAssignMachineRequest
    ) throws -> OkResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentMigrationControlError.unauthorized
        }
        guard let managed = oauth.agentManagementInfo(id: agentId), !managed.deleted else {
            throw AgentMigrationControlError.agentNotFound
        }
        guard let role = oauth.memberRole(serverId: managed.serverId, userId: userId) else {
            throw AgentMigrationControlError.notAMember
        }
        guard role == "owner" || role == "admin" || managed.creatorUserId == userId else {
            throw AgentMigrationControlError.forbidden
        }
        guard let info = oauth.agentRuntimeInfo(id: agentId) else {
            throw AgentMigrationControlError.agentMissing
        }
        if info.runtime == "external" { throw AgentMigrationControlError.externalCannotAssign }
        var machineId: String?
        switch request.machineId {
        case .missing: throw AgentMigrationControlError.machineIdRequired
        case .invalid: throw AgentMigrationControlError.machineIdInvalid
        case .unassign: machineId = nil
        case .machine(let value): machineId = value
        }
        if let machineId,
           BuiltinModelCatalogAdmission.catalogUnavailable(
               machines: machines, machineId: machineId, runtimeConfigJSON: info.runtimeConfigJSON
           ) {
            throw AgentMigrationControlError.builtinCatalogUnavailable
        }
        guard agents.assignMachine(agentId: agentId, machineId: machineId) else {
            throw AgentMigrationControlError.assignAlreadyInProgress
        }
        return OkResponse()
    }

    // MARK: - Agent credentials

    /// The session user's authority over one agent's credentials.
    private func credentialAuthority(
        _ authorization: String?,
        agentId: String
    ) throws -> OAuthLedger.AgentManagementInfo {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentMigrationControlError.unauthorized
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              let role = oauth.memberRole(serverId: info.serverId, userId: userId)
        else { throw AgentMigrationControlError.agentMissing }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            throw AgentMigrationControlError.insufficientRole
        }
        return info
    }

    /// `POST /api/agents/:id/credentials` (`201`, `Cache-Control: no-store`).
    public func issueAgentCredential(
        authorization: String?,
        agentId: String,
        request: AgentCredentialIssueRequest
    ) throws -> AgentCredentialIssuedResponse {
        let info = try credentialAuthority(authorization, agentId: agentId)
        guard info.runtime == "external" else { throw AgentMigrationControlError.agentNotExternal }
        let capabilities = request.scopes.isEmpty
            ? ["channels", "knowledge", "mentions", "reactions", "read", "send", "tasks"]
            : Array(Set(request.scopes)).sorted()
        let key = dependencies.mintAgentCredential(agentId, capabilities, "session-issued")
        return AgentCredentialIssuedResponse(
            credentialId: agents.credentialId(token: key) ?? "",
            apiKey: key,
            agentId: agentId,
            serverId: info.serverId,
            scopes: capabilities
        )
    }

    /// `GET /api/agents/:id/credentials` (`Cache-Control: no-store`).
    public func listAgentCredentials(
        authorization: String?,
        agentId: String
    ) throws -> AgentCredentialListResponse {
        _ = try credentialAuthority(authorization, agentId: agentId)
        let rows = agents.credentials(agentId: agentId).map { entry -> AgentCredentialRow in
            AgentCredentialRow(
                id: entry.credential.id,
                maskedToken: String(entry.token.prefix(14)) + "***",
                name: entry.credential.name,
                scopes: entry.credential.scopes.sorted(),
                createdAt: AgentMigrationTimestamps.string(entry.credential.createdAt) ?? "",
                lastUsedAt: AgentMigrationTimestamps.string(entry.credential.lastUsedAt),
                revokedAt: AgentMigrationTimestamps.string(entry.credential.revokedAt)
            )
        }
        return AgentCredentialListResponse(credentials: rows)
    }

    /// `DELETE /api/agents/:id/credentials/:credentialId` (`204`).
    public func revokeAgentCredential(
        authorization: String?,
        agentId: String,
        credentialId: String
    ) throws -> NoContentResponse {
        _ = try credentialAuthority(authorization, agentId: agentId)
        guard agents.revokeCredential(agentId: agentId, credentialId: credentialId, now: now()) else {
            throw AgentMigrationControlError.credentialNotFound
        }
        return NoContentResponse()
    }
}
