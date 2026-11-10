import Foundation

/// Transient indexes over one retained read snapshot; no cache or owned state.
struct HumanChannelReadSnapshot {
    enum ParentLookup { case indexed, singleLeaf }
    let channelState: ServersAndChannelsStore.State
    let allFacts: HumanAllChannelReadFacts?
    private let messageChannelIds: [String: String]
    private let singleLeafMessages: [StoredHumanMessage]?
    let canonicalIdsByReference: [String: Set<String>]
    let activeLinksByLocal: [String: [JointChannelLink]]
    let activeLinksByCanonical: [String: [JointChannelLink]]

    init(serverId: String, channelState: ServersAndChannelsStore.State, messageRows: [StoredHumanMessage],
         parentLookup: ParentLookup = .indexed, allFacts: HumanAllChannelReadFacts? = nil) {
        self.channelState = channelState
        self.allFacts = allFacts
        if case .singleLeaf = parentLookup {
            messageChannelIds = [:]
            singleLeafMessages = messageRows
        } else {
            var messageChannels: [String: String] = [:]
            for row in messageRows where messageChannels[row.id] == nil { messageChannels[row.id] = row.channelId }
            messageChannelIds = messageChannels
            singleLeafMessages = nil
        }
        var references: [String: Set<String>] = [:]
        var local: [String: [JointChannelLink]] = [:]
        var canonical: [String: [JointChannelLink]] = [:]
        for link in channelState.jointProjections {
            references[link.localChannelId, default: []].insert(link.canonicalChannelId)
            references[link.canonicalChannelId, default: []].insert(link.canonicalChannelId)
            if link.serverId == serverId && link.status == "active" {
                local[link.localChannelId, default: []].append(link)
                canonical[link.canonicalChannelId, default: []].append(link)
            }
        }
        canonicalIdsByReference = references
        activeLinksByLocal = local
        activeLinksByCanonical = canonical
    }

    func parentChannelId(forMessageId id: String) -> String? {
        if let singleLeafMessages { return singleLeafMessages.first { $0.id == id }?.channelId }
        return messageChannelIds[id]
    }
}
