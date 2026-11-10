import Foundation
import RaftShared

extension AgentExecutionDomain {
    /// Node applyTerminalLift for runtime_config_changed. This is not human
    /// takeover: retain needs-manual, all process/launch evidence, native session
    /// and takeover epoch. Missing execution state never creates a placeholder.
    func liftTerminalForConfigChange(serverId: String, agentId: String, runtimeValuesChanged: Bool) throws {
        try requireTransaction()
        _ = try ownedAgent(serverId: serverId, agentId: agentId)
        guard runtimeValuesChanged else { return }
        try mutate { state in
            guard var agent = state.agents[agentId] else { return }
            guard agent.serverId == serverId else { throw AgentExecutionError.ownershipMismatch }
            guard agent.generation < 9_007_199_254_740_991 else { throw AgentExecutionError.manualRecoveryRequired }
            agent.generation += 1
            agent.failureCount = 0; agent.sameFingerprint = nil; agent.sameFingerprintCount = 0
            agent.backoffStep = 0; agent.blockedUntil = nil; agent.probeLaunchId = nil; agent.probeExpiresAt = nil
            agent.currentLaunchId = nil
            state.agents[agentId] = agent
        }
    }

    /// Settings are admitted by the existing PATCH authority. Preserve the old
    /// launch before a config lift clears it, then bind the reset to the lifted
    /// generation in this same owner/transaction. A missing mode never creates
    /// an intent, clears a native session or starts a process.
    func applyRuntimeConfigurationChange(serverId: String, agentId: String,
                                         runtimeValuesChanged: Bool,
                                         restartMode: AgentExecutionResetMode?) throws {
        try requireTransaction()
        let info = try ownedAgent(serverId: serverId, agentId: agentId)
        guard runtimeValuesChanged || restartMode != nil else { return }
        let before = agents.state.execution
        let active = (before.resetIntents ?? [:]).values.first {
            $0.serverId == serverId && $0.agentId == agentId && $0.phase.isActive
        }
        if let active {
            // Never rebase a granted/unknown physical attempt or a changed
            // authority merely because a second settings request arrived.
            guard active.phase != .held, !active.hasUnconfirmedControl,
                  newerStopRevokingReset(active, state: before) == nil,
                  !agents.hasActiveMigration(agentId: agentId),
                  let machine = active.machineId,
                  (try? boundMachine(serverId: serverId, agentId: agentId)) == machine,
                  let agent = before.agents[agentId], agent.machineId == machine,
                  agent.serverId == serverId, agent.generation == active.expectedGeneration,
                  agent.takeoverEpoch == active.expectedTakeoverEpoch,
                  agent.currentLaunchId == active.expectedLaunchId else {
                throw AgentExecutionError.manualRecoveryRequired
            }
            if let epoch = active.connectionEpochId {
                guard before.connections[machine]?.connectionEpochId == epoch,
                      active.daemonInstanceId == before.connections[machine]?.daemonInstanceId else {
                    throw AgentExecutionError.staleConnection
                }
            }
        }
        let priorLaunch = before.agents[agentId]?.currentLaunchId
        try liftTerminalForConfigChange(serverId: serverId, agentId: agentId,
                                        runtimeValuesChanged: runtimeValuesChanged)
        if var intent = active {
            if let restartMode {
                let strongerSession = restartMode == .session && intent.mode == .restart
                if var policy = intent.policy {
                    if runtimeValuesChanged && policy.terminalControl == .none {
                        policy.terminalControl = .runtimeConfigChanged
                    }
                    policy.sessionRequired = policy.sessionRequired || strongerSession
                    intent.policy = policy
                } else if strongerSession {
                    // Keep an existing public human control authoritative.
                    intent.policy = .init(terminalControl: .humanReset, sessionRequired: true)
                }
            }
            try mutate { state in
                if intent.policy != nil { state.agents[agentId]?.currentLaunchId = nil }
                intent.expectedGeneration = state.agents[agentId]?.generation ?? intent.expectedGeneration
                intent.expectedLaunchId = state.agents[agentId]?.currentLaunchId
                state.resetIntents?[intent.operationId.uuidString] = intent
            }
            // A written stop remains written. Session strengthening after that
            // predecessor uses its one publication id; it never resends stop.
            if intent.stopAttempt == .written, intent.effectiveMode != .restart, !intent.sessionCleared {
                try clearResetSessionAfterWrittenStop(intent.operationId)
            }
            return
        }
        guard let restartMode else { return }
        let policy = AgentExecutionResetPolicy(terminalControl: runtimeValuesChanged ? .runtimeConfigChanged : .none)
        _ = try requestReset(.init(serverId: serverId, agentId: agentId, mode: restartMode,
            restart: info.status != "stopped", policy: policy), priorLaunchId: priorLaunch)
    }

