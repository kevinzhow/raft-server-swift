import Foundation

/// A transient agent notice: one system-sender wake with `seq: 0` and a
/// synthetic `message_id`, never a `messages` row and never a channel event.
///
/// It reuses the existing `agent.execution` durable outbox and machine
/// registry. Admission is stricter than an ordinary delivery because the
/// notice is lost rather than queued when the agent cannot receive now: no
/// cold start, no inbox row, no event. Upstream deliberately drops such a
/// wake (`AgentMessageDeliveryResult.status === "dropped"`) and the caller
/// must not stamp its one-shot sent fact.
extension AgentExecutionDomain {
    /// The launch a notice can reach: the current launch has been admitted by
    /// the daemon (or has a process) and is not stopping or terminal.
    func liveNoticeLaunch(agent: AgentExecutionAgent, state: AgentExecutionState) -> AgentExecutionLaunch? {
        guard let launchId = agent.currentLaunchId, let launch = agent.launches[launchId],
              !launch.completed, !launch.notSpawned, !launch.terminalFailure, !launch.stopRequested,
              launch.startAccepted || launch.processInstanceId != nil else { return nil }
        return launch
    }

    func requestNotice(_ request: AgentExecutionNoticeRequest) throws -> AgentExecutionNoticeReceipt {
        try requireTransaction()
        guard let agentInfo = try? ownedAgent(serverId: request.serverId, agentId: request.agentId) else {
            return .dropped(.agentUnavailable)
        }
        guard !request.content.isEmpty, !request.messageId.isEmpty, !request.channelId.isEmpty,
              !request.channelName.isEmpty, ["channel", "private", "joint", "dm", "thread"].contains(request.channelType),
              agentInfo.runtime == "codex" else {
            return .dropped(.targetUnavailable)
        }
        let prior = agents.state.execution
        if let existing = prior.commands[request.commandId.uuidString] {
            guard existing.kind == .notice, existing.serverId == request.serverId,
                  existing.agentId == request.agentId, existing.messageId == request.messageId,
                  existing.channelId == request.channelId else {
                return .dropped(.conflictingCommand)
            }
            return existing.status == .superseded ? .dropped(.conflictingCommand) : .accepted(commandId: existing.commandId)
        }
        if manuallyStopped(serverId: request.serverId, agentId: request.agentId) {
            return .dropped(.manuallyStopped)
        }
        if hasActiveReset(serverId: request.serverId, agentId: request.agentId) {
            return .dropped(.resetInProgress)
        }
        guard let machineId = agents.agentMachineIds[request.agentId],
              machines.machines.contains(where: { $0.id == machineId && $0.serverId == request.serverId }) else {
            return .dropped(.machineNotReady)
        }
        guard let connection = prior.connections[machineId], connection.serverId == request.serverId,
              connection.online, connection.ready, connection.runtimes.contains("codex"),
              connection.daemonInstanceId != nil else {
            return .dropped(.machineNotReady)
        }
        guard let agent = prior.agents[request.agentId], agent.serverId == request.serverId,
              agent.machineId == machineId else {
            return .dropped(.agentNotRunning)
        }
        guard agent.needsManual == nil else { return .dropped(.manualRecovery) }
        guard liveNoticeLaunch(agent: agent, state: prior) != nil else { return .dropped(.agentNotRunning) }

        let deliveryId = UUID().uuidString.lowercased()
        let command = AgentExecutionCommand(
            commandId: request.commandId, kind: .notice, serverId: request.serverId, machineId: machineId,
            agentId: request.agentId, launchId: agent.currentLaunchId ?? "", startDispatchId: nil,
            deliveryId: deliveryId, connectionEpochId: connection.connectionEpochId,
            takeoverEpoch: agent.takeoverEpoch, breakerGeneration: agent.generation, humanStart: false,
            sessionId: agent.sessionId, resumePrompt: nil, channelId: request.channelId,
            messageId: request.messageId,
            notice: AgentExecutionNotice(channelName: request.channelName, channelType: request.channelType,
                                         content: request.content, timestamp: request.timestamp),
            status: .pending, createdAt: Date())
        let result: AgentExecutionCommand = try mutate { state in
            guard state.commands[request.commandId.uuidString] == nil else {
                throw AgentExecutionError.conflictingCommand
            }
            state.commands[request.commandId.uuidString] = command
            return command
        }
        try stage(result)
        return .accepted(commandId: result.commandId)
    }
}
