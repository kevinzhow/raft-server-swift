import Foundation

/// Shared projection for the channel-row facts published by the list and detail
/// routes. Both owners are passed in; no state is cached here.
///
/// `readState` is the upstream `InboxScopeReadFrontier` union. The port retains
/// the cursor presence, the cursor value and the read-state version, so
/// `absent`/`present` are facts. The cursor's independent
/// `latestActivityMessageId`/`latestActivitySeq` columns are not retained; a
/// present frontier therefore publishes `latestActivity: null`, which upstream
/// itself emits when that same-source pair is missing or invalid.
struct ChannelRowFacts: Sendable {
    let oauth: OAuthLedger
    let messages: MessagesAndThreadsStore

    func readState(channelId: String, userId: String) -> ChannelReadStateFrontier {
        guard oauth.hasChannelReadCursor(channelId: channelId, userId: userId) else {
            return .absent
        }
        return .present(
            readStateVersion: messages.channelReadVersion(channelId: channelId, userId: userId),
            maxReadSeq: oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq
        )
    }
}
