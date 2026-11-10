import Foundation

/// Access to thread content is separate from passive thread audience selection.
/// Public-parent followers may read; private/DM followers still need real parent
/// membership. A retained follow never manufactures revoked parent access.
struct AgentExecutionThreadParentAccess {
    static func permitsAgent(serverId: String, agentId: String, parent: PostableChannel?, parentAgentIds: Set<String>) -> Bool {
        guard let parent, parent.serverId == serverId, parent.deletedAt == nil else { return false }
        if parent.kind == "channel" { return true }
        guard ["private", "dm", "joint"].contains(parent.kind), parentAgentIds.contains(agentId) else { return false }
        return parent.kind != "dm" || parent.memberIds.contains(agentId)
    }
}

extension AgentExecutionDomain {
    /// Resolve a local conversation and recheck current authority when the
    /// retained outbox worker or materializer resolves its immutable reference.
    func deliveryIsAuthorized(serverId: String, agentId: String, channelId: String, messageId: String) -> Bool {
        guard !messageId.isEmpty, !channelId.isEmpty else { return false }
        let snapshot = channels.deliveryAckChannelSnapshot()
        guard let local = snapshot.channels[channelId], local.serverId == serverId, local.deletedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else { return false }
        let links = snapshot.jointProjections.filter { $0.localChannelId == channelId }
        let canonical: String
        if links.isEmpty { canonical = channelId }
        else {
            let active = links.filter { $0.serverId == serverId && $0.status == "active" }
            guard active.count == 1 else { return false }
            canonical = active[0].canonicalChannelId
        }
        guard oauth.reminderMessageMetadata(id: messageId)?.channelId == canonical else { return false }
        if let allowed = claimedMentionReadAuthority(serverId: serverId, agentId: agentId,
                                                     channelId: channelId, messageId: messageId, canonical: canonical) {
            // A matching accepted mention keeps its strict current read fence;
            // a stale postable projection must not undo OAuth revocation.
            return allowed
        }
        let joined = oauth.channelAgentIds(channelId: channelId).contains(agentId)
        if local.kind == "dm" { return local.memberIds.contains(agentId) && joined }
        if local.kind == "thread" {
            guard let parentId = local.parentChannelId,
                  AgentExecutionThreadParentAccess.permitsAgent(serverId: serverId, agentId: agentId,
                      parent: snapshot.channels[parentId], parentAgentIds: Set(oauth.channelAgentIds(channelId: parentId))) else { return false }
            // Explicit task delivery can target a real parent member; ordinary
            // human thread sends select active eligible followers in the producer.
            if local.memberIds.contains(agentId) || joined || oauth.channelAgentIds(channelId: parentId).contains(agentId) { return true }
            let follow = "\(serverId)\n\(agentId)\n\(channelId)"
            let active = messages.threadFollowSnapshot()
            return active.follows.contains(follow) && !active.unfollows.contains(follow)
        }
        return local.memberIds.contains(agentId) || joined
    }

    /// nil preserves the ordinary delivery rule. A value comes only from a real
    /// committed/pending-UoW claim with its exact retained host and target, never
    /// from an arbitrary notified flag, requested actor or a temporary join.
    private func claimedMentionReadAuthority(serverId: String, agentId: String, channelId: String,
                                            messageId: String, canonical: String) -> Bool? {
        let rows = messages.humanMessageRows.filter { $0.id == messageId && $0.channelId == canonical }
        guard rows.count == 1, let host = rows.first, ["user", "agent"].contains(host.senderType) else { return nil }
        let claims = messages.state.storedMentions.filter {
            $0.messageId == messageId && $0.channelId == channelId && $0.targetType == "agent"
                && $0.targetId == agentId && !$0.notifiableAtSend && $0.notifiedAt != nil
                && $0.notifiedByType == host.senderType && $0.notifiedById == host.senderId
                && ["notify_only", "add"].contains($0.notifiedAction ?? "")
        }
        guard claims.count == 1 else { return nil }
        guard let local = channels.state.postableChannels[channelId], local.serverId == serverId,
              local.kind == "channel" || local.kind == "thread" else { return false }
        return MessageMentionScopeQuery(messages: messages, channels: channels, oauth: oauth)
            .agentCanRead(channelId: channelId, serverId: serverId, agentId: agentId)
    }

    /// Read-only mention admission preflight. A known manual stop/reset must not
    /// call requestHumanMessageDelivery, whose ordinary message behavior records
    /// a held delivery. The mutating path remains the existing retained facade.
    func mentionDeliveryDropReason(serverId: String, agentId: String) -> String? {
        guard (try? ownedAgent(serverId: serverId, agentId: agentId)) != nil else { return "delivery_unavailable" }
        if manuallyStopped(serverId: serverId, agentId: agentId) || hasActiveReset(serverId: serverId, agentId: agentId) {
            return "target_not_queued"
        }
        guard let machineId = agents.agentMachineIds[agentId],
              machines.machines.contains(where: { $0.id == machineId && $0.serverId == serverId }) else { return "target_not_queued" }
        let state = agents.state.execution
        guard let connection = state.connections[machineId], connection.serverId == serverId,
              connection.online, connection.ready, connection.runtimes.contains("codex"), connection.daemonInstanceId != nil else {
            return "target_not_queued"
        }
        if let agent = state.agents[agentId] {
            guard agent.serverId == serverId, agent.machineId == machineId, agent.needsManual == nil else { return "target_not_queued" }
            let current = agent.currentLaunchId.flatMap { agent.launches[$0] }
            if current.map({ !$0.completed && !$0.notSpawned && !$0.terminalFailure }) != true {
                guard !hasBlockingUnexitedExecution(agentId: agentId, agent: agent, state: state) else { return "target_not_queued" }
                let now = Date()
                if agent.blockedUntil.map({ now < $0 }) == true || agent.probeExpiresAt.map({ now >= $0 }) == true {
                    return "target_not_queued"
                }
                if let launch = current {
                    if !launch.completed && !launch.notSpawned && !launch.terminalFailure { return "target_not_queued" }
                    if launch.terminalFailure && agent.processes.values.contains(where: { !$0.exited && $0.launchIds.contains(launch.launchId) }) {
                        return "target_not_queued"
                    }
                }
                guard agent.generation < 9_007_199_254_740_991, agent.takeoverEpoch < 9_007_199_254_740_991 else {
                    return "target_not_queued"
                }
            } else if current?.stopRequested == true { return "target_not_queued" }
        }
        return nil
    }
}
