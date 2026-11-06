import Foundation

/// OAuth-ledger surface the socket membership rules read. The OAuth domain is
/// not migrated yet, so its ledger is injected behind this small protocol
/// instead of the service holding `EmailLoginDirectory`.
protocol SocketMembershipOAuthProviding: Sendable {
    func memberRole(serverId: String, userId: String) -> String?
    func visibleChannels(serverId: String, userId: String) -> [SocketChannelVisibility]
    func channelHumanIds(channelId: String) -> [String]
    func removeChannelHuman(channelId: String, userId: String)
}

extension OAuthLedger: SocketMembershipOAuthProviding {
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
    private let oauth: any SocketMembershipOAuthProviding
    /// Feature-flag gate owned by the not-yet-migrated integrations domain.
    private let attachmentCommentsEnabled: @Sendable (String, String) -> Bool

    init(
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        oauth: any SocketMembershipOAuthProviding,
        attachmentCommentsEnabled: @escaping @Sendable (String, String) -> Bool
    ) {
        self.channels = channels
        self.messages = messages
        self.oauth = oauth
        self.attachmentCommentsEnabled = attachmentCommentsEnabled
    }

    // MARK: - Socket membership: room visibility, sync:resume, room cleanup

    /// Channel rooms a socket joins at connect time: regular channels the
    /// viewer can list, and private/DM channels they belong to. Thread rooms
    /// are followed, not joined at connect. Guests only see guest-visible
    /// regular channels other than `#all`, the same gate the HTTP channel list
    /// applies.
    public func visibleChannelIds(serverId: String, userId: String) -> SocketVisibleChannelsDTO {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return SocketVisibleChannelsDTO(channelIds: [])
        }
        let isGuest = role == "guest"
        let candidateChannels = oauth.visibleChannels(serverId: serverId, userId: userId)
        let guestVisible = isGuest
            ? channels.guestVisibleChannelIds(candidateChannels.map(\.id))
            : []
        var ids: [String] = []
        for channel in candidateChannels {
            switch channel.type {
            case "channel":
                if isGuest {
                    guard guestVisible.contains(channel.id), channel.name != "all" else { continue }
                }
                ids.append(channel.id)
            case "private", "dm":
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
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else { return nil }
        let isGuest = role == "guest"
        let commentsVisible = attachmentCommentsEnabled(serverId, userId)
        let channelState = channels.channelReadSnapshot()
        let follows = messages.threadFollowSnapshot()
        var readable: [String: Bool] = [:]
        var rows: [(seq: Int, message: SocketSyncMessageDTO)] = []
        for message in messages.messagesForResume(afterSeq: lastSeq) {
            guard let channel = channelState.channels[message.channelId],
                  channel.serverId == serverId,
                  channel.deletedAt == nil
            else { continue }
            guard channelReadable(
                channelId: message.channelId,
                userId: userId,
                isGuest: isGuest,
                channels: channelState.channels,
                guestVisibleChannels: channelState.guestVisibleChannels,
                follows: follows,
                cache: &readable
            ) else { continue }
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

    /// The per-channel read gate used by `sync:resume`. Reads one channel
    /// snapshot and one thread-follow snapshot; no store lock is held while the
    /// recursion runs.
    private func channelReadable(
        channelId: String,
        userId: String,
        isGuest: Bool,
        channels: [String: PostableChannel],
        guestVisibleChannels: [String: Bool],
        follows: MessagesAndThreadsStore.ThreadFollowSnapshot,
        cache: inout [String: Bool]
    ) -> Bool {
        if let cached = cache[channelId] { return cached }
        guard let channel = channels[channelId], channel.deletedAt == nil else {
            cache[channelId] = false
            return false
        }
        let readable: Bool
        switch channel.kind {
        case "thread":
            let key = "\(channel.serverId)\n\(userId)\n\(channelId)"
            let followed = follows.follows.contains(key) && !follows.unfollows.contains(key)
            if followed, let parentId = channel.parentChannelId {
                readable = channelReadable(
                    channelId: parentId,
                    userId: userId,
                    isGuest: isGuest,
                    channels: channels,
                    guestVisibleChannels: guestVisibleChannels,
                    follows: follows,
                    cache: &cache
                )
            } else {
                readable = false
            }
        case "private", "dm":
            readable = channel.memberIds.contains(userId)
                || oauth.channelHumanIds(channelId: channelId).contains(userId)
        default:
            readable = !isGuest
                || ((guestVisibleChannels[channelId] ?? false) && channel.name != "all")
        }
        cache[channelId] = readable
        return readable
    }
}
