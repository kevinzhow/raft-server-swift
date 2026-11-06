import Foundation

// MARK: - Migration transport (AgentHostedMigrationService)

/// Why a migration transport callback did not apply. The service maps each case
/// to its published refusal.
enum MachineMigrationTransportFailure: Error, Sendable, Equatable {
    case migrationMissing
    case controlManifestMissing
    case chunkInvalid
    case chunkReceiptMismatch
    case chunksMissing([Int])
    case generationStale
    case notReady
    case notFlippable
    case sourceMachineMismatch
    case notArriving
    case notActive
    case cancelGenerationStale
    case cancelNotRequested
    case cancelOutcomeMismatch
    case manifestConflict
}

/// What the source-archive dispatch of an arrival callback needs.
struct MachineMigrationArrivalContext: Sendable, Equatable {
    let supportRef: String
    let sourceMachineId: String
    let agentId: String
}

/// The result of the arrival transition: either a settled row to publish, or a
/// row that moved to `starting` and now needs its target start dispatched.
enum MachineMigrationArrivalOutcome: Sendable {
    case settled(MachineMigrationRecord)
    case dispatch(MachineMigrationRecord)
}

/// The auto-start completion: `completed` only the first time.
enum MachineMigrationAutoStartOutcome: Sendable {
    case completed(MachineMigrationRecord)
    case unchanged(MachineMigrationRecord)
}

/// The frozen cancellation facts one acknowledgement publishes.
struct MachineMigrationCancelAckView: Sendable, Equatable {
    let supportRef: String
    let state: String
    let revision: Int
    let disposition: String
}

/// The lease facts the source quiesce receipt answers with.
struct MachineMigrationQuiesceView: Sendable, Equatable {
    let transportGeneration: String
    let transportSessionId: String
}

/// One cancel acknowledgement as the target/source Computer reported it.
struct MachineMigrationCancelAck: Sendable {
    let supportRef: String
    let transportGeneration: String
    let cancelGeneration: String
    let role: String
    let outcome: String
}

extension AgentsRuntimeStore {
    private static let terminalMachineMigrationStates: Set<String> = [
        "canceled_pre_flip", "completed", "aborted", "failed",
    ]

    private static func hasActiveMigrationLocked(state: inout State, agentId: String) -> Bool {
        state.machineMigrations.values.contains {
            $0.agentId == agentId && !Self.terminalMachineMigrationStates.contains($0.state)
        } || state.hostedMigrations[agentId] != nil
    }

    func machineMigration(ref: String) -> MachineMigrationRecord? {
        return withState { state in
            return state.machineMigrations[ref]
        }
    }

    /// Whether the agent has a Computer migration that has not reached a
    /// terminal state, or any hosted migration row.
    func hasActiveMigration(agentId: String) -> Bool {
        return withState { state in
            return Self.hasActiveMigrationLocked(state: &state, agentId: agentId)
        }
    }

    /// The assignment write guarded by the active-migration check, one critical
    /// section. `false` when an active migration owns the agent.
    func assignMachine(agentId: String, machineId: String?) -> Bool {
        return withState { state in
            if Self.hasActiveMigrationLocked(state: &state, agentId: agentId) { return false }
            if let machineId {
                state.agentMachineIds[agentId] = machineId
            } else {
                state.agentMachineIds.removeValue(forKey: agentId)
            }
            return true
        }
    }

    /// Inserts a freshly provisioned Computer migration unless one became
    /// active since the caller's early check. One critical section.
    func insertMachineMigrationIfIdle(_ record: MachineMigrationRecord) -> Bool {
        return withState { state in
            if Self.hasActiveMigrationLocked(state: &state, agentId: record.agentId) { return false }
            state.machineMigrations[record.supportRef] = record
            return true
        }
    }

