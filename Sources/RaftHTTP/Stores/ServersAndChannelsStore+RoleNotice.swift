import Foundation

/// The role-DM owner can only enter these concrete OAuth leaves. The port has
/// no callback or reference to Channels/Messages, so it cannot reverse the locks.
struct RoleNoticeLedgerPort: Sendable {
    private let oauth: OAuthLedger

    init(oauth: OAuthLedger) {
        self.oauth = oauth
    }

    func directChannel(serverId: String, actorUserId: String, agentId: String) -> String {
        oauth.createDirectChannel(serverId: serverId, firstUserId: actorUserId, secondUserId: agentId)
    }

    func bindMembers(channelId: String, actorUserId: String, agentId: String) {
        oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        oauth.addChannelHuman(channelId: channelId, userId: actorUserId)
    }
}

extension ServersAndChannelsStore {
    /// The existing projection or its complete role-notice preparation. Keeping
    /// the projection and membership stages under this owner borrow prevents a
    /// second notice from treating an in-progress projection as ready. OAuth's
    /// existing operation remains the sole DM identity get-or-create.
    func prepareRoleNoticeDirectChannel(
        serverId: String,
        actorUserId: String,
        agentId: String,
        ledger: RoleNoticeLedgerPort
    ) -> String {
        mutex.withLock { state in
            if let existing = state.postableChannels.first(where: { _, channel in
                channel.serverId == serverId && channel.kind == "dm"
                    && channel.memberIds.contains(actorUserId) && channel.memberIds.contains(agentId)
            }) {
                return existing.key
            }
            let channelId = ledger.directChannel(serverId: serverId, actorUserId: actorUserId, agentId: agentId)
            state.postableChannels[channelId] = PostableChannel(
                serverId: serverId,
                memberIds: [actorUserId, agentId],
                kind: "dm",
                name: "dm"
            )
            ledger.bindMembers(channelId: channelId, actorUserId: actorUserId, agentId: agentId)
            return channelId
        }
    }
}
