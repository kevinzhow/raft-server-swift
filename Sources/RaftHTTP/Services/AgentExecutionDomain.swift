import Foundation
import RaftShared

/// All mutations require the existing business transaction. No callback sends
/// commands here; only immutable outbox references leave this domain.
struct AgentExecutionDomain: Sendable {
    let agents: AgentsRuntimeStore
    let machines: MachinesAndComputersStore
    let oauth: OAuthLedger
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let transactionDomain: TransactionDomain = .shared

    func requireTransaction() throws {
        do { try DeferredEffects.requireDurableTransaction(in: transactionDomain) }
        catch { throw AgentExecutionError.durableTransactionRequired }
    }

    func ownsMachine(_ context: AgentExecutionMachineContext) -> Bool {
        !context.connectionEpochId.isEmpty && machines.machines.contains {
            $0.id == context.machineId && $0.serverId == context.serverId
        }
    }

    func boundMachine(serverId: String, agentId: String) throws -> String {
        _ = try ownedAgent(serverId: serverId, agentId: agentId)
        guard let machineId = agents.agentMachineIds[agentId],
              machines.machines.contains(where: { $0.id == machineId && $0.serverId == serverId }) else {
            throw AgentExecutionError.ownershipMismatch
        }
        return machineId
    }

    func mutate<Value>(_ operation: (inout AgentExecutionState) throws -> Value) throws -> Value {
        let result: Result<Value, any Error> = agents.withState { owned in
            do { return .success(try operation(&owned.execution)) }
            catch { return .failure(error) }
        }
        return try result.get()
    }

    func stage(_ command: AgentExecutionCommand) throws {
        do {
            let payload = try JSONEncoder().encode(AgentExecutionIntentReference(commandId: command.commandId))
            try DeferredEffects.persist(kind: "agent.execution", payload: payload, effectID: command.commandId)
        } catch {
            DeferredEffects.markRollbackOnly()
            throw AgentExecutionError.dispatchUnavailable
        }
    }

    /// Node blockingUnexitedEntries, projected from retained local facts. A
    /// dispatch without a process report is still pending evidence. Human
    /// takeover acknowledges older epochs; clean E2 permits the confirmed live
    /// current process, but never assumes that the next daemon start reuses it.
    func hasBlockingUnexitedExecution(agentId: String, agent: AgentExecutionAgent, state: AgentExecutionState) -> Bool {
        let current = agent.currentLaunchId.flatMap { agent.launches[$0] }
        let healthyCurrent = current.map {
            $0.generation == agent.generation && !$0.terminalFailure && !$0.notSpawned
                && agent.blockedUntil == nil && agent.probeLaunchId == nil
        } ?? false
        for process in agent.processes.values where !process.exited {
            let currentEpoch = process.launchIds.contains { agent.launches[$0]?.takeoverEpoch == agent.takeoverEpoch }
            if !currentEpoch { continue }
            if healthyCurrent, let current, process.launchIds.contains(current.launchId) { continue }
            return true
        }
        let sentLaunches = Set(state.commands.values.compactMap { command -> String? in
            guard command.agentId == agentId, command.serverId == agent.serverId, command.machineId == agent.machineId, command.kind == .start,
                  command.status == .accepted || command.status == .dispatched
                    || state.dispatches?[command.commandId.uuidString] != nil else { return nil }
            return command.launchId
        })
        for launch in agent.launches.values where launch.takeoverEpoch == agent.takeoverEpoch && !launch.notSpawned {
            if let processId = launch.processInstanceId {
                if agent.processes[processId] == nil { return true }
            } else if launch.startAccepted || sentLaunches.contains(launch.launchId) {
                return true
            }
        }
        return false
    }