    func hasActiveReset(serverId: String, agentId: String) -> Bool {
        (agents.state.execution.resetIntents ?? [:]).values.contains {
            $0.serverId == serverId && $0.agentId == agentId && $0.phase.isActive
        }
    }

    func stageReset(_ reference: AgentExecutionResetReference) throws {
        do {
            try DeferredEffects.persist(kind: "agent.execution", payload: JSONEncoder().encode(reference), effectID: reference.phaseId)
        } catch { DeferredEffects.markRollbackOnly(); throw AgentExecutionError.dispatchUnavailable }
    }

    func requestReset(_ request: AgentExecutionResetRequest, priorLaunchId: String? = nil) throws -> AgentExecutionResetAdmission {
        try requireTransaction()
        let info = try ownedAgent(serverId: request.serverId, agentId: request.agentId)
        guard info.runtime != "external" else { throw AgentExecutionError.invalidRequest }
        let snapshot = agents.state.execution
        if let previous = snapshot.resetIntents?[request.operationId.uuidString] {
            guard previous.serverId == request.serverId, previous.agentId == request.agentId,
                  previous.mode == request.mode, previous.restart == request.restart else { throw AgentExecutionError.conflictingCommand }
            return previous.admission
        }
        if let active = (snapshot.resetIntents ?? [:]).values.first(where: { $0.serverId == request.serverId && $0.agentId == request.agentId && $0.phase.isActive }) {
            guard active.phase != .held else { throw AgentExecutionError.manualRecoveryRequired }
            return active.admission // Node coalesces the already-running reset.
        }
        guard !agents.hasActiveMigration(agentId: request.agentId) else { throw AgentMigrationControlError.resetMigrationInProgress }
        guard snapshot.commands[request.operationId.uuidString] == nil,
              snapshot.stopIntents?[request.operationId.uuidString] == nil,
              snapshot.heldDeliveries?[request.operationId.uuidString] == nil else { throw AgentExecutionError.conflictingCommand }
        // As in the fenced Stop delta, no surviving owned target means local
        // facts only. A stale/foreign binding never authorizes reset I/O.
        var machine = agents.agentMachineIds[request.agentId].flatMap { assigned in
            machines.machines.contains { $0.id == assigned && $0.serverId == request.serverId } ? assigned : nil
        }
        let current = snapshot.agents[request.agentId]
        if let current, current.machineId != machine { machine = nil }
        if let current {
            guard current.serverId == request.serverId, machine.map({ $0 == current.machineId }) ?? true else { throw AgentExecutionError.ownershipMismatch }
        }
        if machine != nil && request.restart && info.runtime != "codex" { throw AgentExecutionError.invalidRequest }
        let intent = AgentExecutionResetIntent(operationId: request.operationId, serverId: request.serverId,
            agentId: request.agentId, machineId: machine, mode: request.mode, restart: request.restart,
            createdAt: Date(), stopPhaseId: UUID(), workspacePhaseId: UUID(), restartPhaseId: UUID(),
            startCommandId: UUID(), sessionPublicationId: UUID(), priorLaunchId: priorLaunchId ?? current?.currentLaunchId,
            expectedLaunchId: request.policy == nil ? current?.currentLaunchId : nil,
            priorStopIntentIds: Set((snapshot.stopIntents ?? [:]).values.filter { $0.agentId == request.agentId }.map(\.commandId)),
            priorStatus: info.status, expectedGeneration: current?.generation ?? 0,
            expectedTakeoverEpoch: current?.takeoverEpoch ?? 0, connectionEpochId: nil, daemonInstanceId: nil,
            phase: machine == nil ? .localOnly : .stop, policy: request.policy)
        let resetAdmitted = agents.mutateExecutionIfMigrationIdle(agentId: request.agentId) { state in
            if let machine, state.agents[request.agentId] == nil {
                state.agents[request.agentId] = AgentExecutionAgent(serverId: request.serverId, machineId: machine)
            }
            if let launch = intent.priorLaunchId {
                state.agents[request.agentId]?.launches[launch]?.stopRequested = true
            }
            if request.policy != nil {
                // Non-E3 admission fencing: the intentional old exit/session
                // must not be mistaken for a failure of the current launch.
                // Preserve generation, breaker/manual/takeover and process facts.
                state.agents[request.agentId]?.currentLaunchId = nil
            }
            // Keep attempted rows and all dispatch history. Only never-attempted
            // pending delivery work is held for a later separately fenced start.
            var held = state.heldDeliveries ?? [:]
            for (key, command) in state.commands where command.agentId == request.agentId && command.status == .pending {
                if command.kind == .delivery, state.dispatches?[key] == nil, held[key] == nil,
                   let channel = command.channelId, let message = command.messageId {
                    held[key] = AgentExecutionHeldDelivery(commandId: command.commandId, serverId: command.serverId,
                        agentId: command.agentId, channelId: channel, messageId: message, createdAt: command.createdAt)
                } else if command.kind == .start, state.dispatches?[key] == nil {
                    state.commands[key]?.status = .superseded
                }
            }
            state.heldDeliveries = held.isEmpty ? state.heldDeliveries : held
            var resets = state.resetIntents ?? [:]
            resets[intent.operationId.uuidString] = intent
            state.resetIntents = resets
        }
        guard resetAdmitted else { throw AgentMigrationControlError.resetMigrationInProgress }
        do {
            try retireKnownCredentials(agentId: request.agentId)
            if machine == nil {
                try liftAndClearReset(intent.operationId)
            } else {
                // No public manual Stop, manual-stop intent or stop status.
                setIntentStatus(agentId: request.agentId, status: "inactive")
                try stageReset(intent.reference(.stop))
            }
        } catch { DeferredEffects.markRollbackOnly(); throw error }
        return intent.admission
    }

