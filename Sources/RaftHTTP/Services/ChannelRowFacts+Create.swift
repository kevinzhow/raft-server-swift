import Foundation

extension ChannelRowFacts {
    /// Project the freshly created regular channel from retained facts. Shared
    /// read-frontier and peer DTOs keep create hydration aligned with readers;
    /// permission grants follow shared/channelPermissions.ts:145-211.
    func createdRegularChannel(
        channelId: String, userId: String, serverRole: String,
        snapshot: ServersAndChannelsStore.State, readReceiptsEnabled: Bool
    ) throws -> RegularChannelCreatedResponse {
        guard let row = oauth.channelInfo(id: channelId),
              let posting = snapshot.postableChannels[channelId] else {
            throw ManagedMCPOAuthError.channelNotFound
        }
        let kind = oauth.channelType(id: channelId) ?? posting.kind
        let joined = oauth.channelHumanIds(channelId: channelId).contains(userId)
        let localRole = snapshot.channelHumanRoles["\(channelId)\n\(userId)"] ?? "member"
        let inherited = serverRole == "owner" || serverRole == "admin"
        let localAdmin = joined && localRole == "admin" && ["owner", "admin", "member"].contains(serverRole)
        let basis: String? = inherited && localAdmin ? "both" : inherited ? "server_role" : localAdmin ? "channel_role" : nil
        let localCapabilities: Set<String> = [
            "editChannelMetadata", "archiveChannels", "removeChannelMembers", "changeChannelMemberRoles", "manageGuestAccess",
        ]
        func allows(_ key: String) -> Bool {
            ServerRoleCapabilities.allows(key, role: serverRole) || (localAdmin && localCapabilities.contains(key))
        }
        let frontier = readState(channelId: channelId, userId: userId)
        let display = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: userId)
        let detail = ChannelDetailResponse(
            id: channelId, serverId: row.serverId, name: row.name, description: row.description, type: kind,
            createdAt: oauth.channelCreatedAt(id: channelId).map(RuntimeUsageISO.string), directPeer: nil,
            joined: joined, collapseLongMessages: display.collapseLongMessages, displayPrefsVersion: display.prefsVersion,
            maxReadSeq: frontier.maxReadSeq, readStateVersion: frontier.readStateVersion, readState: frontier,
            activityMuteSupported: ChannelActivityMuteSupport.supports(kind), channelRole: localRole,
            channelAdminBasis: basis,
            capabilities: .init(
                editChannelMetadata: allows("editChannelMetadata"), archiveChannels: allows("archiveChannels"),
                addChannelMembers: inherited || (serverRole == "member" && joined),
                removeChannelMembers: allows("removeChannelMembers"), changeChannelMemberRoles: allows("changeChannelMemberRoles"),
                manageGuestAccess: allows("manageGuestAccess"), deleteChannels: allows("deleteChannels"),
                changeChannelVisibility: allows("changeChannelVisibility"), federateChannels: allows("federateChannels")
            ),
            channelAuthorityRevision: snapshot.channelAuthorityRevisions[channelId] ?? 1,
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
