import Foundation

/// Admit the exact typed catalog target before its existing renderer returns it.
struct HumanMessageContextAccessQuery {
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let oauth: OAuthLedger
    let flags: AgentsRuntimeStore

    func authorize(target: MessageContext.Target, scope: HumanChannelReadAccessQuery.ServerScope) throws {
        let root = target.message.channelId.lowercased()
        let source = target.sourceChannelId.lowercased()
        guard ServerScope.isUUID(root), ServerScope.isUUID(source), ServerScope.isUUID(target.message.id) else {
            throw SearchMentionsError.contextMessageNotFound
        }
        if let current = messages.humanMessageRows.first(where: {
            $0.id.caseInsensitiveCompare(target.message.id) == .orderedSame
        }), current.channelId.lowercased() != source {
            throw SearchMentionsError.contextMessageNotFound
        }
        let access = HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: flags)
        guard access.authority(channelId: root, serverId: scope.serverId, userId: scope.userId) != nil else {
            throw SearchMentionsError.contextMessageNotFound
        }
        let state = channels.state
        let links = state.jointProjections.filter {
            $0.localChannelId.lowercased() == root && $0.serverId == scope.serverId && $0.status == "active"
        }
        if root != source || !links.isEmpty {
            guard links.count == 1, links[0].canonicalChannelId.lowercased() == source else {
                throw SearchMentionsError.contextMessageNotFound
            }
        }
        if let thread = target.thread {
            guard let local = state.postableChannels[root], local.kind == "thread",
                  local.parentChannelId?.lowercased() == thread.localParentChannelId.lowercased(),
                  local.parentMessageId?.lowercased() == thread.canonicalParentMessageId.lowercased(),
                  thread.localThreadChannelId.lowercased() == root,
                  thread.canonicalThreadChannelId.lowercased() == source,
                  state.jointProjections.contains(where: {
                      $0.localChannelId.lowercased() == thread.localParentChannelId.lowercased()
                          && $0.canonicalChannelId.lowercased() == thread.canonicalParentChannelId.lowercased()
                          && $0.serverId == scope.serverId && $0.status == "active"
                  }) else { throw SearchMentionsError.contextMessageNotFound }
        }
    }
}
