import Foundation

/// A known wake refusal preserves the human message. readableOnly is explicitly
/// not an offline execution intent: reconnect redrive is outside this candidate.
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
        guard let machineId = agents.agentMachineIds[request.agentId],
              machines.machines.contains(where: { $0.id == machineId && $0.serverId == request.serverId }) else {
            return .readableOnly(.unassigned)
        }
        let state = agents.state.execution
        guard let connection = state.connections[machineId], connection.serverId == request.serverId,
              connection.online, connection.ready, connection.runtimes.contains("codex"), connection.daemonInstanceId != nil else {
            return .readableOnly(.offline)
        }
        if let agent = state.agents[request.agentId] {
            guard agent.serverId == request.serverId, agent.machineId == machineId else { throw AgentExecutionError.ownershipMismatch }
            guard agent.needsManual == nil else { return .readableOnly(.recoveryRequired) }
            let current = agent.currentLaunchId.flatMap { agent.launches[$0] }
            // requestDelivery starts a fresh launch only when no usable current
            // launch exists. Match the strict start guards before its first write.
            if current.map({ !$0.completed && !$0.notSpawned && !$0.terminalFailure }) != true {
                // A lift does not assert process exit. Mirror the strict
                // automatic-start guard before staging any message effect.
                guard !hasBlockingUnexitedExecution(agentId: request.agentId, agent: agent, state: state) else { return .readableOnly(.launchInProgress) }
                let now = Date()
                if agent.blockedUntil.map({ now < $0 }) == true { return .readableOnly(.breakerPaused) }
                if agent.probeExpiresAt.map({ now >= $0 }) == true { return .readableOnly(.recoveryRequired) }
                if let launch = current {
                    if !launch.completed && !launch.notSpawned && !launch.terminalFailure { return .readableOnly(.launchInProgress) }
                    if launch.terminalFailure && agent.processes.values.contains(where: { !$0.exited && $0.launchIds.contains(launch.launchId) }) {
                        return .readableOnly(.launchInProgress)
                    }
                }
                guard agent.generation < 9_007_199_254_740_991, agent.takeoverEpoch < 9_007_199_254_740_991 else {
                    return .readableOnly(.recoveryRequired)
                }
            } else if current?.stopRequested == true {
                return .readableOnly(.recoveryRequired)
            }
        }
        if let admission = try requestDelivery(request) { return .staged(admission) }
        return .held
    }
}
