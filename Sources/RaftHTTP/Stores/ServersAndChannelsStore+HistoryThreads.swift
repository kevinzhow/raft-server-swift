import Foundation

/// Thread-carrier lookups used by the agent history read and the agent send:
/// each is one locked snapshot of the channel rows.
extension ServersAndChannelsStore {
    /// The live thread under `parentId` anchored at exactly `anchorMessageId`.
    func historyThread(parentId: String, anchorMessageId: String) -> String? {
        for (id, channel) in state.postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard channel.parentMessageId == anchorMessageId else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    /// The live thread under `parentId` whose channel id starts with `suffix`.
    func historyThread(parentId: String, idPrefix suffix: String) -> String? {
        for (id, channel) in state.postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard id.hasPrefix(suffix) else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    /// The live thread under `parentId` whose anchor message id starts with `suffix`.
    func historyThread(parentId: String, anchorPrefix suffix: String) -> String? {
        for (id, channel) in state.postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard channel.parentMessageId?.hasPrefix(suffix) == true else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }
}
