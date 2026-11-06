/// The fixed Channels leaf a Tasks transaction may enter. This capability has
/// no callback or Tasks reference; construction retains the owner without
/// querying or caching a row. The caller keeps its existing Tasks borrow.
struct TaskChannelDeletionQuery: Sendable {
    private let channels: ServersAndChannelsStore

    init(channels: ServersAndChannelsStore) {
        self.channels = channels
    }

    func isDeleted(channelId: String) -> Bool {
        channels.postableChannel(id: channelId)?.deletedAt != nil
    }
}
