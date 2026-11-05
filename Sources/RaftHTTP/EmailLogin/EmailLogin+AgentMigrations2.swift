import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {


    public func getMigrationControlManifest(authorization: String?, migrationRef: String) -> HTTPReply {
        guard computerCredentialValid(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        lock.lock()
        let record = machineMigrations[migrationRef]
        lock.unlock()
        guard let record else {
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        guard let manifest = record.manifestJSON else {
            return Self.json(409, "{\"code\":\"migration_control_manifest_missing\",\"error\":\"Migration control manifest is not registered\"}")
        }
        return Self.json(200, "{\"manifest\":\(manifest)}")
    }

    public func putMigrationChunkReceipt(authorization: String?, migrationRef: String, chunkIndex: Int, body: String) -> HTTPReply {
        guard computerCredentialValid(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let sha = object["sha256"] as? String
        else {
            return Self.json(400, "{\"code\":\"migration_streamed_chunk_invalid\",\"error\":\"Streamed chunk is invalid\"}")
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef] else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        guard let manifest = record.manifestJSON, !record.manifestChunks.isEmpty else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_control_manifest_missing\",\"error\":\"Migration control manifest is not registered\"}")
        }
        _ = manifest
        guard let expected = record.manifestChunks[chunkIndex] else {
            lock.unlock()
            return Self.json(400, "{\"code\":\"migration_streamed_chunk_invalid\",\"error\":\"Streamed chunk is invalid\"}")
        }
        guard expected.sha256 == sha.lowercased() else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_chunk_receipt_mismatch\",\"error\":\"Migration chunk receipt does not match the active control manifest\"}")
        }
        record.chunkReceipts[chunkIndex] = sha.lowercased()
        machineMigrations[migrationRef] = record
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"chunkIndex\":\(chunkIndex),\"sha256\":\(jsonString(sha.lowercased()))}")
    }

    public func migrationChunkStatus(authorization: String?, migrationRef: String) -> HTTPReply {
        guard computerCredentialValid(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        lock.lock()
        let record = machineMigrations[migrationRef]
        lock.unlock()
        guard let record else {
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        guard !record.manifestChunks.isEmpty else {
            return Self.json(409, "{\"code\":\"migration_control_manifest_missing\",\"error\":\"Migration control manifest is not registered\"}")
        }
        let all = record.manifestChunks.keys.sorted()
        let received = all.filter { record.chunkReceipts[$0] != nil }
        let missing = all.filter { record.chunkReceipts[$0] == nil }
        return Self.json(200, "{\"chunks\":[\("\(all.map(String.init).joined(separator: ","))")],\"received\":[\("\(received.map(String.init).joined(separator: ","))")],\"missing\":[\("\(missing.map(String.init).joined(separator: ","))")]}")
    }

    public func completeMigrationUpload(authorization: String?, migrationRef: String) -> HTTPReply {
        guard computerCredentialValid(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef] else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        guard !record.manifestChunks.isEmpty else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_control_manifest_missing\",\"error\":\"Migration control manifest is not registered\"}")
        }
        let missing = record.manifestChunks.keys.filter { record.chunkReceipts[$0] == nil }.sorted()
        guard missing.isEmpty else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_chunks_missing\",\"error\":\"Migration chunks are still missing\",\"missing\":[\("\(missing.map(String.init).joined(separator: ","))")]}")
        }
        record.state = "transfer_complete"
        record.revision += 1
        machineMigrations[migrationRef] = record
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"state\":\"transfer_complete\"}")
    }

    func computerMachineId(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let key = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        return computers.first { $0.apiKey == key && $0.revokedAt == nil }?.machineId
    }



    func migrationTargetViewJSON(_ record: MachineMigrationRecord, targetMachineId: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func timestamp(_ date: Date?) -> String {
            date.map { jsonString(formatter.string(from: $0)) } ?? "null"
        }
        let failureReason = record.failureReason.map(jsonString) ?? "null"
        let transportErrorCode = record.transportErrorCode.map(jsonString) ?? "null"
        let transportErrorMessage = record.transportErrorMessage.map(jsonString) ?? "null"
        let autoStartFailureStage = record.autoStartFailureStage.map(jsonString) ?? "null"
        let autoStartFailureCode = record.autoStartFailureCode.map(jsonString) ?? "null"
        return "{\"migrationRef\":\(jsonString(record.supportRef)),\"agentId\":\(jsonString(record.agentId)),\"state\":\(jsonString(record.state)),\"migrationGeneration\":\(jsonString(record.transportGeneration)),\"sourceMachineId\":\(jsonString(record.sourceMachineId)),\"targetMachineId\":\(jsonString(targetMachineId)),\"canDriveTargetImport\":true,\"failureReason\":\(failureReason),\"transportErrorCode\":\(transportErrorCode),\"transportErrorMessage\":\(transportErrorMessage),\"autoStartFailureStage\":\(autoStartFailureStage),\"autoStartFailureCode\":\(autoStartFailureCode),\"completedAt\":\(timestamp(record.completedAt))}"
    }

    func migrationTargetReply(_ record: MachineMigrationRecord) -> HTTPReply {
        Self.json(200, "{\"ok\":true,\"migration\":\(migrationTargetViewJSON(record, targetMachineId: record.targetMachineId))}")
    }

    func isAgentHeldByTarget(_ record: MachineMigrationRecord) -> Bool {
        agentMachineIds[record.agentId] == record.targetMachineId
    }

    func migrationGeneration(from body: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let generation = object["migrationGeneration"] as? String, !generation.isEmpty
        else { return nil }
        return generation
    }

    public func getMigrationTargetView(authorization: String?, migrationRef: String) -> HTTPReply {
        guard let machineId = computerMachineId(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        lock.lock()
        let record = machineMigrations[migrationRef]
        lock.unlock()
        guard let record else {
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        guard record.targetMachineId == machineId else {
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        return migrationTargetReply(record)
    }

    public func startMigrationTransfer(authorization: String?, migrationRef: String, body: String) -> HTTPReply {
        guard let machineId = computerMachineId(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        guard let generation = migrationGeneration(from: body) else {
            return Self.json(400, "{\"code\":\"migration_generation_required\",\"error\":\"migrationGeneration is required\"}")
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef], record.targetMachineId == machineId else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        guard record.transportGeneration == generation else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_generation_stale\",\"error\":\"Migration generation is stale\"}")
        }
        guard record.state == "ready" else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_not_ready\",\"error\":\"Migration is not ready for transfer\"}")
        }
        record.previousTransportGeneration = record.transportGeneration
        record.state = "in_transit"
        record.transportGeneration = "generation-" + UUID().uuidString.lowercased()
        record.revision += 1
        record.updatedAt = Date()
        machineMigrations[migrationRef] = record
        lock.unlock()
        return migrationTargetReply(record)
    }

    /// A flip replayed after it already succeeded returns the current view: the
    /// generation it consumed is no longer current, but the callback is not a
    /// second transition.
    public func flipMigrationMachine(authorization: String?, migrationRef: String, body: String) -> HTTPReply {
        guard let machineId = computerMachineId(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        guard let generation = migrationGeneration(from: body) else {
            return Self.json(400, "{\"code\":\"migration_generation_required\",\"error\":\"migrationGeneration is required\"}")
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef], record.targetMachineId == machineId else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        if (record.state == "arriving" || record.state == "completed") && isAgentHeldByTarget(record) {
            lock.unlock()
            return migrationTargetReply(record)
        }
        guard record.transportGeneration == generation else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_generation_stale\",\"error\":\"Migration generation is stale\"}")
        }
        guard record.state == "in_transit" else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_not_flippable\",\"error\":\"Migration is not ready to flip\"}")
        }
        guard agentMachineIds[record.agentId] == record.sourceMachineId else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_source_machine_mismatch\",\"error\":\"Source machine no longer owns the agent\"}")
        }
        let now = Date()
        record.previousTransportGeneration = record.transportGeneration
        record.state = "arriving"
        record.flippedAt = now
        record.transportGeneration = "generation-" + UUID().uuidString.lowercased()
        record.revision += 1
        record.updatedAt = now
        agentMachineIds[record.agentId] = record.targetMachineId
        machineMigrations[migrationRef] = record
        lock.unlock()
        return migrationTargetReply(record)
    }

    /// Record a failed source-archive attempt. Deliberately does not bump
    /// `revision`: source cleanup is independent of the transfer state machine.
    func recordSourceArchiveFailure(migrationRef: String, code rawCode: String) {
        let code = rawCode.range(of: "^[A-Za-z0-9_:.-]{1,160}$", options: .regularExpression) != nil
            ? rawCode
            : "MIGRATION_SOURCE_WORKSPACE_ARCHIVE_FAILED"
        lock.lock()
        defer { lock.unlock() }
        guard var record = machineMigrations[migrationRef],
              record.sourceWorkspaceArchivedAt == nil,
              record.sourceWorkspaceArchiveAbandonedAt == nil
        else { return }
        let now = Date()
        record.sourceWorkspaceArchiveAttempts += 1
        let agentMoved = Self.migrationSourceArchiveMovedCodes.contains(code)
        let exhausted = agentMoved || record.sourceWorkspaceArchiveAttempts >= Self.migrationSourceArchiveMaxAttempts
        record.sourceWorkspaceArchiveLastError = agentMoved ? "agent_moved" : code
        record.sourceWorkspaceArchiveRetryAt = exhausted
            ? nil
            : now.addingTimeInterval(Self.migrationSourceArchiveBackoff(attempts: record.sourceWorkspaceArchiveAttempts))
        record.sourceWorkspaceArchiveAbandonedAt = exhausted ? now : nil
        record.updatedAt = now
        machineMigrations[migrationRef] = record
    }

    func recordAutoStartFailure(migrationRef: String, stage: String, code: String) -> HTTPReply {
        lock.lock()
        guard var record = machineMigrations[migrationRef] else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        if record.state == "starting" {
            record.failureReason = "auto_start_failed"
            record.autoStartFailureStage = stage
            record.autoStartFailureCode = code
            record.revision += 1
            record.updatedAt = Date()
            machineMigrations[migrationRef] = record
        }
        lock.unlock()
        return migrationTargetReply(record)
    }

    /// Target import arrival: confirm the idempotent source archive, move the row
    /// to `starting`, then dispatch the target start. An archive failure after
    /// the flip is recorded for the background retry and does not fail the
    /// migration; a failed/suppressed start keeps the arrival retryable.

    /// Phase 1 of the arrival callback: cheap validity check plus the input the
    /// source archive dispatch needs. The callback is idempotent once the
    /// authoritative archive is recorded and the target holds the agent.
    func migrationArrivalContext(
        machineId: String,
        migrationRef: String,
        generation: String
    ) -> (reply: HTTPReply?, context: MigrationArrivalContext?) {
        lock.lock()
        defer { lock.unlock() }
        guard let record = machineMigrations[migrationRef], record.targetMachineId == machineId else {
            return (Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}"), nil)
        }
        let archivableStates: Set<String> = ["arriving", "starting", "completed"]
        let archivedAndHeld = archivableStates.contains(record.state)
            && record.sourceWorkspaceArchivedAt != nil
            && isAgentHeldByTarget(record)
        if !archivedAndHeld {
            guard record.transportGeneration == generation else {
                return (Self.json(409, "{\"code\":\"migration_generation_stale\",\"error\":\"Migration generation is stale\"}"), nil)
            }
            guard archivableStates.contains(record.state) else {
                return (Self.json(409, "{\"code\":\"migration_not_arriving\",\"error\":\"Migration is not arriving\"}"), nil)
            }
            guard isAgentHeldByTarget(record) else {
                return (Self.json(409, "{\"code\":\"migration_source_machine_mismatch\",\"error\":\"Source machine no longer owns the agent\"}"), nil)
            }
        }
        return (nil, MigrationArrivalContext(
            supportRef: record.supportRef,
            sourceMachineId: record.sourceMachineId,
            agentId: record.agentId,
            archiveCallback: machineMigrationArchiveSourceWorkspace
        ))
    }

    func recordMigrationArchiveConfirmed(migrationRef: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = machineMigrations[migrationRef], current.sourceWorkspaceArchivedAt == nil else { return }
        current.sourceWorkspaceArchivedAt = Date()
        current.revision += 1
        current.updatedAt = Date()
        machineMigrations[migrationRef] = current
    }

    /// Phase 3: transition `arriving` to `starting`, or observe/reclaim an
    /// already-starting row so a replayed arrival callback is not a second
    /// transition.
    func migrationArrivalTransition(
        machineId: String,
        migrationRef: String,
        generation: String,
        reportPath: String?,
        reportSha256: String?
    ) -> (
        reply: HTTPReply?,
        arrived: MachineMigrationRecord?,
        dispatch: Bool,
        startCallback: (@Sendable (_ agentId: String) async throws -> MachineMigrationAgentStartOutcome)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = machineMigrations[migrationRef], current.targetMachineId == machineId else {
            return (Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}"), nil, false, nil)
        }
        if current.state == "completed" && isAgentHeldByTarget(current) {
            return (migrationTargetReply(current), nil, false, nil)
        }
        if current.state == "starting" && isAgentHeldByTarget(current) {
            if current.failureReason == nil {
                if Date() < current.updatedAt.addingTimeInterval(Self.migrationAutoStartLease) {
                    return (migrationTargetReply(current), nil, false, nil)
                }
                current.revision += 1
                current.updatedAt = Date()
            } else if current.failureReason != "auto_start_failed" {
                return (migrationTargetReply(current), nil, false, nil)
            } else {
                current.failureReason = nil
                current.revision += 1
                current.updatedAt = Date()
            }
        } else {
            guard current.transportGeneration == generation else {
                return (Self.json(409, "{\"code\":\"migration_generation_stale\",\"error\":\"Migration generation is stale\"}"), nil, false, nil)
            }
            guard current.state == "arriving" else {
                return (Self.json(409, "{\"code\":\"migration_not_arriving\",\"error\":\"Migration is not arriving\"}"), nil, false, nil)
            }
            guard isAgentHeldByTarget(current) else {
                return (Self.json(409, "{\"code\":\"migration_source_machine_mismatch\",\"error\":\"Source machine no longer owns the agent\"}"), nil, false, nil)
            }
            current.previousTransportGeneration = current.transportGeneration
            current.state = "starting"
            current.arrivedAt = Date()
            current.failureReason = nil
            current.autoStartFailureStage = nil
            current.autoStartFailureCode = nil
            current.arrivalReportPath = reportPath
            current.arrivalReportSha256 = reportSha256
            current.revision += 1
            current.updatedAt = Date()
        }
        machineMigrations[migrationRef] = current
        return (nil, current, true, machineMigrationStartAgent)
    }

    /// Phase 4: completion means the agent runs on the target. Source cleanup is
    /// tracked separately and never gates this transition.
    func completeMigrationAutoStart(migrationRef: String) -> HTTPReply {
        lock.lock()
        guard var completed = machineMigrations[migrationRef] else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        guard completed.state == "starting" else {
            lock.unlock()
            return migrationTargetReply(completed)
        }
        let now = Date()
        completed.state = "completed"
        completed.failureReason = nil
        completed.autoStartFailureStage = nil
        completed.autoStartFailureCode = nil
        completed.completedAt = now
        completed.transportTeardownAt = now
        completed.previousTransportGeneration = completed.transportGeneration
        completed.transportGeneration = "generation-" + UUID().uuidString.lowercased()
        completed.revision += 1
        completed.updatedAt = now
        agentMachineIds[completed.agentId] = completed.targetMachineId
        machineMigrations[migrationRef] = completed
        lock.unlock()
        createMigrationReceiptDm(agentId: completed.agentId, serverId: completed.serverId, supportRef: completed.supportRef)
        return migrationTargetReply(completed)
    }

    /// Target import arrival: confirm the idempotent source archive, move the row
    /// to `starting`, then dispatch the target start. An archive failure after
    /// the flip is recorded for the background retry and does not fail the
    /// migration; a failed or suppressed start keeps the arrival retryable.
    public func completeMigrationArrival(authorization: String?, migrationRef: String, body: String) async -> HTTPReply {
        guard let machineId = computerMachineId(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let generation = object["migrationGeneration"] as? String, !generation.isEmpty
        else {
            return Self.json(400, "{\"code\":\"migration_generation_required\",\"error\":\"migrationGeneration is required\"}")
        }
        var reportPath: String?
        if let path = object["reportPath"], !(path is NSNull) {
            guard let value = path as? String, !value.isEmpty else {
                return Self.json(400, "{\"code\":\"report_path_invalid\",\"error\":\"reportPath must be a non-empty string\"}")
            }
            reportPath = value
        }
        var reportSha256: String?
        if let sha = object["reportSha256"], !(sha is NSNull) {
            guard let value = sha as? String, !value.isEmpty else {
                return Self.json(400, "{\"code\":\"report_sha256_invalid\",\"error\":\"reportSha256 must be a non-empty string\"}")
            }
            reportSha256 = value
        }

        let preflight = migrationArrivalContext(machineId: machineId, migrationRef: migrationRef, generation: generation)
        if let reply = preflight.reply { return reply }
        guard let context = preflight.context else {
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }

        // Ask the source Computer to archive; a failure is retried in the
        // background and never terminalizes the post-flip migration.
        if let archiveCallback = context.archiveCallback {
            do {
                try await archiveCallback(context.sourceMachineId, context.supportRef, context.agentId)
                recordMigrationArchiveConfirmed(migrationRef: context.supportRef)
            } catch {
                recordSourceArchiveFailure(migrationRef: context.supportRef, code: Self.migrationArchiveFailureCode(error))
            }
        } else {
            recordSourceArchiveFailure(migrationRef: context.supportRef, code: "MIGRATION_SOURCE_WORKSPACE_ARCHIVE_UNAVAILABLE")
        }

        let transition = migrationArrivalTransition(
            machineId: machineId,
            migrationRef: migrationRef,
            generation: generation,
            reportPath: reportPath,
            reportSha256: reportSha256
        )
        if let reply = transition.reply { return reply }
        guard transition.dispatch, let arrived = transition.arrived else {
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        // No configured orchestrator: the in-memory ledger has no daemon to
        // dispatch to, so arrival completes as it did before target start
        // dispatch became observable. Tests that exercise the dispatch seam set
        // `machineMigrationStartAgent`.
        guard let startCallback = transition.startCallback else {
            return completeMigrationAutoStart(migrationRef: migrationRef)
        }
        let outcome: MachineMigrationAgentStartOutcome
        do {
            outcome = try await startCallback(arrived.agentId)
        } catch {
            return recordAutoStartFailure(migrationRef: migrationRef, stage: "start_agent", code: "start_threw")
        }
        guard case .dispatched = outcome else {
            return recordAutoStartFailure(migrationRef: migrationRef, stage: "start_agent", code: "start_not_dispatched")
        }
        return completeMigrationAutoStart(migrationRef: migrationRef)
    }

    public func markMigrationTransportLostFromComputer(authorization: String?, migrationRef: String, body: String) -> HTTPReply {
        guard let machineId = computerMachineId(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let reportedCode = object["code"] as? String
        let code = reportedCode.flatMap { Self.migrationTerminalFailureCodes.contains($0) ? $0 : nil } ?? "MIGRATION_TRANSPORT_LOST"
        let message = (object["message"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        let detailCode = (object["detailCode"] as? String).flatMap { value in
            value.range(of: "^[A-Za-z0-9_:.-]{1,160}$", options: .regularExpression) != nil ? value : nil
        }
        let reportedGeneration = (object["transportGeneration"] as? String).flatMap { value in
            !value.isEmpty && value.count <= 200 ? value : nil
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef],
              record.sourceMachineId == machineId || record.targetMachineId == machineId
        else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        // A replay of the same terminal reason is already persisted.
        if record.state == "failed" && record.failureReason == code {
            lock.unlock()
            return migrationTargetReply(record)
        }
        // A replaced run must not fail the current generation.
        if let reportedGeneration, record.transportGeneration != reportedGeneration {
            lock.unlock()
            return migrationTargetReply(record)
        }
        let activeStates: Set<String> = ["provisioning", "prep", "ready", "in_transit", "arriving", "starting"]
        guard activeStates.contains(record.state) else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_not_active\",\"error\":\"Migration is not active\"}")
        }
        let now = Date()
        record.state = "failed"
        record.revision += 1
        record.failureReason = code
        record.transportErrorCode = detailCode ?? code
        record.transportErrorMessage = message
        record.transportLostAt = now
        record.transportTeardownAt = now
        record.updatedAt = now
        machineMigrations[migrationRef] = record
        lock.unlock()
        return migrationTargetReply(record)
    }

    public func machineMigrationCancelGenerationsForTesting(migrationRef: String) -> (cancel: String, transport: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = machineMigrations[migrationRef],
              let cancel = record.cancelGeneration,
              let transport = record.cancelTransportGeneration
        else { return nil }
        return (cancel, transport)
    }

    public func seedMachineMigrationCancelStateForTesting(
        migrationRef: String,
        state: String,
        cancelGeneration: String,
        cancelTransportGeneration: String,
        disposition: String
    ) {
        lock.lock()
        if var record = machineMigrations[migrationRef] {
            record.state = state
            record.cancelGeneration = cancelGeneration
            record.cancelTransportGeneration = cancelTransportGeneration
            record.cancelDisposition = disposition
            machineMigrations[migrationRef] = record
        }
        lock.unlock()
    }

    public func acknowledgeMigrationCancellation(authorization: String?, migrationRef: String, body: String) -> HTTPReply {
        guard let machineId = computerMachineId(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let ref = object["migrationRef"] as? String, !ref.isEmpty,
              let transportGeneration = object["transportGeneration"] as? String, !transportGeneration.isEmpty,
              let cancelGeneration = object["cancelGeneration"] as? String, !cancelGeneration.isEmpty,
              let role = object["role"] as? String, role == "source" || role == "target",
              let outcome = object["outcome"] as? String, ["cleaned", "stopped", "needs_attention"].contains(outcome)
        else {
            return Self.json(400, "{\"code\":\"migration_cancel_ack_input_required\",\"error\":\"migrationRef, transportGeneration, cancelGeneration, role, and outcome are required\"}")
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef],
              record.supportRef == ref,
              record.serverId == record.serverId,
              (role == "source" ? record.sourceMachineId : record.targetMachineId) == machineId
        else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        guard record.cancelGeneration == cancelGeneration else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_cancel_generation_stale\",\"error\":\"Migration cancel generation is stale\"}")
        }
        guard record.cancelTransportGeneration == transportGeneration else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_generation_stale\",\"error\":\"Migration generation is stale\"}")
        }
        let cancellationStates: Set<String> = ["cancel_requested_pre_flip", "cancel_requested_post_flip", "canceled_pre_flip", "canceled_post_flip"]
        guard cancellationStates.contains(record.state), let disposition = record.cancelDisposition else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_cancel_not_requested\",\"error\":\"Migration cancellation was not requested\"}")
        }
        // Post-flip the target is authoritative: its successful outcome is
        // `stopped`, never `cleaned`. A `cleaned` target acknowledgement must not
        // terminalize the cancellation.
        let successOutcome = (disposition == "post_flip_target_authoritative" && role == "target") ? "stopped" : "cleaned"
        if outcome != "needs_attention" && outcome != successOutcome {
            lock.unlock()
            return Self.json(409, "{\"code\":\"migration_cancel_outcome_mismatch\",\"error\":\"Migration cancel outcome does not match the frozen disposition\"}")
        }
        let now = Date()
        if outcome == "needs_attention" {
            record.cancelErrorCode = record.cancelErrorCode ?? "cleanup_incomplete"
            record.updatedAt = now
            machineMigrations[migrationRef] = record
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"migration\":{\"migrationRef\":\(jsonString(record.supportRef)),\"state\":\(jsonString(record.state)),\"revision\":\(record.revision),\"disposition\":\(jsonString(disposition))}}")
        }
        let alreadyAcknowledged = role == "source" ? record.cancelSourceAckAt : record.cancelTargetAckAt
        if alreadyAcknowledged == nil {
            if role == "source" {
                record.cancelSourceAck = outcome
                record.cancelSourceAckAt = now
            } else {
                record.cancelTargetAck = outcome
                record.cancelTargetAckAt = now
            }
            let terminal = record.cancelSourceAckAt != nil && record.cancelTargetAckAt != nil
            if terminal {
                record.transportTeardownAt = now
                record.canceledAt = record.canceledAt ?? now
            }
            record.revision += 1
            record.updatedAt = now
            machineMigrations[migrationRef] = record
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"migration\":{\"migrationRef\":\(jsonString(record.supportRef)),\"state\":\(jsonString(record.state)),\"revision\":\(record.revision),\"disposition\":\(jsonString(disposition))}}")
    }

    public func recordMigrationSourceQuiesced(authorization: String?, migrationRef: String, body: String) -> HTTPReply {
        guard let machineId = computerMachineId(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let receipt = object["receipt"] as? [String: Any]
        else {
            return Self.json(400, "{\"code\":\"migration_source_quiesce_receipt_required\",\"error\":\"receipt is required\"}")
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef], record.sourceMachineId == machineId else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        record.quiesceReceiptJSON = (try? JSONSerialization.data(withJSONObject: receipt)).flatMap { String(data: $0, encoding: .utf8) }
        machineMigrations[migrationRef] = record
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"migrationGeneration\":\(jsonString(record.transportGeneration)),\"leaseId\":\(jsonString(record.transportSessionId))}")
    }

    public func recordMigrationSourceProgress(authorization: String?, migrationRef: String, body: String) -> HTTPReply {
        guard let machineId = computerMachineId(authorization) else {
            return Self.json(401, "{\"code\":\"migration_transport_token_invalid\",\"error\":\"Migration transport token is invalid\"}")
        }
        lock.lock()
        guard var record = machineMigrations[migrationRef], record.sourceMachineId == machineId else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"migration_missing\",\"error\":\"Migration not found\"}")
        }
        record.progressJSON = body
        machineMigrations[migrationRef] = record
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let deadline = jsonString(formatter.string(from: Date().addingTimeInterval(3600)))
        return Self.json(200, "{\"ok\":true,\"advanced\":true,\"prepDeadlineAt\":\(deadline)}")
    }

    func startHostedMigration(
        info: OAuthLedger.AgentManagementInfo,
        userId: String,
        serverId: String,
        target: [String: Any]
    ) -> HTTPReply {
        lock.lock()
        let hostedEnabled = hostedMigrationServers.contains(serverId)
        let runtimeEnabled = hostedRuntimeServers.contains(serverId)
        let picker = hostedModelPickerServers.contains(serverId)
        let existingHosted = hostedRuntimes[info.id] != nil
        let activeMigration = hostedMigrations[info.id]
        let machineId = agentMachineIds[info.id]
        lock.unlock()
        guard hostedEnabled else {
            return migrationError(403, "HOSTED_TARGET_UNAVAILABLE", "Moving agents to the cloud is not enabled on this server")
        }
        guard runtimeEnabled else {
            return migrationError(409, "HOSTED_TARGET_UNAVAILABLE", "Cloud agents are not enabled for this server")
        }
        let provider = target["provider"] as? String ?? "antiproton"
        guard provider == "antiproton" else {
            return migrationError(422, "HOSTED_TARGET_UNAVAILABLE", "Unknown cloud provider")
        }
        var hostedModel: String?
        if let raw = target["hostedModel"] {
            guard let value = raw as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 200
            else {
                return migrationError(400, "HOSTED_TARGET_MODEL_INVALID", "`target.hostedModel` must be a model id or null")
            }
            hostedModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard machineId != nil else {
            return migrationError(409, "AGENT_HAS_NO_SOURCE_MACHINE", "Agent has no source computer")
        }
        guard !existingHosted else {
            return migrationError(409, "HOSTED_TARGET_ALREADY_USED", "This agent has already run in the cloud")
        }
        if let activeMigration, activeMigration.state != "canceled" {
            return migrationError(409, "MIGRATION_ALREADY_IN_PROGRESS", "Agent already has an active migration")
        }
        if let hostedModel, hostedModel != Self.hostedDefaultModel, !picker {
            return migrationError(422, "HOSTED_TARGET_MODEL_INVALID", "This model cannot be used for a cloud agent here (picker_disabled)")
        }
        let supportRef = "mig_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(22))
        let record = HostedMigrationRecord(
            agentId: info.id,
            serverId: serverId,
            supportRef: supportRef,
            revision: 1,
            state: "preparing",
            sourceMachineId: machineId
        )
        lock.lock()
        hostedMigrations[info.id] = record
        lock.unlock()
        for member in oauth.memberIdsWithRoles(serverId: serverId) where member.role == "owner" || member.role == "admin" {
            emitRealtime("user:\(member.id)", "agent:migration-updated", migrationUpdatedJSON(record))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let deadline = jsonString(formatter.string(from: Date().addingTimeInterval(3600)))
        let source = record.sourceMachineId.map(jsonString) ?? "null"
        return Self.json(200, "{\"migrationRef\":\(jsonString(supportRef)),\"state\":\(jsonString(record.state)),\"targetKind\":\"hosted\",\"sourceMachineId\":\(source),\"targetMachineId\":null,\"prepDeadlineAt\":\(deadline),\"transferDeadlineAt\":\(deadline),\"arrivalDeadlineAt\":\(deadline)}")
    }

    public func assignAgentMachine(authorization: String?, agentId: String, body: String) -> HTTPReply {
        switch agentAuthority(authorization, agentId: agentId) {
        case .denied(let reply):
            return reply
        case .allowed:
            guard let info = oauth.agentRuntimeInfo(id: agentId) else {
                return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
            }
            if info.runtime == "external" {
                return Self.json(400, "{\"error\":\"External agents cannot be assigned to a Computer\"}")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
                  object.keys.contains("machineId")
            else {
                return Self.json(400, "{\"error\":\"machineId is required\"}")
            }
            var machineId: String?
            if let raw = object["machineId"], !(raw is NSNull) {
                guard let value = raw as? String, !value.isEmpty else {
                    return Self.json(400, "{\"error\":\"machineId must be a Computer id or null\"}")
                }
                machineId = value
            }
            if let machineId {
                let config = info.runtimeConfigJSON.flatMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8))
                } as? [String: Any] ?? [:]
                if builtinModelCheck(machineId: machineId, config: config) == .catalogUnavailable {
                    return builtinCatalogFailureReply()
                }
            }
            lock.lock()
            let active = machineMigrations.values.contains {
                $0.agentId == agentId && !["canceled_pre_flip", "completed", "aborted", "failed"].contains($0.state)
            } || hostedMigrations[agentId] != nil
            if active {
                lock.unlock()
                return Self.json(409, "{\"code\":\"MIGRATION_ALREADY_IN_PROGRESS\",\"error\":\"Agent already has an active migration\"}")
            }
            if let machineId {
                agentMachineIds[agentId] = machineId
            } else {
                agentMachineIds.removeValue(forKey: agentId)
            }
            lock.unlock()
            return Self.json(200, "{\"ok\":true}")
        }
    }

    public func issueAgentCredential(authorization: String?, agentId: String, body: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              let role = oauth.memberRole(serverId: info.serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"insufficient_role\",\"error\":\"issueAgentCredentials requires human creator authority\"}")
        }
        guard info.runtime == "external" else {
            return Self.json(400, "{\"code\":\"agent_not_external\",\"error\":\"Only external Agents get credentials\"}")
        }
        let requested = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let requestedScopes = (requested?["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []
        let capabilities = requestedScopes.isEmpty
            ? ["channels", "knowledge", "mentions", "reactions", "read", "send", "tasks"]
            : Array(Set(requestedScopes)).sorted()
        let key = mintAgentCredential(agentId: agentId, scopes: capabilities, name: "session-issued")
        lock.lock()
        let credentialId = agentCredentials[key]?.id ?? ""
        lock.unlock()
        var reply = Self.json(201, "{\"credentialId\":\(jsonString(credentialId)),\"apiKey\":\(jsonString(key)),\"agentId\":\(jsonString(agentId)),\"serverId\":\(jsonString(info.serverId)),\"scopes\":[\(capabilities.map { jsonString($0) }.joined(separator: ","))]}")
        reply.headers["Cache-Control"] = "no-store"
        return reply
    }

    public func listAgentCredentials(authorization: String?, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              let role = oauth.memberRole(serverId: info.serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"insufficient_role\",\"error\":\"issueAgentCredentials requires human creator authority\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let rows = agentCredentials
            .filter { $0.value.agentId == agentId }
            .map { key, credential -> String in
                let masked = String(key.prefix(14)) + "***"
                let created = jsonString(formatter.string(from: credential.createdAt))
                let used = credential.lastUsedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
                let revoked = credential.revokedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
                let scopes = credential.scopes.sorted().map { jsonString($0) }.joined(separator: ",")
                return "{\"id\":\(jsonString(credential.id)),\"maskedToken\":\(jsonString(masked)),\"name\":\(jsonString(credential.name)),\"scopes\":[\(scopes)],\"createdAt\":\(created),\"lastUsedAt\":\(used),\"revokedAt\":\(revoked)}"
            }
        lock.unlock()
        var reply = Self.json(200, "{\"credentials\":[\(rows.joined(separator: ","))]}")
        reply.headers["Cache-Control"] = "no-store"
        return reply
    }

    public func revokeAgentCredential(authorization: String?, agentId: String, credentialId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              let role = oauth.memberRole(serverId: info.serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"insufficient_role\",\"error\":\"issueAgentCredentials requires human creator authority\"}")
        }
        lock.lock()
        guard let token = agentCredentials.first(where: { $0.value.id == credentialId })?.key,
              agentCredentials[token]?.agentId == agentId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Credential not found\"}")
        }
        let existingRevocation = agentCredentials[token]?.revokedAt
        agentCredentials[token]?.revokedAt = existingRevocation ?? Date()
        lock.unlock()
        return HTTPReply(status: 204, headers: [:], body: "")
    }

    public func registerMachine(serverId: String, userId: String, name: String) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        machines.append(MachineRecord(
            id: id,
            serverId: serverId,
            userId: userId,
            name: name,
            description: nil,
            apiKey: Self.machineAPIKeyMaterial()
        ))
        lock.unlock()
        return id
    }

    public func machineRegistrantForTesting(machineId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return machines.first { $0.id == machineId }?.userId
    }

}
