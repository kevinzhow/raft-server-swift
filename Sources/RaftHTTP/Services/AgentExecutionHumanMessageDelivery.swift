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

/// The durable queued-send facts share one release path. Pending deliveries are
/// sends refused while the recipient was not deliverable; held deliveries are
/// real pending commands held across a manual stop/reset. Both are obligations,
/// never attempts: one message gets exactly one live attempt.
enum QueuedDeliveryQueue: Sendable, Equatable {
    case pending(key: String)
    case held(key: String)
}

struct QueuedDeliveryObligation: Sendable, Equatable {
    let queue: QueuedDeliveryQueue
    let serverId: String
    let agentId: String
    let channelId: String
    let messageId: String
    let createdAt: Date
    let releasedCommandId: UUID?
    let cancelled: Bool
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
    /// Upstream `planWakeAction` delivers directly whenever the daemon holds a
    /// runtime: a resident process that finished a turn is still running, and
    /// an in-flight launch accepts the delivery (the daemon buffers it during
    /// startup and queues it while busy). A start is only needed when the daemon
    /// has no process, and only its automatic-start guards can refuse that.
    ///
    /// This port settles a delivery attempt on the daemon's `agent:deliver:ack`.
    /// The official daemon does not acknowledge a frame it buffered during the
    /// start window (`buffered-for-start`), so writing into that window would
    /// leave the send with no settlement at all. A launch that has not reported
    /// a process yet is therefore queued like any other not-yet-deliverable
    /// recipient and released on the start identity / session trigger.
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
            // An admitted launch that has not reported its process yet cannot
            // acknowledge a delivery (the daemon buffers it for the start). The
            // queued fact is released as soon as the launch names its process.
            if let current, launchIsInFlight(current) {
                return current.processInstanceId == nil && !current.completed ? .launchInProgress : nil
            }
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

    /// Release every durable queued delivery for agents bound to this machine
    /// once its ready connection is committed. Each obligation stages at most
    /// one strict attempt; a superseded attempt is retried later, an accepted
    /// one is removed by the delivery ACK (or by its carrying start's ACK).
    func releasePendingHumanDeliveries(_ context: AgentExecutionMachineContext) throws {
        try requireTransaction()
        guard let connection = agents.state.execution.connections[context.machineId], connection.online,
              connection.ready, connection.serverId == context.serverId,
              connection.connectionEpochId == context.connectionEpochId else { return }
        let binding = agents.agentMachineIds
        let obligations = queuedDeliveryObligations(serverId: context.serverId) {
            binding[$0.agentId] == context.machineId
        }
        for obligation in obligations { try releaseQueuedDelivery(obligation) }
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
        let obligations = queuedDeliveryObligations(serverId: serverId) { $0.agentId == agentId }
        for obligation in obligations { try releaseQueuedDelivery(obligation) }
    }

    /// A human start revalidates every queued send's current authority before
    /// the launch can release anything. An obligation whose access is gone is
    /// retired here (the canonical message keeps its history) instead of waiting
    /// for the next delivery-capable trigger to rediscover it.
    func cancelUnauthorizedQueuedDeliveries(serverId: String, agentId: String) throws {
        try requireTransaction()
        let obligations = queuedDeliveryObligations(serverId: serverId) { $0.agentId == agentId }
        for obligation in obligations {
            guard !deliveryIsAuthorized(serverId: obligation.serverId, agentId: obligation.agentId,
                                        channelId: obligation.channelId, messageId: obligation.messageId) else { continue }
            try mutate { state in unlink(obligation.queue, state: &state) }
        }
    }

    /// The strict settlement predicate shared by every release authority: a
    /// start carrying the message, or a delivery command, that is still live on
    /// the agent's current launch. A second authority must link to it instead of
    /// staging a second frame.
    func liveObligationCommand(serverId: String, agentId: String,
                               channelId: String, messageId: String) -> AgentExecutionCommand? {
        agents.state.execution.liveObligationCommand(serverId: serverId, agentId: agentId,
                                                     channelId: channelId, messageId: messageId)
    }

