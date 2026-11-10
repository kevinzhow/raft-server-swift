import Foundation
import RaftShared

extension AgentExecutionDomain {
    func ownedAgent(serverId: String, agentId: String) throws -> OAuthLedger.AgentRuntimeInfo {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId,
              agents.serverAgents[agentId].map({ $0.serverId == serverId }) ?? true else {
            throw AgentExecutionError.ownershipMismatch
        }
        return agent
    }

    func manuallyStopped(serverId: String, agentId: String) -> Bool {
        oauth.agentRuntimeInfo(id: agentId).map { $0.serverId == serverId && $0.status == "stopped" } == true
            || (agents.state.execution.stopIntents ?? [:]).values.contains {
                $0.serverId == serverId && $0.agentId == agentId && $0.clearedByHumanStart == nil
            }
    }

    func setIntentStatus(agentId: String, status: String) {
        oauth.setAgentStatus(id: agentId, status: status)
        agents.withState { $0.serverAgents[agentId]?.status = status }
    }

    func requestStop(_ request: AgentExecutionStopRequest) throws -> AgentExecutionStopAdmission {
        try requireTransaction()
        _ = try ownedAgent(serverId: request.serverId, agentId: request.agentId)
        let previous = agents.state.execution
        if let intent = previous.stopIntents?[request.commandId.uuidString] {
            guard intent.serverId == request.serverId, intent.agentId == request.agentId else { throw AgentExecutionError.conflictingCommand }
            return intent.admission
        }
        // Old snapshots can contain a dispatch command without the new receipt.
        // Replaying that historical request cannot undo a later human takeover.
        if let command = previous.commands[request.commandId.uuidString] {
            guard command.kind == .stop, command.serverId == request.serverId, command.agentId == request.agentId else {
                throw AgentExecutionError.conflictingCommand
            }
            return .init(commandId: command.commandId, requiresMachineDispatch: true)
        }
        guard previous.heldDeliveries?[request.commandId.uuidString] == nil else { throw AgentExecutionError.conflictingCommand }
        // Stopping owned intent does not require a surviving dispatch target.
        // A dangling or foreign binding never authorizes a machine command.
        var machineId = agents.agentMachineIds[request.agentId].flatMap { assigned in
            machines.machines.contains { $0.id == assigned && $0.serverId == request.serverId } ? assigned : nil
        }
        if let existing = previous.agents[request.agentId], existing.machineId != machineId {
            machineId = nil
        }
        let now = Date()
        let command = try mutate { state -> AgentExecutionCommand? in
            var executionAgent = state.agents[request.agentId]
            if let existing = executionAgent {
                guard existing.serverId == request.serverId, machineId.map({ $0 == existing.machineId }) ?? true else {
                    throw AgentExecutionError.ownershipMismatch
                }
            } else if let machineId {
                executionAgent = AgentExecutionAgent(serverId: request.serverId, machineId: machineId)
            }
            if let current = executionAgent?.currentLaunchId { executionAgent?.launches[current]?.stopRequested = true }
            var held = state.heldDeliveries ?? [:]
            for key in Array(state.commands.keys) {
                guard let pending = state.commands[key], pending.agentId == request.agentId, pending.status == .pending else { continue }
                if pending.kind == .delivery {
                    // An existing attempt may have reached the daemon. Keep its
                    // history and never turn it into a fresh delivery attempt.
                    if state.dispatches?[key] == nil, held[key] == nil,
                       let channel = pending.channelId, let message = pending.messageId {
                        held[key] = AgentExecutionHeldDelivery(commandId: pending.commandId, serverId: pending.serverId,
                            agentId: pending.agentId, channelId: channel, messageId: message, createdAt: pending.createdAt)
                    }
                } else {
                    state.commands[key]?.status = .superseded
                }
            }
            state.heldDeliveries = held.isEmpty ? state.heldDeliveries : held
            var intents = state.stopIntents ?? [:]
            intents[request.commandId.uuidString] = AgentExecutionStopIntent(commandId: request.commandId,
                serverId: request.serverId, agentId: request.agentId, machineId: machineId, createdAt: now)
            state.stopIntents = intents
            if let executionAgent { state.agents[request.agentId] = executionAgent }
            guard let machineId, let agent = executionAgent else { return nil }
            let command = AgentExecutionCommand(
                commandId: request.commandId, kind: .stop, serverId: request.serverId, machineId: machineId,
                // With no launch this is only the stop intent's fence token; no
                // launch row is created and the upstream stop frame has no id.
                agentId: request.agentId, launchId: agent.currentLaunchId ?? request.commandId.uuidString,
                startDispatchId: nil, deliveryId: nil, connectionEpochId: state.connections[machineId]?.connectionEpochId ?? "",
                takeoverEpoch: agent.takeoverEpoch, breakerGeneration: agent.generation, humanStart: false,
                sessionId: agent.sessionId, resumePrompt: nil, channelId: nil, messageId: nil, notice: nil, status: .pending, createdAt: now)
            state.commands[request.commandId.uuidString] = command
            return command
        }
        do {
            setIntentStatus(agentId: request.agentId, status: "stopped")
            if let command { try stage(command) }
            try retireKnownCredentials(agentId: request.agentId)
        } catch { DeferredEffects.markRollbackOnly(); throw error }
        return .init(commandId: request.commandId, requiresMachineDispatch: command != nil)
    }

