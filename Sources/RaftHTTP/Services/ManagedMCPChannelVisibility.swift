import Foundation

/// The two channel-visibility decisions the assignment and read-state services
/// (and the unmigrated managed-MCP, inbox and thread callers behind the
/// directory forwarders) share.
struct ManagedMCPChannelVisibility: Sendable {
    let oauth: OAuthLedger
    let channels: ServersAndChannelsStore

    /// A plain channel is visible to every member; any other kind only to its
    /// participants. A channel without a posting row falls back to the ledger.
    func actorCanSee(channelId: String, userId: String) -> Bool {
        if let postable = channels.postableChannel(id: channelId) {
            if oauth.channelInfo(id: channelId) != nil {
                return oauth.channelType(id: channelId) == "channel"
                    || oauth.isChannelParticipant(channelId: channelId, userId: userId)
            }
            return postable.kind == "channel" || postable.memberIds.contains(userId)
        }
        return oauth.channelType(id: channelId) == "channel"
            || oauth.isChannelParticipant(channelId: channelId, userId: userId)
    }

    /// Guests may only see channels they explicitly joined; a hidden public
    /// channel must stay cloaked for the guest role.
    func guestDeniedHiddenChannel(channelId: String, serverId: String, userId: String) -> Bool {
        guard oauth.memberRole(serverId: serverId, userId: userId) == "guest" else { return false }
        return !oauth.channelHumanIds(channelId: channelId).contains(userId)
    }
}
