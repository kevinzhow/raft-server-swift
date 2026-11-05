import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {


    /// Third-party content stays inert: mentions read as plain `user:<handle>`.
    static func neutralizeExternalProjectionContent(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        value = value.replacingOccurrences(of: "@([A-Za-z0-9_.-]+)", with: "user:$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "#([A-Za-z0-9_.-]+)", with: "channel:$1", options: .regularExpression)
        return value
    }


    /// `GET /internal/agent-api/wake-hints/stream`. The SSE projection opens
    /// with the same pending hints; reading it does not drain the inbox.
    /// `POST /internal/agent-api/third-party-events/delivered`. A managed
    /// daemon reports the events it served locally so they stop replaying.
    public func reportThirdPartyEventsDelivered(authorization: String?, body: String) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let raw = object?["eventIds"] as? [Any], !raw.isEmpty else {
                return Self.json(400, "{\"error\":\"eventIds must be a non-empty array\",\"code\":\"event_ids_invalid\"}")
            }
            var ids: [String] = []
            for item in raw {
                guard let text = item as? String,
                      text.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
                else {
                    return Self.json(400, "{\"error\":\"eventIds must contain third-party event ids\",\"code\":\"event_ids_invalid\"}")
                }
                ids.append(text.lowercased())
            }
            let delivered = oauth.markThirdPartyEventsDelivered(agentId: agentId, ids: ids)
            return Self.json(200, "{\"ok\":true,\"delivered\":\(delivered)}")
        }
    }


    func agentReadCredential(_ authorization: String?) -> AgentRead {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .failure(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.scopes.contains("read") else {
            return .failure(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
        recordAgentCredentialUse(token: token)
        return .success(credential.agentId)
    }

    /// A raw agent API key. The mentions inbox accepts it when `mentions` is one of the scopes.
    public func mintAgentCredential(agentId: String, scopes: [String], name: String) -> String {
        let key = "sk_agent_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        lock.lock()
        agentCredentials[key] = AgentCredential(agentId: agentId, scopes: Set(scopes), name: name)
        lock.unlock()
        return key
    }

    /// Binds a machine key to one agent. The legacy agent reaction route accepts that bearer.
    public func registerMachineForAgent(serverId: String, agentId: String) -> String {
        let key = "mk_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        lock.lock()
        machineKeys[key] = (serverId: serverId, agentId: agentId)
        lock.unlock()
        return key
    }

    public func addMessageReactionForTesting(messageId: String, emoji: String, reactorId: String, reactorType: String) {
        lock.lock()
        messageReactions.append(StoredReaction(messageId: messageId, emoji: emoji, reactorId: reactorId, reactorType: reactorType))
        noteDiscussionChangeLocked(messageId: messageId, emoji: emoji)
        lock.unlock()
    }

    public func markAgentLegacyReadForTesting(agentId: String, channelId: String, seq: Int) {
        lock.lock()
        let key = "\(channelId)\n\(agentId)"
        let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
        agentChannelReadCursors[key] = (max(previous.seq, seq), previous.version + 1)
        lock.unlock()
    }

    public func agentReadCursorForTesting(agentId: String, channelId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0
    }

    public func setMachineModelSeenCapabilityForTesting(agentId: String, enabled: Bool) {
        lock.lock()
        if enabled {
            machineModelSeenCapabilityForTesting.insert(agentId)
        } else {
            machineModelSeenCapabilityForTesting.remove(agentId)
        }
        lock.unlock()
    }

    /// Written attested-send events (`gate_triggered`, `e1_exempt`), oldest first.
    public func attestedSendEventsForTesting() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return attestedSendEventRecords.map { record in
            var row: [String: Any] = ["eventType": record.eventType, "agentId": record.agentId]
            if let messageId = record.messageId { row["messageId"] = messageId }
            row["metadata"] = (try? JSONSerialization.jsonObject(with: Data(record.metadataJSON.utf8))) ?? [:]
            return row
        }
    }

    /// Send-side activity log projections (held context / E1 exemption).
    public func recentAgentSendActivityForTesting(agentId: String) -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return (agentSendActivityRecords[agentId] ?? []).map { entry in
            var row = ["title": entry.title, "text": entry.text]
            if let producerFactId = entry.producerFactId { row["producerFactId"] = producerFactId }
            return row
        }
    }

    func recordAttestedSendEvent(
        _ eventType: String,
        agentId: String,
        messageId: String?,
        metadata: [String: Any]
    ) {
        let metadataJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
            metadataJSON = String(decoding: data, as: UTF8.self)
        } else {
            metadataJSON = "{}"
        }
        lock.lock()
        attestedSendEventRecords.append(AttestedSendEventRecord(
            eventType: eventType,
            agentId: agentId,
            messageId: messageId,
            metadataJSON: metadataJSON
        ))
        lock.unlock()
    }

    func recordAgentSendActivity(agentId: String, title: String, text: String, producerFactId: String?) {
        lock.lock()
        agentSendActivityRecords[agentId, default: []].append((title: title, text: text, producerFactId: producerFactId))
        lock.unlock()
    }

    func recordServerMemberEvent(serverId: String, eventType: String, subjectType: String, subjectId: String, provenanceJSON: String) {
        serverMemberEvents.append(ServerMemberEvent(
            serverId: serverId, eventType: eventType, subjectType: subjectType,
            subjectId: subjectId, provenanceJSON: provenanceJSON, deliveryQueued: true
        ))
    }

    public func setSidebarReadAllEnabledForTesting(_ enabled: Bool) {
        lock.lock(); sidebarReadAllEnabled = enabled; lock.unlock()
    }

    public func serverMemberEventsForTesting(serverId: String, eventType: String?) -> [(subjectType: String, subjectId: String, provenanceJSON: String, deliveryQueued: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return serverMemberEvents
            .filter { $0.serverId == serverId && (eventType == nil || $0.eventType == eventType) }
            .map { ($0.subjectType, $0.subjectId, $0.provenanceJSON, $0.deliveryQueued) }
    }

    public func setJointProjectionStatusForTesting(localChannelId: String, serverId: String, status: String) {
        lock.lock()
        if let index = jointProjections.firstIndex(where: { $0.localChannelId == localChannelId && $0.serverId == serverId }) {
            jointProjections[index].status = status
        }
        lock.unlock()
    }

    public func setAgentChannelJoinedAtForTesting(agentId: String, channelId: String, at: Date) {
        lock.lock()
        agentChannelJoinedAt["\(channelId)\n\(agentId)"] = at
        lock.unlock()
    }

    public func addChannelAgent(channelId: String, agentId: String) {
        lock.lock()
        var members = channelAgentMembers[channelId] ?? []
        members.insert(agentId)
        channelAgentMembers[channelId] = members
        lock.unlock()
    }

    public func storedMessageReactionActors(messageId: String) -> [(reactorType: String, reactorId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return messageReactions.filter { $0.messageId == messageId }.map { ($0.reactorType, $0.reactorId) }
    }

    /// Reaction rows still stored for this message. An idempotent add leaves one row; a delete leaves none.
    public func storedMessageReactions(messageId: String) -> [(emoji: String, reactorId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return messageReactions.filter { $0.messageId == messageId }.map { ($0.emoji, $0.reactorId) }
    }

    /// `POST /api/messages/:messageId/reactions`. A second add of the same emoji by the same user does not raise the count.
    public func addMessageReaction(messageId: String, body: String, authorization: String?, serverId: String?) -> HTTPReply {
        mutateMessageReaction(messageId: messageId, body: body, authorization: authorization, serverId: serverId, remove: false)
    }

    /// `DELETE /api/messages/:messageId/reactions`.
    public func removeMessageReaction(messageId: String, body: String, authorization: String?, serverId: String?) -> HTTPReply {
        mutateMessageReaction(messageId: messageId, body: body, authorization: authorization, serverId: serverId, remove: true)
    }

    func mutateMessageReaction(messageId: String, body: String, authorization: String?, serverId: String?, remove: Bool) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard let emoji = Self.reactionEmoji(body) else {
            return Self.json(400, "{\"error\":\"A valid emoji is required\"}")
        }
        lock.lock()
        let message: StoredHumanMessage
        let channel: PostableChannel
        switch resolveReactionTargetLocked(messageId: messageId, userId: userId, serverId: serverId) {
        case .missing:
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        case .ambiguous:
            lock.unlock()
            return Self.json(400, "{\"error\":\"Message short id is ambiguous\"}")
        case .message(let resolvedMessage, let resolvedChannel, _):
            message = resolvedMessage
            channel = resolvedChannel
        }
        if message.messageType == "system" {
            lock.unlock()
            return Self.json(400, "{\"error\":\"System messages cannot receive reactions\"}")
        }
        if !channel.memberIds.contains(userId) {
            lock.unlock()
            return Self.json(403, "{\"error\":\"You must join this channel to react to messages\"}")
        }
        if channel.archived {
            lock.unlock()
            return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
        }
        let changed: Bool
        if remove {
            let before = messageReactions.count
            messageReactions.removeAll { $0.messageId == message.id && $0.emoji == emoji && $0.reactorId == userId && $0.reactorType == "user" }
            changed = messageReactions.count != before
        } else if messageReactions.contains(where: { $0.messageId == message.id && $0.emoji == emoji && $0.reactorId == userId && $0.reactorType == "user" }) {
            changed = false
        } else {
            messageReactions.append(StoredReaction(messageId: message.id, emoji: emoji, reactorId: userId, reactorType: "user"))
            changed = true
        }
        let viewerKey = "\(message.id)\n\(userId)"
        if changed {
            reactionViewerVersions[viewerKey] = (reactionViewerVersions[viewerKey] ?? 0) + 1
            noteDiscussionChangeLocked(messageId: message.id, emoji: emoji)
        }
        let viewerJSON = reactionViewerJSONLocked(messageId: message.id, userId: userId, serverId: serverId ?? "")
        let bodyJSON = finishReactionLocked(message: message, actorId: userId, serverId: serverId, viewerJSON: viewerJSON)
        lock.unlock()
        emitRealtime("user:\(userId)", "reaction_viewer:updated", viewerJSON)
        return Self.json(200, bodyJSON)
    }

    /// `GET /api/messages/:messageId/reactions/viewer`. A cold read uses the same snapshot as the last mutation ACK.
    public func reactionViewer(messageId: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        lock.lock()
        switch resolveReactionTargetLocked(messageId: messageId, userId: userId, serverId: serverId) {
        case .missing:
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        case .ambiguous:
            lock.unlock()
            return Self.json(400, "{\"error\":\"Message short id is ambiguous\"}")
        case .message(let message, let channel, _):
            if message.messageType == "system" {
                lock.unlock()
                return Self.json(400, "{\"error\":\"System messages cannot receive reactions\"}")
            }
            if channel.archived {
                lock.unlock()
                return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
            }
            let body = reactionViewerJSONLocked(messageId: message.id, userId: userId, serverId: serverId ?? "")
            lock.unlock()
            return Self.json(200, body)
        }
    }

    /// `POST` and `DELETE /internal/agent/:agentId/messages/:messageId/reactions`. The machine key must belong to that agent.
    public func mutateAgentMessageReaction(agentId: String, messageId: String, body: String, authorization: String?, remove: Bool) -> HTTPReply {
        guard let emoji = Self.reactionEmoji(body) else {
            return Self.json(400, "{\"error\":\"A valid emoji is required\"}")
        }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        guard let machine = machineKeys[token], machine.agentId == agentId else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let message = humanMessageRows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }),
              postableChannels[message.channelId]?.serverId == machine.serverId,
              channelAgentMembers[message.channelId]?.contains(agentId) == true
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        let bodyJSON = writeAgentReactionLocked(message: message, agentId: agentId, emoji: emoji, serverId: machine.serverId, remove: remove)
        lock.unlock()
        return Self.json(200, bodyJSON)
    }

    /// `POST` and `DELETE /internal/agent-api/messages/:messageId/reactions`. The credential must include `reactions`.
    public func mutateAgentApiMessageReaction(messageId: String, body: String, authorization: String?, remove: Bool) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "reactions") { return denial }
        guard let emoji = Self.reactionEmoji(body) else {
            return Self.json(400, "{\"error\":\"A valid emoji is required\"}")
        }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        guard let credential = agentCredentials[token], credential.scopes.contains("reactions") else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let agentId = credential.agentId
        let agentServerId: String?
        if let agent = serverAgents[agentId] {
            agentServerId = agent.serverId
        } else if let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted {
            agentServerId = agent.serverId
        } else {
            agentServerId = nil
        }
        guard let agentServerId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        // Message ids are a full UUID or an 8-character short id; anything else
        // is a caller error, not an invisible message.
        let isUUID = ServerScope.isUUID(messageId)
        let isShortId = messageId.count == 8 && messageId.allSatisfy { $0.isHexDigit }
        guard isUUID || isShortId else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Message id must be a full UUID or 8-character short id\"}")
        }
        func visibleToAgent(_ message: StoredHumanMessage) -> Bool {
            guard let channel = postableChannels[message.channelId], channel.serverId == agentServerId else { return false }
            if channel.kind == "channel" { return true }
            if channel.kind == "thread",
               let parentId = channel.parentChannelId,
               let parent = postableChannels[parentId],
               parent.serverId == agentServerId {
                if parent.kind == "channel" { return true }
                if parent.memberIds.contains(agentId) || channelAgentMembers[parentId]?.contains(agentId) == true { return true }
            }
            return channel.memberIds.contains(agentId) || channelAgentMembers[message.channelId]?.contains(agentId) == true
        }
        let candidates = humanMessageRows.filter { message in
            if isUUID { return message.id.caseInsensitiveCompare(messageId) == .orderedSame }
            return message.id.lowercased().hasPrefix(messageId.lowercased())
        }.filter { visibleToAgent($0) }
        guard let message = candidates.first else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        guard candidates.count == 1 else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Message short id is ambiguous\",\"errorCode\":\"AMBIGUOUS_ID\"}")
        }
        let bodyJSON = writeAgentReactionLocked(message: message, agentId: agentId, emoji: emoji, serverId: agentServerId, remove: remove)
        lock.unlock()
        return Self.json(200, bodyJSON)
    }

    /// `GET /api/messages/:messageId/reactions/actors`. The cursor is bound to the caller, message, emoji, and discussion version.
    public func listReactionActors(messageId: String, authorization: String?, serverId: String?, emoji: String?, limit: String?, cursor: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard let emoji, let validEmoji = Self.validReactionEmoji(emoji) else {
            return Self.json(400, "{\"error\":\"A valid emoji is required\",\"code\":\"invalid_reaction_emoji\"}")
        }
        let pageLimit: Int
        if let limit {
            guard let parsed = Int(limit), parsed >= 1, parsed <= 100, String(parsed) == limit else {
                return Self.json(400, "{\"error\":\"limit must be an integer between 1 and 100\",\"code\":\"invalid_reaction_actor_limit\"}")
            }
            pageLimit = parsed
        } else {
            pageLimit = 50
        }
        lock.lock()
        let message: StoredHumanMessage
        let channel: PostableChannel
        let localChannelId: String
        switch resolveReactionTargetLocked(messageId: messageId, userId: userId, serverId: serverId) {
        case .missing:
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        case .ambiguous:
            lock.unlock()
            return Self.json(400, "{\"error\":\"Message short id is ambiguous\"}")
        case .message(let resolved, let resolvedChannel, let resolvedLocalId):
            if resolved.messageType == "system" {
                lock.unlock()
                return Self.json(400, "{\"error\":\"System messages cannot receive reactions\"}")
            }
            if resolvedChannel.archived {
                lock.unlock()
                return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
            }
            message = resolved
            channel = resolvedChannel
            localChannelId = resolvedLocalId
        }
        let currentVersion = reactionDiscussionVersions["\(message.id)\n\(validEmoji)"] ?? 0
        var afterKind: String?
        var afterId: String?
        if let cursor {
            guard let decoded = Self.decodeActorCursor(cursor) else {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Invalid reaction actors cursor\",\"code\":\"invalid_reaction_actors_cursor\"}")
            }
            if decoded.principalId != userId || decoded.serverId != (serverId ?? "") || decoded.messageId != message.id || decoded.emoji != validEmoji {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Invalid reaction actors cursor\",\"code\":\"invalid_reaction_actors_cursor\"}")
            }
            let visibility = reactionActorVisibilityLocked(channelId: localChannelId, requesterId: userId)
            if decoded.visibilityHash != visibility.hash {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Reaction actor visibility changed while reading this page\",\"code\":\"reaction_actor_visibility_changed\",\"rebaselineRequired\":true}")
            }
            if decoded.discussionVersion != currentVersion {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Reaction discussion changed while reading this page\",\"code\":\"reaction_discussion_version_changed\",\"currentDiscussionVersion\":\(currentVersion),\"rebaselineRequired\":true}")
            }
            afterKind = decoded.actorKind
            afterId = decoded.actorId
        }
        let visibility = reactionActorVisibilityLocked(channelId: localChannelId, requesterId: userId)
        var actors = messageReactions
            .filter { row in
                row.messageId == message.id && row.emoji == validEmoji && (
                    (row.reactorType == "user" && visibility.humans.contains(row.reactorId))
                    || (row.reactorType == "agent" && visibility.agents.contains(row.reactorId))
                )
            }
            .map { (kind: $0.reactorType, id: $0.reactorId) }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
                return lhs.id < rhs.id
            }
        if let afterKind, let afterId {
            actors = actors.filter { $0.kind > afterKind || ($0.kind == afterKind && $0.id > afterId) }
        }
        let hasMore = actors.count > pageLimit
        let page = Array(actors.prefix(pageLimit))
        let nextCursor: String?
        if hasMore, let last = page.last {
            nextCursor = Self.encodeActorCursor(ActorCursor(
                principalId: userId,
                serverId: serverId ?? "",
                messageId: message.id,
                emoji: validEmoji,
                discussionVersion: currentVersion,
                visibilityHash: visibility.hash,
                actorKind: last.kind,
                actorId: last.id
            ))
        } else {
            nextCursor = nil
        }
        let actorJSON = page.map { "{\"actorRef\":{\"kind\":\(jsonString($0.kind)),\"id\":\(jsonString($0.id))}}" }.joined(separator: ",")
        let cursorJSON = nextCursor.map { jsonString($0) } ?? "null"
        let scopeKind = channel.kind == "thread" ? "thread" : "channel"
        let localServer = jsonString(serverId ?? "")
        let discussion = "{\"root\":{\"kind\":\"message\",\"serverId\":\(localServer),\"id\":\(jsonString(message.id))},\"relation\":{\"kind\":\"reactionActors\",\"emoji\":\(jsonString(validEmoji))},\"parentScope\":{\"serverId\":\(localServer),\"scopeKind\":\(jsonString(scopeKind)),\"scopeId\":\(jsonString(localChannelId))}}"
        lock.unlock()
        return Self.json(200, "{\"discussion\":\(discussion),\"discussionVersion\":\(currentVersion),\"actors\":[\(actorJSON)],\"nextCursor\":\(cursorJSON)}")
    }

    func writeAgentReactionLocked(message: StoredHumanMessage, agentId: String, emoji: String, serverId: String, remove: Bool) -> String {
        let changed: Bool
        if remove {
            let before = messageReactions.count
            messageReactions.removeAll { $0.messageId == message.id && $0.emoji == emoji && $0.reactorId == agentId && $0.reactorType == "agent" }
            changed = messageReactions.count != before
        } else if messageReactions.contains(where: { $0.messageId == message.id && $0.emoji == emoji && $0.reactorId == agentId && $0.reactorType == "agent" }) {
            changed = false
        } else {
            messageReactions.append(StoredReaction(messageId: message.id, emoji: emoji, reactorId: agentId, reactorType: "agent"))
            changed = true
        }
        if changed {
            noteDiscussionChangeLocked(messageId: message.id, emoji: emoji)
        }
        return finishReactionLocked(message: message, actorId: agentId, serverId: serverId)
    }

    func noteDiscussionChangeLocked(messageId: String, emoji: String) {
        let key = "\(messageId)\n\(emoji)"
        reactionDiscussionVersions[key] = (reactionDiscussionVersions[key] ?? 0) + 1
    }

    /// On #all, a member of a hidden human directory sees only themself. Agents stay visible. Owners are not hidden.
    func reactionActorVisibilityLocked(channelId: String, requesterId: String) -> (humans: Set<String>, agents: Set<String>, hash: String) {
        guard let channel = postableChannels[channelId] else { return ([], [], "") }
        let requesterRole = serverMemberRoles["\(channel.serverId)\n\(requesterId)"]
            ?? oauth.memberRole(serverId: channel.serverId, userId: requesterId)
        let hiddenDirectory = hideHumansFromMembers[channel.serverId] == true
            && requesterRole == "member"
            && channel.name == "all"
            && (channel.kind == "channel" || channel.kind == "private")
        let roster = jointRosterLocked(channelId: channelId) ?? channel.memberIds
        let humans = hiddenDirectory
            ? roster.filter { $0 == requesterId }
            : roster
        let agents = channelAgentMembers[channelId] ?? []
        let hash = humans.sorted().joined(separator: ",") + "|" + agents.sorted().joined(separator: ",")
        return (humans, agents, hash)
    }

    func finishReactionLocked(message: StoredHumanMessage, actorId: String, serverId: String?, viewerJSON: String? = nil) -> String {
        let reactions = reactionJSONLocked(messageId: message.id)
        let senderName = accounts.values.first { $0.id == message.senderId }?.name ?? "Unknown user"
        let httpMetadata = forwardedBundleJSONLocked(messageId: message.id, userId: actorId, serverId: serverId, scrub: false)
        let socketMetadata = forwardedBundleJSONLocked(messageId: message.id, userId: actorId, serverId: serverId, scrub: true)
        let commentsVisible = attachmentCommentsEnabled(serverId: serverId ?? "", userId: actorId)
        let commentRef = commentsVisible ? commentRefJSONLocked(messageId: message.id) : nil
        var bodyJSON = "{\"reactions\":[\(reactions)],\"commentRef\":\(commentRef ?? "null"),\"attachments\":[\(messageAttachmentsJSONLocked(message.attachmentIds, commentsVisible: commentsVisible))]"
        if let httpMetadata {
            bodyJSON += ",\"actionMetadata\":\(httpMetadata)"
        }
        if let viewerJSON {
            bodyJSON += ",\"reactionViewer\":\(viewerJSON)"
        }
        bodyJSON += "}"
        var payload = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(message.channelId)),\"content\":\(jsonString(message.content)),\"senderName\":\(jsonString(senderName)),\"commentRef\":null,\"reactions\":[\(reactions)]"
        if let socketMetadata {
            payload += ",\"actionMetadata\":\(socketMetadata)"
        }
        payload += "}"
        emitRealtime("channel:\(message.channelId)", "message:updated", payload)
        return bodyJSON
    }

    func emitRealtime(_ room: String, _ event: String, _ payload: String?) {
        realtimeEmitterLock.lock()
        let emitter = realtimeEmitterStorage
        realtimeEmitterLock.unlock()
        emitter?(room, event, payload)
    }

    /// The HTTP body keeps a forwarded source the viewer can read. The channel broadcast always strips it.
    func forwardedBundleJSONLocked(messageId: String, userId: String, serverId: String?, scrub: Bool) -> String? {
        guard let items = forwardedBundles[messageId], !items.isEmpty else { return nil }
        let rendered = items.map { item -> String in
            let readable = !scrub && viewerCanReadForwardedSourceLocked(item, userId: userId, serverId: serverId)
            if readable {
                return "{\"sourceServerId\":\(jsonString(item.sourceServerId)),\"sourceTargetId\":\(jsonString(item.sourceTargetId)),\"sourceMessageId\":\(jsonString(item.sourceMessageId)),\"sourceTargetSnapshot\":{\"id\":\(jsonString(item.snapshotId)),\"type\":\(jsonString(item.snapshotType)),\"label\":\(jsonString(item.snapshotLabel)),\"labelVisibility\":\(jsonString(item.snapshotLabelVisibility))},\"provenanceState\":\(jsonString(item.provenanceState))}"
            }
            let type = item.snapshotType.isEmpty ? "channel" : item.snapshotType
            return "{\"sourceMessageId\":null,\"sourceServerId\":null,\"sourceTargetId\":null,\"sourceTargetSnapshot\":{\"id\":null,\"type\":\(jsonString(type)),\"label\":\"\",\"labelVisibility\":\"restricted\"},\"provenanceState\":\"original_unavailable\"}"
        }.joined(separator: ",")
        return "{\"kind\":\"forwarded-bundle\",\"forwardedItems\":[\(rendered)]}"
    }

    func viewerCanReadForwardedSourceLocked(_ item: ForwardedSource, userId: String, serverId: String?) -> Bool {
        guard item.sourceServerId == serverId,
              let channel = postableChannels[item.sourceTargetId],
              channel.serverId == serverId
        else { return false }
        if channel.kind == "channel" { return true }
        return channel.memberIds.contains(userId)
    }






    /// A short id counts only messages this user can see. Hidden private rows with the same prefix stay out of the match.
    /// A joint guest resolves the canonical message through that server's local projection.
    func resolveReactionTargetLocked(messageId: String, userId: String, serverId: String?) -> ReactionTarget {
        if MessageContext.isShortId(messageId) {
            let matches = humanMessageRows.filter {
                Self.messageIdHasShortPrefix($0.id, prefix: messageId) && reactionMessageVisibleLocked($0, userId: userId, serverId: serverId)
            }
            if matches.count > 1 { return .ambiguous }
            if let message = matches.first, let channel = postableChannels[message.channelId] {
                return .message(message, channel, message.channelId)
            }
            return .missing
        }
        guard let message = humanMessageRows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }) else {
            return .missing
        }
        if reactionMessageVisibleLocked(message, userId: userId, serverId: serverId),
           let channel = postableChannels[message.channelId] {
            return .message(message, channel, message.channelId)
        }
        if postableChannels[message.channelId]?.deletedAt == nil,
           let localId = jointLocalChannelIdLocked(canonicalChannelId: message.channelId, serverId: serverId, userId: userId),
           let local = postableChannels[localId],
           local.deletedAt == nil {
            return .message(message, local, localId)
        }
        return .missing
    }

    func jointLocalChannelIdLocked(canonicalChannelId: String, serverId: String?, userId: String) -> String? {
        guard let serverId else { return nil }
        return jointProjections.first { link in
            link.canonicalChannelId == canonicalChannelId
                && link.serverId == serverId
                && postableChannels[link.localChannelId]?.memberIds.contains(userId) == true
        }?.localChannelId
    }

    /// Members of every local projection of one joint channel. Nil when this channel is not joint.
    func jointRosterLocked(channelId: String) -> Set<String>? {
        let canonical = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId
            ?? (jointProjections.contains { $0.canonicalChannelId == channelId } ? channelId : nil)
        guard let canonical else { return nil }
        var ids = postableChannels[canonical]?.memberIds ?? []
        for link in jointProjections where link.canonicalChannelId == canonical {
            ids.formUnion(postableChannels[link.localChannelId]?.memberIds ?? [])
        }
        return ids
    }

    /// Public channels are visible to any authenticated user on the server. Private, DM, and thread rows require membership.
    /// A deleted channel is not visible, so the reaction route answers 404 before the archive check.
    func reactionMessageVisibleLocked(_ message: StoredHumanMessage, userId: String, serverId: String?) -> Bool {
        guard let channel = postableChannels[message.channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return false }
        if channel.kind == "channel" { return true }
        return channel.memberIds.contains(userId)
    }

    /// The caller's own emojis, ordered by UTF-16 code units, plus the version that advances only when a row changes.
    func reactionViewerJSONLocked(messageId: String, userId: String, serverId: String) -> String {
        let version = reactionViewerVersions["\(messageId)\n\(userId)"] ?? 0
        let emojis = messageReactions
            .filter { $0.messageId == messageId && $0.reactorType == "user" && $0.reactorId == userId }
            .map(\.emoji)
            .sorted(by: Self.utf16Ascending)
        let list = emojis.map { jsonString($0) }.joined(separator: ",")
        return "{\"serverId\":\(jsonString(serverId)),\"messageId\":\(jsonString(messageId)),\"viewerVersion\":\(version),\"reactedEmojis\":[\(list)]}"
    }


    /// Node `uuidShortIdRange`: the half-open prefix of canonical lowercase UUID text.

    /// Node `parseReactionEmoji`: a trimmed string, at most 16 UTF-16 code units, with no whitespace.

    func reactionJSONLocked(messageId: String) -> String {
        var order: [String] = []
        var buckets: [String: (ids: [String], names: [String])] = [:]
        for row in messageReactions where row.messageId == messageId {
            if buckets[row.emoji] == nil {
                order.append(row.emoji)
                buckets[row.emoji] = ([], [])
            }
            let name: String
            if row.reactorType == "agent" {
                if let runtime = oauth.agentRuntimeInfo(id: row.reactorId) {
                    name = runtime.displayName.isEmpty ? runtime.name : runtime.displayName
                } else {
                    name = serverAgents[row.reactorId]?.name ?? "Unknown agent"
                }
            } else {
                name = accounts.values.first { $0.id == row.reactorId }.map { $0.displayName ?? $0.name } ?? "Unknown user"
            }
            var bucket = buckets[row.emoji] ?? ([], [])
            bucket.ids.append(row.reactorId)
            bucket.names.append(name)
            buckets[row.emoji] = bucket
        }
        return order.map { emoji in
            let bucket = buckets[emoji] ?? ([], [])
            let ids = bucket.ids.map { jsonString($0) }.joined(separator: ",")
            let names = bucket.names.map { jsonString($0) }.joined(separator: ",")
            return "{\"emoji\":\(jsonString(emoji)),\"count\":\(bucket.ids.count),\"reactorIds\":[\(ids)],\"reactorNames\":[\(names)]}"
        }.joined(separator: ",")
    }

    /// Appends one message row and stamps its server-wide sequence.
    @discardableResult
    func appendHumanMessageLocked(_ message: StoredHumanMessage, seq explicitSeq: Int? = nil) -> Int {
        var stored = message
        stored.seq = explicitSeq ?? (humanMessageRows.count + 1)
        humanMessageRows.append(stored)
        // Mirror into the ledger so ledger-backed reads (agent history, thread
        // anchors) see the same server-wide sequence and sender metadata.
        oauth.appendMirroredMessage(
            id: stored.id,
            channelId: stored.channelId,
            content: stored.content,
            senderId: stored.senderId,
            seq: stored.seq,
            createdAt: stored.createdAt,
            senderTimezone: stored.senderTimezone,
            senderType: stored.senderType,
            messageType: stored.messageType
        )
        return stored.seq
    }

    func storeHumanMessage(channelId: String, senderId: String, content: String, randomId: String?, attachmentIds: [String], senderTimezone: String? = nil, mentions: [MentionInput] = []) -> (reply: HTTPReply, created: Bool) {
        lock.lock()
        if let randomId, let existing = humanMessageRows.first(where: { $0.senderId == senderId && $0.randomId == randomId }) {
            if existing.channelId != channelId {
                lock.unlock()
                return (Self.json(409, "{\"error\":\"randomId has already been used for a different message\",\"code\":\"random_id_conflict\"}"), false)
            }
            let matches = attachmentOrderMatches(message: existing, attachmentIds: attachmentIds, uploaderId: senderId)
            let snapshot = existing
            lock.unlock()
            if matches {
                return (Self.humanMessageJSON(snapshot), false)
            }
            return (Self.json(400, "{\"error\":\"This idempotent send was already committed with a different ordered attachment set.\",\"code\":\"attachment_replay_conflict\"}"), false)
        }
        var seenAttachmentIds = Set<String>()
        for id in attachmentIds {
            if seenAttachmentIds.contains(id) {
                lock.unlock()
                return (Self.json(400, "{\"error\":\"Attachment \(id) was requested more than once. Send each attachment ID exactly once.\",\"code\":\"attachment_duplicate\"}"), false)
            }
            seenAttachmentIds.insert(id)
            guard let row = channelAttachments[id], row.channelId == channelId, row.uploaderId == senderId else {
                lock.unlock()
                return (Self.json(400, "{\"error\":\"Attachment \(id) is not available for this sender. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_not_found\"}"), false)
            }
            if row.messageId != nil {
                lock.unlock()
                return (Self.json(400, "{\"error\":\"Attachment \(id) is already attached to another message. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_already_linked\"}"), false)
            }
        }
        let storedMentionsForEcho = postableChannels[channelId]?.kind == "dm"
            ? []
            : mentions.map { StoredMessageMention(type: $0.type, id: $0.id, name: $0.name) }
        let stored = StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: randomId,
            attachmentIds: attachmentIds,
            senderTimezone: senderTimezone,
            mentions: storedMentionsForEcho
        )
        for (position, id) in attachmentIds.enumerated() {
            channelAttachments[id]?.messageId = stored.id
            channelAttachments[id]?.messagePosition = position
        }
        let sequence = appendHumanMessageLocked(stored)
        if postableChannels[channelId]?.kind == "thread" {
            inboxDoneScopes = inboxDoneScopes.filter { !$0.hasSuffix("\n\(channelId)") }
            inboxDoneFrontiers = inboxDoneFrontiers.filter { !$0.key.hasSuffix("\n\(channelId)") }
        }
        // One read-cursor store: the ledger's per-user frontier. Sending is
        // reading your own message, so the sender never counts it as unread.
        let ownCursor = oauth.channelReadCursor(channelId: channelId, userId: senderId)
        if sequence > ownCursor {
            oauth.setChannelReadCursor(channelId: channelId, userId: senderId, seq: sequence)
        }
        recordedChannelMessageEvents.append(ChannelMessageEvent(
            room: "channel:\(channelId)",
            name: "message:new",
            messageId: stored.id,
            attachmentIds: attachmentIds
        ))
        lock.unlock()
        let reply = Self.humanMessageJSON(stored)
        emitRealtime("channel:\(channelId)", "message:new", reply.body)
        return (reply, true)
    }

    /// Replay accepts only the stored ids, positions, and uploader. It does not write.
    func attachmentOrderMatches(message: StoredHumanMessage, attachmentIds: [String], uploaderId: String) -> Bool {
        guard message.attachmentIds.count == attachmentIds.count else { return false }
        for (index, id) in attachmentIds.enumerated() {
            guard message.attachmentIds[index] == id,
                  let row = channelAttachments[id],
                  row.messageId == message.id,
                  row.messagePosition == index,
                  row.uploaderId == uploaderId
            else { return false }
        }
        return true
    }

    public func channelMessageEvents() -> [ChannelMessageEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedChannelMessageEvents
    }

    /// The user behind a normal access token. `requireAuth` does not demand a verified email.
    public func oauthSession(authorization: String?) -> OAuthSession {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missing }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accessTokens[token],
              let account = accounts.values.first(where: { $0.id == userId })
        else { return .invalid }
        return .user(OAuthHuman(
            id: account.id,
            email: account.email,
            name: account.name,
            emailVerified: account.emailVerified,
            avatarUrl: account.avatarUrl
        ))
    }

    func identitiesJSONLocked(userId: String) -> (identities: String, passwordConfigured: Bool) {
        let rows = authProfileStore.identities(userId: userId).map { row in
            "{\"provider\":\(jsonString(row.provider)),\"providerEmail\":\(jsonString(row.providerEmail))}"
        }.joined(separator: ",")
        let account = accounts.values.first { $0.id == userId }
        return (rows, account?.passwordCredentialEstablishedAt != nil)
    }

    public func authIdentities(authorization: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let state = identitiesJSONLocked(userId: userId)
        lock.unlock()
        return Self.json(200, "{\"identities\":[\(state.identities)],\"passwordConfigured\":\(state.passwordConfigured)}")
    }

    public func unlinkAuthIdentity(authorization: String?, provider: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        var rows = authProfileStore.identities(userId: userId)
        guard let index = rows.firstIndex(where: { $0.provider == provider }) else {
            let state = identitiesJSONLocked(userId: userId)
            lock.unlock()
            return Self.json(200, "{\"unlinked\":false,\"identities\":[\(state.identities)],\"passwordConfigured\":\(state.passwordConfigured)}")
        }
        let passwordConfigured = identitiesJSONLocked(userId: userId).passwordConfigured
        if rows.count == 1, !passwordConfigured {
            lock.unlock()
            return Self.json(409, "{\"code\":\"PASSWORD_CREDENTIAL_REQUIRED\",\"error\":\"Set a password before disconnecting your final sign-in account.\"}")
        }
        rows.remove(at: index)
        authProfileStore.replaceIdentities(userId: userId, rows: rows)
        let state = identitiesJSONLocked(userId: userId)
        lock.unlock()
        return Self.json(200, "{\"unlinked\":true,\"identities\":[\(state.identities)],\"passwordConfigured\":\(state.passwordConfigured)}")
    }

    public func resetPassword(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty,
              let password = object["password"] as? String, !password.isEmpty
        else {
            return Self.json(400, "{\"error\":\"token and password are required\"}")
        }
        let hash = Self.sha256(token)
        lock.lock()
        guard let reset = authProfileStore.resetToken(hash: hash), reset.expiresAt > Date(),
              let email = accounts.first(where: { $0.value.id == reset.userId })?.key
        else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid or expired reset token\"}")
        }
        authProfileStore.removeResetToken(hash: hash)
        accounts[email]?.passwordHash = Self.sha256(password)
        accounts[email]?.passwordCredentialEstablishedAt = Date()
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func mintAccessTokenForTesting(userId: String) -> String {
        lock.lock()
        let token = openSessionLocked(userId: userId).accessToken
        lock.unlock()
        return token
    }

    public func authIdentityCount(userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return authProfileStore.identityCount(userId: userId)
    }

    public func addAuthIdentityForTesting(userId: String, provider: String, providerEmail: String) {
        lock.lock()
        authProfileStore.appendIdentity(userId: userId, provider: provider, providerEmail: providerEmail)
        lock.unlock()
    }

    public func addPasswordResetTokenForTesting(userId: String, token: String, expiresAt: Date) {
        lock.lock()
        authProfileStore.setResetToken(hash: Self.sha256(token), userId: userId, expiresAt: expiresAt)
        lock.unlock()
    }

    public func passwordCredentialEstablished(userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accounts.values.first { $0.id == userId }?.passwordCredentialEstablishedAt != nil
    }

    public func integrationSettingsClients(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let data = try? JSONSerialization.data(withJSONObject: oauth.integrationSettingsClients(serverId: serverId))
        return Self.json(200, String(decoding: data ?? Data("[]".utf8), as: UTF8.self))
    }

    public func login(body: String) -> HTTPReply {
        switch Self.parse(body) {
        case .invalid(let issues):
            return Self.invalid(issues)
        case .request(let request):
            return authenticate(request)
        }
    }




    /// `POST /api/auth/app-login/start`. The handoff accepts only the shipped
    /// HarmonyOS return URIs and an S256 PKCE challenge.
    public func appLoginStart(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let returnUri = object["returnUri"] as? String, !returnUri.isEmpty,
              let codeChallenge = object["codeChallenge"] as? String, !codeChallenge.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid app login request\",\"code\":\"invalid_request\"}")
        }
        guard Self.appLoginReturnUris.contains(returnUri) else {
            return Self.json(400, "{\"error\":\"Return URI is not allowed\",\"code\":\"return_uri_not_allowed\"}")
        }
        if let method = object["codeChallengeMethod"] as? String, method != "S256" {
            return Self.json(400, "{\"error\":\"PKCE challenge method must be S256\",\"code\":\"code_challenge_method_invalid\"}")
        }
        guard codeChallenge.wholeMatch(of: /^[A-Za-z0-9_-]{43}$/) != nil else {
            return Self.json(400, "{\"error\":\"PKCE challenge is invalid\",\"code\":\"code_challenge_invalid\"}")
        }
        let requestId = UUID().uuidString.lowercased()
        let expiresAt = Self.appLoginExpiresAt()
        lock.lock()
        appLoginRequests[requestId] = AppLoginRequest(
            id: requestId,
            returnUri: returnUri,
            codeChallenge: codeChallenge,
            status: "pending",
            code: nil,
            userId: nil,
            expiresAt: expiresAt,
            consumedAt: nil
        )
        lock.unlock()
        let loginUrl = "\(appURL)/login/app?request=\(requestId)"
        return Self.json(201, "{\"requestId\":\(jsonString(requestId)),\"loginUrl\":\(jsonString(loginUrl)),\"expiresAt\":\(jsonString(Self.iso8601(expiresAt)))}")
    }

    func appLoginActor(_ authorization: String?) -> String? {
        if case .user(let id) = authorize(authorization) { return id }
        return nil
    }

    func appLoginRequestLocked(_ requestId: String) -> AppLoginRequest? {
        appLoginRequests[requestId]
    }

    /// `GET /api/auth/app-login/requests/:requestId`. Only a signed-in user may read the request.
    public func appLoginDescribe(authorization: String?, requestId: String) -> HTTPReply {
        guard appLoginActor(authorization) != nil else { return Self.invalidToken }
        lock.lock()
        let request = appLoginRequestLocked(requestId)
        lock.unlock()
        guard let request else { return Self.json(404, "{\"error\":\"App login request not found\",\"code\":\"request_not_found\"}") }
        return Self.json(200, "{\"requestId\":\(jsonString(request.id)),\"status\":\(jsonString(request.status)),\"returnUri\":\(jsonString(request.returnUri)),\"expiresAt\":\(jsonString(Self.iso8601(request.expiresAt)))}")
    }

    /// `POST /api/auth/app-login/requests/:requestId/approve`.
    public func appLoginApprove(authorization: String?, requestId: String) -> HTTPReply {
        guard let userId = appLoginActor(authorization) else { return Self.invalidToken }
        let now = Date()
        lock.lock()
        guard var request = appLoginRequestLocked(requestId) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"App login request not found\",\"code\":\"request_not_found\"}")
        }
        if request.expiresAt <= now {
            lock.unlock()
            return Self.json(410, "{\"error\":\"App login request expired\",\"code\":\"request_expired\",\"redirectUrl\":\(jsonString(Self.appLoginRedirect(request.returnUri, requestId: request.id, query: "error=expired")))}")
        }
        guard request.status == "pending" else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"App login request is not pending\",\"code\":\"request_not_pending\"}")
        }
        let code = Self.token()
        request.status = "approved"
        request.code = code
        request.userId = userId
        appLoginRequests[requestId] = request
        lock.unlock()
        let redirectUrl = Self.appLoginRedirect(request.returnUri, requestId: request.id, query: "code=\(code)")
        return Self.json(200, "{\"redirectUrl\":\(jsonString(redirectUrl))}")
    }

    /// `POST /api/auth/app-login/requests/:requestId/deny`.
    public func appLoginDeny(authorization: String?, requestId: String) -> HTTPReply {
        guard appLoginActor(authorization) != nil else { return Self.invalidToken }
        let now = Date()
        lock.lock()
        guard var request = appLoginRequestLocked(requestId) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"App login request not found\",\"code\":\"request_not_found\"}")
        }
        if request.expiresAt <= now {
            lock.unlock()
            return Self.json(410, "{\"error\":\"App login request expired\",\"code\":\"request_expired\",\"redirectUrl\":\(jsonString(Self.appLoginRedirect(request.returnUri, requestId: request.id, query: "error=expired")))}")
        }
        guard request.status == "pending" else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"App login request is not pending\",\"code\":\"request_not_pending\"}")
        }
        request.status = "denied"
        appLoginRequests[requestId] = request
        lock.unlock()
        let redirectUrl = Self.appLoginRedirect(request.returnUri, requestId: request.id, query: "error=access_denied")
        return Self.json(200, "{\"redirectUrl\":\(jsonString(redirectUrl))}")
    }

    /// `POST /api/auth/app-login/complete`. The one-time code is bound to the
    /// request's S256 challenge and request expiry; a wrong verifier does not burn it.
    public func appLoginComplete(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty,
              let verifier = object["codeVerifier"] as? String, !verifier.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid app login completion\",\"code\":\"invalid_request\"}")
        }
        let now = Date()
        lock.lock()
        guard let request = appLoginRequests.values.first(where: { $0.code == code }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"App login code not found\",\"code\":\"code_not_found\"}")
        }
        if request.consumedAt != nil {
            lock.unlock()
            return Self.json(410, "{\"error\":\"App login code was already used\",\"code\":\"code_consumed\"}")
        }
        if request.expiresAt <= now {
            lock.unlock()
            return Self.json(410, "{\"error\":\"App login code expired\",\"code\":\"code_expired\"}")
        }
        guard Self.pkceS256(verifier) == request.codeChallenge else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"PKCE verifier does not match\",\"code\":\"pkce_mismatch\"}")
        }
        guard let userId = request.userId else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"App login request is not approved\",\"code\":\"request_not_approved\"}")
        }
        var approved = request
        approved.consumedAt = now
        appLoginRequests[approved.id] = approved
        guard let account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return Self.invalidToken
        }
        let issued = openSessionLocked(userId: userId)
        let user = Self.userJSON(account)
        lock.unlock()
        return Self.json(200, "{\"user\":\(user),\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken))}")
    }

    public func expireAppLoginRequestForTesting(requestId: String) {
        lock.lock()
        appLoginRequests[requestId]?.expiresAt = Date().addingTimeInterval(-1)
        lock.unlock()
    }

    func authenticate(_ request: Request) -> HTTPReply {
        let email = Self.normalize(request.email)
        lock.lock()
        var pendingLink: PendingSocialLink?
        if let token = request.pendingLinkToken, !token.isEmpty {
            guard var pending = pendingSocialLinks[token], !pending.consumed, !pending.cancelled,
                  pending.expiresAt > Date()
            else {
                lock.unlock()
                return Self.json(410, "{\"error\":\"This sign-in link expired. Sign in again to connect the account.\",\"code\":\"pending_link_expired\"}")
            }
            guard pending.email == email else {
                lock.unlock()
                return Self.json(403, "{\"error\":\"The pending link belongs to a different account\",\"code\":\"pending_link_account_mismatch\"}")
            }
            pendingLink = pending
        }
        let account = accounts[email]
        let matches = account.map { $0.passwordHash == Self.sha256(request.password) } ?? false
        guard var accountSnapshot = account, matches, accountSnapshot.retiredAt == nil else {
            lock.unlock()
            return Self.rejected
        }
        if accountSnapshot.passwordCredentialEstablishedAt == nil {
            accountSnapshot.passwordCredentialEstablishedAt = Date()
            accounts[email] = accountSnapshot
        }
        if failNextSessionIssuanceForTesting {
            failNextSessionIssuanceForTesting = false
            lock.unlock()
            return Self.json(500, "{\"error\":\"Unable to complete sign-in\"}")
        }
        let issued = openSessionLocked(userId: accountSnapshot.id)
        var linkedProviderJSON = "null"
        if var pending = pendingLink {
            pending.consumed = true
            pendingSocialLinks[pending.token] = pending
            if !linkedIdentities.contains(where: {
                $0.userId == accountSnapshot.id && $0.provider == pending.provider && $0.providerUserId == pending.providerUserId
            }) {
                linkedIdentities.append(LinkedIdentity(
                    userId: accountSnapshot.id, provider: pending.provider,
                    providerUserId: pending.providerUserId, providerEmail: pending.email
                ))
            }
            linkedProviderJSON = jsonString(pending.provider)
        }
        let body = "{\"user\":{\"id\":\(jsonString(accountSnapshot.id)),\"email\":\(jsonString(accountSnapshot.email))},\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken)),\"linkedProvider\":\(linkedProviderJSON)}"
        lock.unlock()
        return Self.json(200, body)
    }

    /// `POST /api/auth/me/avatar`. A file over 5 MB is refused before the stored path changes.
    public func uploadAvatar(authorization: String?, contentType: String?, body: Data) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard let file = Self.multipartFile(named: "avatar", contentType: contentType, body: body) else {
            return Self.json(400, "{\"error\":\"No avatar file provided\"}")
        }
        if file.count > Self.maxProfileAvatarBytes {
            return Self.json(400, "{\"error\":\"Avatar image must be 5 MB or smaller\",\"errorCode\":\"PROFILE_AVATAR_TOO_LARGE\",\"maxBytes\":\(Self.maxProfileAvatarBytes)}")
        }
        let hash = String(Self.sha256(file).prefix(32))
        let avatarURL = "/api/avatars/users/\(hash).webp"
        lock.lock()
        guard var account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return Self.invalidToken
        }
        account.avatarUrl = avatarURL
        accounts[account.email] = account
        let snapshot = account
        lock.unlock()
        return Self.json(200, Self.userJSON(snapshot))
    }

    /// `GET /api/auth/me`. The hash is SHA-256 of the stored email, trimmed and lowercased.
    public func me(authorization: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        lock.lock()
        let account = accounts.values.first { $0.id == userId }
        lock.unlock()
        guard let account, account.retiredAt == nil else { return Self.invalidToken }
        var json = Self.userJSON(account)
        lock.lock()
        let observation = timezoneObservations[userId]
        lock.unlock()
        if let observation {
            let extra = String(Self.timezoneJSON(observation).dropFirst())
            if let closing = json.lastIndex(of: "}") {
                json = String(json[..<closing]) + "," + extra
            }
        }
        return Self.json(200, json)
    }

    /// `PATCH /api/auth/me`. A wrong current password is refused before any profile write.
    /// Display language accepts only the shipped UI catalogs, `en` and `zh-cn`.
    public func patch(authorization: String?, body: String) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Failed to update profile\"}")
        }

        if let current = object["currentPassword"] as? String, !current.isEmpty,
           let newPassword = object["newPassword"] as? String, !newPassword.isEmpty {
            if newPassword.count < 8 {
                return Self.json(400, "{\"error\":\"New password must be at least 8 characters\"}")
            }
            lock.lock()
            guard var account = accounts.values.first(where: { $0.id == userId }) else {
                lock.unlock()
                return Self.invalidToken
            }
            guard account.passwordHash == Self.sha256(current) else {
                lock.unlock()
                return Self.wrongPassword
            }
            account.passwordHash = Self.sha256(newPassword)
            accounts[account.email] = account
            lock.unlock()
        }

        var languageUpdate: String??
        if object["displayLanguage"] != nil {
            switch Self.parseDisplayLanguage(object["displayLanguage"]!) {
            case .invalid(let message):
                return Self.json(400, "{\"error\":\(jsonString(message))}")
            case .value(let language):
                languageUpdate = language
            }
        } else {
            languageUpdate = nil
        }

        var shareUpdate: Bool?? = nil
        if let raw = object["shareUsageData"] {
            if raw is NSNull {
                shareUpdate = .some(nil)
            } else if let bool = raw as? Bool {
                shareUpdate = .some(bool)
            } else {
                return Self.json(400, "{\"error\":\"shareUsageData must be a boolean or null\"}")
            }
        }

        var languagePreference: String?? = nil
        if let raw = object["preferredLanguage"] {
            if raw is NSNull {
                languagePreference = .some(nil)
            } else if let value = raw as? String,
                      value.wholeMatch(of: /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/) != nil {
                languagePreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Unsupported preferredLanguage\"}")
            }
        }
        var timezonePreference: String?? = nil
        if let raw = object["preferredTimezone"] {
            if raw is NSNull {
                timezonePreference = .some(nil)
            } else if let value = raw as? String, TimeZone(identifier: value) != nil {
                timezonePreference = .some(value)
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredTimezone\"}")
            }
        }
        var modePreference: String? = nil
        if let raw = object["preferredTranslationMode"] {
            guard let value = raw as? String, ["off", "manual", "auto"].contains(value) else {
                return Self.json(400, "{\"error\":\"Invalid preferredTranslationMode\"}")
            }
            modePreference = value
        }
        var autoPreference: Bool? = nil
        if let raw = object["autoTranslationEnabled"] {
            guard let value = raw as? Bool else {
                return Self.json(400, "{\"error\":\"Invalid autoTranslationEnabled\"}")
            }
            autoPreference = value
        }
        var displayPreference: String? = nil
        if let raw = object["preferredTranslationDisplay"] {
            guard let value = raw as? String, ["translated", "bilingual", "original"].contains(value) else {
                return Self.json(400, "{\"error\":\"Invalid preferredTranslationDisplay\"}")
            }
            displayPreference = value
        }
        var timeFormatPreference: String?? = nil
        if let raw = object["preferredTimeFormat"] {
            if raw is NSNull {
                timeFormatPreference = .some(nil)
            } else if let value = raw as? String, ["12h", "24h"].contains(value.lowercased()) {
                timeFormatPreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredTimeFormat\"}")
            }
        }
        var fontSizePreference: String?? = nil
        if let raw = object["preferredMessageBodyFontSize"] {
            if raw is NSNull {
                fontSizePreference = .some(nil)
            } else if let value = raw as? String, ["sm", "md", "lg", "xl"].contains(value.lowercased()) {
                fontSizePreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredMessageBodyFontSize\"}")
            }
        }

        var referralSourceUpdate: String?? = nil
        var referralOtherUpdate: String?? = nil
        var referralSkipped = false
        if let raw = object["referralSource"] {
            if raw is NSNull {
                referralSourceUpdate = .some(nil)
                referralOtherUpdate = .some(nil)
            } else if let value = raw as? String,
                      ["twitter_x", "linkedin", "friend_colleague", "search", "hn_reddit", "podcast_blog_newsletter", "other"].contains(value) {
                referralSourceUpdate = .some(value)
                if value == "other", let other = object["referralSourceOther"] as? String {
                    let trimmed = String(other.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                    referralOtherUpdate = .some(trimmed.isEmpty ? nil : trimmed)
                } else {
                    referralOtherUpdate = .some(nil)
                }
            } else {
                return Self.json(400, "{\"error\":\"Invalid referralSource\"}")
            }
        } else if object["referralSourceOther"] != nil {
            return Self.json(400, "{\"error\":\"referralSource is required when referralSourceOther is provided\"}")
        }
        if let raw = object["referralSourceSkipped"] {
            guard let value = raw as? Bool else {
                return Self.json(400, "{\"error\":\"referralSourceSkipped must be a boolean\"}")
            }
            referralSkipped = value
        }

        lock.lock()
        guard var account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return Self.invalidToken
        }
        var changed = false
        if let value = referralSourceUpdate {
            account.referralSource = value
            account.referralSourceSkippedAt = nil
            changed = true
        }
        if let value = referralOtherUpdate {
            account.referralSourceOther = value
            changed = true
        }
        if referralSkipped {
            account.referralSourceSkippedAt = Date()
            changed = true
        }
        if let value = languagePreference { account.preferredLanguage = value; changed = true }
        if let value = timezonePreference { account.preferredTimezone = value; changed = true }
        if let value = modePreference { account.preferredTranslationMode = value; changed = true }
        if let value = autoPreference { account.autoTranslationEnabled = value; changed = true }
        if let value = displayPreference { account.preferredTranslationDisplay = value; changed = true }
        if let value = timeFormatPreference { account.preferredTimeFormat = value; changed = true }
        if let value = fontSizePreference { account.preferredMessageBodyFontSize = value; changed = true }
        if let language = languageUpdate {
            account.displayLanguage = language
            changed = true
        }
        if let share = shareUpdate {
            account.shareUsageData = share
            if share == true {
                if analyticsIds[account.id] == nil {
                    analyticsIds[account.id] = UUID().uuidString.lowercased()
                }
            } else if share == false {
                analyticsIds.removeValue(forKey: account.id)
            }
            changed = true
        }
        if changed {
            accounts[account.email] = account
        }
        let snapshot = account
        lock.unlock()
        return Self.json(200, Self.userJSON(snapshot))
    }

}