    /// Upstream `attempt-wake`/`maybeWakePendingInboxAfterReady`: the oldest
    /// owed message rides the start itself as the first input. A tracked mention
    /// is never embedded (its occurrence needs the concrete session identity).
    /// Returns the updated start when it now carries a message.
    func carryQueuedWakeMessage(on start: AgentExecutionCommand) throws -> AgentExecutionCommand? {
        try requireTransaction()
        guard start.kind == .start, start.wakeMessage == nil else { return nil }
        let obligations = queuedDeliveryObligations(serverId: start.serverId) { $0.agentId == start.agentId }
        for obligation in obligations {
            if let released = obligation.releasedCommandId, !isSuperseded(released) { continue }
            guard deliveryIsAuthorized(serverId: obligation.serverId, agentId: obligation.agentId,
                                       channelId: obligation.channelId, messageId: obligation.messageId) else { continue }
            // A formal mention is delivered as a tracked occurrence once the
            // daemon reports the session identity; embedding it would lose that.
            guard messages.ensureMentionDeliveryOccurrence(
                messageId: obligation.messageId, agentId: obligation.agentId) == nil else { continue }
            let wake = AgentExecutionWakeMessage(channelId: obligation.channelId, messageId: obligation.messageId)
            var carried: AgentExecutionCommand?
            try mutate { state in
                guard var command = state.commands[start.commandId.uuidString],
                      command.kind == .start, command.wakeMessage == nil else { return }
                command.wakeMessage = wake
                state.commands[start.commandId.uuidString] = command
                link(obligation.queue, to: start.commandId, state: &state)
                carried = command
            }
            if let carried { return carried }
        }
        return nil
    }

    private func isSuperseded(_ commandId: UUID) -> Bool {
        agents.state.execution.commands[commandId.uuidString]?.status == .superseded
    }

    private func queuedDeliveryObligations(
        serverId: String, filter: (QueuedDeliveryObligation) -> Bool
    ) -> [QueuedDeliveryObligation] {
        let state = agents.state.execution
        var obligations: [QueuedDeliveryObligation] = []
        for (key, row) in state.pendingHumanDeliveries ?? [:] where row.serverId == serverId {
            obligations.append(QueuedDeliveryObligation(
                queue: .pending(key: key), serverId: row.serverId, agentId: row.agentId,
                channelId: row.channelId, messageId: row.messageId, createdAt: row.createdAt,
                releasedCommandId: row.releasedCommandId, cancelled: false))
        }
        for (key, row) in state.heldDeliveries ?? [:] where row.serverId == serverId && !row.cancelled {
            obligations.append(QueuedDeliveryObligation(
                queue: .held(key: key), serverId: row.serverId, agentId: row.agentId,
                channelId: row.channelId, messageId: row.messageId, createdAt: row.createdAt,
                releasedCommandId: row.releasedCommandId, cancelled: row.cancelled))
        }
        return obligations
            .filter(filter)
            .sorted { ($0.createdAt, $0.messageId) < ($1.createdAt, $1.messageId) }
    }

    /// Stage at most one strict attempt for one queued obligation. The release
    /// link is committed with the attempt so a second trigger (a start ACK, a
    /// process report, a session, a ready) can never stage the same message
    /// again, whichever authority reaches it first.
    private func releaseQueuedDelivery(_ obligation: QueuedDeliveryObligation) throws {
        try requireTransaction()
        let state = agents.state.execution
        if let released = obligation.releasedCommandId,
           let command = state.commands[released.uuidString], command.status != .superseded {
            return
        }
        if let live = liveObligationCommand(serverId: obligation.serverId, agentId: obligation.agentId,
                                            channelId: obligation.channelId, messageId: obligation.messageId) {
            try mutate { state in link(obligation.queue, to: live.commandId, state: &state) }
            return
        }
        guard deliveryIsAuthorized(serverId: obligation.serverId, agentId: obligation.agentId,
                                   channelId: obligation.channelId, messageId: obligation.messageId) else {
            // The message or the agent's access is gone: drop only the queued
            // fact; the canonical message keeps its history.
            try mutate { state in unlink(obligation.queue, state: &state) }
            return
        }
        if manuallyStopped(serverId: obligation.serverId, agentId: obligation.agentId)
            || hasActiveReset(serverId: obligation.serverId, agentId: obligation.agentId) { return }
        guard try humanMessageWakeRefusal(serverId: obligation.serverId, agentId: obligation.agentId) == nil else { return }
        let request = AgentExecutionDeliveryRequest(serverId: obligation.serverId, agentId: obligation.agentId,
                                                    channelId: obligation.channelId, messageId: obligation.messageId)
        let disposition = try requestHumanMessageDelivery(request)
        guard case .staged(let admission) = disposition else { return }
        try mutate { state in link(obligation.queue, to: admission.commandId, state: &state) }
    }

    private func link(_ queue: QueuedDeliveryQueue, to commandId: UUID, state: inout AgentExecutionState) {
        switch queue {
        case .pending(let key):
            guard var row = state.pendingHumanDeliveries?[key] else { return }
            row.releasedCommandId = commandId
            state.pendingHumanDeliveries?[key] = row
        case .held(let key):
            guard var row = state.heldDeliveries?[key] else { return }
            row.releasedCommandId = commandId
            state.heldDeliveries?[key] = row
        }
    }

    private func unlink(_ queue: QueuedDeliveryQueue, state: inout AgentExecutionState) {
        switch queue {
        case .pending(let key):
            _ = state.pendingHumanDeliveries?.removeValue(forKey: key)
        case .held(let key):
            state.heldDeliveries?[key]?.cancelled = true
        }
    }
}
