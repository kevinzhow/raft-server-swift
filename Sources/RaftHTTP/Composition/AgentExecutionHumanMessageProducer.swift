import Foundation
import RaftShared

/// Recipient selection stays inside the human-message business transaction. The
/// execution owner records only immutable delivery/command references; its worker
/// and materializer remain the only path to the authenticated machine transport.
struct AgentExecutionHumanMessageProducer: Sendable {
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let oauth: OAuthLedger
    let execution: AgentExecutionService

    /// The current human writer stores the requested channel, whereas joint
    /// materialization needs canonical storage and regular-participant authority.
    /// Reject only an actual active joint surface, after caller authorization and
    /// before mutation. A historical/inactive link does not classify an ordinary
    /// channel as a joint. Unbound legacy compositions do not invoke this gate.
    func requireSupportedSurface(channelId: String) throws {
        let snapshot = channels.deliveryAckChannelSnapshot()
        var ids: Set<String> = [channelId]
        if let channel = snapshot.channels[channelId], channel.kind == "thread", let parent = channel.parentChannelId {
            ids.insert(parent)
        }
        if snapshot.jointProjections.contains(where: {
            $0.status == "active" && (ids.contains($0.localChannelId) || ids.contains($0.canonicalChannelId))
        }) {
            throw HumanMessageExecutionUnsupportedSurface()
        }
    }

    /// Returns the agents whose wake upstream would report as suppressed. The
    /// canonical message stays committed; the sender-visible v2 warning is the
    /// only place a non-deliverable recipient is surfaced, never a fake receipt.
    func deliverCreated(messageId: String, channelId: String) throws -> [String] {
        try requireSupportedSurface(channelId: channelId)
        let snapshot = channels.deliveryAckChannelSnapshot()
        guard let channel = snapshot.channels[channelId], channel.deletedAt == nil,
              ["channel", "private", "dm", "thread"].contains(channel.kind),
              !snapshot.jointProjections.contains(where: { $0.localChannelId == channelId }),
              let message = messages.humanMessageRows.first(where: { $0.id == messageId && $0.channelId == channelId }),
              ["user", "human"].contains(message.senderType), message.externalMessageId == nil else { return [] }
        let candidates: Set<String>
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId, let parent = snapshot.channels[parentId], parent.kind != "joint" else { return [] }
            let parentAgents = Set(oauth.channelAgentIds(channelId: parentId))
            let follows = messages.deliveryAckMessageSnapshot().threadFollows.values
            let active = messages.threadFollowSnapshot()
            candidates = Set(follows.compactMap { follow in
                guard follow.serverId == channel.serverId, follow.threadChannelId == channelId,
                      follow.parentMessageId == channel.parentMessageId,
                      !active.unfollows.contains("\(follow.serverId)\n\(follow.userId)\n\(channelId)"),
                      AgentExecutionThreadParentAccess.permitsAgent(serverId: channel.serverId, agentId: follow.userId,
                          parent: snapshot.channels[parentId], parentAgentIds: parentAgents) else { return nil }
                return follow.userId
            })
        } else {
            let joined = Set(oauth.channelAgentIds(channelId: channelId))
            // A DM target is implicit only when both retained owners agree it is
            // an actual direct participant. No mention or legacy agentId is needed.
            candidates = channel.kind == "dm" ? joined.intersection(channel.memberIds) : joined
        }
        let suppression = MessageSuppressionService(messages: messages, oauth: oauth)
        let recipients = candidates.filter { id in
            guard let agent = oauth.agentRuntimeInfo(id: id), !agent.deleted,
                  agent.serverId == channel.serverId, agent.runtime == "codex" else { return false }
            return !suppression.isSuppressed(message, agentId: id)
        }.sorted()
        guard !recipients.isEmpty else { return [] }
        var wakeSuppressed: [String] = []
        do {
            try DeferredEffects.requireDurableTransaction(in: .shared)
            for agentId in recipients {
                let disposition = try execution.requestHumanMessageDelivery(.init(
                    serverId: channel.serverId, agentId: agentId, channelId: channelId, messageId: messageId))
                switch disposition {
                case .staged, .held: break
                case .readableOnly(let refusal):
                    // Canonical message/unread history remain committed. There is
                    // no claim of an offline queue, future retry or daemon receipt.
                    // Upstream reports a suppressed wake for a DM; carry the real
                    // refusal out so the v2 sender sees it instead of a silent 200.
                    if refusal == .recoveryRequired || refusal == .breakerPaused { wakeSuppressed.append(agentId) }
                }
            }
        } catch {
            DeferredEffects.markRollbackOnly()
            throw error
        }
        return wakeSuppressed.sorted()
    }
}

/// An explicit native limitation, not a claim of Node joint-send parity.
private struct HumanMessageExecutionUnsupportedSurface: DomainError {
    var status: UInt { 503 }
    var errorMessage: String { "Human-message execution is not supported for joint conversations" }
    var errorCode: String? { "human_delivery_scope_unsupported" }
}
