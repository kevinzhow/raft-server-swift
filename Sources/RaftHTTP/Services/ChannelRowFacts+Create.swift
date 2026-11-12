import Foundation

extension ChannelRowFacts {
    /// Project the freshly created regular channel from retained facts. Shared
    /// read-frontier and peer DTOs keep create hydration aligned with readers;
    /// permission grants follow shared/channelPermissions.ts:145-211.
    func createdRegularChannel(
        channelId: String, userId: String,
        snapshot: ServersAndChannelsStore.State, readReceiptsEnabled: Bool
    ) throws -> RegularChannelCreatedResponse {
        guard let row = oauth.channelInfo(id: channelId),
              let posting = snapshot.postableChannels[channelId] else {
            throw ManagedMCPOAuthError.channelNotFound
        }
        let kind = oauth.channelType(id: channelId) ?? posting.kind
        guard let authority = HumanChannelAuthorizationQuery(oauth: oauth).resolve(
            channelId: channelId, serverId: row.serverId, userId: userId, snapshot: snapshot
        ) else { throw ManagedMCPOAuthError.channelNotFound }
        let joined = authority.joined
        let frontier = readState(channelId: channelId, userId: userId)
        let display = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: userId)
        let detail = ChannelDetailResponse(
            id: channelId, serverId: row.serverId, name: row.name, description: row.description, type: kind,
            createdAt: oauth.channelCreatedAt(id: channelId).map(RuntimeUsageISO.string), directPeer: nil,
            joined: joined, collapseLongMessages: display.collapseLongMessages, displayPrefsVersion: display.prefsVersion,
            maxReadSeq: frontier.maxReadSeq, readStateVersion: frontier.readStateVersion, readState: frontier,
            activityMuteSupported: ChannelActivityMuteSupport.supports(kind), channelRole: authority.channelRole,
            channelAdminBasis: authority.basis, capabilities: authority.capabilities,
            channelAuthorityRevision: authority.authorityRevision,
            peerReadState: readReceiptsEnabled && joined ? createdPeerReadState(channelId: channelId) : nil
        )
        return RegularChannelCreatedResponse(
            channel: detail, guestVisible: snapshot.guestVisibleChannels[channelId] ?? false,
            guestJoinable: snapshot.guestJoinableChannels[channelId] ?? false,
            parentMessageId: posting.parentMessageId, parentChannelId: posting.parentChannelId,
            archivedAt: oauth.channelArchivedAt(id: channelId).map(RuntimeUsageISO.string),
            deletedAt: posting.deletedAt.map(RuntimeUsageISO.string), activityMuted: prefs.activityMuted,
            muteFromSeq: prefs.muteFromSeq, prefsVersion: prefs.prefsVersion
        )
    }

    private func createdPeerReadState(channelId: String) -> ChannelDetailResponse.PeerReadState {
        let peers = oauth.channelAgentIds(channelId: channelId).map {
            (peerId: $0, maxReadSeq: messages.agentChannelReadSeq(channelId: channelId, agentId: $0))
        }
        guard peers.count > 50 else { return .states(peers) }
        var counts: [Int: Int] = [:]
        for peer in peers { counts[peer.maxReadSeq, default: 0] += 1 }
        var cumulative = 0
        let descending = counts.keys.sorted(by: >).map { seq -> (seq: Int, count: Int) in
            cumulative += counts[seq] ?? 0
            return (seq, cumulative)
        }
        return .summary(peerCount: peers.count, readCountAtSeq: Array(descending.reversed()))
    }
}