    /// The first stop-written/local-only transition retains its original
    /// selected terminal effect. Ordinary model PATCH still has the route lift,
    /// this reset lift, and the later canonical start's generation increment.
    func liftAndClearReset(_ operation: UUID) throws {
        try mutate { state in
            guard var intent = state.resetIntents?[operation.uuidString] else { throw AgentExecutionError.invalidRequest }
            if var agent = state.agents[intent.agentId] {
                if intent.usesHumanStart {
                    guard agent.generation < 9_007_199_254_740_991 else { throw AgentExecutionError.manualRecoveryRequired }
                    agent.generation += 1
                    agent.failureCount = 0; agent.sameFingerprint = nil; agent.sameFingerprintCount = 0
                    agent.backoffStep = 0; agent.blockedUntil = nil; agent.probeLaunchId = nil; agent.probeExpiresAt = nil
                }
                // Preserve needs-manual and all unexited facts. Only the later
                // canonical human_start may acknowledge takeover of those facts.
                agent.currentLaunchId = nil
                intent.expectedGeneration = agent.generation
                intent.expectedLaunchId = nil
                state.agents[intent.agentId] = agent
            }
            state.resetIntents?[operation.uuidString] = intent
        }
        try clearResetSession(operation)
    }

    /// A later settings transaction may strengthen an already-written stop.
    /// Its stop receipt and selected terminal transition committed together;
    /// attempting/ambiguous control permission is never sufficient evidence.
    /// Only the remaining session transition is allowed, with no second E3.
    func clearResetSessionAfterWrittenStop(_ operation: UUID) throws {
        try requireTransaction()
        let state = agents.state.execution
        guard let intent = state.resetIntents?[operation.uuidString],
              intent.stopAttempt == .written, !intent.hasUnconfirmedControl,
              intent.phase == .restart || intent.phase == .workspace,
              intent.effectiveMode != .restart,
              newerStopRevokingReset(intent, state: state) == nil else {
            throw AgentExecutionError.invalidRequest
        }
        try clearResetSession(operation)
    }

