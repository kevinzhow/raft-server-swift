import Foundation
import RaftShared

extension AgentExecutionDomain {
    func observeReady(_ context: AgentExecutionMachineContext, daemonInstanceId: String?, capabilities: [String]?,
                      runtimes: [String]?, runningAgentIds: [String]?, detectionComplete: Bool,
                      unreliableAgentIds: [String]) throws {
        try requireTransaction()
        guard ownsMachine(context) else { throw AgentExecutionError.ownershipMismatch }
        let reported = Set((runningAgentIds ?? []) + unreliableAgentIds)
        let owned = Set(reported.filter { (try? boundMachine(serverId: context.serverId, agentId: $0)) == context.machineId })
        let inventoryOwned = owned == reported
        // Read the assigned agents' authoritative status before the owner borrow;
        // the projection itself is written inside that borrow.
        let machineAgents = readyReconcileAgents(context)
        let now = Date()
        var presence = AgentPresenceReconcile()
        let outcome: Result<Void, any Error> = agents.withState { state in
            do {
                guard var connection = state.execution.connections[context.machineId], connection.online,
                      connection.serverId == context.serverId, connection.connectionEpochId == context.connectionEpochId else {
                    throw AgentExecutionError.staleConnection
                }
                connection.ready = false
                if let daemonInstanceId, !daemonInstanceId.isEmpty {
                    if let old = connection.daemonInstanceId, old != daemonInstanceId {
                        for key in Array(state.execution.agents.keys) where state.execution.agents[key]?.machineId == context.machineId {
                            if state.execution.agents[key]?.hasUnsettledExecution == true {
                                state.execution.agents[key]?.needsManual = "daemon_restarted_with_unsettled_execution"
                            }
                        }
                    }
                    connection.daemonInstanceId = daemonInstanceId
                }
                if let runtimes { connection.runtimes = Set(runtimes) }
                if let capabilities { connection.capabilities = Set(capabilities) }
                if let daemonInstanceId, !daemonInstanceId.isEmpty, let capabilities, let runtimes, let runningAgentIds,
                   detectionComplete, inventoryOwned, capabilities.allSatisfy({ !$0.isEmpty }), runtimes.allSatisfy({ !$0.isEmpty }),
                   runningAgentIds.allSatisfy({ !$0.isEmpty }) {
                    let required: Set<String> = ["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"]
                    connection.ready = runtimes.contains("codex") && required.isSubset(of: Set(capabilities))
                }
                for agentId in runningAgentIds ?? [] where owned.contains(agentId) {
                    var agent = state.execution.agents[agentId] ?? AgentExecutionAgent(serverId: context.serverId, machineId: context.machineId)
                    if !agent.processes.values.contains(where: { !$0.exited }) { agent.needsManual = "untracked_running_process" }
                    state.execution.agents[agentId] = agent
                }
                for agentId in unreliableAgentIds where owned.contains(agentId) {
                    var agent = state.execution.agents[agentId] ?? AgentExecutionAgent(serverId: context.serverId, machineId: context.machineId)
                    agent.needsManual = "daemon_outcome_storage_unreliable"
                    state.execution.agents[agentId] = agent
                }
                state.execution.connections[context.machineId] = connection
                reconcileConnectionRecovery(&state.execution, machineId: context.machineId,
                    connectionEpochId: context.connectionEpochId, daemonInstanceId: connection.daemonInstanceId,
                    runningAgentIds: runningAgentIds ?? [])
                // A complete ready is the daemon's current process inventory:
                // running agents become active/online, missing active agents stay
                // wakeable/online, inactive/stopped agents stay offline.
                if let runningAgentIds, daemonInstanceId != nil {
                    presence = reconcileReadyPresence(&state, context: context, machineAgents: machineAgents,
                                                       runningAgentIds: Set(runningAgentIds), now: now)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try outcome.get()
        applyReadyPresenceStatusUpdates(presence.statusUpdates)
        queuePresenceEmissions(presence.emissions)
    }

    /// Reconnect reconciliation for a recovery flag that was derived only from
    /// the lost connection. The daemon's complete ready frame is the real fact
    /// that it still holds this machine; a same-instance live process plus the
    /// retained owner state prove whether a delivery or turn is still
    /// unsettled. Only the two connection-history reasons are clearable, and
    /// only from facts already retained: no blanket reset and no other
    /// recovery reason.
    func reconcileConnectionRecovery(_ state: inout AgentExecutionState, machineId: String,
                                     connectionEpochId: String, daemonInstanceId: String?,
                                     runningAgentIds: [String]) {
        guard state.connections[machineId]?.ready == true,
              let daemonInstanceId, !daemonInstanceId.isEmpty else { return }
        let running = Set(runningAgentIds)
        for agentId in Array(state.agents.keys) {
            guard var agent = state.agents[agentId], agent.machineId == machineId else { continue }
            guard agent.needsManual == "connection_lost_with_unsettled_execution"
                    || agent.needsManual == "server_restarted_with_unsettled_execution" else { continue }
            guard let currentId = agent.currentLaunchId, let current = agent.launches[currentId] else { continue }
            // The current launch must be usable for the next delivery: a
            // completed turn starts a new launch, and an incomplete one must
            // have been admitted by the daemon.
            guard current.completed || current.notSpawned || current.terminalFailure
                    || current.startAccepted || current.processInstanceId != nil else { continue }
            // The daemon's report is the only reconnect fact that proves this
            // process survived; an absent report cannot be distinguished from
            // a process that the daemon lost track of.
            guard running.contains(agentId),
                  agent.processes.values.contains(where: { !$0.exited && $0.daemonInstanceId == daemonInstanceId })
            else { continue }
            guard !state.hasUnsettledDeliveryWrite(agentId: agentId),
                  !state.hasAcceptedTurnWithoutCompletion(agentId: agentId) else { continue }
            // A pending delivery with no dispatch record was never written:
            // upstream re-sends it on the new connection. Re-fence the command
            // to the current epoch; never touch a command with a dispatch row.
            for key in Array(state.commands.keys) {
                guard let command = state.commands[key], command.agentId == agentId,
                      command.kind == .delivery, command.status == .pending,
                      state.dispatches?[key] == nil else { continue }
                state.commands[key]?.connectionEpochId = connectionEpochId
            }
            agent.needsManual = nil
            state.agents[agentId] = agent
        }
    }

    /// Internal pending decision. Never expose this result to transport until
    /// BusinessPersistenceRuntime.execute has completed its fenced COMMIT.
    func stageIngress(context: AgentExecutionMachineContext, type: String, payload: Data) throws -> AgentExecutionIngressResult {
        try requireTransaction()
        guard AgentExecutionOutcomeFrame.supportsCanonicalNumbers(payload) else { return .hold(reason: "unsupported_numeric_representation") }
        if type == "agent:deliver:ack" { return try stageDeliveryAcknowledgement(context: context, payload: payload) }
        // The daemon's presence channel. Both frames are display/state facts,
        // not execution outcomes: they carry no durable ACK.
        if type == "agent:status" { return try stageReportedStatus(context: context, payload: payload) }
        if type == "agent:activity" { return try stageReportedActivity(context: context, payload: payload) }
        if type == "agent:session" || type == "agent:start:ack" {
            return try stageControl(context: context, type: type, payload: payload)
        }
        guard let frame = AgentExecutionOutcomeFrame.parse(type: type, payload: payload) else {
            return .hold(reason: "malformed_identity")
        }
        guard ownsMachine(context),
              (try? boundMachine(serverId: context.serverId, agentId: frame.agentId)) == context.machineId else {
            return .hold(reason: "ownership_mismatch")
        }
        let result: AgentExecutionIngressResult = try mutate { state in
            guard let connection = state.connections[context.machineId], connection.serverId == context.serverId else {
                return .hold(reason: "ownership_mismatch")
            }
            guard connection.online, connection.connectionEpochId == context.connectionEpochId else {
                return .hold(reason: "stale_connection")
            }
            var agent = state.agents[frame.agentId] ?? AgentExecutionAgent(serverId: context.serverId, machineId: context.machineId)
            guard agent.serverId == context.serverId, agent.machineId == context.machineId else { return .hold(reason: "ownership_mismatch") }
            let scope = AgentExecutionState.key(context.machineId, frame.agentId, frame.daemonInstanceId ?? "marker")
            let receipt = AgentExecutionState.key(scope, frame.gapId.map { "marker:\($0)" } ?? "sequence:\(frame.clientSeq!)")
            if let previous = state.receipts[receipt] {
                if previous == frame.fingerprint { return .committed(ack: frame.acknowledgement) }
                agent.needsManual = "conflicting_identity"
                state.agents[frame.agentId] = agent
                return .hold(reason: "conflicting_identity")
            }
            if let sequence = frame.clientSeq, let watermark = state.watermarks[scope], sequence <= watermark {
                // Missing historical fingerprint cannot authorize a guessed
                // re-application. Commit a lost-evidence decision, then ACK.
                agent.needsManual = "historical_receipt_unavailable"
            } else if let refusal = apply(frame, agent: &agent, state: state) {
                agent.needsManual = refusal
                state.agents[frame.agentId] = agent
                return .hold(reason: refusal)
            }
            state.agents[frame.agentId] = agent
            state.receipts[receipt] = frame.fingerprint
            if let sequence = frame.clientSeq {
                state.watermarks[scope] = max(state.watermarks[scope] ?? sequence, sequence)
            }
            if case .terminalFailure(let failedLaunch, _, _) = frame.event,
               agent.launches[failedLaunch]?.terminalFailure == true {
                // Retire only work proven never attempted. A dispatch record
                // may already represent a wire write, so preserve that history.
                for key in Array(state.commands.keys) {
                    guard let command = state.commands[key], command.kind == .delivery,
                          command.agentId == frame.agentId, command.serverId == context.serverId,
                          command.machineId == context.machineId, command.launchId == failedLaunch,
                          command.status == .pending, state.dispatches?[key] == nil else { continue }
                    state.commands[key]?.status = .superseded
                }
            }
            for key in Array(state.commands.keys) {
                guard let command = state.commands[key], command.kind == .start, command.agentId == frame.agentId,
                      let launch = agent.launches[command.launchId], launch.processInstanceId != nil || launch.startAccepted else { continue }
                state.commands[key]?.status = .accepted
                if var dispatches = state.dispatches, var dispatch = dispatches[key] {
                    dispatch.phase = .accepted
                    dispatches[key] = dispatch
                    state.dispatches = dispatches
                }
            }
            return .committed(ack: frame.acknowledgement)
        }
        if case .committed = result {
            let launchIds = agents.state.execution.agents[frame.agentId].map { Array($0.launches.keys) } ?? []
            for launchId in launchIds {
                _ = try agents.revokeRetiredMaterializationCredential(agentId: frame.agentId, launchId: launchId, at: Date())
            }
        }
        return result
    }

    private func apply(_ frame: AgentExecutionOutcomeFrame, agent: inout AgentExecutionAgent, state: AgentExecutionState) -> String? {
        switch frame.event {
        case .lost(let reason):
            agent.needsManual = reason
            return nil
        case .marker(let epoch, let critical):
            if critical && epoch >= agent.takeoverEpoch { agent.needsManual = "outcome_evidence_lost" }
            return nil
        default: break
        }
        let launchId: String
        switch frame.event {
        case .spawned(let launch, _, _, _), .exited(let launch, _, _), .rebound(let launch, _),
             .notSpawned(let launch, _), .terminalFailure(let launch, _, _), .turnCompleted(let launch, _, _):
            launchId = launch
        default: return nil
        }
        guard var launch = agent.launches[launchId], launch.daemonInstanceId == frame.daemonInstanceId else {
            return "launch_ownership_mismatch"
        }
        switch frame.event {
        case .spawned(_, let processId, let superseded, let respawn):
            guard !launch.notSpawned else { return "spawned_after_not_spawned" }
            guard superseded.allSatisfy({ agent.launches[$0]?.daemonInstanceId == frame.daemonInstanceId }) else {
                return "superseded_launch_ownership_mismatch"
            }
            guard processIsOwned(processId, frame: frame, agent: agent, state: state) else { return "process_ownership_mismatch" }
            if let existing = agent.processes[processId] {
                guard existing.daemonInstanceId == frame.daemonInstanceId, !existing.exited else { return "process_identity_conflict" }
            }
            if let previous = launch.processInstanceId, previous != processId, !respawn { return "process_identity_conflict" }
            var process = agent.processes[processId] ?? AgentExecutionProcess(
                processInstanceId: processId, daemonInstanceId: frame.daemonInstanceId!, spawnLaunchId: launchId, launchIds: [])
            process.launchIds.formUnion(superseded + [launchId])
            agent.processes[processId] = process
            launch.processInstanceId = processId
            for alias in superseded { agent.launches[alias]?.processInstanceId = processId }
        case .rebound(_, let processId):
            guard !launch.notSpawned else { return "rebound_after_not_spawned" }
            guard processIsOwned(processId, frame: frame, agent: agent, state: state) else { return "process_ownership_mismatch" }
            var process = agent.processes[processId] ?? AgentExecutionProcess(
                processInstanceId: processId, daemonInstanceId: frame.daemonInstanceId!, spawnLaunchId: nil, launchIds: [])
            guard !process.exited, process.daemonInstanceId == frame.daemonInstanceId else { return "process_identity_conflict" }
            process.launchIds.insert(launchId)
            agent.processes[processId] = process
            launch.processInstanceId = processId
            launch.startAccepted = true
        case .exited(_, let processId, let spawnLaunch):
            guard var process = agent.processes[processId], process.daemonInstanceId == frame.daemonInstanceId,
                  process.launchIds.contains(launchId), process.spawnLaunchId == spawnLaunch else {
                return "process_ownership_mismatch"
            }
            process.exited = true
            agent.processes[processId] = process
            if launch.generation == agent.generation, agent.currentLaunchId == launchId,
               !launch.completed && !launch.terminalFailure {
                agent.needsManual = "process_exited_without_turn_outcome"
            }
        case .notSpawned(_, let reason):
            guard launch.processInstanceId == nil, !launch.completed else { return "not_spawned_conflicts_with_process" }
            launch.notSpawned = true
            if launch.generation == agent.generation {
                if reason == "spawn_error" {
                    agent.backoffStep = min(agent.backoffStep + 1, 6)
                    agent.blockedUntil = Date().addingTimeInterval(min(6 * 3600, 300 * pow(2, Double(agent.backoffStep - 1))))
                } else if reason == "terminal_failure_needs_manual" || reason == "terminal_failure_outcome_storage_blocked" {
                    agent.needsManual = "daemon_refused_outcome_recovery"
                }
            }
        case .terminalFailure(_, _, let fingerprint):
            if !launch.terminalFailure && !launch.completed {
                // Historical outcomes remain real launch/exit evidence after
                // E3; they cannot update the new generation's breaker counts.
                launch.terminalFailure = true
                if launch.generation == agent.generation {
                    agent.failureCount += 1
                    agent.sameFingerprintCount = agent.sameFingerprint == fingerprint ? agent.sameFingerprintCount + 1 : 1
                    agent.sameFingerprint = fingerprint
                    if agent.probeLaunchId == launchId || agent.sameFingerprintCount >= 2 || agent.failureCount >= 3 {
                        if agent.probeLaunchId == launchId { agent.backoffStep = min(agent.backoffStep + 1, 2) }
                        let backoffs: [TimeInterval] = [3600, 4 * 3600, 24 * 3600]
                        agent.blockedUntil = Date().addingTimeInterval(backoffs[min(agent.backoffStep, 2)])
                        agent.probeLaunchId = nil
                        agent.probeExpiresAt = nil
                    }
                }
            }
        case .turnCompleted(_, let session, let catchupBatchId):
            if !launch.terminalFailure {
                if launch.generation == agent.generation {
                    if let session, let persisted = agent.sessionId, session != persisted { return "session_identity_conflict" }
                    agent.failureCount = 0
                    agent.sameFingerprint = nil
                    agent.sameFingerprintCount = 0
                    agent.backoffStep = 0
                    agent.blockedUntil = nil
                    agent.probeLaunchId = nil
                    agent.probeExpiresAt = nil
                    if catchupBatchId != nil {
                        // This implementation has not issued a catchup coverage
                        // batch. Never pretend an unowned echo settled unread work.
                        agent.needsManual = "unowned_catchup_batch"
                    }
                }
                launch.completed = true
            }
        default: break
        }
        agent.launches[launchId] = launch
        return nil
    }

    private func processIsOwned(_ processId: String, frame: AgentExecutionOutcomeFrame,
                                agent: AgentExecutionAgent, state: AgentExecutionState) -> Bool {
        !state.agents.contains { key, other in
            key != frame.agentId && other.machineId == agent.machineId
                && other.processes[processId]?.daemonInstanceId == frame.daemonInstanceId
        }
    }

    private enum ReportedStatusDecision: Sendable, Equatable {
        case staleConnection
        case ignore
        case persist(String)
    }

    private enum ReportedActivityDecision: Sendable, Equatable {
        case staleConnection
        case staleLaunch
        case written(Int)
    }

    /// `agent:status` is the daemon's sequenced process-state channel. Its
    /// persisted projection is the agent's `status` (active/inactive), except
    /// that a manual `stopped` intent can only be cleared by a human start.
    private func stageReportedStatus(context: AgentExecutionMachineContext, payload: Data) throws -> AgentExecutionIngressResult {
        guard let body = AgentExecutionOutcomeFrame.object(payload),
              AgentExecutionOutcomeFrame.string(body["type"]) == "agent:status",
              let agentId = AgentExecutionOutcomeFrame.id(body["agentId"]),
              let rawStatus = AgentExecutionOutcomeFrame.string(body["status"]),
              let reported = AgentPresenceSignal.reportedStatus(rawStatus),
              validOptionalIdentity(body["launchId"]),
              validOptionalIdentity(body["daemonInstanceId"]),
              body["clientSeq"] == nil || AgentExecutionOutcomeFrame.count(body["clientSeq"]) != nil,
              ownsMachine(context),
              let current = oauth.agentRuntimeInfo(id: agentId), !current.deleted,
              current.serverId == context.serverId,
              (try? boundMachine(serverId: context.serverId, agentId: agentId)) == context.machineId else {
            return .hold(reason: "malformed_status")
        }
        let launchId = AgentExecutionOutcomeFrame.id(body["launchId"])
        let frameInstanceId = AgentExecutionOutcomeFrame.id(body["daemonInstanceId"])
        let frameSequence = AgentExecutionOutcomeFrame.count(body["clientSeq"])
        let decision: ReportedStatusDecision = try agents.withState { state -> Result<ReportedStatusDecision, any Error> in
            guard let connection = state.execution.connections[context.machineId], connection.online,
                  connection.serverId == context.serverId,
                  connection.connectionEpochId == context.connectionEpochId else {
                return .success(.staleConnection)
            }
            // RFC 069 §8: sequenced status frames are ordered per daemon
            // process. A frame from another process, or at or below the last
            // accepted sequence for this one, is a replay and is ignored.
            var nextVersion: (daemonInstanceId: String, clientSeq: Int64)?
            switch AgentPresenceSignal.sequencedStatus(
                frameDaemonInstanceId: frameInstanceId, frameClientSeq: frameSequence,
                connectionDaemonInstanceId: connection.daemonInstanceId,
                last: state.sequencedStatusVersions[agentId]) {
            case .staleInstance, .staleSequence:
                return .success(.ignore)
            case .unsequenced:
                break
            case .accept(let daemonInstanceId, let clientSeq):
                nextVersion = (daemonInstanceId, clientSeq)
            }
            // A launch that is not the agent's current launch is stale. An
            // absent current launch (e.g. restored state without execution) or
            // an unsequenced legacy frame keeps the accept path.
            if let launchId, let currentLaunch = state.execution.agents[agentId]?.currentLaunchId, currentLaunch != launchId {
                return .success(.ignore)
            }
            guard let next = AgentPresenceSignal.nextPersistedStatus(reported: reported, persisted: current.status) else {
                return .success(.ignore)
            }
            // Only an accepted frame consumes its sequence; a launch-guarded
            // frame must not mask the frame that follows it.
            if let nextVersion { state.sequencedStatusVersions[agentId] = nextVersion }
            return .success(.persist(next))
        }.get()
        switch decision {
        case .staleConnection:
            return .hold(reason: "stale_connection")
        case .ignore:
            return .committed(ack: nil)
        case .persist(let next):
            if current.status != next { oauth.setAgentStatus(id: agentId, status: next) }
            agents.withState { $0.serverAgents[agentId]?.status = next }
            return .committed(ack: nil)
        }
    }

    /// `agent:activity` is the live-activity channel. The activity kind is
    /// derived from the canonical `detailKind`; the frame never carries an
    /// authoritative producer conclusion. Retained state is process presence
    /// (`agentActivities`), and the post-commit Socket.IO push is queued below.
    private func stageReportedActivity(context: AgentExecutionMachineContext, payload: Data) throws -> AgentExecutionIngressResult {
        guard let body = AgentExecutionOutcomeFrame.object(payload),
              AgentExecutionOutcomeFrame.string(body["type"]) == "agent:activity",
              let agentId = AgentExecutionOutcomeFrame.id(body["agentId"]),
              body["detail"] == nil || AgentExecutionOutcomeFrame.string(body["detail"]) != nil,
              body["detailKind"] == nil || body["detailKind"] == .null || AgentExecutionOutcomeFrame.string(body["detailKind"]) != nil,
              body["activityKind"] == nil || body["activityKind"] == .null || AgentExecutionOutcomeFrame.string(body["activityKind"]) != nil,
              body["activity"] == nil || body["activity"] == .null || AgentExecutionOutcomeFrame.string(body["activity"]) != nil,
              validOptionalIdentity(body["launchId"]),
              validOptionalIdentity(body["probeId"]),
              validOptionalIdentity(body["producerFactId"]),
              body["clientSeq"] == nil || AgentExecutionOutcomeFrame.count(body["clientSeq"]) != nil,
              body["isHeartbeat"] == nil || body["isHeartbeat"] == .bool(true) || body["isHeartbeat"] == .bool(false),
              let signal = AgentPresenceSignal.activity(
                detailKind: AgentExecutionOutcomeFrame.string(body["detailKind"]),
                legacyActivity: AgentExecutionOutcomeFrame.string(body["activityKind"])
                    ?? AgentExecutionOutcomeFrame.string(body["activity"])
              ),
              ownsMachine(context),
              let current = oauth.agentRuntimeInfo(id: agentId), !current.deleted,
              current.serverId == context.serverId,
              (try? boundMachine(serverId: context.serverId, agentId: agentId)) == context.machineId else {
            return .hold(reason: "malformed_activity")
        }
        // A manual stop suppresses daemon activity, matching the lifecycle
        // planner; the process is not an operator-visible state change.
        guard current.status != "stopped" else { return .committed(ack: nil) }
        let detail = AgentExecutionOutcomeFrame.string(body["detail"]) ?? ""
        let launchId = AgentExecutionOutcomeFrame.id(body["launchId"])
        let clientSeq = AgentExecutionOutcomeFrame.count(body["clientSeq"])
        let now = Date()
        let nowMilliseconds = Int((now.timeIntervalSince1970 * 1000).rounded(.down))
        let decision = agents.withState { state -> ReportedActivityDecision in
            guard let connection = state.execution.connections[context.machineId], connection.online,
                  connection.serverId == context.serverId,
                  connection.connectionEpochId == context.connectionEpochId else {
                return .staleConnection
            }
            if let launchId, let currentLaunch = state.execution.agents[agentId]?.currentLaunchId, currentLaunch != launchId {
                return .staleLaunch
            }
            state.agentActivities[agentId] = (activity: signal.activity, detail: detail)
            state.agentActivityDetailKind[agentId] = signal.detailKind
            state.agentActivityObservedAt[agentId] = now
            // Upstream's `nextActivityServerSeq`: wall-clock milliseconds,
            // bumped monotonically for out-of-order socket dedupe.
            let sequence = max(nowMilliseconds, state.agentActivityServerSeq + 1)
            state.agentActivityServerSeq = sequence
            return .written(sequence)
        }
        switch decision {
        case .staleConnection:
            return .hold(reason: "stale_connection")
        case .staleLaunch:
            return .committed(ack: nil)
        case .written(let sequence):
            var fields: [OrderedJSONField] = [
                OrderedJSONField("agentId", agentId),
                OrderedJSONField("activity", signal.activity),
                OrderedJSONField("activityKind", signal.activity),
                OrderedJSONField("detail", detail),
                OrderedJSONField("detailKind", signal.detailKind),
                OrderedJSONField("timestamp", nowMilliseconds),
                OrderedJSONField("serverSeq", sequence),
            ]
            if let launchId { fields.append(OrderedJSONField("launchId", launchId)) }
            if let clientSeq { fields.append(OrderedJSONField("clientSeq", Int(clientSeq))) }
            if let probeId = AgentExecutionOutcomeFrame.id(body["probeId"]) { fields.append(OrderedJSONField("probeId", probeId)) }
            if let fact = AgentExecutionOutcomeFrame.id(body["producerFactId"]) { fields.append(OrderedJSONField("producerFactId", fact)) }
            if case .bool(let heartbeat)? = body["isHeartbeat"] { fields.append(OrderedJSONField("isHeartbeat", heartbeat)) }
            let rendered = OrderedJSON.object(fields).render()
            DeferredEffects.emit {
                RealtimeRelayService(messages: self.messages)
                    .emit("server:\(context.serverId)", "agent:activity", rendered)
            }
            return .committed(ack: nil)
        }
    }

    /// An optional wire identity must be absent, null, or a nonempty string.
    private func validOptionalIdentity(_ value: JSONValue?) -> Bool {
        value == nil || value == .null || AgentExecutionOutcomeFrame.id(value) != nil
    }

    private func stageDeliveryAcknowledgement(context: AgentExecutionMachineContext, payload: Data) throws -> AgentExecutionIngressResult {
        guard let body = AgentExecutionOutcomeFrame.object(payload), AgentExecutionOutcomeFrame.string(body["type"]) == "agent:deliver:ack",
              let agentId = AgentExecutionOutcomeFrame.id(body["agentId"]),
              let deliveryId = AgentExecutionOutcomeFrame.id(body["deliveryId"]),
              let sequence = AgentExecutionOutcomeFrame.count(body["seq"]), ownsMachine(context),
              (try? boundMachine(serverId: context.serverId, agentId: agentId)) == context.machineId else {
            return .hold(reason: "malformed_delivery_ack")
        }
        return try mutate { state in
            guard let connection = state.connections[context.machineId], connection.online,
                  connection.serverId == context.serverId, connection.connectionEpochId == context.connectionEpochId else {
                return .hold(reason: "stale_connection")
            }
            guard let match = state.commands.first(where: { $0.value.kind == .delivery && $0.value.agentId == agentId && $0.value.deliveryId == deliveryId }),
                  match.value.serverId == context.serverId, match.value.machineId == context.machineId,
                  match.value.connectionEpochId == context.connectionEpochId,
                  var dispatches = state.dispatches, var dispatch = dispatches[match.key],
                  dispatch.connectionEpochId == context.connectionEpochId else { return .hold(reason: "unowned_delivery_ack") }
            guard dispatch.deliverySequence == sequence else {
                state.agents[agentId]?.needsManual = "conflicting_delivery_ack"
                return .hold(reason: "conflicting_delivery_ack")
            }
            dispatch.phase = .accepted
            dispatches[match.key] = dispatch
            state.dispatches = dispatches
            state.commands[match.key]?.status = .accepted
            // The accepted delivery settles its queued offline send; the
            // canonical message row keeps the history.
            if var pending = state.pendingHumanDeliveries {
                let commandId = match.value.commandId
                pending = pending.filter { $0.value.releasedCommandId != commandId }
                state.pendingHumanDeliveries = pending.isEmpty ? nil : pending
            }
            return .committed(ack: nil)
        }
    }

    private func stageControl(context: AgentExecutionMachineContext, type: String, payload: Data) throws -> AgentExecutionIngressResult {
        guard let body = AgentExecutionOutcomeFrame.object(payload), AgentExecutionOutcomeFrame.string(body["type"]) == type,
              let agentId = AgentExecutionOutcomeFrame.id(body["agentId"]), ownsMachine(context),
              (try? boundMachine(serverId: context.serverId, agentId: agentId)) == context.machineId else {
            return .hold(reason: "ownership_mismatch")
        }
        return try mutate { state in
            guard let connection = state.connections[context.machineId], connection.online,
                  connection.connectionEpochId == context.connectionEpochId else { return .hold(reason: "stale_connection") }
            guard var agent = state.agents[agentId],
                  let launchId = AgentExecutionOutcomeFrame.id(body["launchId"]), launchId == agent.currentLaunchId,
                  var launch = agent.launches[launchId] else { return .hold(reason: "launch_ownership_mismatch") }
            if type == "agent:session" {
                guard !(state.resetIntents ?? [:]).values.contains(where: {
                    $0.serverId == context.serverId && $0.agentId == agentId && $0.phase.isActive && $0.priorLaunchId == launchId
                }) else { return .hold(reason: "reset_session_fenced") }
                guard let session = AgentExecutionOutcomeFrame.id(body["sessionId"]) else { return .hold(reason: "malformed_session") }
                agent.sessionId = session
            } else {
                guard launch.connectionEpochId == context.connectionEpochId,
                      AgentExecutionOutcomeFrame.string(body["startDispatchId"]) == launch.startDispatchId,
                      let queueState = AgentExecutionOutcomeFrame.string(body["queueState"]),
                      AgentExecutionOutcomeFrame.count(body["queueDepth"]) != nil,
                      AgentExecutionOutcomeFrame.count(body["queueAgeMs"]) != nil,
                      ["queued", "starting", "running", "rebound"].contains(queueState) else {
                    return .hold(reason: "start_dispatch_mismatch")
                }
                // Admission ACK is not evidence of a process, turn, posted
                // message, task completion, or cursor/catchup advancement.
                launch.startAccepted = true
                for key in Array(state.commands.keys) where state.commands[key]?.startDispatchId == launch.startDispatchId {
                    state.commands[key]?.status = .accepted
                    if var dispatches = state.dispatches, var dispatch = dispatches[key] {
                        dispatch.phase = .accepted
                        dispatches[key] = dispatch
                        state.dispatches = dispatches
                    }
                }
            }
            agent.launches[launchId] = launch
            state.agents[agentId] = agent
            return .committed(ack: nil)
        }
    }
}
