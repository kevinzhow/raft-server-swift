import Foundation
import RaftShared

/// One `agent:activity` Socket.IO frame produced by a server-owned presence
/// projection (`ready` reconciliation or a machine disconnect). The values come
/// only from retained facts; the sequence is the process-lifetime monotonic
/// counter shared with daemon activity frames.
struct AgentPresenceEmission: Sendable {
    let serverId: String
    let agentId: String
    let timestampMilliseconds: Int
    let sequence: Int
    let presence: AgentPresenceSignal.ReadyPresence
}

/// The owner-borrow result of one ready reconciliation: the activity frames to
/// publish after COMMIT and the persisted agent statuses to write.
struct AgentPresenceReconcile: Sendable {
    var emissions: [AgentPresenceEmission] = []
    var statusUpdates: [(agentId: String, status: String)] = []
}

extension AgentExecutionDomain {
    /// The agents assigned to this machine, with their authoritative persisted
    /// status. Upstream `loadAgentsForReadyReconcile` reads the same binding.
    /// An invalid stored status is reported as invalid and never guessed into a
    /// writable value; the caller fails closed to `inactive` for planning only.
    func readyReconcileAgents(_ context: AgentExecutionMachineContext)
        -> [(agentId: String, status: String, valid: Bool)] {
        agents.agentIds(boundToMachine: context.machineId).sorted().compactMap { agentId in
            guard let info = oauth.agentRuntimeInfo(id: agentId), !info.deleted,
                  info.serverId == context.serverId else { return nil }
            let valid = ["active", "inactive", "stopped"].contains(info.status)
            return (agentId, info.status, valid)
        }
    }

    /// Apply `planReadyReconcileAction` over every agent assigned to the
    /// machine. Must run inside the caller's Agents owner borrow with the
    /// connection already marked ready. Persisted statuses are written by the
    /// caller after this borrow releases, matching the existing status signal.
    func reconcileReadyPresence(_ state: inout AgentsRuntimeStore.State,
                                context: AgentExecutionMachineContext,
                                machineAgents: [(agentId: String, status: String, valid: Bool)],
                                runningAgentIds: Set<String>,
                                now: Date) -> AgentPresenceReconcile {
        var result = AgentPresenceReconcile()
        for entry in machineAgents {
            // An invalid persisted status fails closed for planning only; the
            // stored status is preserved and never rewritten from a guess.
            let status = entry.valid ? entry.status : "inactive"
            let running = runningAgentIds.contains(entry.agentId)
            let resetActive = (state.execution.resetIntents ?? [:]).values.contains {
                $0.serverId == context.serverId && $0.agentId == entry.agentId && $0.phase.isActive
            }
            let action = AgentPresenceSignal.readyReconcileAction(
                status: status, running: running, resetActive: resetActive)
            if action == .markWakeableNotRunning,
               hasPendingStart(state.execution, agentId: entry.agentId, machineId: context.machineId) {
                // A start this server already sent is still awaiting its ACK.
                // The ready inventory predates it; do not drop its launch guard.
                continue
            }
            let presence = AgentPresenceSignal.readyPresence(action, status: status)
            // The dbStatus projection is independent of the live activity
            // broadcast: a deduped/suppressed online broadcast still persists
            // the reconciled agent status.
            if entry.valid, let persisted = presence.status, persisted != status {
                result.statusUpdates.append((entry.agentId, persisted))
            }
            if action == .markActiveOnline || action == .markWakeableNotRunning {
                // `broadcastReadyOnline`: dedupe window first, then preserve a
                // fresh busy observation instead of stamping it online.
                if let last = state.lastReadyOnlineBroadcastAt[entry.agentId],
                   now.timeIntervalSince(last) < AgentPresenceSignal.readyOnlineDedupeSeconds {
                    continue
                }
                if AgentPresenceSignal.isFreshBusyActivity(
                    activity: state.agentActivities[entry.agentId]?.activity,
                    detailKind: state.agentActivityDetailKind[entry.agentId],
                    observedAt: state.agentActivityObservedAt[entry.agentId], now: now) {
                    continue
                }
                state.lastReadyOnlineBroadcastAt[entry.agentId] = now
            }
            result.emissions.append(writePresence(state: &state, context: context,
                                                 agentId: entry.agentId, presence: presence, now: now))
        }
        return result
    }

    /// Project the retained machine-disconnect activity after the upstream grace
    /// window. The caller (production ingress) schedules this; it is a no-op if
    /// the machine reconnected or a newer epoch already projected.
    func projectMachineDisconnect(_ context: AgentExecutionMachineContext) throws {
        try requireTransaction()
        guard ownsMachine(context) else { throw AgentExecutionError.ownershipMismatch }
        let machineAgents = readyReconcileAgents(context)
        let now = Date()
        guard let emissions = projectMachineDisconnectPresence(context, machineAgents: machineAgents, now: now) else { return }
        queuePresenceEmissions(emissions)
    }

