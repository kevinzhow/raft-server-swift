import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Saved messages, direct channels and read-receipt tool surfaces.
/// Migrated verbatim from the second half of `EmailLogin+ManagedMCP2.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ManagedMCPToolExecutionService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {
    public func checkSavedMessages(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageIds = object["messageIds"] as? [String]
        else {
            return Self.json(400, "{\"error\":\"Invalid saved check request\"}")
        }
        let saved = Set(oauth.savedMessages(userId: userId).map(\.messageId))
        lock.lock()
        let visible = messageIds.filter { id in
            guard saved.contains(id) else { return false }
            guard let entry = oauth.savedMessages(userId: userId).first(where: { $0.messageId == id }) else { return false }
            if let scope = postableChannels[entry.channelId] {
                guard scope.serverId == serverId, scope.deletedAt == nil, !scope.archived else { return false }
                return scope.kind == "channel" || scope.memberIds.contains(userId)
            }
            return true
        }
        lock.unlock()
        let ids = visible.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"savedIds\":[\("\(ids)")]}")
    }

    public func listSavedMessages(
        authorization: String?,
        serverId: String,
        query: String?,
        channelId: String?,
        sort: String?,
        limit: Int,
        offset: Int
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        var entries = oauth.savedMessages(userId: userId)
        lock.lock()
        entries = entries.filter { entry in
            if let scope = postableChannels[entry.channelId] {
                guard scope.serverId == serverId, scope.deletedAt == nil, !scope.archived else { return false }
                if scope.kind == "channel" { return true }
                return scope.memberIds.contains(userId)
            }
            if let parentChannelId = entry.parentChannelId, let parent = postableChannels[parentChannelId] {
                guard parent.serverId == serverId, parent.deletedAt == nil, !parent.archived else { return false }
                return parent.kind == "channel" || parent.memberIds.contains(userId)
            }
            return true
        }
        lock.unlock()
        if let channelId, !channelId.isEmpty {
            entries = entries.filter { $0.channelId == channelId || $0.parentChannelId == channelId }
        }
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = query.lowercased()
            entries = entries.filter {
                $0.content.lowercased().contains(needle)
                    || ($0.parentMessagePreview?.lowercased().contains(needle) ?? false)
            }
        }
        if sort == "asc" {
            entries.sort { $0.savedAt < $1.savedAt }
        } else {
            entries.sort { $0.savedAt > $1.savedAt }
        }
        let total = entries.count
        let page = Array(entries.dropFirst(max(0, offset)).prefix(max(0, limit)))
        let rows = page.map { entry -> String in
            let parentChannel = entry.parentChannelId.map { jsonString($0) } ?? "null"
            let parentMessage = entry.parentMessageId.map { jsonString($0) } ?? "null"
            let preview = entry.parentMessagePreview.map { jsonString($0) } ?? "null"
            return "{\"messageId\":\(jsonString(entry.messageId)),\"channelId\":\(jsonString(entry.channelId)),\"channelType\":\(jsonString(entry.channelType)),\"content\":\(jsonString(entry.content)),\"parentChannelId\":\(parentChannel),\"parentMessageId\":\(parentMessage),\"parentMessagePreview\":\(preview),\"replyCount\":\(entry.replyCount)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"saved\":[\("\(rows)")],\"total\":\(total),\"hasMore\":\(offset + page.count < total)}")
    }

    public func setAllChannelVisibility(authorization: String?, serverId: String, visible: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let allChannelId = oauth.allChannelId(serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        oauth.setChannelType(id: allChannelId, type: visible ? "channel" : "private")
        return Self.json(200, "{\"id\":\(jsonString(allChannelId)),\"visible\":\(visible)}")
    }

    public func createDirectChannelRoute(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid DM peer\"}")
        }
        if let agentId = object["agentId"] as? String {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
                return Self.json(404, "{\"error\":\"Agent not found in this server\"}")
            }
            let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: agentId)
            oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            lock.lock()
            postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: [userId, agentId], kind: "dm", name: "dm")
            lock.unlock()
            emitRealtime("channel:\(channelId)", "dm:new", "{\"channelId\":\(jsonString(channelId))}")
            emitRealtime("user:\(userId)", "dm:new", "{\"channelId\":\(jsonString(channelId))}")
            return Self.json(200, "{\"id\":\(jsonString(channelId)),\"type\":\"dm\",\"activityMuteSupported\":false,\"peerId\":\(jsonString(agentId)),\"peerType\":\"agent\"}")
        }
        guard let peerId = object["userId"] as? String,
              oauth.memberRole(serverId: serverId, userId: peerId) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid DM peer\"}")
        }
        let existingDm = oauth.channelsForServer(serverId: serverId, userId: userId).first { channel in
            channel.type == "dm"
                && oauth.channelHumanIds(channelId: channel.id).contains(userId)
                && oauth.channelHumanIds(channelId: channel.id).contains(peerId)
        }
        lock.lock()
        let hiddenDirectory = hideHumansFromMembers[serverId] == true
        lock.unlock()
        if existingDm == nil, hiddenDirectory, peerId != userId {
            return Self.json(404, "{\"error\":\"DM target not found\"}")
        }
        let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: peerId)
        oauth.addChannelHuman(channelId: channelId, userId: userId)
        oauth.addChannelHuman(channelId: channelId, userId: peerId)
        if existingDm == nil, peerId != userId {
            var order = oauth.sanitizedSidebarOrder(serverId: serverId, userId: peerId)
            if !order.hiddenDmIds.contains(channelId) {
                order.hiddenDmIds.append(channelId)
                oauth.setSidebarOrder(serverId: serverId, userId: peerId, order: order)
            }
        }
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: [userId, peerId], kind: "dm", name: "dm")
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"type\":\"dm\",\"activityMuteSupported\":false,\"peerId\":\(jsonString(peerId)),\"peerType\":\"user\"}")
    }

    public func listDirectChannels(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = oauth.channelsForServer(serverId: serverId, userId: userId)
            .filter { $0.type == "dm" }
            .compactMap { channel -> String? in
                let agentIds = oauth.channelAgentIds(channelId: channel.id)
                let humanIds = oauth.channelHumanIds(channelId: channel.id)
                let peerId: String
                let peerType: String
                if let agent = agentIds.first(where: { $0 != userId }) {
                    // A deleted agent peer stays hydratable by detail id but must
                    // not reappear in the normal DM list.
                    if oauth.agentRuntimeInfo(id: agent)?.deleted == true { return nil }
                    peerId = agent
                    peerType = "agent"
                } else if let human = humanIds.first(where: { $0 != userId }) {
                    peerId = human
                    peerType = "user"
                } else {
                    peerId = userId
                    peerType = "self"
                }
                let last = channel.lastMessageAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
                lock.lock()
                let lastRow = humanMessageRows.last { $0.channelId == channel.id }
                lock.unlock()
                let preview = lastRow.map { jsonString(String($0.content.prefix(120))) } ?? "null"
                let senderName: String
                if let lastRow, lastRow.senderId != "system" {
                    if lastRow.senderType == "agent" {
                        if let agent = oauth.agentRuntimeInfo(id: lastRow.senderId) {
                            senderName = agent.displayName.isEmpty ? agent.name : agent.displayName
                        } else {
                            senderName = ""
                        }
                    } else {
                        lock.lock()
                        let account = accounts.values.first { $0.id == lastRow.senderId }
                        lock.unlock()
                        senderName = account.map { ($0.displayName ?? "").isEmpty ? $0.name : ($0.displayName ?? $0.name) } ?? ""
                    }
                } else {
                    senderName = ""
                }
                let senderJSON = senderName.isEmpty ? "null" : jsonString(senderName)
                return "{\"id\":\(jsonString(channel.id)),\"type\":\"dm\",\"joined\":\(channel.joined),\"activityMuteSupported\":false,\"peerId\":\(jsonString(peerId)),\"peerType\":\(jsonString(peerType)),\"lastMessageAt\":\(last),\"lastMessagePreview\":\(preview),\"lastMessageSenderName\":\(senderJSON)}"
            }
            .joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func enableReadReceiptsForServer(_ serverId: String) {
        lock.lock()
        readReceiptsServers.insert(serverId)
        lock.unlock()
    }

    public func emitAgentScopeRead(serverId: String, channelId: String, agentId: String, maxReadSeq: Int) {
        lock.lock()
        let enabled = readReceiptsServers.contains(serverId)
        let peer = oauth.channelAgentIds(channelId: channelId).contains(agentId)
        lock.unlock()
        guard enabled, peer else { return }
        let payload = "{\"scopeId\":\(jsonString(channelId)),\"peerKind\":\"agent\",\"peerId\":\(jsonString(agentId)),\"maxReadSeq\":\(maxReadSeq)}"
        emitRealtime("channel:\(channelId)", "scope_read:updated", payload)
    }

    public func readReceiptsEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readReceiptsServers.contains(serverId)
    }

    public func agentReadCursor(channelId: String, agentId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0
    }

    public func humanReadCursor(channelId: String, userId: String) -> Int {
        return oauth.channelReadCursor(channelId: channelId, userId: userId)
    }

    public func agentMuteStateForTesting(channelId: String, agentId: String) -> (serverId: String, muteFromSeq: Int)? {
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: agentId)
        guard prefs.activityMuted, let muteFromSeq = prefs.muteFromSeq else { return nil }
        return (oauth.channelServerId(channelId) ?? "", muteFromSeq)
    }

    func agentMessageSuppressedLocked(_ message: StoredHumanMessage, agentId: String) -> Bool {
        let prefs = oauth.notificationPrefs(channelId: message.channelId, userId: agentId)
        guard prefs.activityMuted, let from = prefs.muteFromSeq, message.seq >= from else {
            return false
        }
        let mentioned = storedMentions.contains {
            $0.messageId == message.id && $0.targetType == "agent" && $0.targetId == agentId
        }
        return !mentioned
    }

    /// `POST /internal/agent-api/channels/:id/mute|unmute`. The mute is keyed by
    /// the agent receiver, not the channel, and only channel members may set it.
    public func agentChannelArchive(authorization: String?, body: String, archive: Bool) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "channels") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: nil) else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: target)
        else {
            return Self.json(400, "{\"error\":\"Invalid channel target\"}")
        }
        lock.lock()
        postableChannels[channelId]?.archived = archive
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"archived\":\(archive)}")
    }

    public func agentSetChannelMute(authorization: String?, channelId: String, muted: Bool) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "channels") { return denial }
        guard let writer = agentWriterAndRole(authorization: authorization, legacyAgentId: nil, scopes: []),
              let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let isMember = postableChannels[channelId]?.memberIds.contains(agent.id) == true
            || channelAgentMembers[channelId]?.contains(agent.id) == true
            || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
        guard isMember else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Agent is not a member of this channel\",\"code\":\"not_channel_member\"}")
        }
        let latest = humanMessageRows.filter { $0.channelId == channelId }.map(\.seq).max() ?? 0
        lock.unlock()
        let state = oauth.setActivityMuted(
            channelId: channelId,
            receiverId: agent.id,
            muted: muted,
            muteFromSeq: muted ? latest + 1 : nil
        )
        let name = channel.name
        if muted {
            let muteFromSeq = state.prefs.muteFromSeq ?? (latest + 1)
            let attention = "{\"state\":\"muted\",\"unmuteCommand\":\(jsonString("raft channel unmute #\(name)")),\"unmuteApi\":\(jsonString("POST /internal/agent-api/channels/\(channelId)/unmute")),\"stillArrives\":[\"Personal @mentions still arrive.\",\"Direct messages still arrive.\",\"Threads you follow deliver independently.\"],\"threadBoundary\":\(jsonString("Channel mute suppresses ordinary Activity from this channel only. Threads you follow keep delivering independently until you unfollow them.")),\"catchUp\":\(jsonString("Run `raft channel history #\(name)` or GET /internal/agent-api/history to catch up."))}"
            return Self.json(200, "{\"activityMuted\":true,\"muteFromSeq\":\(muteFromSeq),\"attention\":\(attention)}")
        }
        let attention = "{\"state\":\"unmuted\",\"muteCommand\":\(jsonString("raft channel mute #\(name)"))}"
        return Self.json(200, "{\"activityMuted\":false,\"muteFromSeq\":null,\"attention\":\(attention)}")
    }

    public func systemMessageContents(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows
            .filter { $0.channelId == channelId && $0.messageType == "system" }
            .map(\.content)
    }

    public func humanMessageSequence(id: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.first(where: { $0.id == id })?.seq
    }

    public func setAgentReadCursorForTesting(agentId: String, channelId: String, seq: Int, version: Int = 1) {
        lock.lock()
        agentChannelReadCursors["\(channelId)\n\(agentId)"] = (seq, version)
        lock.unlock()
    }

    public func setChannelHumanRoleForTesting(channelId: String, userId: String, role: String) {
        lock.lock()
        channelHumanRoles["\(channelId)\n\(userId)"] = role
        lock.unlock()
    }

    public func getChannelRoute(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
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
        let type = oauth.channelType(id: channelId) ?? "channel"
        // A thread is visible to whoever can see its parent; a private parent
        // must not leak its child thread's existence or metadata.
        let threadParentId = type == "thread" ? oauth.channelParentChannelId(id: channelId) : nil
        let canSee = threadParentId.map { channelActorCanSee(channelId: $0, userId: userId) }
            ?? channelActorCanSee(channelId: channelId, userId: userId)
        guard canSee else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let joined = channel.name == "all"
            || postableChannels[channelId]?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: channelId).contains(userId)
        lock.unlock()
        let supported = type == "channel"
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        lock.lock()
        let version = channelReadVersions["\(channelId)\n\(userId)"] ?? 0
        let receiptsEnabled = readReceiptsServers.contains(serverId)
        let agentIds = oauth.channelAgentIds(channelId: channelId)
        let peerSeqs = agentIds.map { agentId in
            (agentId, agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0)
        }
        lock.unlock()
        let serverRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        lock.lock()
        let localRole = channelHumanRoles["\(channelId)\n\(userId)"]
        let authorityRevision = channelAuthorityRevisions[channelId] ?? 1
        lock.unlock()
        let basis: String? = localRole == "admin" ? "channel_role"
            : ((serverRole == "owner" || serverRole == "admin") ? "server_role" : nil)
        let channelRole = basis == nil ? "member" : "admin"
        let serverAdmin = serverRole == "owner" || serverRole == "admin"
        let capability = basis != nil
        let isJoint = jointProjections.contains { $0.localChannelId == channelId }
        let metadataCap = capability
        let roleCap = capability
        let archiveCap = capability && !isJoint
        let addCap = capability && !isJoint
        let capsJSON = "{\"editChannelMetadata\":\(metadataCap),\"archiveChannels\":\(archiveCap),\"addChannelMembers\":\(addCap),\"removeChannelMembers\":\(addCap),\"changeChannelMemberRoles\":\(roleCap),\"manageGuestAccess\":\(serverAdmin && !isJoint),\"deleteChannels\":\(serverAdmin),\"changeChannelVisibility\":\(serverAdmin),\"federateChannels\":\(serverAdmin)}"
        var peersJSON = ""
        if receiptsEnabled {
            if peerSeqs.count > 50 {
                var counts: [Int: Int] = [:]
                for (_, seq) in peerSeqs { counts[seq, default: 0] += 1 }
                let buckets = counts.keys.sorted().map { seq in
                    "{\"seq\":\(seq),\"count\":\(counts[seq] ?? 0)}"
                }.joined(separator: ",")
                peersJSON = ",\"peerReadSummary\":{\"peerCount\":\(peerSeqs.count),\"readCountAtSeq\":[\("\(buckets)")]}"
            } else {
                let peers = peerSeqs.map { agentId, seq in
                    "{\"peerKind\":\"agent\",\"peerId\":\(jsonString(agentId)),\"maxReadSeq\":\(seq)}"
                }.joined(separator: ",")
                peersJSON = ",\"peerReadStates\":[\("\(peers)")]"
            }
        }
        let displayPrefs = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        var dmFields = ""
        if type == "dm" {
            lock.lock()
            let peerId = postableChannels[channelId]?.memberIds.first { $0 != userId }
            lock.unlock()
            if let peerId {
                if let agent = oauth.agentRuntimeInfo(id: peerId) {
                    dmFields = ",\"peerType\":\"agent\",\"peerId\":\(jsonString(peerId)),\"peerName\":\(jsonString(agent.name))"
                } else if let account = accounts.values.first(where: { $0.id == peerId }) {
                    dmFields = ",\"peerType\":\"human\",\"peerId\":\(jsonString(peerId)),\"peerName\":\(jsonString(account.name))"
                }
            }
        }
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(type)),\"joined\":\(joined)\(dmFields),\"maxReadSeq\":\(info.maxReadSeq),\"readStateVersion\":\(version),\"activityMuteSupported\":\(supported),\"collapseLongMessages\":\(displayPrefs.collapseLongMessages),\"displayPrefsVersion\":\(displayPrefs.prefsVersion),\"channelRole\":\(jsonString(channelRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"channelAuthorityRevision\":\(authorityRevision),\"channelCapabilities\":\(capsJSON)\(peersJSON)}")
    }

    public func channelDisplaySettings(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if oauth.channelType(id: channelId) == "thread" {
            return Self.json(400, "{\"error\":\"Display preferences are stored on the parent channel\"}")
        }
        guard oauth.canAccessChannelPrefs(channelId: channelId, userId: userId, serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let prefs = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        return Self.json(200, "{\"collapseLongMessages\":\(prefs.collapseLongMessages),\"prefsVersion\":\(prefs.prefsVersion)}")
    }

    public func patchChannelDisplaySettings(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if oauth.channelType(id: channelId) == "thread" {
            return Self.json(400, "{\"error\":\"Display preferences are stored on the parent channel\"}")
        }
        guard oauth.canAccessChannelPrefs(channelId: channelId, userId: userId, serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let collapse = object["collapseLongMessages"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"collapseLongMessages must be a boolean\"}")
        }
        let prefs = oauth.setCollapseLongMessages(channelId: channelId, userId: userId, collapse: collapse)
        return Self.json(200, "{\"collapseLongMessages\":\(prefs.collapseLongMessages),\"prefsVersion\":\(prefs.prefsVersion)}")
    }

    public func setAccountDescriptionForTesting(userId: String, description: String?) {
        lock.lock()
        if let index = accounts.values.firstIndex(where: { $0.id == userId }) {
            var account = accounts.values[index]
            account.description = description
            accounts.values[index] = account
        }
        lock.unlock()
    }

    public func seedDMForTesting(serverId: String, humanUserId: String, agentId: String, name: String = "dm") -> String {
        let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: humanUserId, secondUserId: agentId)
        addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "dm", name: name)
        addPostableChannel(serverId: serverId, channelId: channelId, memberId: humanUserId, kind: "dm", name: name)
        oauth.addChannelHuman(channelId: channelId, userId: humanUserId)
        return channelId
    }

    public func channelCardRevisionForTesting(channelId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return channelCardSnapshotLocked(channelId: channelId)?.rev
    }

    public func mentionsForTesting(messageId: String) -> [(targetType: String, targetId: String, handle: String)] {
        lock.lock(); defer { lock.unlock() }
        return storedMentions.filter { $0.messageId == messageId }.map { ($0.targetType, $0.targetId, $0.handle) }
    }

    public func addStoredMentionForTesting(
        channelId: String,
        messageId: String,
        targetId: String,
        targetType: String = "user",
        handle: String = "peer",
        terminalCode: String? = nil
    ) {
        lock.lock()
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: messageId,
            channelId: channelId,
            senderId: "peer",
            targetType: targetType,
            targetId: targetId,
            handle: handle,
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil,
            terminalCode: terminalCode
        ))
        lock.unlock()
    }

    public func updateChannelReadState(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
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
        let readable = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readable else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let seq = object["seq"] as? Int, seq >= 0
        else {
            return Self.json(400, "{\"error\":\"seq must be a non-negative integer\"}")
        }
        let key = "\(channelId)\n\(userId)"
        lock.lock()
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        let current = max(info.maxReadSeq, channelReadVersions[key] == nil ? 0 : info.maxReadSeq)
        if seq <= info.maxReadSeq {
            let version = channelReadVersions[key] ?? 0
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"maxReadSeq\":\(current),\"readStateVersion\":\(version)}")
        }
        channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
        let version = channelReadVersions[key] ?? 1
        lock.unlock()
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: seq)
        return Self.json(200, "{\"ok\":true,\"maxReadSeq\":\(seq),\"readStateVersion\":\(version)}")
    }


    /// Synchronous context gathering for the resume handler; the async method
    /// only awaits the dispatch callback.
    func resumeAllAgentsContext(
        userId: String,
        serverId: String,
        channelId: String,
        requestedAgentIds: Set<String>?
    ) -> ResumeAllAgentsContext {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId], channel.serverId == serverId else {
            return ResumeAllAgentsContext(targets: [], dispatch: nil, error: Self.json(404, "{\"error\":\"Channel not found\"}"))
        }
        let readable = channel.kind == "channel"
            || channel.memberIds.contains(userId)
            || oauth.isChannelParticipant(channelId: channelId, userId: userId)
        guard readable else {
            return ResumeAllAgentsContext(targets: [], dispatch: nil, error: Self.json(404, "{\"error\":\"Channel not found\"}"))
        }
        let channelAgentIds = Array(channelAgentMembers[channelId] ?? []).sorted()
        let targets = requestedAgentIds.map { requested in channelAgentIds.filter { requested.contains($0) } } ?? channelAgentIds
        return ResumeAllAgentsContext(targets: targets, dispatch: agentStartDispatch, error: nil)
    }

    /// `POST /api/channels/:id/resume-all-agents`. Sends an optional resume
    /// prompt to every agent in the channel (or the explicit `agentIds` subset)
    /// and reports an agent whose start was skipped instead of counting it
    /// resumed.
    public func resumeAllAgents(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: String
    ) async -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let object: [String: Any]
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object = [:]
        } else if let parsed = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] {
            object = parsed
        } else {
            return Self.json(400, "{\"error\":\"Invalid resume request\"}")
        }
        let prompt = object["prompt"] as? String
        var requestedAgentIds: Set<String>?
        if let raw = object["agentIds"], !(raw is NSNull) {
            guard let ids = raw as? [String] else {
                return Self.json(400, "{\"error\":\"agentIds must be an array of agent ids\"}")
            }
            requestedAgentIds = Set(ids)
        }
        let context = resumeAllAgentsContext(
            userId: userId,
            serverId: serverId,
            channelId: channelId,
            requestedAgentIds: requestedAgentIds
        )
        if let error = context.error { return error }
        var results: [String] = []
        var started = 0
        for agentId in context.targets {
            var dispatched = false
            var skipReason: String?
            if let dispatch = context.dispatch {
                do {
                    switch try await dispatch(agentId, prompt) {
                    case .dispatched:
                        dispatched = true
                    case .skipped:
                        skipReason = "start_in_flight"
                    }
                } catch {
                    skipReason = "start_failed"
                }
            } else {
                dispatched = true
            }
            if dispatched { started += 1 }
            if let skipReason {
                results.append("{\"agentId\":\(jsonString(agentId)),\"ok\":false,\"reason\":\(jsonString(skipReason))}")
            } else {
                results.append("{\"agentId\":\(jsonString(agentId)),\"ok\":true}")
            }
        }
        let allStarted = started == context.targets.count
        return Self.json(200, "{\"ok\":\(allStarted ? "true" : "false"),\"started\":\(started),\"total\":\(context.targets.count),\"results\":[\(results.joined(separator: ","))]}")
    }

    public func markChannelReadAll(authorization: String?, serverId: String, channelId: String, body: String = "{}") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        // A kinded receiver delegates the read to that agent. Authority is the
        // server role or the agent's creator, never the caller's own membership:
        // the human caller's read state must stay untouched.
        if let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
           let receiver = object["receiver"] as? [String: Any],
           let kind = receiver["kind"] as? String,
           let receiverId = receiver["id"] as? String {
            guard kind == "agent",
                  let agent = oauth.agentRuntimeInfo(id: receiverId),
                  agent.serverId == serverId
            else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            let canDelegate = role == "owner" || role == "admin" || agent.creatorUserId == userId
            guard canDelegate, oauth.channelAgentIds(channelId: channelId).contains(agent.id) else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            let latestSeq = oauth.channelUnreadInfo(channelId: channelId, userId: userId).latestSeq ?? 0
            lock.lock()
            let key = "\(channelId)\n\(receiverId)"
            let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            let advanced = latestSeq > previous.seq
            let version = advanced ? previous.version + 1 : previous.version
            agentChannelReadCursors[key] = (seq: max(previous.seq, latestSeq), version: version)
            lock.unlock()
            if advanced {
                onAgentReadUpdated?(serverId, channelId, receiverId, latestSeq)
            }
            return Self.json(200, "{\"ok\":true,\"seq\":\(max(previous.seq, latestSeq)),\"readStateVersion\":\(max(version, 1))}")
        }
        lock.lock()
        let readableAll = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readableAll else {
            lock.lock()
            let facts = inboxFactStore.all().filter {
                $0.receiverType == "user" && $0.receiverId == userId
                    && $0.channelId == channelId && $0.serverId == serverId
            }
            lock.unlock()
            var ownedSeq = oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq
            if let lastFact = facts.last,
               let owned = oauth.historyMessages(channelId: channelId).first(where: { $0.id == lastFact.messageId }) {
                ownedSeq = max(ownedSeq, owned.seq)
            }
            guard ownedSeq > 0 else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: ownedSeq)
            let key = "\(channelId)\n\(userId)"
            lock.lock()
            inboxDoneScopes.insert("\(userId)\n\(channelId)")
            inboxDoneAt["\(userId)\n\(channelId)"] = Date()
            channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
            let version = channelReadVersions[key] ?? 1
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"seq\":\(ownedSeq),\"readStateVersion\":\(version)}")
        }
        let latest = oauth.channelUnreadInfo(channelId: channelId, userId: userId).latestSeq ?? 0
        let key = "\(channelId)\n\(userId)"
        lock.lock()
        channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
        let version = channelReadVersions[key] ?? 1
        lock.unlock()
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: latest)
        return Self.json(200, "{\"ok\":true,\"seq\":\(latest),\"readStateVersion\":\(version)}")
    }

    @discardableResult
    public func setAnnouncementAudienceForTesting(id: String, serverIds: [String]) {
        lock.lock()
        if let index = announcements.firstIndex(where: { $0.id == id }) {
            announcements[index].audienceServerIds = serverIds
        }
        lock.unlock()
    }

    /// A targeted announcement is only visible inside one of its servers; the
    /// audience itself is never echoed to the client.
    func announcementVisibleLocked(
        _ announcement: (id: String, title: String, pages: [String], startsAt: Date, expiresAt: Date?, status: String, publishedAt: Date?, imageId: String?, audienceServerIds: [String]),
        userId: String,
        serverId: String?
    ) -> Bool {
        guard !announcement.audienceServerIds.isEmpty else { return true }
        guard let serverId else { return false }
        return announcement.audienceServerIds.contains(serverId)
            && oauth.memberRole(serverId: serverId, userId: userId) != nil
    }


    /// `server_id` must appear at most once and be a UUID; a duplicate or a
    /// malformed value never degrades into an unscoped answer.

}
