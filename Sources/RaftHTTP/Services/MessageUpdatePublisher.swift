import Foundation

/// Publishes `message:updated` projections whose non-row facts live in another
/// owner (an action card's executed metadata). Reaction updates build their own
/// frame in `ProfileAndChannelFilesService`; both go through
/// `MessageRealtimeService.messageUpdatedFrames`.
struct MessageUpdatePublisher: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let profiles: AuthProfileStore
    let oauth: OAuthLedger
    let emit: @Sendable (_ room: String, _ event: String, _ payload: String) -> Void

    /// Upstream `emitActionCardMessageUpdated` / `emitActionCardCarrierMessage`:
    /// reload the committed carrier, use the channel room for a non-thread
    /// carrier and the authority-filtered follower user rooms for a thread.
    func actionCard(messageId: String, metadataJSON: String) {
        guard let message = messages.humanMessageRow(id: messageId) else { return }
        let audience: MessageRealtimeService.MessageUpdateAudience =
            channels.postableChannel(id: message.channelId)?.kind == "thread" ? .threadFollowers : .channel
        let realtime = MessageRealtimeService(
            messages: messages, channels: channels, profiles: profiles, oauth: oauth
        )
        for frame in realtime.messageUpdatedFrames(
            for: message, actionMetadata: .raw(metadataJSON), audience: audience
        ) {
            emit(frame.room, frame.event, frame.payload)
        }
    }
}
