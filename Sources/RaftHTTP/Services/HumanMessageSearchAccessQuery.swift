import Foundation

/// Node searchService.buildUserVisibleChannelsSql, distinct from scoped leaf ACL.
struct HumanMessageSearchAccessQuery {
    struct ChannelFacts: Sendable {
        let parentChannelId: String
        let channelType: String
        let parentChannelType: String
    }

    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let oauth: OAuthLedger
    let flags: AgentsRuntimeStore

    func parentChannelIds(serverId: String, userId: String) -> [String: String] {
        channelFacts(serverId: serverId, userId: userId).mapValues(\.parentChannelId)
    }

    /// The same selected facts drive admission and the published type projection.
    func channelFacts(serverId: String, userId: String) -> [String: ChannelFacts] {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else { return [:] }
        let snapshot: HumanChannelReadSnapshot
        let allowedRoots: Set<String>?
        if role == "guest" {
            let access = HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: flags)
            guard let batch = access.readableLocalChannelSnapshot(serverId: serverId, userId: userId) else { return [:] }
            snapshot = batch.snapshot
            let roots = Set(batch.ids.filter {
                guard let row = snapshot.channelState.postableChannels[$0] else { return false }
                return ["channel", "private", "joint"].contains(row.kind)
            })
            guard !roots.isEmpty else { return [:] }
            allowedRoots = roots
        } else {
            snapshot = HumanChannelReadSnapshot(serverId: serverId, channelState: channels.state, messageRows: messages.humanMessageRows)
            allowedRoots = nil
        }
        let allFacts = snapshot.allFacts ?? HumanAllChannelReadFacts(oauth: oauth, serverId: serverId)
        var result: [String: ChannelFacts] = [:]
        for (id, row) in snapshot.channelState.postableChannels where row.serverId == serverId && row.deletedAt == nil {
            guard let kind = allFacts.currentType(channelId: id, row: row) else { continue }
            let root: String
            let parentType: String
            if kind == "thread" {
                // Node's 0297 column is trigger-derived from this actual parent message.
                guard let messageId = row.parentMessageId,
                      let parentId = snapshot.parentChannelId(forMessageId: messageId),
                      let actual = snapshot.channelState.postableChannels[parentId],
                      actual.serverId == serverId, actual.deletedAt == nil,
                      let actualType = allFacts.currentType(channelId: parentId, row: actual) else { continue }
                root = parentId
                parentType = actualType
            } else {
                root = id
                parentType = kind
            }
            if let allowedRoots {
                if allowedRoots.contains(root) { result[id] = ChannelFacts(parentChannelId: root, channelType: kind, parentChannelType: parentType) }
                continue
            }
            if kind == "channel"
                || (["private", "dm"].contains(kind) && oauth.isChannelParticipant(channelId: id, userId: userId))
                || (kind == "thread" && (parentType == "channel"
                    || (["private", "dm"].contains(parentType) && oauth.isChannelParticipant(channelId: root, userId: userId)))) {
                result[id] = ChannelFacts(parentChannelId: root, channelType: kind, parentChannelType: parentType)
            }
        }
        return result
    }
}