    func requestStart(_ request: AgentExecutionStartRequest) throws -> AgentExecutionAdmission {
        try requireTransaction()
        _ = try ownedAgent(serverId: request.serverId, agentId: request.agentId)
        if request.control == .automatic && manuallyStopped(serverId: request.serverId, agentId: request.agentId) {
            throw AgentExecutionError.manuallyStopped
        }
        let machineId = try boundMachine(serverId: request.serverId, agentId: request.agentId)
        guard oauth.agentRuntimeInfo(id: request.agentId)?.runtime == "codex" else { throw AgentExecutionError.invalidRequest }
        if agents.state.execution.commands[request.commandId.uuidString] == nil,
           hasActiveReset(serverId: request.serverId, agentId: request.agentId) { throw AgentExecutionError.manualRecoveryRequired }
        let result = try mutate { state -> (AgentExecutionCommand, Bool) in
            guard state.stopIntents?[request.commandId.uuidString] == nil,
                  state.heldDeliveries?[request.commandId.uuidString] == nil else { throw AgentExecutionError.conflictingCommand }
            if let previous = state.commands[request.commandId.uuidString] {
                guard previous.kind == .start, previous.serverId == request.serverId,
                      previous.agentId == request.agentId,
                      previous.humanStart == (request.control == .humanStart), previous.resumePrompt == request.resumePrompt else {
                    throw AgentExecutionError.conflictingCommand
                }
                return (previous, false)
            }
            guard let connection = state.connections[machineId], connection.serverId == request.serverId,
                  connection.online, connection.ready, connection.runtimes.contains("codex"),
                  let daemonInstanceId = connection.daemonInstanceId else { throw AgentExecutionError.machineNotReady }
            var agent = state.agents[request.agentId] ?? AgentExecutionAgent(serverId: request.serverId, machineId: machineId)
            guard agent.serverId == request.serverId, agent.machineId == machineId else { throw AgentExecutionError.ownershipMismatch }
            let now = Date()
            let human = request.control == .humanStart
            if !human {
                guard agent.needsManual == nil else { throw AgentExecutionError.manualRecoveryRequired }
                // A config/reset lift clears currentLaunchId, not process facts.
                // Automatic starts cannot bypass an unexited older launch.
                guard !hasBlockingUnexitedExecution(agentId: request.agentId, agent: agent, state: state) else { throw AgentExecutionError.launchInProgress }
                guard agent.blockedUntil.map({ now >= $0 }) ?? true else { throw AgentExecutionError.breakerPaused }
                if let expiry = agent.probeExpiresAt, now >= expiry {
                    agent.needsManual = "probe_outcome_unobservable"
                    state.agents[request.agentId] = agent
                    throw AgentExecutionError.manualRecoveryRequired
                }
                if let current = agent.currentLaunchId, let launch = agent.launches[current] {
                    if !launch.completed && !launch.notSpawned && !launch.terminalFailure {
                        throw AgentExecutionError.launchInProgress
                    }
                    if launch.terminalFailure && agent.processes.values.contains(where: { !$0.exited && $0.launchIds.contains(current) }) {
                        throw AgentExecutionError.launchInProgress
                    }
                }
            }
            guard agent.generation < 9_007_199_254_740_991,
                  agent.takeoverEpoch < 9_007_199_254_740_991 else { throw AgentExecutionError.manualRecoveryRequired }
            agent.generation += 1
            if human {
                for key in Array(state.commands.keys) where state.commands[key]?.agentId == request.agentId {
                    if state.commands[key]?.status == .pending || state.commands[key]?.status == .dispatched {
                        state.commands[key]?.status = .superseded
                    }
                }
                agent.takeoverEpoch += 1
                agent.needsManual = nil
                agent.failureCount = 0
                agent.sameFingerprint = nil
                agent.sameFingerprintCount = 0
                agent.blockedUntil = nil
                agent.probeLaunchId = nil
                agent.probeExpiresAt = nil
                if var intents = state.stopIntents {
                    for key in Array(intents.keys) where intents[key]?.serverId == request.serverId && intents[key]?.agentId == request.agentId {
                        if intents[key]?.clearedByHumanStart == nil { intents[key]?.clearedByHumanStart = request.commandId }
                    }
                    state.stopIntents = intents
                }
            }
            let launchId = UUID().uuidString.lowercased()
            let dispatchId = UUID().uuidString.lowercased()
            if !human && agent.blockedUntil != nil {
                agent.probeLaunchId = launchId
                agent.probeExpiresAt = now.addingTimeInterval(30 * 60)
            }
            agent.currentLaunchId = launchId
            agent.launches[launchId] = AgentExecutionLaunch(
                launchId: launchId, startDispatchId: dispatchId, daemonInstanceId: daemonInstanceId,
                connectionEpochId: connection.connectionEpochId, generation: agent.generation, takeoverEpoch: agent.takeoverEpoch)
            let command = AgentExecutionCommand(
                commandId: request.commandId, kind: .start, serverId: request.serverId, machineId: machineId,
                agentId: request.agentId, launchId: launchId, startDispatchId: dispatchId, deliveryId: nil,
                connectionEpochId: connection.connectionEpochId, takeoverEpoch: agent.takeoverEpoch,
                breakerGeneration: agent.generation, humanStart: human, sessionId: agent.sessionId,
                resumePrompt: request.resumePrompt, channelId: nil, messageId: nil, status: .pending, createdAt: now)
            state.agents[request.agentId] = agent
            state.commands[request.commandId.uuidString] = command
            return (command, true)
        }
        if result.1 {
            do {
                try stage(result.0)
                if request.control == .humanStart {
                    setIntentStatus(agentId: request.agentId, status: "active")
                    try releaseHeldDeliveries(start: result.0)
                    try retireKnownCredentials(agentId: request.agentId)
                }
            } catch { DeferredEffects.markRollbackOnly(); throw error }
        }
        return result.0.admission
    }