    func holdDelivery(_ request: AgentExecutionDeliveryRequest) throws {
        try mutate { state in
            guard state.commands[request.commandId.uuidString] == nil,
                  state.stopIntents?[request.commandId.uuidString] == nil else { throw AgentExecutionError.conflictingCommand }
            var held = state.heldDeliveries ?? [:]
            held[request.commandId.uuidString] = AgentExecutionHeldDelivery(commandId: request.commandId,
                serverId: request.serverId, agentId: request.agentId, channelId: request.channelId,
                messageId: request.messageId, createdAt: Date())
            state.heldDeliveries = held
        }
    }

    func releaseHeldDeliveries(start: AgentExecutionCommand) throws {
        let held = (agents.state.execution.heldDeliveries ?? [:]).values.filter {
            $0.serverId == start.serverId && $0.agentId == start.agentId && $0.releasedCommandId == nil && !$0.cancelled
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.commandId.uuidString < $1.commandId.uuidString : $0.createdAt < $1.createdAt
        }
        for delivery in held {
            guard agents.state.execution.dispatches?[delivery.commandId.uuidString] == nil else {
                throw AgentExecutionError.manualRecoveryRequired
            }
            let authorized = deliveryIsAuthorized(serverId: delivery.serverId, agentId: delivery.agentId,
                                                 channelId: delivery.channelId, messageId: delivery.messageId)
            let released = try mutate { state -> AgentExecutionCommand? in
                guard var current = state.heldDeliveries?[delivery.commandId.uuidString],
                      current.releasedCommandId == nil, !current.cancelled else { throw AgentExecutionError.conflictingCommand }
                guard authorized else {
                    current.cancelled = true
                    state.heldDeliveries?[delivery.commandId.uuidString] = current
                    return nil
                }
                let command = AgentExecutionCommand(commandId: UUID(), kind: .delivery,
                    serverId: start.serverId, machineId: start.machineId, agentId: start.agentId,
                    launchId: start.launchId, startDispatchId: nil, deliveryId: UUID().uuidString.lowercased(),
                    connectionEpochId: start.connectionEpochId, takeoverEpoch: start.takeoverEpoch,
                    breakerGeneration: start.breakerGeneration, humanStart: false, sessionId: start.sessionId,
                    resumePrompt: nil, channelId: current.channelId, messageId: current.messageId, notice: nil, status: .pending, createdAt: Date())
                current.releasedCommandId = command.commandId
                state.heldDeliveries?[delivery.commandId.uuidString] = current
                state.commands[command.commandId.uuidString] = command
                return command
            }
            if let released { try stage(released) }
        }
    }

    /// Caller holds the business transaction or committed read view. Transport
    /// still needs beginDispatch's committed attempt and the socket epoch fence.
    func resolveDispatch(reference: AgentExecutionIntentReference) -> AgentExecutionDispatchResolution {
        let state = agents.state.execution
        guard var command = state.commands[reference.commandId.uuidString], command.status != .superseded else { return .obsolete }
        if command.status == .accepted || command.kind == .stop && command.status == .dispatched { return .obsolete }
        guard (try? boundMachine(serverId: command.serverId, agentId: command.agentId)) == command.machineId else { return .obsolete }
        if command.kind != .stop && hasActiveReset(serverId: command.serverId, agentId: command.agentId) {
            return .wait(reason: "agent_reset_in_progress")
        }
        if command.kind != .stop && manuallyStopped(serverId: command.serverId, agentId: command.agentId) {
            return .wait(reason: "agent_manually_stopped")
        }
        guard let connection = state.connections[command.machineId], connection.online,
              connection.serverId == command.serverId else { return .wait(reason: "machine_offline") }
        if let current = state.agents[command.agentId]?.currentLaunchId, current != command.launchId { return .obsolete }
        if command.kind == .stop {
            command.connectionEpochId = connection.connectionEpochId
            return .ready(command)
        }
        guard command.connectionEpochId == connection.connectionEpochId else { return .obsolete }
        guard connection.ready, connection.runtimes.contains("codex") else { return .wait(reason: "runtime_not_ready") }
        guard let agent = state.agents[command.agentId], agent.needsManual == nil,
              let launch = agent.launches[command.launchId], !launch.stopRequested else { return .obsolete }
        if command.kind == .start, launch.startAccepted || launch.processInstanceId != nil || launch.notSpawned || launch.completed { return .obsolete }
        if command.kind == .delivery {
            guard let channelId = command.channelId, let messageId = command.messageId,
                  deliveryIsAuthorized(serverId: command.serverId, agentId: command.agentId, channelId: channelId, messageId: messageId) else { return .obsolete }
        }
        // A notice has no stored row to authorize. It is still only sent to a
        // launch the daemon admitted; a dead agent is never started here.
        if (command.kind == .delivery || command.kind == .notice),
           !launch.startAccepted && launch.processInstanceId == nil {
            return .wait(reason: "start_not_admitted_by_daemon")
        }
        return .ready(command)
    }
}
