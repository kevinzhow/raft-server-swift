import Foundation

/// Preview-specific root resolution; shared human channel policy checks the real
/// current parent/joint authority on both sides of external attachment I/O.
struct AttachmentPreviewAccessQuery: Sendable {
    typealias Authority = HumanChannelReadAccessQuery.Authority
    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let oauth: OAuthLedger
    let flags: AgentsRuntimeStore

    func authority(attachment: ChannelAttachment, serverId: String, userId: String) -> Authority? {
        let root: String
        if let messageId = attachment.messageId {
            guard let message = messages.humanMessageRows.first(where: { $0.id == messageId }) else { return nil }
            root = message.channelId
        } else { root = attachment.channelId }
        return HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: flags)
            .authority(channelId: root, serverId: serverId, userId: userId,
                       origin: attachment.messageId == nil ? .localChannel : .storedMessage)
    }
}