    /// `reduceMachineDisconnectLifecycle`: one projection per connection epoch.
    /// Only agents whose persisted status is `active` are marked offline; the
    /// status write is deliberately skipped and the activity is retained as the
    /// transport-loss fact. Returns nil when this connection already projected
    /// or a newer connection for the machine exists.
    func projectMachineDisconnectPresence(_ context: AgentExecutionMachineContext,
                                          machineAgents: [(agentId: String, status: String, valid: Bool)],
                                          now: Date) -> [AgentPresenceEmission]? {
        var emissions: [AgentPresenceEmission] = []
        var projected = false
        agents.withState { state in
            guard let connection = state.execution.connections[context.machineId],
                  connection.serverId == context.serverId,
                  connection.connectionEpochId == context.connectionEpochId,
                  !connection.online else { return }
            let key = AgentExecutionState.key(context.machineId, context.connectionEpochId)
            guard state.projectedMachineDisconnects.insert(key).inserted else { return }
            projected = true
            for entry in machineAgents where entry.valid && entry.status == "active" {
                emissions.append(writePresence(state: &state, context: context, agentId: entry.agentId,
                                               presence: AgentPresenceSignal.machineDisconnectedPresence, now: now))
            }
        }
        return projected ? emissions : nil
    }

    /// One owner-borrow activity write with the shared activity sequence.
    private func writePresence(state: inout AgentsRuntimeStore.State,
                               context: AgentExecutionMachineContext, agentId: String,
                               presence: AgentPresenceSignal.ReadyPresence,
                               now: Date) -> AgentPresenceEmission {
        state.agentActivities[agentId] = (presence.activity, presence.detail)
        state.agentActivityDetailKind[agentId] = presence.detailKind
        state.agentActivityObservedAt[agentId] = now
        let nowMilliseconds = Int((now.timeIntervalSince1970 * 1000).rounded(.down))
        let sequence = max(nowMilliseconds, state.agentActivityServerSeq + 1)
        state.agentActivityServerSeq = sequence
        return AgentPresenceEmission(serverId: context.serverId, agentId: agentId,
                                     timestampMilliseconds: nowMilliseconds, sequence: sequence,
                                     presence: presence)
    }

    /// The upstream `agent:status` frame the ready planner already sent but the
    /// daemon has not acknowledged. Such an agent must not be marked not-running.
    private func hasPendingStart(_ state: AgentExecutionState, agentId: String, machineId: String) -> Bool {
        state.commands.values.contains {
            $0.kind == .start && $0.agentId == agentId && $0.machineId == machineId
                && ($0.status == .pending || $0.status == .dispatched)
        }
    }

    /// RFC 071 §9 `projectTerminalBlock`: a wake suppressed by the manual /
    /// breaker gate is shown to the Web as the typed offline activity. The
    /// upstream server stores that snapshot; this port keeps the daemon's real
    /// activity fact and serves the block from the retained recovery gate at
    /// read time, so this only pushes the equivalent `agent:activity` notice.
    func queueTerminalBlockFrame(serverId: String, agentId: String,
                                 block: (detail: String, detailKind: String), now: Date = Date()) {
        let milliseconds = Int((now.timeIntervalSince1970 * 1000).rounded(.down))
        let fields: [OrderedJSONField] = [
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("activity", "offline"),
            OrderedJSONField("activityKind", "offline"),
            OrderedJSONField("detail", block.detail),
            OrderedJSONField("detailKind", block.detailKind),
            OrderedJSONField("timestamp", milliseconds),
            OrderedJSONField("serverSeq", milliseconds),
        ]
        let rendered = OrderedJSON.object(fields).render()
        let room = "server:\(serverId)"
        let messages = messages
        DeferredEffects.emit {
            RealtimeRelayService(messages: messages).emit(room, "agent:activity", rendered)
        }
    }

    /// Persist the ready-reconciled statuses in the same transaction as the
    /// activity projection. The local mirror is updated exactly like the daemon
    /// status signal path so both readers agree.
    func applyReadyPresenceStatusUpdates(_ updates: [(agentId: String, status: String)]) {
        for update in updates {
            oauth.setAgentStatus(id: update.agentId, status: update.status)
            agents.withState { $0.serverAgents[update.agentId]?.status = update.status }
        }
    }

    /// Post-COMMIT Socket.IO push for server-owned presence projections. The
    /// payload member order matches the daemon activity broadcast.
    func queuePresenceEmissions(_ emissions: [AgentPresenceEmission]) {
        for emission in emissions {
            let fields: [OrderedJSONField] = [
                OrderedJSONField("agentId", emission.agentId),
                OrderedJSONField("activity", emission.presence.activity),
                OrderedJSONField("activityKind", emission.presence.activity),
                OrderedJSONField("detail", emission.presence.detail),
                OrderedJSONField("detailKind", emission.presence.detailKind),
                OrderedJSONField("timestamp", emission.timestampMilliseconds),
                OrderedJSONField("serverSeq", emission.sequence),
            ]
            let rendered = OrderedJSON.object(fields).render()
            let room = "server:\(emission.serverId)"
            let messages = messages
            DeferredEffects.emit {
                RealtimeRelayService(messages: messages).emit(room, "agent:activity", rendered)
            }
        }
    }
}
