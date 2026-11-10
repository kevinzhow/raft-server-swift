import Foundation

/// One operation's real #all identity/type facts, never a store or cross-call cache.
struct HumanAllChannelReadFacts {
    let channelId: String?
    let channelType: String?

    init(oauth: OAuthLedger, serverId: String) {
        let id = oauth.allChannelId(serverId: serverId)
        channelId = id
        channelType = id.flatMap { oauth.channelType(id: $0) }
    }

    func type(forChannelId id: String) -> String? {
        id == channelId ? channelType : nil
    }

    func currentType(channelId id: String, row: PostableChannel) -> String? {
        if id == channelId || (row.name == "all" && ["channel", "private"].contains(row.kind)) {
            guard id == channelId, let channelType, ["channel", "private"].contains(channelType) else { return nil }
            return channelType
        }
        return row.kind
    }

    /// Node aggregate excludes hidden #all globally, even for actual participants.
    func isHidden(channelId id: String, row: PostableChannel) -> Bool {
        (id == channelId || row.name == "all") && currentType(channelId: id, row: row) != "channel"
    }
}