    /// Best-effort creation is different from an explicit start. Decline known
    /// non-admission conditions before any write or effect, then use the strict
    /// staging path. The caller may keep its real agent-creation result on nil.
    func requestAutomaticStartIfReady(_ request: AgentExecutionStartRequest) throws -> AgentExecutionAdmission? {
        try requireTransaction()
        guard request.control == .automatic else { throw AgentExecutionError.invalidRequest }
        _ = try ownedAgent(serverId: request.serverId, agentId: request.agentId)
        if manuallyStopped(serverId: request.serverId, agentId: request.agentId) || hasActiveReset(serverId: request.serverId, agentId: request.agentId) { return nil }
        let machineId = try boundMachine(serverId: request.serverId, agentId: request.agentId)
        if agents.state.execution.commands[request.commandId.uuidString] != nil { return try requestStart(request) }
        guard oauth.agentRuntimeInfo(id: request.agentId)?.runtime == "codex" else { return nil }
        let state = agents.state.execution
        guard let connection = state.connections[machineId], connection.serverId == request.serverId,
              connection.online, connection.ready, connection.runtimes.contains("codex"), connection.daemonInstanceId != nil else { return nil }
        if let agent = state.agents[request.agentId] {
            guard agent.serverId == request.serverId, agent.machineId == machineId else { throw AgentExecutionError.ownershipMismatch }
            let now = Date()
            guard agent.needsManual == nil, !hasBlockingUnexitedExecution(agentId: request.agentId, agent: agent, state: state),
                  agent.blockedUntil.map({ now >= $0 }) ?? true,
                  agent.probeExpiresAt.map({ now < $0 }) ?? true else { return nil }
            if let id = agent.currentLaunchId, let launch = agent.launches[id],
               (!launch.completed && !launch.notSpawned && !launch.terminalFailure
                || launch.terminalFailure && agent.processes.values.contains(where: { !$0.exited && $0.launchIds.contains(id) })) { return nil }
        }
        return try requestStart(request)
    }

    /// nil is a durable held delivery, not a failed user message or task write.
    func requestDelivery(_ request: AgentExecutionDeliveryRequest) throws -> AgentExecutionAdmission? {
        try requireTransaction()
        _ = try ownedAgent(serverId: request.serverId, agentId: request.agentId)
        guard deliveryIsAuthorized(serverId: request.serverId, agentId: request.agentId,
                                   channelId: request.channelId, messageId: request.messageId) else {
            throw AgentExecutionError.invalidRequest
        }
        if let held = agents.state.execution.heldDeliveries?[request.commandId.uuidString] {
            guard held.serverId == request.serverId, held.agentId == request.agentId,
                  held.channelId == request.channelId, held.messageId == request.messageId else { throw AgentExecutionError.conflictingCommand }
            return held.releasedCommandId.flatMap { agents.state.execution.commands[$0.uuidString]?.admission }
        }
        guard agents.state.execution.stopIntents?[request.commandId.uuidString] == nil else { throw AgentExecutionError.conflictingCommand }
        if let previous = agents.state.execution.commands[request.commandId.uuidString] {
            guard previous.kind == .delivery, previous.serverId == request.serverId, previous.agentId == request.agentId,
                  previous.channelId == request.channelId, previous.messageId == request.messageId else {
                throw AgentExecutionError.conflictingCommand
            }
            return previous.admission
        }
        if manuallyStopped(serverId: request.serverId, agentId: request.agentId) || hasActiveReset(serverId: request.serverId, agentId: request.agentId) {
            try holdDelivery(request)
            return nil
        }
        let machineId = try boundMachine(serverId: request.serverId, agentId: request.agentId)
        let snapshot = agents.state.execution.agents[request.agentId]
        if snapshot?.currentLaunchId.flatMap({ snapshot?.launches[$0] }).map({ !$0.completed && !$0.notSpawned && !$0.terminalFailure }) != true {
            _ = try requestStart(.init(serverId: request.serverId, agentId: request.agentId))
        }
        do {
            let command = try mutate { state -> AgentExecutionCommand in
                guard let connection = state.connections[machineId], connection.online, connection.ready,
                      let agent = state.agents[request.agentId], agent.needsManual == nil,
                      let launchId = agent.currentLaunchId, let launch = agent.launches[launchId], !launch.stopRequested, !launch.terminalFailure else {
                    throw AgentExecutionError.manualRecoveryRequired
                }
                let command = AgentExecutionCommand(
                    commandId: request.commandId, kind: .delivery, serverId: request.serverId, machineId: machineId,
                    agentId: request.agentId, launchId: launchId, startDispatchId: nil, deliveryId: UUID().uuidString.lowercased(),
                    connectionEpochId: connection.connectionEpochId, takeoverEpoch: agent.takeoverEpoch,
                    breakerGeneration: agent.generation, humanStart: false, sessionId: agent.sessionId,
                    resumePrompt: nil, channelId: request.channelId, messageId: request.messageId, status: .pending, createdAt: Date())
                state.commands[request.commandId.uuidString] = command
                return command
            }
            try stage(command)
            return command.admission
        } catch {
            // A cold start may already be staged. Never commit half the producer
            // request if the caller converts this error to an HTTP response.
            DeferredEffects.markRollbackOnly()
            throw error
        }
    }

