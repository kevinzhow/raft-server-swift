import Foundation

/// The existing channel probe decision, shared by lifecycle and assignments.
/// Each query reads its owners when called; no row or permission is cached.
struct ChannelProbeAccessQuery: Sendable {
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let inboxFacts: InboxFactStore
    let oauth: OAuthLedger

    func access(channelId: String, serverId: String, userId: String) -> ChannelProbeAccess {
        let channelRows = channels.postableChannels
        guard let channel = channelRows[channelId], channel.serverId == serverId else { return .hidden }
        if channel.kind == "channel"
            || channel.memberIds.contains(userId)
            || oauth.channelType(id: channelId) == "channel"
            || oauth.isChannelParticipant(channelId: channelId, userId: userId)
            || (channel.kind == "thread" && messages.threadFollows["\(serverId)\n\(userId)\n\(channelId)"] != nil) {
            return .allowed
        }
        let residue = messages.inboxResidues.contains("\(userId)\n\(channelId)")
            || inboxFacts.all().contains {
                $0.receiverType == "user" && $0.receiverId == userId && $0.channelId == channelId
            }
            || oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq > 0
        return residue ? .residue : .hidden
    }
}
