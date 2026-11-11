import Foundation

/// A known wake refusal preserves the human message. `readableOnly` is an
/// explicit refusal for this connection, never a claim of delivery. Every known
/// refusal also keeps a durable pending-delivery fact (the upstream durable
/// inbox) that a later deliverable moment releases through the strict path.
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
            // Upstream leaves every accepted message in the durable agent inbox
            // and suppresses only its wake. The pending-delivery fact records
            // that this send is owed a delivery, so a later deliverable moment
            // (machine ready, a settled start, a human start) releases it
            // exactly once. It is not a launch, process or receipt.
            try queuePendingHumanDelivery(request)
            // RFC 071 §9: a manual/breaker suppression is shown to the Web as
            // the typed offline activity, exactly like upstream's
            // `projectTerminalBlock` wake-refusal projection.
            if refusal == .recoveryRequired || refusal == .breakerPaused,
               let recovery = agents.state.execution.agents[request.agentId],
               let block = AgentPresenceSignal.terminalBlock(needsManual: recovery.needsManual,
                                                             blockedUntil: recovery.blockedUntil, now: Date()) {
                queueTerminalBlockFrame(serverId: request.serverId, agentId: request.agentId, block: block)
            }
            return .readableOnly(refusal)
        }
        switch try stageDelivery(request) {
        case .staged(let admission):
            return .staged(admission)
        case .held:
            return .held
        case .deferred:
            // The wake start (or an already admitted launch) plus the durable
            // occurrence own the obligation; `agent:session` delivers it once
            // the concrete session identity exists. The canonical message stays
            // readable and a pending fact keeps a later ready retrying.
            try queuePendingHumanDelivery(request)
            return .readableOnly(.launchInProgress)
        }
    }

    /// The read-only half of the wake decision: nil means the ordinary strict
    /// delivery path may run now. Any other value is a known refusal that keeps
    /// the committed message readable and durably queued.
    ///
    /// Upstream `planWakeAction` delivers directly whenever the daemon reports a
    /// runtime: a resident process that finished a turn is still running, and an
    /// in-flight launch accepts the delivery (the daemon buffers it during
    /// startup and queues it while busy). A start is only needed when the daemon
    /// has no process, and only its automatic-start guards can refuse that.
    func humanMessageWakeRefusal(serverId: String, agentId: String) throws -> HumanMessageWakeRefusal? {
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
            guard current?.stopRequested != true else { return .recoveryRequired }
            // Upstream `deliver-directly`: the resident process carries the
            // delivery itself, whatever launch/turn state it last recorded. It
            // must still name a launch this server can fence the command to; a
            // process without any usable launch is refused and queued rather
            // than staged as an undispatchable command.
            if let process = liveRuntimeProcess(agent, in: state) {
                if current.map(launchIsUsableForDelivery) == true { return nil }
                guard process.launchIds.contains(where: { id in
                    agent.launches[id].map(launchIsUsableForDelivery) == true
                }) else { return .launchInProgress }
                return nil
            }
            // An admitted launch that is still starting buffers the delivery.
            if let current, launchIsInFlight(current) { return nil }
            // No runtime and no in-flight launch: requestDelivery stages a start.
            // Mirror that start's automatic guards before any message effect.
            guard !hasBlockingUnexitedExecution(agentId: agentId, agent: agent, state: state) else { return .launchInProgress }
            let now = Date()
            if agent.blockedUntil.map({ now < $0 }) == true { return .breakerPaused }
            if agent.probeExpiresAt.map({ now >= $0 }) == true { return .recoveryRequired }
            if let current, current.terminalFailure,
               agent.processes.values.contains(where: { !$0.exited && $0.launchIds.contains(current.launchId) }) {
                return .launchInProgress
            }
            guard agent.generation < 9_007_199_254_740_991, agent.takeoverEpoch < 9_007_199_254_740_991 else {
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
    /// most one strict delivery attempt; a superseded attempt is retried later,
    /// an accepted one is removed by the delivery ACK.
    func releasePendingHumanDeliveries(_ context: AgentExecutionMachineContext) throws {
        try requireTransaction()
        guard let connection = agents.state.execution.connections[context.machineId], connection.online,
              connection.ready, connection.serverId == context.serverId,
              connection.connectionEpochId == context.connectionEpochId else { return }
        let binding = agents.agentMachineIds
        let pending = (agents.state.execution.pendingHumanDeliveries ?? [:])
            .sorted { $0.key < $1.key }
            .filter { $0.value.serverId == context.serverId && binding[$0.value.agentId] == context.machineId }
        for (key, entry) in pending {
            try releasePendingHumanDelivery(entry, key: key)
        }
    }

    /// Release the durable wake obligations of one agent whose runtime just
    /// became deliverable again (a start admission carrying the daemon's process
    /// identity, or a human start). Called in its own committed step so a
    /// release refusal never fails the daemon's outcome ACK or a control frame.
    func releasePendingHumanDeliveries(serverId: String, agentId: String) throws {
        try requireTransaction()
        guard let agent = agents.state.execution.agents[agentId], agent.serverId == serverId,
              let machineId = agents.agentMachineIds[agentId],
              let connection = agents.state.execution.connections[machineId], connection.online,
              connection.ready, connection.serverId == serverId, connection.daemonInstanceId != nil else { return }
        let pending = (agents.state.execution.pendingHumanDeliveries ?? [:])
            .sorted { $0.key < $1.key }
            .filter { $0.value.serverId == serverId && $0.value.agentId == agentId }
        for (key, entry) in pending {
            try releasePendingHumanDelivery(entry, key: key)
        }
    }

    /// Stage at most one strict attempt for one pending entry. An entry whose
    /// attempt was accepted is removed by the delivery ACK; one whose attempt was
    /// superseded is retried on a later deliverable moment.
    private func releasePendingHumanDelivery(_ entry: AgentExecutionPendingDelivery, key: String) throws {
        if let released = entry.releasedCommandId,
           let command = agents.state.execution.commands[released.uuidString], command.status != .superseded {
            return
        }
        guard deliveryIsAuthorized(serverId: entry.serverId, agentId: entry.agentId,
                                   channelId: entry.channelId, messageId: entry.messageId) else {
            // The message or the agent's access is gone: drop only the
            // pending delivery; the canonical message keeps its history.
            try mutate { state in _ = state.pendingHumanDeliveries?.removeValue(forKey: key) }
            return
        }
        if manuallyStopped(serverId: entry.serverId, agentId: entry.agentId)
            || hasActiveReset(serverId: entry.serverId, agentId: entry.agentId) { return }
        guard try humanMessageWakeRefusal(serverId: entry.serverId, agentId: entry.agentId) == nil else { return }
        let request = AgentExecutionDeliveryRequest(serverId: entry.serverId, agentId: entry.agentId,
                                                    channelId: entry.channelId, messageId: entry.messageId)
        let disposition = try requestHumanMessageDelivery(request)
        guard case .staged(let admission) = disposition else { return }
        try mutate { state in
            guard var current = state.pendingHumanDeliveries?[key] else { return }
            current.releasedCommandId = admission.commandId
            state.pendingHumanDeliveries?[key] = current
        }
    }
}
