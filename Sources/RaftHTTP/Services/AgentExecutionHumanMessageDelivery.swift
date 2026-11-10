import Foundation

/// A known wake refusal preserves the human message. `readableOnly` is an
/// explicit refusal for this connection, never a claim of delivery. Offline and
/// unassigned recipients additionally keep a durable pending-delivery fact that
/// a later machine `ready` releases through the ordinary strict path.
enum HumanMessageExecutionDisposition: Sendable {
    case staged(AgentExecutionAdmission)
    case held
    case readableOnly(HumanMessageWakeRefusal)
}

enum HumanMessageWakeRefusal: Sendable, Equatable {
    case unassigned, offline, recoveryRequired, breakerPaused, launchInProgress
}

extension AgentExecutionDomain {
    /// Read-only preflight of known wake conditions. Never catch a mutating
    /// strict request's error and turn its rollback-only UoW into a success.
    func requestHumanMessageDelivery(_ request: AgentExecutionDeliveryRequest) throws -> HumanMessageExecutionDisposition {
        try requireTransaction()
        let owned = try ownedAgent(serverId: request.serverId, agentId: request.agentId)
        guard owned.runtime == "codex",
              deliveryIsAuthorized(serverId: request.serverId, agentId: request.agentId,
                                   channelId: request.channelId, messageId: request.messageId) else {
            throw AgentExecutionError.invalidRequest
        }
        // Reuse the existing held-delivery facts for manual stop/reset, without
        // creating another queue, state owner, runtime callback or success event.
        if manuallyStopped(serverId: request.serverId, agentId: request.agentId)
            || hasActiveReset(serverId: request.serverId, agentId: request.agentId) {
            _ = try requestDelivery(request)
            return .held
        }
        if let refusal = try humanMessageWakeRefusal(serverId: request.serverId, agentId: request.agentId) {
            // Upstream leaves the message in the durable agent inbox. The
            // pending-delivery fact records that this send was accepted while
            // the recipient was not deliverable, so the machine's next ready
            // releases it exactly once. It is not a launch, process or receipt.
            if refusal == .offline || refusal == .unassigned {
                try queuePendingHumanDelivery(request)
            }
            return .readableOnly(refusal)
        }
        if let admission = try requestDelivery(request) { return .staged(admission) }
        return .held
    }

    /// The read-only half of the wake decision: nil means the ordinary strict
    /// delivery path may run now. Any other value is a known refusal that keeps
    /// the committed message readable.
    private func humanMessageWakeRefusal(serverId: String, agentId: String) throws -> HumanMessageWakeRefusal? {
        guard let machineId = agents.agentMachineIds[agentId],
              machines.machines.contains(where: { $0.id == machineId && $0.serverId == serverId }) else {
            return .unassigned
        }
        let state = agents.state.execution
        guard let connection = state.connections[machineId], connection.serverId == serverId,
              connection.online, connection.ready, connection.runtimes.contains("codex"), connection.daemonInstanceId != nil else {
            return .offline
        }
        if let agent = state.agents[agentId] {
            guard agent.serverId == serverId, agent.machineId == machineId else { throw AgentExecutionError.ownershipMismatch }
            guard agent.needsManual == nil else { return .recoveryRequired }
            let current = agent.currentLaunchId.flatMap { agent.launches[$0] }
            // requestDelivery starts a fresh launch only when no usable current
            // launch exists. Match the strict start guards before its first write.
            if current.map({ !$0.completed && !$0.notSpawned && !$0.terminalFailure }) != true {
                // A lift does not assert process exit. Mirror the strict
                // automatic-start guard before staging any message effect.
                guard !hasBlockingUnexitedExecution(agentId: agentId, agent: agent, state: state) else { return .launchInProgress }
                let now = Date()
                if agent.blockedUntil.map({ now < $0 }) == true { return .breakerPaused }
                if agent.probeExpiresAt.map({ now >= $0 }) == true { return .recoveryRequired }
                if let launch = current {
                    if !launch.completed && !launch.notSpawned && !launch.terminalFailure { return .launchInProgress }
                    if launch.terminalFailure && agent.processes.values.contains(where: { !$0.exited && $0.launchIds.contains(launch.launchId) }) {
                        return .launchInProgress
                    }
                }
                guard agent.generation < 9_007_199_254_740_991, agent.takeoverEpoch < 9_007_199_254_740_991 else {
                    return .recoveryRequired
                }
            } else if current?.stopRequested == true {
                return .recoveryRequired
            }
        }
        return nil
    }

    /// Remember one accepted human send for a recipient that is not currently
    /// deliverable. The key is the real (server, agent, channel, message)
    /// identity, so a replay of the same send cannot duplicate the fact.
    func queuePendingHumanDelivery(_ request: AgentExecutionDeliveryRequest) throws {
        try mutate { state in
            let key = AgentExecutionState.key(request.serverId, request.agentId, request.channelId, request.messageId)
            var pending = state.pendingHumanDeliveries ?? [:]
            guard pending[key] == nil else { return }
            pending[key] = AgentExecutionPendingDelivery(
                serverId: request.serverId, agentId: request.agentId, channelId: request.channelId,
                messageId: request.messageId, createdAt: Date())
            state.pendingHumanDeliveries = pending
        }
    }

    /// Release every durable pending human delivery for agents bound to this
    /// machine once its ready connection is committed. Each entry stages at
    /// most one strict delivery attempt; a superseded attempt is retried on a
    /// later ready, an accepted one is removed by the delivery ACK.
    func releasePendingHumanDeliveries(_ context: AgentExecutionMachineContext) throws {
        try requireTransaction()
        guard let connection = agents.state.execution.connections[context.machineId], connection.online,
              connection.ready, connection.serverId == context.serverId,
              connection.connectionEpochId == context.connectionEpochId else { return }
        let binding = agents.agentMachineIds
        let pending = (agents.state.execution.pendingHumanDeliveries ?? [:])
            .sorted { $0.key < $1.key }
            .map { $0.value }
            .filter { $0.serverId == context.serverId && binding[$0.agentId] == context.machineId }
        for entry in pending {
            let key = AgentExecutionState.key(entry.serverId, entry.agentId, entry.channelId, entry.messageId)
            if let released = entry.releasedCommandId,
               let command = agents.state.execution.commands[released.uuidString], command.status != .superseded {
                continue
            }
            guard deliveryIsAuthorized(serverId: entry.serverId, agentId: entry.agentId,
                                       channelId: entry.channelId, messageId: entry.messageId) else {
                // The message or the agent's access is gone: drop only the
                // pending delivery; the canonical message keeps its history.
                try mutate { state in _ = state.pendingHumanDeliveries?.removeValue(forKey: key) }
                continue
            }
            if manuallyStopped(serverId: entry.serverId, agentId: entry.agentId)
                || hasActiveReset(serverId: entry.serverId, agentId: entry.agentId) { continue }
            guard try humanMessageWakeRefusal(serverId: entry.serverId, agentId: entry.agentId) == nil else { continue }
            let request = AgentExecutionDeliveryRequest(serverId: entry.serverId, agentId: entry.agentId,
                                                        channelId: entry.channelId, messageId: entry.messageId)
            let disposition = try requestHumanMessageDelivery(request)
            guard case .staged(let admission) = disposition else { continue }
            try mutate { state in
                guard var current = state.pendingHumanDeliveries?[key] else { return }
                current.releasedCommandId = admission.commandId
                state.pendingHumanDeliveries?[key] = current
            }
        }
    }
}
