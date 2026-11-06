import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Socket room membership: connect-time visibility, thread-room enumeration,
/// `sync:resume` catch-up and server-membership resource revocation.
///
/// The directory owns only the stores and locks. Every decision here reads the
/// ledger through the directory's forwarding accessors so the upstream
/// visibility rules stay in one place instead of an `EmailLogin+*.swift`
/// fragment.
struct SocketMembershipService {
    let directory: EmailLoginDirectory

    init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    // MARK: - Socket membership: room visibility, sync:resume, room cleanup

    /// Channel rooms a socket joins at connect time: regular channels the
    /// viewer can list, and private/DM channels they belong to. Thread rooms
    /// are followed, not joined at connect. Guests only see guest-visible
    /// regular channels other than `#all`, the same gate the HTTP channel list
    /// applies.
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        guard let role = directory.oauth.memberRole(serverId: serverId, userId: userId) else { return [] }
        let isGuest = role == "guest"
        var ids: [String] = []
        for channel in directory.oauth.channelsForServer(serverId: serverId, userId: userId) {
            switch channel.type {
            case "channel":
                if isGuest {
                    directory.lock.lock()
                    let visible = directory.guestVisibleChannels[channel.id] ?? false
                    directory.lock.unlock()
                    guard visible, channel.name != "all" else { continue }
                }
                ids.append(channel.id)
            case "private", "dm":
                ids.append(channel.id)
            default:
                continue
            }
        }
        return ids
    }

    /// `channel:<id>` plus every child thread room. A membership change that
    /// loses the parent channel must also drop existing child-room
    /// subscriptions.
    func channelRoomIds(channelId: String) -> [String] {
        directory.lock.lock()
        defer { directory.lock.unlock() }
        var rooms = ["channel:\(channelId)"]
        for (id, channel) in directory.postableChannels
        where channel.kind == "thread" && channel.parentChannelId == channelId {
            rooms.append("channel:\(id)")
        }
        return rooms
    }

    /// Viewer-filtered catch-up for the `sync:resume` socket outlet. Mirrors
    /// upstream `messageService.syncMessages(lastSeq, nil, limit, serverId, nil, userId)`:
    /// regular channels are server-readable (guests need `guestVisible`),
    /// private/DM channels require membership, and threads require an active
    /// follow plus a readable parent channel. Returns nil without a server role.
    func syncMessagesPayload(
        serverId: String,
        userId: String,
        lastSeq: Int,
        limit: Int
    ) -> String? {
        guard lastSeq > 0, limit > 0 else { return nil }
        guard let role = directory.oauth.memberRole(serverId: serverId, userId: userId) else { return nil }
        let isGuest = role == "guest"
        let commentsVisible = directory.attachmentCommentsEnabled(serverId: serverId, userId: userId)
        directory.lock.lock()
        var readable: [String: Bool] = [:]
        var rows: [(seq: Int, json: String)] = []
        for message in directory.humanMessageRows where message.seq > lastSeq {
            guard let channel = directory.postableChannels[message.channelId],
                  channel.serverId == serverId,
                  channel.deletedAt == nil
            else { continue }
            guard channelReadableLocked(
                channelId: message.channelId,
                userId: userId,
                isGuest: isGuest,
                cache: &readable
            ) else { continue }
            var row = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(message.channelId)),\"seq\":\(message.seq),\"content\":\(jsonString(message.content)),\"attachments\":[\(directory.messageAttachmentsJSONLocked(message.attachmentIds, commentsVisible: commentsVisible))]"
            if commentsVisible, let commentRef = directory.commentRefJSONLocked(messageId: message.id) {
                row += ",\"commentRef\":\(commentRef)"
            }
            rows.append((message.seq, row + "}"))
        }
        directory.lock.unlock()
        rows.sort { $0.seq < $1.seq }
        let page = rows.prefix(limit)
        let currentSeq = page.last?.seq ?? lastSeq
        let hasMore = rows.count >= limit
        let body = page.map(\.json).joined(separator: ",")
        return "{\"messages\":[\(body)],\"currentSeq\":\(currentSeq),\"hasMore\":\(hasMore)}"
    }

    /// Upstream `serverService.removeMember` cascades resource rows:
    /// private/DM-parent thread follows and channel membership for the
    /// server's channels die with the server membership. Routes call this after
    /// a successful leave/remove so a departed member loses channel access.
    func revokeServerMembershipResources(serverId: String, userId: String) {
        directory.lock.lock()
        var channelIds: [String] = []
        var threadKeys: [String] = []
        for (id, channel) in directory.postableChannels where channel.serverId == serverId {
            channelIds.append(id)
            directory.postableChannels[id]?.memberIds.remove(userId)
            // Mirrors `removeMember`: only follows hanging off a private/DM
            // parent die with the server membership; public-parent follows
            // survive so the thread stays in Activity after a rejoin.
            guard channel.kind == "thread",
                  let parentId = channel.parentChannelId,
                  let parent = directory.postableChannels[parentId],
                  parent.kind == "private" || parent.kind == "dm"
            else { continue }
            threadKeys.append("\(serverId)\n\(userId)\n\(id)")
        }
        for key in threadKeys {
            directory.threadFollows.removeValue(forKey: key)
            directory.threadUnfollows.removeValue(forKey: key)
            directory.threadFollowStarts.removeValue(forKey: key)
        }
        directory.lock.unlock()
        for channelId in channelIds {
            directory.oauth.removeChannelHuman(channelId: channelId, userId: userId)
        }
    }

    /// The per-channel read gate used by `sync:resume`. Caller holds the
    /// directory lock.
    private func channelReadableLocked(
        channelId: String,
        userId: String,
        isGuest: Bool,
        cache: inout [String: Bool]
    ) -> Bool {
        if let cached = cache[channelId] { return cached }
        guard let channel = directory.postableChannels[channelId], channel.deletedAt == nil else {
            cache[channelId] = false
            return false
        }
        let readable: Bool
        switch channel.kind {
        case "thread":
            let key = "\(channel.serverId)\n\(userId)\n\(channelId)"
            let followed = directory.threadFollows[key] != nil && directory.threadUnfollows[key] == nil
            if followed, let parentId = channel.parentChannelId {
                readable = channelReadableLocked(
                    channelId: parentId,
                    userId: userId,
                    isGuest: isGuest,
                    cache: &cache
                )
            } else {
                readable = false
            }
        case "private", "dm":
            readable = channel.memberIds.contains(userId)
                || directory.oauth.channelHumanIds(channelId: channelId).contains(userId)
        default:
            readable = !isGuest || ((directory.guestVisibleChannels[channelId] ?? false) && channel.name != "all")
        }
        cache[channelId] = readable
        return readable
    }
}

// MARK: - Directory entry points

extension EmailLoginDirectory {
    /// Channel rooms a socket joins at connect time. See `SocketMembershipService`.
    public func realtimeVisibleChannelIds(serverId: String, userId: String) -> [String] {
        SocketMembershipService(directory: self).visibleChannelIds(serverId: serverId, userId: userId)
    }

    /// `channel:<id>` plus every child thread room.
    public func realtimeChannelRoomIds(channelId: String) -> [String] {
        SocketMembershipService(directory: self).channelRoomIds(channelId: channelId)
    }

    /// Viewer-filtered catch-up for the `sync:resume` socket outlet.
    public func realtimeSyncMessagesPayload(
        serverId: String,
        userId: String,
        lastSeq: Int,
        limit: Int
    ) -> String? {
        SocketMembershipService(directory: self).syncMessagesPayload(
            serverId: serverId,
            userId: userId,
            lastSeq: lastSeq,
            limit: limit
        )
    }

    /// Revokes a departed member's channel membership and private-parent thread follows.
    public func revokeServerMembershipResources(serverId: String, userId: String) {
        SocketMembershipService(directory: self).revokeServerMembershipResources(serverId: serverId, userId: userId)
    }
}
