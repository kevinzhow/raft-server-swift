import Foundation

extension OAuthLedger {
    func visibleChannels(serverId: String, userId: String) -> [SocketChannelVisibility] {
        channelsForServer(serverId: serverId, userId: userId).map {
            SocketChannelVisibility(id: $0.id, name: $0.name, type: $0.type)
        }
    }
}

/// Socket room membership: connect-time visibility, thread-room enumeration,
/// `sync:resume` catch-up and server-membership resource revocation.
///
/// The service owns the visibility rules and returns typed DTOs; the channel
/// and message rows stay in their per-domain stores, each read behind that
/// store's own lock. It holds no `EmailLoginDirectory` and no lock of its own.
public struct SocketMembershipService: Sendable {
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let oauth: OAuthLedger
    private let flags: AgentsRuntimeStore
    /// Feature-flag gate owned by the not-yet-migrated integrations domain.
    private let attachmentCommentsEnabled: @Sendable (String, String) -> Bool

    init(
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        oauth: OAuthLedger,
        flags: AgentsRuntimeStore,
        attachmentCommentsEnabled: @escaping @Sendable (String, String) -> Bool
    ) {
        self.channels = channels
        self.messages = messages
        self.oauth = oauth
        self.flags = flags
        self.attachmentCommentsEnabled = attachmentCommentsEnabled
    }

    // MARK: - Socket membership: room visibility, sync:resume, room cleanup

    /// Server role read by the transport handshake.
    public func serverRole(serverId: String, userId: String) -> String? {
        oauth.activeRegularServerMember(serverId: serverId, userId: userId)
            ? oauth.memberRole(serverId: serverId, userId: userId) : nil
    }

    /// Channel rooms a socket joins at connect time: listable regular channels,
    /// joined private/DM channels and joined active local joint projections.
    /// Thread rooms are followed, not joined at connect. Guests only see guest-visible
    /// regular channels other than `#all`, the same gate the HTTP channel list
    /// applies.
    public func visibleChannelIds(serverId: String, userId: String) -> SocketVisibleChannelsDTO {
        guard let role = serverRole(serverId: serverId, userId: userId) else {
            return SocketVisibleChannelsDTO(channelIds: [])
        }
        let isGuest = role == "guest"
        let candidateChannels = oauth.visibleChannels(serverId: serverId, userId: userId)
        let guestVisible = isGuest
            ? channels.guestVisibleChannelIds(candidateChannels.map(\.id))
            : []
        let roomState = channels.deliveryAckChannelSnapshot()
        let linksByLocal = Dictionary(grouping: roomState.jointProjections, by: \.localChannelId)
        var ids: [String] = []
        for channel in candidateChannels {
            // Room listability uses actual OAuth type, not aggregate read policy.
            guard !(channel.name == "all" && channel.type != "channel") else { continue }
            switch channel.type {
            case "channel":
                if isGuest {
                    guard guestVisible.contains(channel.id), channel.name != "all" else { continue }
                }
                ids.append(channel.id)
            case "private", "dm":
                ids.append(channel.id)
            case "joint":
                let links = linksByLocal[channel.id] ?? []
                let active = links.filter { $0.serverId == serverId && $0.status == "active" }
                guard !isGuest, let local = roomState.channels[channel.id],
                      local.serverId == serverId, local.kind == "joint", local.deletedAt == nil,
                      Set(links.map(\.canonicalChannelId)).count == 1, active.count == 1,
                      oauth.channelHumanIds(channelId: channel.id).contains(userId)
                else { continue }
                ids.append(channel.id)
            default:
                continue
            }
        }
        return SocketVisibleChannelsDTO(channelIds: ids)
    }

    /// `channel:<id>` plus every child thread room. A membership change that
    /// loses the parent channel must also drop existing child-room
    /// subscriptions.
    public func channelRoomIds(channelId: String) -> SocketChannelRoomsDTO {
        SocketChannelRoomsDTO(rooms: channels.channelRoomIds(channelId: channelId))
    }

