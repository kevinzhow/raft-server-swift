import Foundation

/// Upstream `recoverDurableMentionDeliveriesForMachine` and
/// `recoverDurableMentionDeliveriesForAgent`.
///
/// The durable occurrence, not the ack-retry map, is the recovery authority:
/// `ready` re-drives rows the machine was already told about, and
/// `agent:session` additionally decides rows that never had a session identity.
/// Each pass is its own committed step with the ordinary staged outbox
/// command, so a refusal never rolls back the ready/session frame that
/// triggered it.
extension AgentExecutionDomain {
    /// One recovery pass for a machine's durable occurrences. Only rows that
    /// already carry a server decision are re-driven here; a row with no
    /// decision is waiting for a concrete session identity and is handled by
    /// the `agent:session` pass.
    func recoverMentionDeliveriesForMachine(_ context: AgentExecutionMachineContext) throws -> Int {
        try requireTransaction()
        guard let connection = agents.state.execution.connections[context.machineId], connection.online,
              connection.ready, connection.serverId == context.serverId else { return 0 }
        let rows = messages.recoverableMentionDeliveries(machineId: context.machineId)
        var recovered = 0
        let binding = agents.agentMachineIds
        for agentId in Set(rows.map(\.targetId)).sorted() {
            guard binding[agentId] == context.machineId,
                  let agent = agents.state.execution.agents[agentId],
                  agent.serverId == context.serverId, agent.machineId == context.machineId,
                  let launchId = agent.currentLaunchId,
                  let launch = agent.launches[launchId], launch.daemonInstanceId == connection.daemonInstanceId,
                  let sessionId = agent.sessionId else { continue }
            recovered += try recoverMentionDeliveries(
                serverId: context.serverId, agentId: agentId, machineId: context.machineId,
                launchId: launchId, sessionId: sessionId,
                rows: rows.filter { $0.targetId == agentId })
        }
        return recovered
    }

    /// The `agent:session` pass: decides rows that never had an identity, then
    /// sends every live row again with the now-current identity.
    func recoverMentionDeliveriesForAgent(serverId: String, agentId: String) throws -> Int {
        try requireTransaction()
        guard let agent = agents.state.execution.agents[agentId], agent.serverId == serverId,
              let machineId = agents.agentMachineIds[agentId],
              let connection = agents.state.execution.connections[machineId],
              connection.online, connection.ready, connection.serverId == serverId,
              let launchId = agent.currentLaunchId,
              let sessionId = agent.sessionId else { return 0 }
        let rows = messages.recoverableMentionDeliveries(machineId: machineId, agentId: agentId)
        return try recoverMentionDeliveries(serverId: serverId, agentId: agentId, machineId: machineId,
                                            launchId: launchId, sessionId: sessionId, rows: rows)
    }

    private func recoverMentionDeliveries(
        serverId: String, agentId: String, machineId: String, launchId: String, sessionId: String,
        rows: [MessagesAndThreadsStore.MentionDeliveryOccurrenceRow]
    ) throws -> Int {
        let identity = MentionDeliveryOccurrenceEvaluation.Identity(
            machineId: machineId, launchId: launchId, sessionId: sessionId)
        var recovered = 0
        for row in rows {
            guard deliveryIsAuthorized(serverId: serverId, agentId: agentId,
                                       channelId: row.channelId, messageId: row.messageId) else { continue }
            var current = row.occurrence
            if current.serverDecidedAt != nil {
                guard MentionDeliveryOccurrenceEvaluation.identityMatches(current, identity) else {
                    _ = messages.recordMentionDeliveryTerminalError(
                        occurrenceId: row.occurrenceId, messageId: row.messageId, agentId: agentId,
                        identity: identity, code: "IDENTITY_DRIFT",
                        decision: MentionDeliveryTerminalDecision(
                            layer: "server", stage: "recovery", originalDaemonCode: nil),
                        requireIdentity: true)
                    continue
                }
            }
            // An undecided row needs no decision here: the materializer freezes
            // it with the exact payload it is about to send.
            if current.state == MentionDeliveryState.daemonDrained.rawValue { continue }
            // A command that is still waiting to be written already owns the
            // next attempt; re-staging would duplicate the same frame.
            if agents.state.execution.commands.values.contains(where: {
                $0.kind == .delivery && $0.mentionDeliveryOccurrenceId == row.occurrenceId
                    && ($0.status == .pending || $0.status == .dispatched)
            }) { continue }
            // Every automatic round for an occurrence the daemon already holds
            // spends budget; a row the daemon never received keeps recovering.
            let claim = messages.claimMentionDeliveryRecovery(
                occurrenceId: row.occurrenceId, expectedVersion: current.version)
            switch claim {
            case .stale, .exhausted:
                continue
            case .claimed(let claimed):
                current = claimed
            }
            guard let connection = agents.state.execution.connections[machineId], connection.online,
                  connection.ready, connection.serverId == serverId,
                  agents.state.execution.agents[agentId]?.currentLaunchId == launchId,
                  agents.state.execution.agents[agentId]?.sessionId == sessionId else { continue }
            let command = AgentExecutionCommand(
                commandId: UUID(), kind: .delivery, serverId: serverId, machineId: machineId,
                agentId: agentId, launchId: launchId, startDispatchId: nil,
                deliveryId: row.occurrenceId, connectionEpochId: connection.connectionEpochId,
                takeoverEpoch: agents.state.execution.agents[agentId]?.takeoverEpoch ?? 0,
                breakerGeneration: agents.state.execution.agents[agentId]?.generation ?? 0,
                humanStart: false, sessionId: sessionId, resumePrompt: nil,
                channelId: row.channelId, messageId: row.messageId, notice: nil,
                mentionDeliveryOccurrenceId: row.occurrenceId, status: .pending, createdAt: Date())
            try mutate { state in state.commands[command.commandId.uuidString] = command }
            try stage(command)
            recovered += 1
        }
        return recovered
    }
}
