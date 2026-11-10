import Foundation

/// Applies follow facts from an actual newly committed agent reply. It owns no
/// state and never dispatches agent messages or invents recipient membership.
struct AgentReplyThreadFollowCommit: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let oauth: OAuthLedger

    func apply(messageId: String, channelId: String, serverId: String, agentId: String, mentions: [MentionInput]) {
        guard messages.humanMessageRows.contains(where: {
            $0.id == messageId && $0.channelId == channelId && $0.senderId == agentId && $0.senderType == "agent"
        }), let thread = channels.postableChannel(id: channelId), thread.kind == "thread",
            thread.serverId == serverId, thread.deletedAt == nil,
            let parentId = thread.parentChannelId, let parentMessageId = thread.parentMessageId,
            let parent = channels.postableChannel(id: parentId), parent.serverId == serverId, parent.deletedAt == nil
        else { return }
        let parentAgents = Set(oauth.channelAgentIds(channelId: parentId))
        // Actual parent membership is required for a reply to reactivate a
        // receiver; public readability alone cannot create this authority.
        guard parentAgents.contains(agentId), parent.kind != "dm" || parent.memberIds.contains(agentId) else { return }
        var eligible: [ThreadMentionFollowTarget] = []
        for mention in mentions where mention.id != agentId {
            let isMember: Bool
            switch mention.type {
            case "agent":
                guard let agent = oauth.agentRuntimeInfo(id: mention.id), !agent.deleted, agent.serverId == serverId else { continue }
                isMember = parentAgents.contains(mention.id) && (parent.kind != "dm" || parent.memberIds.contains(mention.id))
            case "user":
                isMember = parent.memberIds.contains(mention.id) && oauth.memberRole(serverId: serverId, userId: mention.id) != nil
            default: continue
            }
            if isMember { eligible.append(ThreadMentionFollowTarget(userId: mention.id, isParentMember: true)) }
        }
        messages.applyThreadReplyFollows(serverId: serverId, threadChannelId: channelId,
            parentMessageId: parentMessageId, senderId: agentId, mentioned: eligible)
        let parentSender = oauth.historyMessages(channelId: parentId).first { $0.id == parentMessageId }?.senderId
            ?? messages.humanMessageRows.first { $0.id == parentMessageId }?.senderId
        if let parentSender, parentSender != "system", parentSender != agentId,
           oauth.memberRole(serverId: serverId, userId: parentSender) != nil {
            // The authored-parent default is not an explicit reactivation.
            messages.ensureThreadFollows([(serverId, parentSender, channelId, parentMessageId)])
        }
    }
}
