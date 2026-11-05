import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {

    // MARK: - Socket membership: room visibility, sync:resume, room cleanup

    /// Channel rooms a socket joins at connect time: regular channels the
    /// viewer can list, and private/DM channels they belong to. Thread rooms
    /// are followed, not joined at connect. Guests only see guest-visible
    /// regular channels other than `#all`, the same gate the HTTP channel list
    /// applies.
    public func realtimeVisibleChannelIds(serverId: String, userId: String) -> [String] {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else { return [] }
        let isGuest = role == "guest"
        var ids: [String] = []
        for channel in oauth.channelsForServer(serverId: serverId, userId: userId) {
            switch channel.type {
            case "channel":
                if isGuest {
                    lock.lock()
                    let visible = guestVisibleChannels[channel.id] ?? false
                    lock.unlock()
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
    public func realtimeChannelRoomIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var rooms = ["channel:\(channelId)"]
        for (id, channel) in postableChannels
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
    public func realtimeSyncMessagesPayload(
        serverId: String,
        userId: String,
        lastSeq: Int,
        limit: Int
    ) -> String? {
        guard lastSeq > 0, limit > 0 else { return nil }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else { return nil }
        let isGuest = role == "guest"
        let commentsVisible = attachmentCommentsEnabled(serverId: serverId, userId: userId)
        lock.lock()
        var readable: [String: Bool] = [:]
        var rows: [(seq: Int, json: String)] = []
        for message in humanMessageRows where message.seq > lastSeq {
            guard let channel = postableChannels[message.channelId],
                  channel.serverId == serverId,
                  channel.deletedAt == nil
            else { continue }
            guard realtimeChannelReadableLocked(
                channelId: message.channelId,
                userId: userId,
                isGuest: isGuest,
                cache: &readable
            ) else { continue }
            var row = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(message.channelId)),\"seq\":\(message.seq),\"content\":\(jsonString(message.content)),\"attachments\":[\(messageAttachmentsJSONLocked(message.attachmentIds, commentsVisible: commentsVisible))]"
            if commentsVisible, let commentRef = commentRefJSONLocked(messageId: message.id) {
                row += ",\"commentRef\":\(commentRef)"
            }
            rows.append((message.seq, row + "}"))
        }
        lock.unlock()
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
    public func revokeServerMembershipResources(serverId: String, userId: String) {
        lock.lock()
        var channelIds: [String] = []
        var threadKeys: [String] = []
        for (id, channel) in postableChannels where channel.serverId == serverId {
            channelIds.append(id)
            postableChannels[id]?.memberIds.remove(userId)
            // Mirrors `removeMember`: only follows hanging off a private/DM
            // parent die with the server membership; public-parent follows
            // survive so the thread stays in Activity after a rejoin.
            guard channel.kind == "thread",
                  let parentId = channel.parentChannelId,
                  let parent = postableChannels[parentId],
                  parent.kind == "private" || parent.kind == "dm"
            else { continue }
            threadKeys.append("\(serverId)\n\(userId)\n\(id)")
        }
        for key in threadKeys {
            threadFollows.removeValue(forKey: key)
            threadUnfollows.removeValue(forKey: key)
            threadFollowStarts.removeValue(forKey: key)
        }
        lock.unlock()
        for channelId in channelIds {
            _ = oauth.removeChannelHuman(channelId: channelId, userId: userId)
        }
    }

    /// The per-channel read gate used by `sync:resume`. Caller holds `lock`.
    private func realtimeChannelReadableLocked(
        channelId: String,
        userId: String,
        isGuest: Bool,
        cache: inout [String: Bool]
    ) -> Bool {
        if let cached = cache[channelId] { return cached }
        guard let channel = postableChannels[channelId], channel.deletedAt == nil else {
            cache[channelId] = false
            return false
        }
        let readable: Bool
        switch channel.kind {
        case "thread":
            let key = "\(channel.serverId)\n\(userId)\n\(channelId)"
            let followed = threadFollows[key] != nil && threadUnfollows[key] == nil
            if followed, let parentId = channel.parentChannelId {
                readable = realtimeChannelReadableLocked(
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
                || oauth.channelHumanIds(channelId: channelId).contains(userId)
        default:
            readable = !isGuest || ((guestVisibleChannels[channelId] ?? false) && channel.name != "all")
        }
        cache[channelId] = readable
        return readable
    }
}