    /// Upstream `messageService.getMaxSeq(serverId)`: the highest retained
    /// message sequence for the server, published by the application
    /// `heartbeat`. The sequence is the same `seq` assigned to message rows and
    /// replayed by `sync:resume`; this reads those rows instead of keeping a
    /// second in-memory counter. Canonical joint-channel rows count toward the
    /// local server because upstream calls `updateMaxSeq(localServerId, ...)`
    /// when it projects them.
    public func maxMessageSeq(serverId: String) -> Int {
        let snapshot = channels.channelReadSnapshot()
        var channelIds = Set(snapshot.channels.compactMap { id, channel in
            channel.serverId == serverId ? id : nil
        })
        for link in snapshot.jointProjections where link.serverId == serverId && link.status == "active" {
            channelIds.insert(link.canonicalChannelId)
        }
        guard !channelIds.isEmpty else { return 0 }
        return messages.maxMessageSeq(channelIds: channelIds)
    }

    /// Viewer-filtered catch-up for the `sync:resume` socket outlet. Mirrors
    /// upstream `messageService.syncMessages(lastSeq, nil, limit, serverId, nil, userId)`:
    /// regular channels are server-readable (guests need `guestVisible`),
    /// private/DM channels require membership, and threads require an active
    /// follow plus a readable parent channel. Returns nil without a server role.
    public func syncMessages(
        serverId: String,
        userId: String,
        lastSeq: Int,
        limit: Int
    ) -> SocketSyncResumeDTO? {
        guard lastSeq > 0, limit > 0 else { return nil }
        let reads = HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: flags)
        guard (try? reads.requireServerScope(serverId: serverId, userId: userId)) != nil else { return nil }
        // This is the Node aggregate SQL policy, distinct from room listability
        // and scoped/search participant policy. Capture it once for this replay.
        let readable = reads.aggregateLocalChannelIds(serverId: serverId, userId: userId)
        guard !readable.isEmpty else {
            return SocketSyncResumeDTO(messages: [], currentSeq: lastSeq, hasMore: false)
        }
        let commentsVisible = attachmentCommentsEnabled(serverId, userId)
        let channelState = channels.channelReadSnapshot()
        var rows: [(seq: Int, message: SocketSyncMessageDTO)] = []
        for message in messages.messagesForResume(afterSeq: lastSeq) {
            guard let channel = channelState.channels[message.channelId],
                  channel.serverId == serverId,
                  channel.deletedAt == nil
            else { continue }
            guard readable.contains(message.channelId) else { continue }
            let attachments = messages.attachmentCommentSummaries(
                ids: message.attachmentIds,
                commentsVisible: commentsVisible
            ).map { SocketSyncAttachmentDTO(id: $0.attachmentId, commentCount: $0.commentCount) }
            var commentRef: SocketSyncCommentRefDTO?
            if commentsVisible, let ref = messages.commentRef(messageId: message.id) {
                commentRef = SocketSyncCommentRefDTO(
                    attachmentId: ref.attachmentId,
                    hostMessageId: ref.hostMessageId,
                    hostSource: SocketSyncCommentSourceDTO(
                        type: "channel",
                        routeKind: "channel",
                        channelId: ref.hostChannelId,
                        rootThreadChannelId: ref.threadChannelId
                    )
                )
            }
            rows.append((message.seq, SocketSyncMessageDTO(
                id: message.id,
                channelId: message.channelId,
                seq: message.seq,
                content: message.content,
                attachments: attachments,
                commentRef: commentRef
            )))
        }
        rows.sort { $0.seq < $1.seq }
        let page = rows.prefix(limit)
        let currentSeq = page.last?.seq ?? lastSeq
        let hasMore = rows.count >= limit
        return SocketSyncResumeDTO(
            messages: page.map(\.message),
            currentSeq: currentSeq,
            hasMore: hasMore
        )
    }

    /// Upstream `serverService.removeMember` cascades resource rows:
    /// private/DM-parent thread follows and channel membership for the
    /// server's channels die with the server membership. Routes call this after
    /// a successful leave/remove so a departed member loses channel access.
    public func revokeServerMembershipResources(serverId: String, userId: String) {
        let revocation = channels.revokeMembership(serverId: serverId, userId: userId)
        messages.removeThreadFollows(keys: revocation.threadKeys)
        for channelId in revocation.channelIds {
            oauth.removeChannelHuman(channelId: channelId, userId: userId)
        }
    }

}
