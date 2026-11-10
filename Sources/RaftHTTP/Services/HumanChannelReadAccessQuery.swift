import Foundation

/// Human channel-read authority from existing retained owners inside the caller's BPR scope.
struct HumanChannelReadAccessQuery: Sendable {
    enum ScopeOrigin: Sendable, Equatable { case localChannel, storedMessage }
    struct Authority: Sendable, Equatable { let channelPath: [String] }
    struct ServerScope: Sendable, Equatable { let serverId: String; let userId: String }

    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let oauth: OAuthLedger
    let flags: AgentsRuntimeStore

    func requireServerScope(serverId: String?, userId: String) throws -> ServerScope {
        guard let serverId, !serverId.isEmpty else { throw MessageSendError.missingServerId }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId) else { throw MessageSendError.notServerMember }
        return ServerScope(serverId: serverId, userId: userId)
    }

    func authority(channelId: String, serverId: String, userId: String,
                   origin: ScopeOrigin = .localChannel) -> Authority? {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else { return nil }
        let guestRolloutEnabled = role != "guest" || isGuestRolloutEnabled(serverId: serverId, userId: userId)
        guard guestRolloutEnabled else { return nil }
        let snapshot = HumanChannelReadSnapshot(serverId: serverId, channelState: channels.state,
            messageRows: messages.humanMessageRows, parentLookup: .singleLeaf)
        return authority(channelId: channelId, serverId: serverId, userId: userId, role: role,
                         guestRolloutEnabled: guestRolloutEnabled, snapshot: snapshot, origin: origin)
    }

    /// Archived channels remain readable; directory callers apply listable/all rules.
    func readableLocalChannelIds(serverId: String, userId: String) -> Set<String> {
        readableLocalChannelSnapshot(serverId: serverId, userId: userId)?.ids ?? []
    }

    /// Search may reuse this one indexed snapshot for its distinct root selection.
    func readableLocalChannelSnapshot(serverId: String, userId: String) -> (snapshot: HumanChannelReadSnapshot, ids: Set<String>)? {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else { return nil }
        let guestRolloutEnabled = role != "guest" || isGuestRolloutEnabled(serverId: serverId, userId: userId)
        guard guestRolloutEnabled else { return nil }
        let snapshot = HumanChannelReadSnapshot(serverId: serverId, channelState: channels.state, messageRows: messages.humanMessageRows,
            allFacts: HumanAllChannelReadFacts(oauth: oauth, serverId: serverId))
        let ids = Set(snapshot.channelState.postableChannels.keys.filter {
            authority(channelId: $0, serverId: serverId, userId: userId, role: role,
                      guestRolloutEnabled: guestRolloutEnabled, snapshot: snapshot, origin: .localChannel) != nil
        })
        return (snapshot, ids)
    }

    /// Storage namespaces admitted through local projections; not search's SQL scope.
    func readableMessageChannelIds(serverId: String, userId: String) -> Set<String> {
        guard let batch = readableLocalChannelSnapshot(serverId: serverId, userId: userId), !batch.ids.isEmpty else { return [] }
        var ids = batch.ids
        for link in batch.snapshot.channelState.jointProjections
            where link.serverId == serverId && link.status == "active" && batch.ids.contains(link.localChannelId) {
            ids.insert(link.canonicalChannelId)
        }
        return ids
    }

    /// A cursor at zero is a witness; current membership alone never is.
    func hasPriorRelationship(channelId: String, serverId: String, userId: String) -> Bool {
        guard channels.postableChannels[channelId]?.serverId == serverId else { return false }
        let state = messages.state
        let key = "\(serverId)\n\(userId)\n\(channelId)"
        return oauth.hasChannelReadCursor(channelId: channelId, userId: userId)
            || state.channelReadVersions["\(channelId)\n\(userId)"] != nil
            || state.inboxResidues.contains("\(userId)\n\(channelId)")
            || state.inboxDoneScopes.contains("\(userId)\n\(channelId)")
            || state.threadFollows[key] != nil || state.threadUnfollows[key] != nil
    }

    private func isGuestRolloutEnabled(serverId: String, userId: String) -> Bool {
        flags.evaluateFeatureFlag(key: "server_guest_v0", userId: userId, serverId: serverId,
            platform: nil, client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)).enabled
    }

    private func authority(channelId: String, serverId: String, userId: String, role: String,
                           guestRolloutEnabled: Bool, snapshot: HumanChannelReadSnapshot, origin: ScopeOrigin) -> Authority? {
        let channelState = snapshot.channelState
        func currentAllType(_ id: String) -> String? {
            if let facts = snapshot.allFacts { return facts.type(forChannelId: id) }
            return oauth.channelType(id: id)
        }
        var seen: Set<String> = []
        var path: [String] = []
        func localScope(_ id: String, allowSiblingProjection: Bool) -> (id: String, row: PostableChannel, joint: Bool)? {
            if let canonicalIds = snapshot.canonicalIdsByReference[id] {
                guard canonicalIds.count == 1, let canonical = canonicalIds.first else { return nil }
                let active = allowSiblingProjection
                    ? (snapshot.activeLinksByCanonical[canonical] ?? []) : (snapshot.activeLinksByLocal[id] ?? [])
                guard active.count == 1, let link = active.first,
                      let local = channelState.postableChannels[link.localChannelId],
                      local.serverId == serverId, local.deletedAt == nil else { return nil }
                return (link.localChannelId, local, true)
            }
            guard let row = channelState.postableChannels[id], row.serverId == serverId,
                  row.deletedAt == nil, row.kind != "joint" else { return nil }
            return (id, row, false)
        }
        func readable(_ id: String, allowSiblingProjection: Bool) -> Bool {
            guard seen.count < 64, let scope = localScope(id, allowSiblingProjection: allowSiblingProjection),
                  seen.insert(scope.id).inserted else { return false }
            path.append(scope.id)
            let row = scope.row
            if row.kind == "thread" {
                if scope.joint {
                    guard role != "guest", let parentId = row.parentChannelId,
                          let parent = channelState.postableChannels[parentId],
                          parent.serverId == serverId, parent.deletedAt == nil else { return false }
                    return readable(parentId, allowSiblingProjection: false)
                }
                guard let parentMessageId = row.parentMessageId,
                      let parentChannelId = snapshot.parentChannelId(forMessageId: parentMessageId),
                      let parent = channelState.postableChannels[parentChannelId],
                      parent.serverId == serverId, parent.deletedAt == nil else { return false }
                return readable(parentChannelId, allowSiblingProjection: true)
            }
            let joined = oauth.isChannelParticipant(channelId: scope.id, userId: userId)
            let all = row.name == "all" && ["channel", "private"].contains(row.kind)
            let allEnabled = !all || (row.kind == "channel" && currentAllType(scope.id) == "channel")
            if role == "guest" {
                guard guestRolloutEnabled, !scope.joint, row.kind != "joint" else { return false }
                switch row.kind {
                case "private", "dm": return joined
                case "channel":
                    let visible = channelState.guestVisibleChannels[scope.id] ?? false
                    return all ? allEnabled && visible : joined || visible
                default: return false
                }
            }
            guard allEnabled else { return false }
            if scope.joint || row.kind == "joint" { return joined }
            if row.kind == "channel" { return true }
            return joined
        }
        guard readable(channelId, allowSiblingProjection: origin == .storedMessage) else { return nil }
        return Authority(channelPath: path)
    }

    /// Independent Node aggregate policy: visible non-all public broadcast, followed threads.
    func aggregateLocalChannelIds(serverId: String, userId: String) -> Set<String> {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else { return [] }
        let guest = role == "guest"
        guard !guest || isGuestRolloutEnabled(serverId: serverId, userId: userId) else { return [] }
        let state = channels.state
        let messageState = messages.state
        let allFacts = HumanAllChannelReadFacts(oauth: oauth, serverId: serverId)
        let snapshot = HumanChannelReadSnapshot(serverId: serverId, channelState: state, messageRows: messageState.humanMessageRows, allFacts: allFacts)
        func joined(_ id: String) -> Bool { oauth.isChannelParticipant(channelId: id, userId: userId) }
        func parentReadable(_ row: PostableChannel) -> Bool {
            guard let parentId = row.parentMessageId,
                  let parentChannelId = snapshot.parentChannelId(forMessageId: parentId),
                  let parent = state.postableChannels[parentChannelId], parent.serverId == serverId,
                  parent.deletedAt == nil, !allFacts.isHidden(channelId: parentChannelId, row: parent) else { return false }
            if parent.kind == "joint" {
                guard !guest, snapshot.activeLinksByLocal[parentChannelId]?.isEmpty == false else { return false }
            }
            let publicRead = parent.kind == "channel" && (!guest ||
                ((state.guestVisibleChannels[parentChannelId] ?? false) && parent.name != "all"))
            return publicRead || joined(parentChannelId)
        }
        return Set(state.postableChannels.compactMap { id, row -> String? in
            guard row.serverId == serverId, row.deletedAt == nil,
                  !allFacts.isHidden(channelId: id, row: row) else { return nil }
            switch row.kind {
            case "channel":
                return !guest || ((state.guestVisibleChannels[id] ?? false) && row.name != "all") ? id : nil
            case "private", "dm": return joined(id) ? id : nil
            case "thread":
                let key = "\(serverId)\n\(userId)\n\(id)"
                return messageState.threadFollows[key] != nil && messageState.threadUnfollows[key] == nil && parentReadable(row) ? id : nil
            default: return nil
            }
        })
    }
}