    /// This shared session-only effect never changes terminal or launch facts.
    /// The one publication identity and sessionCleared flag make retries inert.
    private func clearResetSession(_ operation: UUID) throws {
        let changed = try mutate { state -> (AgentExecutionResetIntent, Bool) in
            guard var intent = state.resetIntents?[operation.uuidString] else { throw AgentExecutionError.invalidRequest }
            let publishSession = intent.effectiveMode != .restart && !intent.sessionCleared
            if publishSession {
                state.agents[intent.agentId]?.sessionId = nil
                intent.sessionCleared = true
                state.resetIntents?[operation.uuidString] = intent
            }
            return (intent, publishSession)
        }
        let intent = changed.0
        let status = intent.effectiveMode != .restart && intent.priorStatus == "stopped" ? "stopped" : "inactive"
        setIntentStatus(agentId: intent.agentId, status: status)
        if changed.1 {
            let payload = OrderedJSONObject([.init("agentId", intent.agentId), .init("sessionId", .null)]).json.render()
            let publication = RealtimePublication(eventId: intent.sessionPublicationId, room: "server:\(intent.serverId)",
                                                  event: "agent:session", payloadJSON: payload)
            try DeferredEffects.persist(kind: "realtime.publish", payload: JSONEncoder().encode(publication), effectID: publication.eventId)
        }
    }

    func newerStopRevokingReset(_ intent: AgentExecutionResetIntent, state: AgentExecutionState) -> UUID? {
        (state.stopIntents ?? [:]).values.filter {
            $0.serverId == intent.serverId && $0.agentId == intent.agentId && !intent.priorStopIntentIds.contains($0.commandId)
        }.sorted { $0.commandId.uuidString < $1.commandId.uuidString }.first?.commandId
    }

    /// Commit revocation before any worker may settle an unsent claim. A durable
    /// attempt permission is not proof that the socket did not write.
    func reconcileReset(_ reference: AgentExecutionResetReference) throws -> AgentExecutionResetResolution {
        try requireTransaction()
        let resolution = try resolveReset(reference)
        guard resolution == .cancelled else { return resolution }
        return try mutate { state in
            guard var intent = state.resetIntents?[reference.resetOperationId.uuidString], intent.reference(reference.phase) == reference else {
                throw AgentExecutionError.invalidRequest
            }
            if intent.phase == .cancelled { return .cancelled }
            guard intent.phase.isActive, !intent.hasUnconfirmedControl,
                  let stop = newerStopRevokingReset(intent, state: state), state.commands[intent.startCommandId.uuidString] == nil else {
                throw AgentExecutionError.conflictingCommand
            }
            intent.phase = .cancelled
            intent.cancelledByStopId = stop
            intent.holdReason = nil
            state.resetIntents?[intent.operationId.uuidString] = intent
            return .cancelled
        }
    }