    func retireKnownCredentials(agentId: String) throws {
        let launches = agents.state.execution.agents[agentId].map { Array($0.launches.keys) } ?? []
        for launchId in launches {
            _ = try agents.revokeRetiredMaterializationCredential(agentId: agentId, launchId: launchId, at: Date())
        }
    }

    func connectionOpened(_ context: AgentExecutionMachineContext) throws {
        try requireTransaction()
        guard ownsMachine(context) else { throw AgentExecutionError.ownershipMismatch }
        try mutate { state in
            if state.connections[context.machineId]?.connectionEpochId == context.connectionEpochId { return }
            markAmbiguousExecutions(&state, machineId: context.machineId)
            state.connections[context.machineId] = AgentExecutionConnection(
                serverId: context.serverId, connectionEpochId: context.connectionEpochId,
                online: true, ready: false, daemonInstanceId: nil, runtimes: [])
        }
    }

    func connectionReady(_ context: AgentExecutionMachineContext, daemonInstanceId: String,
                         runtimes: [String], runningAgentIds: [String], detectionComplete: Bool) throws {
        try requireTransaction()
        guard ownsMachine(context), !daemonInstanceId.isEmpty else { throw AgentExecutionError.ownershipMismatch }
        for agentId in runningAgentIds {
            guard try boundMachine(serverId: context.serverId, agentId: agentId) == context.machineId else {
                throw AgentExecutionError.ownershipMismatch
            }
        }
        try mutate { state in
            guard state.connections[context.machineId]?.connectionEpochId == context.connectionEpochId,
                  state.connections[context.machineId]?.online == true else { throw AgentExecutionError.staleConnection }
            state.connections[context.machineId]?.daemonInstanceId = daemonInstanceId
            state.connections[context.machineId]?.runtimes = Set(runtimes)
            state.connections[context.machineId]?.ready = detectionComplete && runtimes.contains("codex")
            for agentId in runningAgentIds {
                var agent = state.agents[agentId] ?? AgentExecutionAgent(serverId: context.serverId, machineId: context.machineId)
                if !agent.processes.values.contains(where: { !$0.exited && $0.daemonInstanceId == daemonInstanceId }) {
                    agent.needsManual = "untracked_running_process"
                }
                state.agents[agentId] = agent
            }
        }
    }

    func connectionClosed(_ context: AgentExecutionMachineContext) throws {
        try requireTransaction()
        try mutate { state in
            guard state.connections[context.machineId]?.connectionEpochId == context.connectionEpochId else { return }
            state.connections[context.machineId]?.online = false
            state.connections[context.machineId]?.ready = false
            markAmbiguousExecutions(&state, machineId: context.machineId)
        }
    }

    private func markAmbiguousExecutions(_ state: inout AgentExecutionState, machineId: String) {
        for agentId in Array(state.agents.keys) where state.agents[agentId]?.machineId == machineId {
            if state.agents[agentId]?.hasUnsettledExecution == true {
                state.agents[agentId]?.needsManual = "connection_lost_with_unsettled_execution"
            }
        }
    }
}
