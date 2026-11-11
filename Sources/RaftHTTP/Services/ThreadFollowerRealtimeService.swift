import Foundation

/// Upstream `getHumanThreadFollowerIds` plus the send-time `socketsJoin` loop
/// shared by `emitPersistedMessageToFrontend`, `broadcastSystemMessage` and the
/// action-card carrier emitter.
///
/// The follow ledger is the Messages owner; channel visibility and server
/// membership stay with their existing owners. This type joins no lock of its
/// own: it reads each snapshot separately and never calls the relay while a
/// store borrow is held.
struct ThreadFollowerRealtimeService: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let oauth: OAuthLedger

    /// Active human followers of one thread that may receive its room events.
    ///
    /// Non-joint threads follow the upstream predicate: a public parent admits
    /// a live server member unless the member is a guest on a non-guest-visible
    /// channel; a channel-local human member is always admitted. A joint thread
    /// projection admits only the parent's channel-local humans.
    func humanFollowerIds(threadChannelId: String, serverId: String) -> [String] {
        let storage = channels.state
        guard let thread = storage.postableChannels[threadChannelId],
              thread.kind == "thread",
              thread.deletedAt == nil,
              thread.serverId == serverId,
              let parentChannelId = thread.parentChannelId,
              let parent = storage.postableChannels[parentChannelId],
              parent.deletedAt == nil
        else { return [] }
        let jointThread = storage.jointProjections.contains {
            $0.localChannelId == threadChannelId && $0.status == "active"
        }
        let channelHumans = Set(oauth.channelHumanIds(channelId: parentChannelId))
        let guestVisible = storage.guestVisibleChannels[parentChannelId] == true
        let follows = messages.threadFollows.values
            .filter { $0.serverId == serverId && $0.threadChannelId == threadChannelId }
            .sorted { $0.userId < $1.userId }
        var seen = Set<String>()
        var ids: [String] = []
        for follow in follows {
            let userId = follow.userId
            guard seen.insert(userId).inserted else { continue }
            // Thread follows share one ledger for humans and agents. The
            // upstream socket join selects `followerType === "user"` only.
            guard oauth.agentRuntimeInfo(id: userId) == nil else { continue }
            let isParentHuman = channelHumans.contains(userId) || parent.memberIds.contains(userId)
            let isServerMember: Bool
            if jointThread {
                isServerMember = false
            } else if parent.kind == "channel",
                      let role = oauth.memberRole(serverId: serverId, userId: userId) {
                isServerMember = role != "guest" || guestVisible
            } else {
                isServerMember = false
            }
            if isParentHuman || isServerMember { ids.append(userId) }
        }
        return ids
    }

    /// Upstream's `isSystemMessageIdentity` parent guard plus the
    /// `senderId !== senderId` exemption for a reply to one's own message.
    static func parentAuthorId(of parent: StoredHumanMessage?, replyingSenderId: String) -> String? {
        guard let parent, parent.messageType != "system", parent.senderId != "system",
              parent.senderType == "user" || parent.senderType == "agent",
              parent.senderId != replyingSenderId
        else { return nil }
        return parent.senderId
    }

    /// Grant every eligible follower's server-scoped sockets the thread room.
    /// Callers run this after their follow writes and immediately before the
    /// `message:new` emit, matching the upstream ordering.
    func joinHumanFollowers(threadChannelId: String, serverId: String) {
        let relay = RealtimeRelayService(messages: messages)
        for userId in humanFollowerIds(threadChannelId: threadChannelId, serverId: serverId) {
            relay.joinUserServerSessions(userId, serverId, "channel:\(threadChannelId)")
        }
    }
}
