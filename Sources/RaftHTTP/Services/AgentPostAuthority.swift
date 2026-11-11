import Foundation

/// Upstream `channelService.canAgentPostToChannel` for the decisions the send
/// and action-card target paths need before a channel row exists (a new DM) or
/// after one is resolved (a DM, a thread, `#all`).
///
/// RFC 074 §2: an assistant (raw `agents.assistant_owner_user_id`, independent
/// of the `identity_borrowing` display flag) posts only in its DM with its
/// owner, or a thread under that DM. That verdict comes before the enabled
/// `#all` shortcut, so an assistant is refused there even though ordinary
/// server agents may post.
struct AgentPostAuthority: Sendable {
    let oauth: OAuthLedger
    let channels: ServersAndChannelsStore
    let agents: AgentsRuntimeStore

    /// `nil` when the agent is not an assistant (the ordinary rules apply).
    func assistantMayPost(
        serverId: String,
        agentId: String,
        channelId: String,
        kind: String
    ) -> Bool? {
        guard let owner = AssistantOwnershipQuery(agents: agents, oauth: oauth)
            .rawOwner(agentId: agentId) else { return nil }
        let dmChannelId: String
        if kind == "thread" {
            guard let parentId = channels.postableChannel(id: channelId)?.parentChannelId,
                  let parent = channels.postableChannel(id: parentId),
                  parent.kind == "dm" else { return false }
            dmChannelId = parentId
        } else if kind == "dm" {
            dmChannelId = channelId
        } else {
            return false
        }
        guard oauth.channelHumanIds(channelId: dmChannelId).contains(owner),
              oauth.channelAgentIds(channelId: dmChannelId).contains(agentId),
              channels.postableChannel(id: dmChannelId)?.serverId == serverId else {
            return false
        }
        return true
    }

    func canPost(serverId: String, agentId: String, channelId: String) -> Bool {
        guard let channel = channels.postableChannel(id: channelId),
              channel.serverId == serverId, channel.deletedAt == nil else { return false }
        if let verdict = assistantMayPost(
            serverId: serverId, agentId: agentId, channelId: channelId, kind: channel.kind
        ) {
            return verdict
        }
        if channel.kind == "channel", oauth.allChannelId(serverId: serverId) == channelId {
            return true
        }
        return channel.memberIds.contains(agentId)
            || oauth.channelAgentIds(channelId: channelId).contains(agentId)
    }
}
