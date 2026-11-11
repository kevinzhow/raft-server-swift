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
    /// The deliverability rule is the same one an ordinary human message uses.
    func mentionDeliveryDropReason(serverId: String, agentId: String) -> String? {
        guard (try? ownedAgent(serverId: serverId, agentId: agentId)) != nil else { return "delivery_unavailable" }
        do {
            // An admitted launch that has not reported its process defers the
            // tracked mention to `agent:session`; `stageDelivery` accepts that
            // readable-only disposition as a successful queue. It is not a
            // reason to drop the action.
            guard let refusal = try humanMessageWakeRefusal(serverId: serverId, agentId: agentId) else {
                return nil
            }
            return refusal == .launchInProgress ? nil : "target_not_queued"
        } catch {
            return "target_not_queued"
        }
    }
}
