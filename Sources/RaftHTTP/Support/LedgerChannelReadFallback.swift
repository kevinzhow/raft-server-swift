import Foundation

/// Ledger-only channels predate the posting-row snapshot. The pinned server has
/// one channels table, so its access rule still resolves a thread through the
/// parent for those rows. Callers use this when the leaf has no posting row.
/// Existing posting tombstones on every ancestor still deny access; only absent
/// posting rows use the typed ledger membership.
enum LedgerChannelReadFallback {
    static func canReadHuman(
        channelId: String, serverId: String, userId: String, oauth: OAuthLedger, channels: ServersAndChannelsStore
    ) -> Bool {
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else { return false }
        var visited: Set<String> = []
        func visit(_ id: String) -> Bool {
            guard visited.count < 64, visited.insert(id).inserted,
                  channels.postableChannels[id]?.deletedAt == nil,
                  let info = oauth.channelInfo(id: id), info.serverId == serverId
            else { return false }
            switch oauth.channelType(id: id) ?? "channel" {
            case "channel":
                return true
            case "thread":
                guard let parentId = oauth.channelParentChannelId(id: id) else { return false }
                return visit(parentId)
            default:
                return oauth.isChannelParticipant(channelId: id, userId: userId)
            }
        }
        return visit(channelId)
    }

    static func canReadAgent(
        channelId: String, serverId: String, agentId: String, oauth: OAuthLedger, channels: ServersAndChannelsStore
    ) -> Bool {
        guard oauth.agentRuntimeInfo(id: agentId)?.serverId == serverId else { return false }
        var visited: Set<String> = []
        func visit(_ id: String) -> Bool {
            guard visited.count < 64, visited.insert(id).inserted,
                  channels.postableChannels[id]?.deletedAt == nil,
                  let info = oauth.channelInfo(id: id), info.serverId == serverId
            else { return false }
            switch oauth.channelType(id: id) ?? "channel" {
            case "channel":
                return true
            case "thread":
                guard let parentId = oauth.channelParentChannelId(id: id) else { return false }
                return visit(parentId)
            default:
                return oauth.channelAgentIds(channelId: id).contains(agentId)
            }
        }
        return visit(channelId)
    }
}
