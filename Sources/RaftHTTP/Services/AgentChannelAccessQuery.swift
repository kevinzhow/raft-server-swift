import Foundation

/// Agent channel visibility over the retained posting rows. A thread is
/// readable through its parent, exactly like the pinned
/// `filterAgentsWithChannelAccess` (`channelService.ts:6740-6756`), which
/// recurses through the parent message's channel for a plain thread and through
/// the local parent projection for a joint thread.
struct AgentChannelAccessQuery: Sendable {
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let oauth: OAuthLedger

    func canAccess(channelId: String, serverId: String, agentId: String) -> Bool {
        var visited: Set<String> = []
        func visit(_ id: String) -> Bool {
            guard visited.count < 64, visited.insert(id).inserted,
                  let channel = channels.postableChannels[id],
                  channel.serverId == serverId, channel.deletedAt == nil
            else { return false }
            switch channel.kind {
            case "channel":
                return true
            case "thread":
                if let parentId = channel.parentChannelId, visit(parentId) { return true }
                guard let parentMessageId = channel.parentMessageId,
                      let parentChannelId = messages.humanMessageRows.first(where: { $0.id == parentMessageId })?.channelId
                else { return false }
                return visit(parentChannelId)
            default:
                return channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
                    || oauth.isChannelParticipant(channelId: id, userId: agentId)
            }
        }
        if visit(channelId) { return true }
        guard channels.postableChannels[channelId] == nil else { return false }
        return LedgerChannelReadFallback.canReadAgent(
            channelId: channelId, serverId: serverId, agentId: agentId, oauth: oauth)
    }
}