    func resetFence(_ intent: AgentExecutionResetIntent, context: AgentExecutionMachineContext, state: AgentExecutionState) -> Bool {
        guard intent.machineId == context.machineId, intent.serverId == context.serverId,
              let connection = state.connections[context.machineId], connection.online,
              connection.serverId == context.serverId, connection.connectionEpochId == context.connectionEpochId,
              let agent = state.agents[intent.agentId], agent.serverId == intent.serverId, agent.machineId == context.machineId,
              agent.takeoverEpoch == intent.expectedTakeoverEpoch, agent.generation == intent.expectedGeneration,
              agent.currentLaunchId == intent.expectedLaunchId else { return false }
        if let epoch = intent.connectionEpochId, epoch != context.connectionEpochId { return false }
        if let daemon = intent.daemonInstanceId, daemon != connection.daemonInstanceId { return false }
        return !(state.stopIntents ?? [:]).values.contains {
            $0.agentId == intent.agentId && $0.serverId == intent.serverId && !intent.priorStopIntentIds.contains($0.commandId)
        }
    }

    func resolveReset(_ reference: AgentExecutionResetReference) throws -> AgentExecutionResetResolution {
        let state = agents.state.execution
        guard let intent = state.resetIntents?[reference.resetOperationId.uuidString], intent.reference(reference.phase) == reference else {
            return .hold(reason: "reset_reference_missing")
        }
        if intent.attempt(reference.phase) == .written { return .settled }
        if intent.machineId == nil || reference.phase == .workspace && intent.effectiveMode != .full
            || reference.phase == .restart && !intent.restart { return .hold(reason: "reset_reference_missing") }
        if intent.phase == .cancelled { return .cancelled }
        if intent.phase.isActive, newerStopRevokingReset(intent, state: state) != nil {
            return intent.hasUnconfirmedControl ? .hold(reason: "reset_dispatch_unconfirmed") : .cancelled
        }
        if intent.phase == .held || intent.attempt(reference.phase) == .attempting || intent.attempt(reference.phase) == .ambiguous {
            return .hold(reason: intent.holdReason ?? "reset_dispatch_unconfirmed")
        }
        guard intent.phase.rawValue == reference.phase.rawValue else { return .wait(reason: "predecessor_not_written") }
        guard let machine = intent.machineId, let connection = state.connections[machine], connection.online else { return .wait(reason: "machine_offline") }
        guard connection.daemonInstanceId?.isEmpty == false else { return .wait(reason: "daemon_identity_pending") }
        if reference.phase == .stop, connection.capabilities?.contains("agent:stop") != true {
            return .wait(reason: "control_capabilities_pending")
        }
        let context = AgentExecutionMachineContext(machineId: machine, serverId: intent.serverId, connectionEpochId: connection.connectionEpochId)
        guard !agents.hasActiveMigration(agentId: intent.agentId),
              (try? boundMachine(serverId: intent.serverId, agentId: intent.agentId)) == machine,
              resetFence(intent, context: context, state: state) else { return .hold(reason: "reset_fence_changed") }
        if reference.phase == .restart, !connection.ready || !connection.runtimes.contains("codex") {
            return .wait(reason: "runtime_not_ready")
        }
        if reference.phase == .restart, !intent.usesHumanStart, let agent = state.agents[intent.agentId] {
            // Automatic replacement must respect retained failure/process facts.
            // These are real exit/outcome gates, never a nonexistent stop ACK.
            if agent.needsManual != nil || agent.blockedUntil.map({ Date() < $0 }) == true {
                return .wait(reason: "automatic_restart_blocked")
            }
            if agent.probeExpiresAt.map({ Date() >= $0 }) == true {
                return .wait(reason: "probe_outcome_unobservable")
            }
            if hasBlockingUnexitedExecution(agentId: intent.agentId, agent: agent, state: state) {
                return .wait(reason: "unexited_execution")
            }
        }
        return .ready(.init(reference: reference, context: context, agentId: intent.agentId))
    }
}
