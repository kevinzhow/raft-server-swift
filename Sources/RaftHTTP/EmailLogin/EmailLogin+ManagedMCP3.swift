import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {
    public func addAnnouncementForTesting(
        title: String,
        pages: [String],
        startsAt: Date = Date(),
        expiresAt: Date? = nil,
        status: String = "published",
        publishedAt: Date? = nil,
        imageId: String? = nil,
        audienceServerIds: [String] = []
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        announcements.append((
            id: id,
            title: title,
            pages: pages,
            startsAt: startsAt,
            expiresAt: expiresAt,
            status: status,
            publishedAt: publishedAt ?? (status == "draft" ? nil : Date()),
            imageId: imageId,
            audienceServerIds: audienceServerIds
        ))
        lock.unlock()
        return id
    }

    public func setAnnouncementStateForTesting(
        id: String,
        status: String,
        publishedAt: Date?,
        startsAt: Date
    ) {
        lock.lock()
        if let index = announcements.firstIndex(where: { $0.id == id }) {
            announcements[index].status = status
            announcements[index].publishedAt = publishedAt
            announcements[index].startsAt = startsAt
        }
        lock.unlock()
    }

    public func addAnnouncementImageForTesting(id: String, announcementId: String, contentType: String, bytes: Data) {
        lock.lock()
        announcementImageAssets[id] = AnnouncementImageAsset(
            id: id,
            announcementId: announcementId,
            contentType: contentType,
            bytes: bytes
        )
        lock.unlock()
    }





    public func addExternalAvatarForTesting(
        id: String,
        contentType: String = "image/webp",
        bytes: Data,
        sourceDigest: String,
        active: Bool = true
    ) {
        lock.lock()
        externalAvatarAssets[id] = ExternalAvatarAsset(
            id: id,
            contentType: contentType,
            bytes: bytes,
            sourceDigest: sourceDigest,
            active: active
        )
        lock.unlock()
    }

    public func setExternalAvatarStorageAvailableForTesting(_ available: Bool) {
        lock.lock()
        externalAvatarStorageAvailable = available
        lock.unlock()
    }

    public func externalAvatar(file: String) -> HTTPReply {
        guard file.hasSuffix(".webp") else {
            return Self.avatarPlainText(404, "Not found")
        }
        let id = String(file.dropLast(".webp".count))
        guard ServerScope.isUUID(id) else {
            return Self.avatarPlainText(404, "Not found")
        }
        lock.lock()
        let asset = externalAvatarAssets[id]
        let storageAvailable = externalAvatarStorageAvailable
        lock.unlock()
        guard let asset, asset.active else {
            return Self.avatarPlainText(404, "Not found")
        }
        guard storageAvailable else {
            return Self.avatarPlainText(503, "Avatar storage is unavailable")
        }
        return HTTPReply(
            status: 200,
            headers: [
                "Content-Type": asset.contentType,
                "Content-Length": String(asset.bytes.count),
                "Content-Disposition": "inline",
                "Cache-Control": "public, no-cache, must-revalidate",
                "ETag": "\"sha256-\(asset.sourceDigest)\"",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "cross-origin",
            ],
            body: String(decoding: asset.bytes, as: UTF8.self)
        )
    }


    public func setAnnouncementImageStorageAvailableForTesting(_ available: Bool) {
        lock.lock()
        announcementImageStorageAvailable = available
        lock.unlock()
    }

    public func announcementImage(id: String) -> HTTPReply {
        guard ServerScope.isUUID(id) else {
            return Self.json(404, "{\"error\":\"Announcement image not found\"}")
        }
        lock.lock()
        let asset = announcementImageAssets[id]
        let announcement = announcements.first { $0.id == asset?.announcementId }
        let storageAvailable = announcementImageStorageAvailable
        lock.unlock()
        guard let asset, let announcement,
              announcement.publishedAt != nil,
              announcement.status != "draft",
              announcement.startsAt <= Date()
        else {
            return Self.json(404, "{\"error\":\"Announcement image not found\"}")
        }
        guard storageAvailable else {
            return Self.json(503, "{\"error\":\"Announcement image storage unavailable\"}")
        }
        return HTTPReply(
            status: 200,
            headers: [
                "Content-Type": asset.contentType,
                "Cache-Control": "public, max-age=31536000, immutable",
                "Cross-Origin-Resource-Policy": "cross-origin",
                "Content-Length": String(asset.bytes.count),
            ],
            body: String(decoding: asset.bytes, as: UTF8.self)
        )
    }

    public func activeAnnouncements(authorization: String?, after: String?, query: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if let after, !after.isEmpty, !ServerScope.isUUID(after) {
            return Self.json(400, "{\"error\":\"Invalid announcement cursor\"}")
        }
        let scopedServer: String?
        switch Self.announcementContextQuery(query) {
        case .failure(let reply):
            return reply
        case .success(let serverId):
            scopedServer = serverId
        }
        let now = Date()
        lock.lock()
        // Drafts never surface; a published row only surfaces once published and
        // until it expires. Expiring the newest row falls through to the next
        // unread one, which is what makes scheduled windows queue.
        let rows = announcements
            .filter { $0.status == "published" && $0.publishedAt != nil }
            .filter { $0.startsAt <= now && ($0.expiresAt == nil || $0.expiresAt! > now) }
            .filter { announcementVisibleLocked($0, userId: userId, serverId: scopedServer) }
            .filter { !announcementDismissals.contains("\(userId)\n\($0.id)") }
            .filter { after == nil || $0.id != after }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(1)
        let documents = rows.map { announcement -> String in
            let pages = announcement.pages.map { jsonString($0) }.joined(separator: ",")
            return "{\"id\":\(jsonString(announcement.id)),\"title\":\(jsonString(announcement.title)),\"pages\":[\(pages)]}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"announcements\":[\(documents)]}")
    }

    public func dismissAnnouncement(
        authorization: String?,
        announcementId: String,
        query: String? = nil,
        headerServerId: String? = nil
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let scopedServer: String?
        switch Self.announcementContextQuery(query, headerServerId: headerServerId) {
        case .failure(let reply):
            return reply
        case .success(let serverId):
            scopedServer = serverId
        }
        lock.lock()
        guard let announcement = announcements.first(where: { $0.id == announcementId }),
              announcementVisibleLocked(announcement, userId: userId, serverId: scopedServer)
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Announcement not found\"}")
        }
        announcementDismissals.insert("\(userId)\n\(announcementId)")
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func setAgentActivity(agentId: String, activity: String, detail: String) {
        lock.lock()
        agentActivities[agentId] = (activity, detail)
        lock.unlock()
    }

    public func agentReadCursor(agentId: String, channelId: String) -> (seq: Int, version: Int) {
        lock.lock()
        defer { lock.unlock() }
        return agentChannelReadCursors["\(channelId)\n\(agentId)"] ?? (0, 0)
    }

    public func markChannelUnread(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let readableUnread = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readableUnread else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let cursor = max(0, (oauth.latestPeerMessageSeq(channelId: channelId, excluding: userId) ?? 1) - 1)
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: cursor)
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        return Self.json(200, "{\"channelId\":\(jsonString(channelId)),\"unreadCount\":\(info.unreadCount),\"maxReadSeq\":\(info.maxReadSeq)}")
    }

    public func channelUnread(authorization: String?, serverId: String, summary: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let channels = oauth.channelsForServer(serverId: serverId, userId: userId).filter { channel in
            guard channel.joined else { return false }
            if let thread = postableChannels[channel.id], thread.kind == "thread" {
                guard let parentId = thread.parentChannelId,
                      let parent = postableChannels[parentId],
                      parent.deletedAt == nil
                else { return false }
            }
            return true
        }
        if !summary {
            let pairs = channels.compactMap { channel -> String? in
                let info = oauth.channelUnreadInfo(channelId: channel.id, userId: userId)
                guard info.unreadCount > 0 else { return nil }
                return "\(jsonString(channel.id)):\(info.unreadCount)"
            }.joined(separator: ",")
            return Self.privateJSON("{\(pairs)}")
        }
        var entries: [String] = []
        var threadUnread: [String: (count: Int, hasMention: Bool)] = [:]
        for channel in channels {
            let info = oauth.channelUnreadInfo(channelId: channel.id, userId: userId)
            let thread = postableChannels[channel.id].flatMap { $0.kind == "thread" ? $0 : nil }
            if thread != nil {
                guard threadFollows["\(serverId)\n\(userId)\n\(channel.id)"] != nil,
                      !inboxDoneScopes.contains("\(userId)\n\(channel.id)")
                else { continue }
            }
            let threadReplies = thread == nil ? [] : humanMessageRows.filter { $0.channelId == channel.id }
            var unreadCount = info.unreadCount
            var latestMessageId = info.latestMessageId
            var latestSeq = info.latestSeq
            if !threadReplies.isEmpty {
                unreadCount = threadReplies.filter { $0.seq > info.maxReadSeq && $0.senderId != userId }.count
                latestMessageId = threadReplies.last?.id
                latestSeq = threadReplies.count
            }
            let mentions = storedMentions.filter { $0.channelId == channel.id && $0.targetType == "user" && $0.targetId == userId }
            let hasAny = !mentions.isEmpty
            if let thread, unreadCount > 0, let parentId = thread.parentChannelId {
                var aggregate = threadUnread[parentId] ?? (count: 0, hasMention: false)
                aggregate.count += 1
                aggregate.hasMention = aggregate.hasMention || hasAny
                threadUnread[parentId] = aggregate
            }
            guard unreadCount > 0 else { continue }
            let latest: String
            if let messageId = latestMessageId, let seq = latestSeq {
                latest = "{\"messageId\":\(jsonString(messageId)),\"seq\":\"\(seq)\"}"
            } else {
                latest = "null"
            }
            var entry = "{\"unreadCount\":\(unreadCount),\"hasMention\":\(hasAny),\"hasAnyMention\":\(hasAny),\"readState\":{\"kind\":\"present\",\"readStateVersion\":0,\"maxReadSeq\":\"\(info.maxReadSeq)\",\"latestActivity\":\(latest)}"
            if let thread, let parentId = thread.parentChannelId {
                entry += ",\"parentChannelId\":\(jsonString(parentId))"
                if let parentMessageId = thread.parentMessageId {
                    entry += ",\"parentMessageId\":\(jsonString(parentMessageId))"
                }
            }
            entry += "}"
            entries.append("\(jsonString(channel.id)):\(entry)")
        }
        let threadJSON = threadUnread.keys.sorted().map { parentId -> String in
            let value = threadUnread[parentId] ?? (count: 0, hasMention: false)
            return "\(jsonString(parentId)):{\"count\":\(value.count),\"hasMention\":\(value.hasMention)}"
        }.joined(separator: ",")
        return Self.privateJSON("{\"channels\":{\(entries.joined(separator: ","))},\"threadUnread\":{\(threadJSON)}}")
    }

    public func channelNotificationSettings(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let channelType = oauth.channelType(id: channelId) ?? "channel"
        guard channelType != "thread" else {
            return Self.json(400, "{\"error\":\"Threads use follow/unfollow instead of activity mute\"}")
        }
        let supported = channelType == "channel"
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: userId)
        let muteSeq = prefs.muteFromSeq.map(String.init) ?? "null"
        return Self.json(200, "{\"activityMuted\":\(prefs.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(prefs.prefsVersion),\"activityMuteSupported\":\(supported)}")
    }

    public func patchChannelNotificationSettings(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        let channelType = oauth.channelType(id: channelId) ?? "channel"
        guard channelType != "thread" else {
            return Self.json(400, "{\"error\":\"Threads use follow/unfollow instead of activity mute\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let muted = object["activityMuted"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"activityMuted must be a boolean\"}")
        }
        let result = oauth.setActivityMuted(channelId: channelId, userId: userId, muted: muted)
        let muteSeq = result.prefs.muteFromSeq.map(String.init) ?? "null"
        let supported = channelType == "channel"
        return Self.json(200, "{\"activityMuted\":\(result.prefs.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(result.prefs.prefsVersion),\"activityMuteSupported\":\(supported)}")
    }

    public func patchChannelRoute(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil,
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel update\"}")
        }
        if object["guestVisible"] != nil || object["guestJoinable"] != nil {
            guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            lock.lock()
            if let visible = object["guestVisible"] as? Bool { guestVisibleChannels[channelId] = visible }
            if let joinable = object["guestJoinable"] as? Bool { guestJoinableChannels[channelId] = joinable }
            let visibleNow = guestVisibleChannels[channelId] ?? false
            let joinableNow = guestJoinableChannels[channelId] ?? false
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"id\":\(jsonString(channelId)),\"guestVisible\":\(visibleNow),\"guestJoinable\":\(joinableNow)}")
        }
        if let rawVisibility = object["visibility"] {
            guard let visibility = rawVisibility as? String, ["private", "public"].contains(visibility) else {
                return Self.json(400, "{\"error\":\"Invalid channel visibility\"}")
            }
            if oauth.allChannelId(serverId: serverId) == channelId {
                return Self.json(403, "{\"error\":\"Only a human can do it, from channel settings or server settings\",\"code\":\"all_channel_visibility_managed_separately\"}")
            }
            guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            lock.lock()
            let isMember = postableChannels[channelId]?.memberIds.contains(userId) == true
            lock.unlock()
            guard isMember || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
                return Self.json(403, "{\"error\":\"You must be a channel member\",\"code\":\"channel_membership_required\"}")
            }
            _ = oauth.setChannelType(id: channelId, type: visibility == "private" ? "private" : "channel")
            lock.lock()
            postableChannels[channelId]?.kind = visibility == "private" ? "private" : "channel"
            if visibility == "private" {
                let snapshot = postableChannels[channelId]?.memberIds ?? []
                let threadIds = Set(postableChannels.filter { $0.value.kind == "thread" && $0.value.parentChannelId == channelId }.keys)
                for (key, follow) in threadFollows where threadIds.contains(follow.threadChannelId) && !snapshot.contains(follow.userId) {
                    threadFollows.removeValue(forKey: key)
                }
            }
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"id\":\(jsonString(channelId)),\"visibility\":\(jsonString(visibility)),\"type\":\(jsonString(visibility == "private" ? "private" : "channel"))}")
        }
        let serverRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        lock.lock()
        let actorChannelRole = channelHumanRoles["\(channelId)\n\(userId)"]
        let jointCanonical = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId
        let jointLinks = jointCanonical.map { canonical in
            jointProjections.filter { $0.canonicalChannelId == canonical }.map(\.localChannelId)
        } ?? []
        let actorName = accounts.values.first(where: { $0.id == userId })?.name ?? "Someone"
        lock.unlock()
        guard actorChannelRole == "admin" || serverRole == "owner" || serverRole == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if !jointLinks.isEmpty {
            if object["visibility"] != nil || object["archived"] != nil {
                return Self.json(403, "{\"error\":\"Only a server admin can change joint visibility or archive\",\"code\":\"joint_channel_admin_limited\"}")
            }
            let jointName = object["name"] as? String
            let jointDescription = object["description"] as? String
            if let jointName, jointName.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) == nil {
                return Self.json(400, "{\"error\":\"Invalid channel name\"}")
            }
            var systemSeq: Int?
            for linkId in jointLinks {
                let seq = oauth.updateChannel(id: linkId, name: jointName, description: jointDescription, systemMessage: nil)
                systemSeq = seq ?? systemSeq
                lock.lock()
                if let jointName { postableChannels[linkId]?.name = jointName }
                lock.unlock()
            }
            let latest = oauth.channelInfo(id: channelId)
            let nameJSON = jsonString(latest?.name ?? channel.name)
            let descriptionJSON = latest?.description.map(jsonString) ?? "null"
            return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(nameJSON),\"description\":\(descriptionJSON),\"systemMessageSeq\":\(systemSeq.map(String.init) ?? "null")}")
        }
        var newName: String?
        if let name = object["name"] as? String, name != channel.name {
            guard name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil else {
                return Self.json(400, "{\"error\":\"Invalid channel name\"}")
            }
            newName = name
        }
        let newDescription = object["description"] as? String
        var systemMessage: String?
        if let newName {
            systemMessage = "@\(actorName) renamed this channel from #\(channel.name) to #\(newName)."
        }
        let seq = oauth.updateChannel(
            id: channelId,
            name: newName,
            description: newDescription,
            systemMessage: systemMessage
        )
        let latest = oauth.channelInfo(id: channelId)
        let nameJSON = jsonString(latest?.name ?? channel.name)
        let descriptionJSON = latest?.description.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(nameJSON),\"description\":\(descriptionJSON),\"systemMessageSeq\":\(seq.map(String.init) ?? "null")}")
    }

    public func createChannelRoute(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String,
              name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil,
              name != "all"
        else {
            return Self.json(400, "{\"error\":\"Invalid channel\"}")
        }
        if (object["visibility"] as? String) == "joint" {
            guard let targetSlug = (object["targetServerSlug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let targetServerId = oauth.serverIdForSlug(targetSlug),
                  targetServerId != serverId,
                  let targetServer = oauth.serverDetailsValue(id: targetServerId)
            else {
                return Self.json(400, "{\"error\":\"targetServerSlug is required\"}")
            }
            let invited = object["invitedPeople"] as? [String] ?? []
            let inviteHandle = invited.first.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 } ?? ""
            let targetOwnerId = accounts.values.first { $0.name.caseInsensitiveCompare(inviteHandle) == .orderedSame }?.id
            guard let targetOwnerId, oauth.memberRole(serverId: targetServerId, userId: targetOwnerId) != nil else {
                return Self.json(400, "{\"error\":\"invited person must belong to the target server\"}")
            }
            let hostChannelId = oauth.createChannel(serverId: serverId, name: name, creatorUserId: userId)
            _ = oauth.setChannelType(id: hostChannelId, type: "joint")
            let targetChannelId = oauth.createChannel(serverId: targetServerId, name: name, creatorUserId: targetOwnerId)
            _ = oauth.setChannelType(id: targetChannelId, type: "joint")
            addJointChannelProjection(localChannelId: hostChannelId, canonicalChannelId: hostChannelId, serverId: serverId)
            addJointChannelProjection(localChannelId: targetChannelId, canonicalChannelId: hostChannelId, serverId: targetServerId)
            lock.lock()
            postableChannels[hostChannelId] = PostableChannel(serverId: serverId, memberIds: [userId], kind: "joint", name: name)
            postableChannels[targetChannelId] = PostableChannel(serverId: targetServerId, memberIds: [], kind: "joint", name: name)
            let inviteId = UUID().uuidString.lowercased()
            jointInvites.append((inviteId, serverId, hostChannelId, targetServerId, targetChannelId, targetOwnerId, "pending"))
            lock.unlock()
            return Self.json(200, "{\"id\":\(jsonString(hostChannelId)),\"name\":\(jsonString(name)),\"type\":\"joint\",\"targetServerSlug\":\(jsonString(targetServer.slug)),\"jointInvite\":{\"id\":\(jsonString(inviteId)),\"status\":\"pending\"},\"joined\":true}")
        }
        lock.lock()
        let collision = postableChannels.first { _, channel in
            channel.serverId == serverId && channel.name == name && channel.deletedAt == nil
                && (channel.kind == "channel" || channel.kind == "private")
        }
        if let collision {
            let canUnarchive = collision.value.archived
                && channelHumanRoles["\(collision.key)\n\(userId)"] == "admin"
            lock.unlock()
            return Self.json(409, "{\"error\":\"A channel named #\(name) already exists\",\"canUnarchiveArchivedChannel\":\(canUnarchive)}")
        }
        lock.unlock()
        let description = object["description"] as? String
        let channelId = oauth.createChannel(
            serverId: serverId,
            name: name,
            creatorUserId: userId,
            description: description
        )
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: [userId], name: name)
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name)),\"joined\":true,\"activityMuteSupported\":true,\"activityMuted\":false,\"muteFromSeq\":null,\"prefsVersion\":0,\"maxReadSeq\":0,\"readStateVersion\":0}")
    }

    public func setUserChannelReadCursorForTesting(userId: String, channelId: String, seq: Int) {
        lock.lock()
        userChannelReadCursorsForTesting["\(userId)\n\(channelId)"] = seq
        lock.unlock()
    }

    func agentUserPageValues(limit: String?, offset: String?) -> (limit: Int, offset: Int)? {
        if let limit, Int(limit) == nil { return nil }
        if let offset, Int(offset) == nil { return nil }
        let resolvedLimit = limit.flatMap(Int.init) ?? 50
        let resolvedOffset = offset.flatMap(Int.init) ?? 0
        guard (1...200).contains(resolvedLimit), resolvedOffset >= 0 else { return nil }
        return (resolvedLimit, resolvedOffset)
    }

    func agentUserChannelsPayload(identity: (agentId: String, serverId: String), name: String, limit: String?, offset: String?) -> (text: String, json: String, status: Int)? {
        let normalized = name.hasPrefix("@") ? String(name.dropFirst()) : name
        guard !normalized.isEmpty else { return nil }
        guard let page = agentUserPageValues(limit: limit, offset: offset) else { return nil }
        lock.lock()
        let hidden = hideHumansFromMembers[identity.serverId] ?? false
        lock.unlock()
        let callerAgentRole = oauth.agentRole(serverId: identity.serverId, agentId: identity.agentId) ?? "member"
        guard let subject = accounts.values.first(where: { $0.name == normalized }) else { return nil }
        if hidden, callerAgentRole != "owner", callerAgentRole != "admin" { return nil }
        let subjectServerRole = oauth.memberRole(serverId: identity.serverId, userId: subject.id)
        guard let subjectServerRole else { return nil }
        var unchecked = 0
        lock.lock()
        let postableSnapshot = postableChannels
        let jointSnapshot = jointProjections
        lock.unlock()
        let callerReadsRoster: (String) -> Bool = { [self] channelId in
            if postableSnapshot[channelId]?.memberIds.contains(identity.agentId) == true { return true }
            return oauth.channelAgentIds(channelId: channelId).contains(identity.agentId)
        }
        let channels = oauth.channelsForServer(serverId: identity.serverId, userId: subject.id, includeArchived: false)
        var rows: [String] = []
        for channel in channels {
            let type = oauth.channelType(id: channel.id) ?? channel.type
            if type == "joint" {
                guard let link = jointSnapshot.first(where: { $0.localChannelId == channel.id && $0.serverId == identity.serverId }),
                      link.status == "active",
                      callerReadsRoster(channel.id)
                else {
                    unchecked += 1
                    continue
                }
            }
            let role: String? = {
                guard (type == "channel" || type == "private"), channel.name != "all" else { return nil }
                lock.lock()
                let channelRole = channelHumanRoles["\(channel.id)\n\(subject.id)"]
                lock.unlock()
                return channelRole == "admin" ? "admin" : "member"
            }()
            let roleJSON = role.map(jsonString) ?? "null"
            rows.append("{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(type)),\"joined\":\(channel.joined),\"channelRole\":\(roleJSON)}")
        }
        let pageRows = Array(rows.dropFirst(page.offset).prefix(page.limit))
        let json = "{\"kind\":\"human\",\"name\":\(jsonString(subject.name)),\"uncheckedCount\":\(unchecked),\"memberships\":[\("\(pageRows.joined(separator: ","))")],\"page\":{\"total\":\(rows.count),\"offset\":\(page.offset),\"limit\":\(page.limit)}}"
        var text = pageRows.map { row -> String in
            let name = (try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])?["name"] as? String ?? ""
            return "#\(name)"
        }.joined(separator: "\n")
        if unchecked > 0 {
            text += (text.isEmpty ? "" : "\n") + "Skipped \(unchecked) visible channel roster checks because the server rejected them."
        }
        return (text, json, 200)
    }

    public func appAgentReminderMessage(authorization: String?, body: String) -> HTTPReply {
        guard let access = oauth.appInstallationAccess(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Invalid installation credential\"}")
        }
        guard access.official, access.groups.contains("agent_reminder_write") else {
            return Self.json(403, "{\"error\":\"Agent reminder write is not authorized for this app\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let agentId = object["agentId"] as? String, ServerScope.isUUID(agentId),
              let key = object["idempotencyKey"] as? String, (1...200).contains(key.count),
              let text = object["text"] as? String, (1...8000).contains(text.count)
        else {
            return Self.json(400, "{\"error\":\"Invalid agent reminder request\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == access.serverId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        let ledgerKey = "\(access.clientId)\n\(agentId)\n\(key)"
        lock.lock()
        if let existing = appAgentReminderLedger[ledgerKey] {
            lock.unlock()
            return Self.json(200, "{\"created\":false,\"messageId\":\(jsonString(existing)),\"surface\":{\"channelType\":\"dm\",\"channelName\":\"reminders\",\"target\":\"dm:@reminders\"}}")
        }
        var channelId = agentReminderSurfaceChannels[agentId]
        if let existing = channelId, postableChannels[existing]?.deletedAt != nil {
            agentReminderSurfaceChannels.removeValue(forKey: agentId)
            channelId = nil
        }
        lock.unlock()
        if channelId == nil {
            let createdChannel = oauth.createChannel(serverId: access.serverId, name: "reminders", creatorUserId: agentId, type: "dm")
            oauth.addChannelAgent(channelId: createdChannel, agentId: agentId)
            lock.lock()
            postableChannels[createdChannel] = PostableChannel(serverId: access.serverId, memberIds: [agentId], kind: "dm", name: "reminders")
            agentReminderSurfaceChannels[agentId] = createdChannel
            lock.unlock()
            channelId = createdChannel
        }
        guard let channelId else { return Self.json(500, "{\"error\":\"reminder surface unavailable\"}") }
        let message = oauth.createMessageRecord(
            channelId: channelId,
            content: text,
            senderId: "system",
            senderType: "user",
            messageType: "system",
            systemSubtype: "agent.reminder_due"
        )
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: message.id,
            channelId: channelId,
            senderId: "system",
            content: text,
            randomId: nil,
            messageType: "system",
            senderType: "user",
            systemSubtype: "agent.reminder_due"
        ))
        appAgentReminderLedger[ledgerKey] = message.id
        lock.unlock()
        return Self.json(200, "{\"created\":true,\"messageId\":\(jsonString(message.id)),\"surface\":{\"channelType\":\"dm\",\"channelName\":\"reminders\",\"target\":\"dm:@reminders\"}}")
    }

    public func softDeleteAgentReminderSurfaceForTesting(agentId: String) {
        lock.lock()
        if let channelId = agentReminderSurfaceChannels[agentId] {
            postableChannels[channelId]?.deletedAt = Date()
        }
        lock.unlock()
    }

    public func agentReminderSurfaceForTesting(agentId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return agentReminderSurfaceChannels[agentId]
    }

    public func agentUserChannels(authorization: String?, name: String, limit: String?, offset: String?) -> HTTPReply {
        guard let identity = agentCredentialIdentity(authorization: authorization, capability: "channels") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        guard agentCredentialScopes(authorization: authorization)?.contains("read") == true else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        let scopes = agentCredentialScopes(authorization: authorization) ?? []
        for required in ["channel:read", "server:read"] where !scopes.contains(required) {
            return Self.json(403, "{\"error\":\"missing required scope\",\"requiredScope\":\(jsonString(required)),\"reason\":\"missing_scope\"}")
        }
        guard agentUserPageValues(limit: limit, offset: offset) != nil else {
            return Self.json(400, "{\"error\":\"Invalid page window\",\"code\":\"agent_api_contract_invalid\"}")
        }
        guard let payload = agentUserChannelsPayload(identity: identity, name: name, limit: limit, offset: offset) else {
            return Self.json(404, "{\"error\":\"User not found or not visible\",\"code\":\"user_not_found\"}")
        }
        return Self.json(payload.status, payload.json)
    }

    public func agentUserInfo(authorization: String?, name: String, limit: String?, offset: String?) -> HTTPReply {
        guard let identity = agentCredentialIdentity(authorization: authorization, capability: "channels") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        guard agentCredentialScopes(authorization: authorization)?.contains("read") == true else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        let scopes = agentCredentialScopes(authorization: authorization) ?? []
        for required in ["channel:read", "server:read"] where !scopes.contains(required) {
            return Self.json(403, "{\"error\":\"missing required scope\",\"requiredScope\":\(jsonString(required)),\"reason\":\"missing_scope\"}")
        }
        let normalized = name.hasPrefix("@") ? String(name.dropFirst()) : name
        if normalized.isEmpty || agentUserPageValues(limit: limit, offset: offset) == nil {
            return Self.json(400, "{\"error\":\"User not found or not visible\",\"code\":\"user_not_found\"}")
        }
        guard let payload = agentUserChannelsPayload(identity: identity, name: name, limit: limit, offset: offset) else {
            return Self.json(404, "{\"error\":\"User not found or not visible\",\"code\":\"user_not_found\"}")
        }
        return HTTPReply(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store"], body: payload.text)
    }

    public func conversationReadAll(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = sidebarReadAllEnabled
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil,
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let hasAccess = postableChannels[channelId]?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: channelId).contains(userId)
            || oauth.channelType(id: channelId) == "channel"
        guard hasAccess else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        var scopeIds = [channelId]
        for (_, follow) in threadFollows where follow.userId == userId && follow.parentMessageId != "" {
            guard let parentRow = humanMessageRows.first(where: { $0.id == follow.parentMessageId }),
                  parentRow.channelId == channelId
            else { continue }
            if !scopeIds.contains(follow.threadChannelId) { scopeIds.append(follow.threadChannelId) }
        }
        let rows = scopeIds.map { scope -> String in
            let latest = humanMessageRows.filter { $0.channelId == scope }.map(\.seq).max() ?? 0
            let key = "\(userId)\n\(scope)"
            let previous = userChannelReadCursorsForTesting[key] ?? 0
            let version = previous + 1
            userChannelReadCursorsForTesting[key] = max(previous, latest)
            return "{\"scopeId\":\(jsonString(scope)),\"maxReadSeq\":\(latest),\"readStateVersion\":\(version)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"serverId\":\(jsonString(serverId)),\"scopes\":[\(rows)]}")
    }

    public func postReadMutation(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let mutationId = object["mutationId"] as? String,
              ServerScope.isUUID(mutationId)
        else {
            return Self.json(400, "{\"error\":\"Invalid mutation id\",\"code\":\"INVALID_MUTATION_ID\"}")
        }
        guard mutationId != "00000000-0000-1000-8000-000000000000" else {
            return Self.json(400, "{\"error\":\"Invalid mutation id\",\"code\":\"INVALID_MUTATION_ID\"}")
        }
        guard let rawKind = object["kind"] as? String else {
            return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
        }
        let rawScope = (object["scopeId"] as? String).flatMap { ServerScope.isUUID($0) ? $0 : nil }
        let rawThrough = (object["throughSeq"] as? NSNumber)?.stringValue ?? (object["throughSeq"] as? String)
        let fingerprint = "\(rawKind):\(rawScope ?? ""):\(rawThrough ?? "")"
        let key = "\(serverId)\n\(userId)\n\(mutationId)"
        lock.lock()
        if let existing = readMutationRecords[key] {
            guard existing.fingerprint == fingerprint else {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Mutation id reused with a different payload\",\"code\":\"MUTATION_ID_PAYLOAD_MISMATCH\"}")
            }
            let cursor = userChannelReadCursorsForTesting["\(userId)\n\(existing.scopeId ?? "")"] ?? 0
            lock.unlock()
            if existing.kind == "channel_read_all", cursor > 0 {
                return Self.json(200, "{\"outcome\":\"ALREADY_TERMINAL\",\"ack\":{\"terminalReason\":\"completed\",\"capturedBoundary\":[{\"scopeId\":\(jsonString(existing.scopeId ?? "")),\"throughSeq\":\(cursor)}],\"scopes\":[{\"scopeId\":\(jsonString(existing.scopeId ?? "")),\"maxReadSeq\":\(cursor)}]}}")
            }
            return Self.json(200, "{\"outcome\":\"ALREADY_ADMITTED\"}")
        }
        lock.unlock()
        guard rawKind == "global_read_all" || rawKind == "channel_read_all" else {
            return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
        }
        var scopeId: String?
        if rawKind == "channel_read_all" {
            guard let rawScope else {
                return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
            }
            guard let channelType = oauth.channelType(id: rawScope), oauth.channelInfo(id: rawScope) != nil else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            lock.lock()
            let hasOwnedCursor = userChannelReadCursorsForTesting["\(userId)\n\(rawScope)"] != nil
            let visible = postableChannels[rawScope]?.memberIds.contains(userId) == true
                || oauth.channelHumanIds(channelId: rawScope).contains(userId)
                || (channelType == "channel" && oauth.memberRole(serverId: serverId, userId: userId) != nil)
                || (hasOwnedCursor && oauth.memberRole(serverId: serverId, userId: userId) != nil)
            lock.unlock()
            guard visible else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            scopeId = rawScope
        }
        lock.lock()
        let sequenceKey = "\(serverId)\n\(userId)"
        let seq = (readMutationAuthoritySeq[sequenceKey] ?? 0) + 1
        readMutationAuthoritySeq[sequenceKey] = seq
        readMutationRecords[key] = ReadMutationRecord(
            mutationId: mutationId, serverId: serverId, principalId: userId,
            kind: rawKind, scopeId: scopeId, fingerprint: fingerprint,
            authoritySeq: seq, state: "admitted"
        )
        readMutationOrder.append(key)
        lock.unlock()
        return Self.json(201, "{\"outcome\":\"ADMITTED\",\"serverId\":\(jsonString(serverId)),\"principalId\":\(jsonString(userId)),\"authoritySeq\":\(seq),\"mutationId\":\(jsonString(mutationId))}")
    }

    public func readMutationFrontier(authorization: String?, scopeIds: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let sequences = readMutationAuthoritySeq.filter { $0.key.hasSuffix("\n\(userId)") || $0.key.contains("\n\(userId)") }
        let upper = sequences.values.max() ?? 0
        let keys = readMutationOrder.filter { readMutationRecords[$0]?.principalId == userId }
        let records = keys.compactMap { readMutationRecords[$0] }
        var lastTerminal = 0
        let items = records.map { record -> String in
            if record.state != "admitted" { lastTerminal = max(lastTerminal, record.authoritySeq) }
            return "{\"mutationId\":\(jsonString(record.mutationId)),\"authoritySeq\":\(record.authoritySeq),\"state\":\(jsonString(record.state))}"
        }.joined(separator: ",")
        var scopesJSON: String?
        if let scopeIds {
            let rows = scopeIds.split(separator: ",").map(String.init).map { scope -> String in
                let cursor = userChannelReadCursorsForTesting["\(userId)\n\(scope)"] ?? 0
                return "{\"scopeId\":\(jsonString(scope)),\"maxReadSeq\":\(cursor)}"
            }.joined(separator: ",")
            scopesJSON = "[\("\(rows)")]"
        }
        lock.unlock()
        let scopesField = scopesJSON.map { ",\"scopes\":\($0)" } ?? ""
        return Self.json(200, "{\"nextAuthoritySeq\":\(upper + 1),\"lastTerminalAuthoritySeq\":\(lastTerminal),\"snapshotUpperAuthoritySeq\":\(upper),\"items\":[\(items)]\(scopesField)}")
    }


    public func acceptJointChannelInvite(authorization: String?, inviteId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = jointInvites.firstIndex(where: { $0.id == inviteId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Invite not found\"}")
        }
        let invite = jointInvites[index]
        lock.unlock()
        guard oauth.memberRole(serverId: invite.targetServerId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        oauth.addChannelHuman(channelId: invite.targetChannelId, userId: userId)
        lock.lock()
        jointInvites[index].status = "accepted"
        postableChannels[invite.targetChannelId]?.memberIds.insert(userId)
        let channel = postableChannels[invite.targetChannelId]
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(invite.targetChannelId)),\"name\":\(jsonString(channel?.name ?? "")),\"type\":\"joint\",\"joined\":true}")
    }

    public func listChannels(authorization: String?, serverId: String, archived: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let guestVisibleSnapshot = guestVisibleChannels
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: archived == "include")
            .filter { archived == "include" || oauth.channelArchivedAt(id: $0.id) == nil }
            .filter { role != "guest" || (guestVisibleSnapshot[$0.id] ?? true) }
            .map { channel -> String in
            let last = channel.lastMessageAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
            let muteSeq = channel.muteFromSeq.map(String.init) ?? "null"
            let archivedAt = oauth.channelArchivedAt(id: channel.id).map { jsonString(formatter.string(from: $0)) } ?? "null"
            let displayPrefs = oauth.channelDisplayPrefs(channelId: channel.id, userId: userId)
            lock.lock()
            let localRole = channelHumanRoles["\(channel.id)\n\(userId)"]
            let isJoint = jointProjections.contains { $0.localChannelId == channel.id }
            lock.unlock()
            let serverAdmin = role == "owner" || role == "admin"
            let capability = localRole == "admin" || serverAdmin
            let basis: String? = localRole == "admin" ? "channel_role" : (serverAdmin ? "server_role" : nil)
            let channelRole = basis == nil ? "member" : "admin"
            let caps = "{\"editChannelMetadata\":\(capability),\"archiveChannels\":\(capability && !isJoint),\"addChannelMembers\":\(capability && !isJoint),\"removeChannelMembers\":\(capability && !isJoint),\"changeChannelMemberRoles\":\(capability),\"manageGuestAccess\":\(serverAdmin && !isJoint),\"deleteChannels\":\(serverAdmin),\"changeChannelVisibility\":\(serverAdmin),\"federateChannels\":\(serverAdmin)}"
            return "{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(channel.type)),\"joined\":\(channel.name == "all" || channel.joined),\"archivedAt\":\(archivedAt),\"lastMessageAt\":\(last),\"activityMuted\":\(channel.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(channel.prefsVersion),\"activityMuteSupported\":\(channel.type == "channel"),\"collapseLongMessages\":\(displayPrefs.collapseLongMessages),\"displayPrefsVersion\":\(displayPrefs.prefsVersion),\"channelRole\":\(jsonString(channelRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"channelCapabilities\":\(caps)}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func completeProfile(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String,
              let rawDisplay = object["displayName"] as? String
        else {
            return Self.json(400, "{\"error\":\"name and displayName are required\",\"code\":\"PROFILE_SETUP_INVALID\"}")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !displayName.isEmpty else {
            return Self.json(400, "{\"error\":\"name and displayName are required\",\"code\":\"PROFILE_SETUP_INVALID\"}")
        }
        let lowered = name.lowercased()
        if lowered.hasPrefix("pending_") || Self.reservedAgentNames.contains(lowered) {
            return Self.json(400, "{\"error\":\"This username is reserved. Choose another name.\",\"code\":\"PROFILE_SETUP_NAME_RESERVED\"}")
        }
        lock.lock()
        guard let key = accounts.first(where: { $0.value.id == userId })?.key, var account = accounts[key] else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if let completedAt = account.profileSetupCompletedAt {
            let replay = account.name == name && (account.displayName ?? account.name) == displayName
            lock.unlock()
            if replay {
                let user = Self.userJSON(accounts[key] ?? account)
                return Self.json(200, "{\"name\":\(jsonString(account.name)),\"displayName\":\(jsonString(account.displayName ?? account.name)),\"profileSetupCompletedAt\":\(jsonString(Self.isoString(completedAt))),\"user\":\(user)}")
            }
            return Self.json(409, "{\"error\":\"Profile setup is already completed\",\"code\":\"PROFILE_SETUP_ALREADY_COMPLETED\"}")
        }
        let taken = Set(accounts.values.filter { $0.id != userId }.map { $0.name.lowercased() })
        guard !taken.contains(lowered) else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"That username is taken\",\"code\":\"PROFILE_SETUP_NAME_TAKEN\"}")
        }
        account.name = name
        account.displayName = displayName
        account.profileSetupCompletedAt = Date()
        accounts[key] = account
        lock.unlock()
        let completed = account.profileSetupCompletedAt ?? Date()
        let user = Self.userJSON(account)
        return Self.json(200, "{\"name\":\(jsonString(name)),\"displayName\":\(jsonString(displayName)),\"profileSetupCompletedAt\":\(jsonString(Self.isoString(completed))),\"user\":\(user)}")
    }

    public func createServer(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let profileSetupPending = accounts.values.first { $0.id == userId }.map {
            $0.emailVerified && $0.profileSetupCompletedAt == nil
        } ?? false
        lock.unlock()
        if profileSetupPending {
            return Self.json(403, "{\"error\":\"Profile setup required\",\"code\":\"PROFILE_SETUP_REQUIRED\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String,
              let rawSlug = object["slug"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid server request\"}")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !slug.isEmpty else {
            return Self.json(400, "{\"error\":\"Invalid server request\"}")
        }
        if let existing = oauth.serverIdForSlug(slug) {
            if let profile = oauth.serverProfile(id: existing), let role = oauth.memberRole(serverId: existing, userId: userId) {
                return Self.json(200, "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"role\":\(jsonString(role))}")
            }
            return Self.json(409, "{\"error\":\"Slug is already taken\"}")
        }
        guard slug.count >= 5 else {
            return Self.json(400, "{\"error\":\"Slug must be at least 5 characters\"}")
        }
        let serverId = UUID().uuidString.lowercased()
        oauth.addOwnedServer(id: serverId, slug: slug, name: name, ownerId: userId)
        return Self.json(200, "{\"id\":\(jsonString(serverId)),\"name\":\(jsonString(name)),\"slug\":\(jsonString(slug)),\"role\":\"owner\"}")
    }

    public func serverProductAnalyticsSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let enabled = oauth.serverAnalyticsAllowed(id: serverId) ?? true
        let canManage = role == "owner" || role == "admin"
        return Self.json(200, "{\"productAnalyticsEnabled\":\(enabled),\"canManageProductAnalytics\":\(canManage)}")
    }

    public func patchServerProductAnalyticsSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["productAnalyticsEnabled"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"productAnalyticsEnabled must be a boolean\"}")
        }
        oauth.setServerProductAnalytics(id: serverId, enabled: enabled)
        return Self.json(200, "{\"productAnalyticsEnabled\":\(enabled),\"canManageProductAnalytics\":true}")
    }

    public func serverDetails(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let profile = oauth.serverProfile(id: serverId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        if role == "guest" {
            return Self.json(200, "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":null}")
        }
        let avatar = profile.avatarUrl.map { jsonString($0) } ?? "null"
        let body = "{\"id\":\(jsonString(profile.id)),\"ownerId\":\(jsonString(profile.ownerId)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":\(avatar),\"plan\":\(jsonString(profile.plan)),\"translationEnabled\":\(profile.translationEnabled),\"publiclyVisible\":\(profile.publiclyVisible),\"publicGuestJoinEnabled\":\(profile.publicGuestJoinEnabled)}"
        return Self.json(200, body)
    }

    public func setProviderConnectionsEnabled(serverId: String, enabled: Bool) {
        lock.lock()
        if enabled {
            providerConnectionsEnabledServers.insert(serverId)
        } else {
            providerConnectionsEnabledServers.remove(serverId)
        }
        lock.unlock()
    }

    public static let providerConnectionProviderIds = [
        "deepseek", "minimax", "minimax-cn", "zai", "zai-coding-cn", "moonshotai",
        "moonshotai-cn", "kimi-coding", "qwen-token-plan", "qwen-token-plan-cn",
        "openrouter", "openai", "anthropic", "google", "xai", "xiaomi",
        "openai-compatible", "anthropic-compatible",
    ]

    public func listProviderConnections(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = providerConnections.filter { $0.serverId == serverId }
        lock.unlock()
        let connections = rows.map { Self.providerConnectionJSON($0) }.joined(separator: ",")
        let options = Self.providerConnectionProviderIds.map { id -> String in
            let kind = id.hasSuffix("-compatible") ? "gateway" : "preset"
            return "{\"id\":\(jsonString(id)),\"label\":\(jsonString(Self.providerConnectionLabel(id))),\"providerKind\":\(jsonString(kind))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"connections\":[\(connections)],\"providerOptions\":[\(options)]}")
    }

    public func createProviderConnection(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let providerId = object["providerId"] as? String,
              Self.providerConnectionProviderIds.contains(providerId),
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let allowedKeys: Set<String> = ["name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let now = Date()
        let connection = ProviderConnection(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            providerId: providerId,
            endpointUrl: object["endpointUrl"] as? String,
            supportsImageInput: object["supportsImageInput"] as? Bool ?? false,
            status: "unchecked",
            configVersion: 1,
            credentialVersion: 1,
            hasCredential: true,
            createdAt: now,
            updatedAt: now
        )
        lock.lock()
        providerConnections.append(connection)
        lock.unlock()
        return Self.json(201, Self.providerConnectionJSON(connection))
    }

    public func retiredProviderProbe(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        return Self.json(410, "{\"error\":\"Provider probing is retired\"}")
    }

    public func patchProviderConnection(authorization: String?, serverId: String, connectionId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let allowedKeys: Set<String> = ["name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        if object["apiKey"] != nil, object["providerId"] != nil {
            return Self.json(400, "{\"error\":\"Rotate the credential separately from provider configuration\"}")
        }
        lock.lock()
        guard let index = providerConnections.firstIndex(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        if let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providerConnections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let endpoint = object["endpointUrl"] as? String {
            providerConnections[index].endpointUrl = endpoint
        }
        if let supports = object["supportsImageInput"] as? Bool {
            providerConnections[index].supportsImageInput = supports
        }
        if let apiKey = object["apiKey"] as? String, !apiKey.isEmpty {
            providerConnections[index].credentialVersion += 1
            providerConnections[index].status = "unchecked"
            providerConnections[index].hasCredential = true
        }
        providerConnections[index].updatedAt = Date()
        let updated = providerConnections[index]
        lock.unlock()
        return Self.json(200, Self.providerConnectionJSON(updated))
    }

    public func rotateProviderConnectionCredential(authorization: String?, serverId: String, connectionId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"apiKey is required\"}")
        }
        lock.lock()
        guard let index = providerConnections.firstIndex(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        providerConnections[index].credentialVersion += 1
        providerConnections[index].status = "unchecked"
        providerConnections[index].hasCredential = true
        providerConnections[index].updatedAt = Date()
        let updated = providerConnections[index]
        lock.unlock()
        return Self.json(200, Self.providerConnectionJSON(updated))
    }

    public func pushRegistration(installationId: String, provider: String) -> PushRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return pushRegistrations.first { $0.installationId == installationId && $0.provider == provider }
    }

    public func registerPushDevice(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let installationId = object["installationId"] as? String,
              installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil,
              let provider = object["provider"] as? String, provider == "apns" || provider == "fcm",
              let topic = object["topic"] as? String,
              topic.wholeMatch(of: /^[A-Za-z0-9.-]{1,155}$/) != nil,
              let deviceToken = object["deviceToken"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid push registration\"}")
        }
        let env = object["env"] as? String ?? ""
        if provider == "apns" {
            guard env == "sandbox" || env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._-]{1,256}$/) != nil
            else {
                return Self.json(400, "{\"error\":\"Invalid push registration\"}")
            }
        } else {
            guard env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._:-]{1,4096}$/) != nil
            else {
                return Self.json(400, "{\"error\":\"Invalid push registration\"}")
            }
        }
        let appVersion = object["appVersion"] as? String
        lock.lock()
        let familyId = principal.familyId ?? UUID().uuidString.lowercased()
        if sessionFamilies[familyId] == nil {
            sessionFamilies[familyId] = SessionFamily(userId: principal.userId)
        }
        var nonce = sessionFamilies[familyId]?.revokeCapabilityNonce
        if nonce == nil {
            let minted = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            sessionFamilies[familyId]?.revokeCapabilityNonce = minted
            nonce = minted
        }
        let revokeCapability = "\(familyId).\(nonce ?? "")"
        if let index = pushRegistrations.firstIndex(where: {
            $0.installationId == installationId && $0.provider == provider
        }) {
            pushRegistrations[index].env = env
            pushRegistrations[index].topic = topic
            pushRegistrations[index].deviceToken = deviceToken
            pushRegistrations[index].appVersion = appVersion
            pushRegistrations[index].userId = principal.userId
            pushRegistrations[index].serverId = serverId
            pushRegistrations[index].sessionFamilyId = familyId
            pushRegistrations[index].revokeCapability = revokeCapability
        } else {
            pushRegistrations.append(PushRegistration(
                installationId: installationId,
                provider: provider,
                env: env,
                topic: topic,
                deviceToken: deviceToken,
                appVersion: appVersion,
                userId: principal.userId,
                serverId: serverId,
                sessionFamilyId: familyId,
                revokeCapability: revokeCapability
            ))
        }
        lock.unlock()
        let registration = "{\"installationId\":\(jsonString(installationId)),\"provider\":\(jsonString(provider)),\"env\":\(jsonString(env)),\"topic\":\(jsonString(topic))}"
        return Self.json(200, "{\"revoke_capability\":\(jsonString(revokeCapability)),\"registration\":\(registration)}")
    }

    public func webPushEndpoints(userId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return webPushSubscriptions.filter { $0.userId == userId }.map { $0.endpoint }
    }

    public func recordWebPushSubscription(authorization: String?, body: String) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let endpoint = object["endpoint"] as? String,
              Self.isPublicHTTPSPushEndpoint(endpoint),
              let keys = object["keys"] as? [String: Any],
              let p256dh = keys["p256dh"] as? String, !p256dh.isEmpty,
              let auth = keys["auth"] as? String, !auth.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid push subscription\"}")
        }
        lock.lock()
        if !webPushSubscriptions.contains(where: { $0.userId == principal.userId && $0.endpoint == endpoint }) {
            webPushSubscriptions.append(WebPushSubscription(userId: principal.userId, endpoint: endpoint))
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }


    public func revokePushFamily(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let capability = object["capability"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid capability\"}")
        }
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0].wholeMatch(of: /^[A-Za-z0-9-]+$/) != nil,
              parts[1].wholeMatch(of: /^[A-Za-z0-9]+$/) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid capability\"}")
        }
        lock.lock()
        guard let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key,
              var family = sessionFamilies[familyId]
        else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Capability is no longer valid\"}")
        }
        let now = Date()
        if let revokedAt = family.revokedAt {
            if let retain = family.capabilityRetainUntil, retain > now {
                lock.unlock()
                return Self.json(204, "")
            }
            _ = revokedAt
            lock.unlock()
            return Self.json(403, "{\"error\":\"Capability is no longer valid\"}")
        }
        family.revokedAt = now
        family.revokedReason = "push_family"
        family.capabilityRetainUntil = now.addingTimeInterval(30 * 24 * 60 * 60)
        sessionFamilies[familyId] = family
        let refreshTokens = sessions.filter { $0.value.familyId == familyId }.map { $0.key }
        for token in refreshTokens { sessions.removeValue(forKey: token) }
        let accessTokensToDrop = accessTokenFamilies.filter { $0.value == familyId }.map { $0.key }
        for token in accessTokensToDrop {
            accessTokens.removeValue(forKey: token)
            accessTokenFamilies.removeValue(forKey: token)
        }
        lock.unlock()
        return Self.json(204, "")
    }

    public func pushFamilyStatus(capability: String) -> (revoked: Bool, reason: String?, retainUntil: Date?)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let family = sessionFamilies.values.first(where: { $0.revokeCapabilityNonce == parts[1] }) else {
            return nil
        }
        return (family.revokedAt != nil, family.revokedReason, family.capabilityRetainUntil)
    }

    public func expirePushFamilyCapability(capability: String) {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return }
        lock.lock()
        if let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key {
            sessionFamilies[familyId]?.capabilityRetainUntil = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    public func pushDeliveryStatus(authorization: String?, installationId: String?) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let installationId, installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil else {
            return Self.json(400, "{\"error\":\"Valid installationId is required\"}")
        }
        lock.lock()
        let active = fcmPushAvailable && pushRegistrations.contains {
            $0.installationId == installationId
                && $0.provider == "fcm"
                && $0.userId == principal.userId
        }
        lock.unlock()
        let servers = oauth.serverIdsForMember(userId: principal.userId).sorted()
        let rows = servers.map { "\"\($0)\":{\"fcmActive\":\(active ? "true" : "false")}" }.joined(separator: ",")
        return Self.json(200, "{\"servers\":{\(rows)}}")
    }

    public func unbindPushInstallation(authorization: String?, serverId: String, installationId: String) -> HTTPReply {
        guard pushPrincipal(authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        var unbound = 0
        for index in pushRegistrations.indices where pushRegistrations[index].installationId == installationId {
            pushRegistrations[index].userId = nil
            pushRegistrations[index].serverId = nil
            pushRegistrations[index].sessionFamilyId = nil
            unbound += 1
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"unbound\":\(unbound)}")
    }

    func pushPrincipal(_ authorization: String?) -> (userId: String, familyId: String?)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let userId = accessTokens[token]
        let familyId = accessTokenFamilies[token]
        lock.unlock()
        guard let userId else { return nil }
        return (userId, familyId)
    }

    public func assignAgentToProviderConnection(connectionId: String, serverId: String, agentId: String, computerName: String?) {
        lock.lock()
        providerAssignments.append(ProviderAssignment(
            connectionId: connectionId,
            serverId: serverId,
            agentId: agentId,
            computerName: computerName
        ))
        lock.unlock()
    }

    public func listAssignedProviderAgents(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        var rows: [String] = []
        for assignment in assignments {
            guard let info = oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId) else { continue }
            let computer = assignment.computerName.map { jsonString($0) } ?? "null"
            rows.append("{\"id\":\(jsonString(assignment.agentId)),\"name\":\(jsonString(info.name)),\"displayName\":\(jsonString(info.displayName)),\"runtime\":\(jsonString(info.runtime)),\"status\":\(jsonString(info.status)),\"computerName\":\(computer),\"deleted\":\(info.deleted)}")
        }
        return Self.json(200, "{\"agents\":[\(rows.joined(separator: ","))]}")
    }

}