    /// Stores the control manifest and its parsed chunk table. A manifest that
    /// differs from the registered one conflicts; presence and write share the
    /// lock.
    func putControlManifest(
        ref: String,
        body: String,
        chunks: [Int: (sha256: String, sizeBytes: Int)]
    ) -> Result<Void, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref] else { return .failure(.migrationMissing) }
            if let existing = record.manifestJSON, existing != body { return .failure(.manifestConflict) }
            record.manifestJSON = body
            record.manifestChunks = chunks
            if record.chunkReceipts.isEmpty { record.chunkReceipts = [:] }
            state.machineMigrations[ref] = record
            return .success(())
        }
    }

    /// Records one chunk receipt against the registered manifest.
    func recordChunkReceipt(
        ref: String,
        chunkIndex: Int,
        sha256: String
    ) -> Result<Void, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref] else { return .failure(.migrationMissing) }
            guard record.manifestJSON != nil, !record.manifestChunks.isEmpty else {
                return .failure(.controlManifestMissing)
            }
            guard let expected = record.manifestChunks[chunkIndex] else { return .failure(.chunkInvalid) }
            guard expected.sha256 == sha256 else { return .failure(.chunkReceiptMismatch) }
            record.chunkReceipts[chunkIndex] = sha256
            state.machineMigrations[ref] = record
            return .success(())
        }
    }

    /// `transfer_complete` once every manifest chunk has a receipt. The missing
    /// check and the state write share one critical section.
    func completeUpload(ref: String) -> Result<Void, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref] else { return .failure(.migrationMissing) }
            guard !record.manifestChunks.isEmpty else { return .failure(.controlManifestMissing) }
            let missing = record.manifestChunks.keys.filter { record.chunkReceipts[$0] == nil }.sorted()
            guard missing.isEmpty else { return .failure(.chunksMissing(missing)) }
            record.state = "transfer_complete"
            record.revision += 1
            state.machineMigrations[ref] = record
            return .success(())
        }
    }

    /// The target Computer's read of its own row.
    func targetMigration(
        ref: String,
        machineId: String
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        return withState { state in
            guard let record = state.machineMigrations[ref], record.targetMachineId == machineId else {
                return .failure(.migrationMissing)
            }
            return .success(record)
        }
    }

    /// `ready` to `in_transit`: ownership, generation and state checks and the
    /// write are one critical section, so two concurrent starts cannot both
    /// consume the generation.
    func startTransfer(
        ref: String,
        machineId: String,
        generation: String,
        nextGeneration: String,
        now: Date
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref], record.targetMachineId == machineId else {
                return .failure(.migrationMissing)
            }
            guard record.transportGeneration == generation else { return .failure(.generationStale) }
            guard record.state == "ready" else { return .failure(.notReady) }
            record.previousTransportGeneration = record.transportGeneration
            record.state = "in_transit"
            record.transportGeneration = nextGeneration
            record.revision += 1
            record.updatedAt = now
            state.machineMigrations[ref] = record
            return .success(record)
        }
    }

    /// `in_transit` to `arriving`: the row transition and the agent's machine
    /// binding move together. A replay after the flip returns the current row.
    func flipMachine(
        ref: String,
        machineId: String,
        generation: String,
        nextGeneration: String,
        now: Date
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref], record.targetMachineId == machineId else {
                return .failure(.migrationMissing)
            }
            if (record.state == "arriving" || record.state == "completed")
                && state.agentMachineIds[record.agentId] == record.targetMachineId {
                return .success(record)
            }
            guard record.transportGeneration == generation else { return .failure(.generationStale) }
            guard record.state == "in_transit" else { return .failure(.notFlippable) }
            guard state.agentMachineIds[record.agentId] == record.sourceMachineId else {
                return .failure(.sourceMachineMismatch)
            }
            record.previousTransportGeneration = record.transportGeneration
            record.state = "arriving"
            record.flippedAt = now
            record.transportGeneration = nextGeneration
            record.revision += 1
            record.updatedAt = now
            state.agentMachineIds[record.agentId] = record.targetMachineId
            state.machineMigrations[ref] = record
            return .success(record)
        }
    }

    /// Records a failed source-archive attempt. It does not bump `revision`:
    /// source cleanup is independent of the transfer state machine.
    func recordSourceArchiveFailure(ref: String, rawCode: String, now: Date) {
        let code = rawCode.range(of: "^[A-Za-z0-9_:.-]{1,160}$", options: .regularExpression) != nil
            ? rawCode
            : "MIGRATION_SOURCE_WORKSPACE_ARCHIVE_FAILED"
        return withState { state in
            guard var record = state.machineMigrations[ref],
                  record.sourceWorkspaceArchivedAt == nil,
                  record.sourceWorkspaceArchiveAbandonedAt == nil
            else { return }
            record.sourceWorkspaceArchiveAttempts += 1
            let agentMoved = MachineMigrationPolicy.migrationSourceArchiveMovedCodes.contains(code)
            let exhausted = agentMoved
                || record.sourceWorkspaceArchiveAttempts >= MachineMigrationPolicy.migrationSourceArchiveMaxAttempts
            record.sourceWorkspaceArchiveLastError = agentMoved ? "agent_moved" : code
            record.sourceWorkspaceArchiveRetryAt = exhausted
                ? nil
                : now.addingTimeInterval(
                    MachineMigrationPolicy.migrationSourceArchiveBackoff(attempts: record.sourceWorkspaceArchiveAttempts)
                )
            record.sourceWorkspaceArchiveAbandonedAt = exhausted ? now : nil
            record.updatedAt = now
            state.machineMigrations[ref] = record
        }
    }

    /// Stamps the source archive confirmation once.
    func confirmSourceArchive(ref: String, now: Date) {
        return withState { state in
            guard var current = state.machineMigrations[ref], current.sourceWorkspaceArchivedAt == nil else { return }
            current.sourceWorkspaceArchivedAt = now
            current.revision += 1
            current.updatedAt = now
            state.machineMigrations[ref] = current
        }
    }

    /// Records a failed target start while the row is `starting`; any other
    /// state leaves the row unchanged. Returns the row either way.
    func recordAutoStartFailure(
        ref: String,
        stage: String,
        code: String,
        now: Date
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref] else { return .failure(.migrationMissing) }
            if record.state == "starting" {
                record.failureReason = "auto_start_failed"
                record.autoStartFailureStage = stage
                record.autoStartFailureCode = code
                record.revision += 1
                record.updatedAt = now
                state.machineMigrations[ref] = record
            }
            return .success(record)
        }
    }

    /// Phase 1 of the arrival callback: the cheap validity check plus the input
    /// the source archive dispatch needs. Idempotent once the archive is
    /// recorded and the target holds the agent.
    func arrivalContext(
        machineId: String,
        ref: String,
        generation: String
    ) -> Result<MachineMigrationArrivalContext, MachineMigrationTransportFailure> {
        return withState { state in
            guard let record = state.machineMigrations[ref], record.targetMachineId == machineId else {
                return .failure(.migrationMissing)
            }
            let archivableStates: Set<String> = ["arriving", "starting", "completed"]
            let held = state.agentMachineIds[record.agentId] == record.targetMachineId
            let archivedAndHeld = archivableStates.contains(record.state)
                && record.sourceWorkspaceArchivedAt != nil
                && held
            if !archivedAndHeld {
                guard record.transportGeneration == generation else { return .failure(.generationStale) }
                guard archivableStates.contains(record.state) else { return .failure(.notArriving) }
                guard held else { return .failure(.sourceMachineMismatch) }
            }
            return .success(MachineMigrationArrivalContext(
                supportRef: record.supportRef,
                sourceMachineId: record.sourceMachineId,
                agentId: record.agentId
            ))
        }
    }

    /// Phase 3: `arriving` to `starting`, or observe or reclaim an
    /// already-starting row so a replayed arrival is not a second transition.
    func arrivalTransition(
        machineId: String,
        ref: String,
        generation: String,
        reportPath: String?,
        reportSha256: String?,
        now: Date
    ) -> Result<MachineMigrationArrivalOutcome, MachineMigrationTransportFailure> {
        return withState { state in
            guard var current = state.machineMigrations[ref], current.targetMachineId == machineId else {
                return .failure(.migrationMissing)
            }
            let held = state.agentMachineIds[current.agentId] == current.targetMachineId
            if current.state == "completed" && held {
                return .success(.settled(current))
            }
            if current.state == "starting" && held {
                if current.failureReason == nil {
                    if now < current.updatedAt.addingTimeInterval(MachineMigrationPolicy.migrationAutoStartLease) {
                        return .success(.settled(current))
                    }
                    current.revision += 1
                    current.updatedAt = now
                } else if current.failureReason != "auto_start_failed" {
                    return .success(.settled(current))
                } else {
                    current.failureReason = nil
                    current.revision += 1
                    current.updatedAt = now
                }
            } else {
                guard current.transportGeneration == generation else { return .failure(.generationStale) }
                guard current.state == "arriving" else { return .failure(.notArriving) }
                guard held else { return .failure(.sourceMachineMismatch) }
                current.previousTransportGeneration = current.transportGeneration
                current.state = "starting"
                current.arrivedAt = now
                current.failureReason = nil
                current.autoStartFailureStage = nil
                current.autoStartFailureCode = nil
                current.arrivalReportPath = reportPath
                current.arrivalReportSha256 = reportSha256
                current.revision += 1
                current.updatedAt = now
            }
            state.machineMigrations[ref] = current
            return .success(.dispatch(current))
        }
    }

    /// Phase 4: the agent runs on the target. The row transition and the
    /// machine binding are one critical section.
    func completeAutoStart(
        ref: String,
        nextGeneration: String,
        now: Date
    ) -> Result<MachineMigrationAutoStartOutcome, MachineMigrationTransportFailure> {
        return withState { state in
            guard var completed = state.machineMigrations[ref] else { return .failure(.migrationMissing) }
            guard completed.state == "starting" else { return .success(.unchanged(completed)) }
            completed.state = "completed"
            completed.failureReason = nil
            completed.autoStartFailureStage = nil
            completed.autoStartFailureCode = nil
            completed.completedAt = now
            completed.transportTeardownAt = now
            completed.previousTransportGeneration = completed.transportGeneration
            completed.transportGeneration = nextGeneration
            completed.revision += 1
            completed.updatedAt = now
            state.agentMachineIds[completed.agentId] = completed.targetMachineId
            state.machineMigrations[ref] = completed
            return .success(.completed(completed))
        }
    }

    /// A Computer's transport-lost report. A replay of the same terminal reason
    /// and a report for a replaced generation return the current row.
    func markTransportLost(
        machineId: String,
        ref: String,
        code: String,
        message: String?,
        detailCode: String?,
        reportedGeneration: String?,
        now: Date
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref],
                  record.sourceMachineId == machineId || record.targetMachineId == machineId
            else { return .failure(.migrationMissing) }
            if record.state == "failed" && record.failureReason == code { return .success(record) }
            if let reportedGeneration, record.transportGeneration != reportedGeneration { return .success(record) }
            let activeStates: Set<String> = ["provisioning", "prep", "ready", "in_transit", "arriving", "starting"]
            guard activeStates.contains(record.state) else { return .failure(.notActive) }
            record.state = "failed"
            record.revision += 1
            record.failureReason = code
            record.transportErrorCode = detailCode ?? code
            record.transportErrorMessage = message
            record.transportLostAt = now
            record.transportTeardownAt = now
            record.updatedAt = now
            state.machineMigrations[ref] = record
            return .success(record)
        }
    }

    /// One cancel acknowledgement from the source or the target. The generation
    /// checks, the frozen-disposition outcome check and the acknowledgement
    /// stamp are one critical section.
    func acknowledgeCancel(
        machineId: String,
        ref: String,
        ack: MachineMigrationCancelAck,
        now: Date
    ) -> Result<MachineMigrationCancelAckView, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref],
                  record.supportRef == ack.supportRef,
                  (ack.role == "source" ? record.sourceMachineId : record.targetMachineId) == machineId
            else { return .failure(.migrationMissing) }
            guard record.cancelGeneration == ack.cancelGeneration else { return .failure(.cancelGenerationStale) }
            guard record.cancelTransportGeneration == ack.transportGeneration else {
                return .failure(.generationStale)
            }
            let cancellationStates: Set<String> = [
                "cancel_requested_pre_flip", "cancel_requested_post_flip", "canceled_pre_flip", "canceled_post_flip",
            ]
            guard cancellationStates.contains(record.state), let disposition = record.cancelDisposition else {
                return .failure(.cancelNotRequested)
            }
            // Post-flip the target is authoritative: its successful outcome is
            // `stopped`, never `cleaned`.
            let successOutcome = (disposition == "post_flip_target_authoritative" && ack.role == "target")
                ? "stopped"
                : "cleaned"
            if ack.outcome != "needs_attention" && ack.outcome != successOutcome {
                return .failure(.cancelOutcomeMismatch)
            }
            if ack.outcome == "needs_attention" {
                record.cancelErrorCode = record.cancelErrorCode ?? "cleanup_incomplete"
                record.updatedAt = now
                state.machineMigrations[ref] = record
            } else {
                let alreadyAcknowledged = ack.role == "source" ? record.cancelSourceAckAt : record.cancelTargetAckAt
                if alreadyAcknowledged == nil {
                    if ack.role == "source" {
                        record.cancelSourceAck = ack.outcome
                        record.cancelSourceAckAt = now
                    } else {
                        record.cancelTargetAck = ack.outcome
                        record.cancelTargetAckAt = now
                    }
                    if record.cancelSourceAckAt != nil && record.cancelTargetAckAt != nil {
                        record.transportTeardownAt = now
                        record.canceledAt = record.canceledAt ?? now
                    }
                    record.revision += 1
                    record.updatedAt = now
                    state.machineMigrations[ref] = record
                }
            }
            return .success(MachineMigrationCancelAckView(
                supportRef: record.supportRef,
                state: record.state,
                revision: record.revision,
                disposition: disposition
            ))
        }
    }

    /// Stores the source quiesce receipt for the source Computer's row.
    func recordSourceQuiesced(
        machineId: String,
        ref: String,
        receiptJSON: String?
    ) -> Result<MachineMigrationQuiesceView, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref], record.sourceMachineId == machineId else {
                return .failure(.migrationMissing)
            }
            record.quiesceReceiptJSON = receiptJSON
            state.machineMigrations[ref] = record
            return .success(MachineMigrationQuiesceView(
                transportGeneration: record.transportGeneration,
                transportSessionId: record.transportSessionId
            ))
        }
    }

    /// Stores the source progress body for the source Computer's row.
    func recordSourceProgress(
        machineId: String,
        ref: String,
        body: String
    ) -> Result<Void, MachineMigrationTransportFailure> {
        return withState { state in
            guard var record = state.machineMigrations[ref], record.sourceMachineId == machineId else {
                return .failure(.migrationMissing)
            }
            record.progressJSON = body
            state.machineMigrations[ref] = record
            return .success(())
        }
    }
}
