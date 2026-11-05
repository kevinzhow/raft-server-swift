import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {


    /// Records a channel the owner can post in. Resource-reference checks run only after this membership is visible.
    public func addPostableChannel(serverId: String, channelId: String, memberId: String, kind: String = "channel", parentChannelId: String? = nil, parentMessageId: String? = nil, name: String? = nil) {
        lock.lock()
        var channel = postableChannels[channelId] ?? PostableChannel(serverId: serverId, memberIds: [])
        channel.serverId = serverId
        channel.memberIds.insert(memberId)
        if channel.kind == "channel" || kind != "channel" {
            channel.kind = kind
        }
        if let parentChannelId {
            channel.parentChannelId = parentChannelId
        }
        if let parentMessageId {
            channel.parentMessageId = parentMessageId
        }
        if let name {
            channel.name = name
        }
        postableChannels[channelId] = channel
        lock.unlock()
    }

    /// Server role used by the hidden human directory. Only `member` is hidden on #all.
    public func setServerMemberRole(serverId: String, userId: String, role: String) {
        lock.lock()
        serverMemberRoles["\(serverId)\n\(userId)"] = role
        lock.unlock()
    }

    public func setHideHumansFromMembers(serverId: String, hidden: Bool) {
        lock.lock()
        hideHumansFromMembers[serverId] = hidden
        lock.unlock()
    }

    /// Links a server's local joint channel to the canonical channel that stores the messages.
    public func addJointChannelProjection(localChannelId: String, canonicalChannelId: String, serverId: String) {
        lock.lock()
        jointProjections.append(JointChannelLink(localChannelId: localChannelId, canonicalChannelId: canonicalChannelId, serverId: serverId))
        lock.unlock()
    }

    /// A thread whose messages hang off one parent message. Context short links on the parent channel can land here.
    public func addThreadChannel(serverId: String, threadChannelId: String, parentChannelId: String, parentMessageId: String, memberId: String) {
        lock.lock()
        var channel = postableChannels[threadChannelId] ?? PostableChannel(serverId: serverId, memberIds: [])
        channel.serverId = serverId
        channel.memberIds.insert(memberId)
        channel.kind = "thread"
        channel.parentChannelId = parentChannelId
        channel.parentMessageId = parentMessageId
        postableChannels[threadChannelId] = channel
        lock.unlock()
    }

    /// A user-to-user DM. Only the two participants may be notified by a mention.
    public func addDirectMessage(serverId: String, channelId: String, participantIds: [String], agentId: String? = nil) {
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: Set(participantIds), kind: "dm", agentId: agentId)
        lock.unlock()
    }


    /// A public channel is searchable by anyone on the server. A thread follows its parent, and a deleted parent hides the thread. Archived channels stay searchable.
    func messageSearchVisibleLocked(messageChannelId: String, serverId: String?, viewer: SearchViewer) -> Bool {
        func isMember(_ id: String, _ channel: PostableChannel) -> Bool {
            switch viewer {
            case .user(let userId):
                return channel.memberIds.contains(userId)
            case .agent(let agentId):
                return channel.memberIds.contains(agentId)
                    || channelAgentMembers[id]?.contains(agentId) == true
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
            }
        }
        guard let channel = postableChannels[messageChannelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return false }
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId,
                  let parent = postableChannels[parentId],
                  parent.serverId == serverId,
                  parent.deletedAt == nil
            else { return false }
            return parent.kind == "channel" || isMember(parentId, parent) || isMember(messageChannelId, channel)
        }
        return channel.kind == "channel" || channel.kind == "joint" || isMember(messageChannelId, channel)
    }

    /// `DELETE /api/channels/:channelId`. A member soft-deletes the channel. Search then hides it and threads under it.
    public func deleteChannel(channelId: String, authorization: String?, serverId: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        lock.lock()
        guard var channel = postableChannels[channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let role = oauth.memberRole(serverId: serverId ?? "", userId: userId) {
            guard role == "owner" || role == "admin" else {
                lock.unlock()
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
        } else if !channel.memberIds.contains(userId) {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let now = Date()
        channel.deletedAt = now
        postableChannels[channelId] = channel
        closeOrphanTasksLocked(channelId: channelId, now: now)
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    /// `GET /internal/agent/:agentId/search`. The machine key must belong to that agent. Public channels on its server are visible.
    /// `GET /internal/agent/:id/search`. Machine-keyed managed agents search
    /// the Server's visible messages, with optional sender/member-handle and
    /// absolute-instant date filters.
    public func searchAgentMessages(
        agentId: String,
        query: String?,
        limit: String?,
        authorization: String?,
        sender: String? = nil,
        after: String? = nil,
        before: String? = nil,
        sort: String? = nil
    ) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let pageLimit: Int
        if let limit, let parsed = Int(limit), parsed > 0 {
            pageLimit = min(parsed, 100)
        } else {
            pageLimit = 20
        }
        let queryTokens = Self.searchTokens((query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        if queryTokens.isEmpty {
            return Self.json(200, "{\"results\":[],\"hasMore\":false}")
        }
        func parseBoundary(_ raw: String?, label: String) -> (date: Date?, reply: HTTPReply?) {
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, nil) }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasZone = trimmed.hasSuffix("Z")
                || trimmed.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
            guard hasZone else {
                return (nil, Self.json(400, "{\"error\":\"\(label) filter is missing a timezone offset; add an explicit offset such as +08:00 (raft CLI adds it automatically)\",\"errorCode\":\"INVALID_DATE_FILTER\"}"))
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: trimmed) { return (date, nil) }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: trimmed) { return (date, nil) }
            return (nil, Self.json(400, "{\"error\":\"\(label) filter is not a valid ISO-8601 instant\",\"errorCode\":\"INVALID_DATE_FILTER\"}"))
        }
        let afterParsed = parseBoundary(after, label: "after")
        if let reply = afterParsed.reply { return reply }
        let beforeParsed = parseBoundary(before, label: "before")
        if let reply = beforeParsed.reply { return reply }
        let afterBoundary = afterParsed.date
        let beforeBoundary = beforeParsed.date
        lock.lock()
        guard let machine = machineKeys[token], machine.agentId == agentId else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let serverId = machine.serverId
        var senderScope: String?
        if let sender, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let handle = sender.hasPrefix("@") ? String(sender.dropFirst()) : sender
            let directoryHidden = hideHumansFromMembers[serverId] == true
                && oauth.agentRole(serverId: serverId, agentId: agentId) == "member"
            let humans = directoryHidden ? [] : accounts.values.filter { account in
                oauth.memberRole(serverId: serverId, userId: account.id) != nil
                    && (account.name.caseInsensitiveCompare(handle) == .orderedSame
                        || (account.displayName ?? "").caseInsensitiveCompare(handle) == .orderedSame)
            }.map(\.id)
            let agents = oauth.activeAgentIds(serverId: serverId).filter {
                oauth.agentRuntimeInfo(id: $0)?.name.caseInsensitiveCompare(handle) == .orderedSame
            }
            let matches = humans + agents
            if matches.isEmpty {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Member not found\",\"errorCode\":\"member_not_found\"}")
            }
            if matches.count > 1 {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Member handle is ambiguous\",\"errorCode\":\"ambiguous_member_ref\"}")
            }
            senderScope = matches[0]
        }
        var strict: [(StoredHumanMessage, Int)] = []
        var relaxed: [(StoredHumanMessage, Int)] = []
        for message in humanMessageRows where messageSearchVisibleLocked(
            messageChannelId: message.channelId,
            serverId: serverId,
            viewer: .agent(agentId)
        ) {
            if let senderScope, message.senderId != senderScope { continue }
            if let afterBoundary, message.createdAt <= afterBoundary { continue }
            if let beforeBoundary, message.createdAt >= beforeBoundary { continue }
            let counts = Self.tokenCounts(message.content)
            if let score = Self.matchScore(counts, queryTokens, requireAll: true) {
                strict.append((message, score))
            } else if queryTokens.count > 1, let score = Self.matchScore(counts, queryTokens, requireAll: false) {
                relaxed.append((message, score))
            }
        }
        let fallbackUsed = strict.isEmpty && !relaxed.isEmpty
        var hits = fallbackUsed ? relaxed : strict
        if sort == "recent" {
            hits.sort { $0.0.createdAt > $1.0.createdAt }
        } else {
            hits.sort { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.createdAt > rhs.0.createdAt
            }
        }
        let hasMore = !fallbackUsed && hits.count > pageLimit
        let page = hits.prefix(pageLimit)
        let results = page.map { pair -> String in
            let message = pair.0
            let channel = postableChannels[message.channelId]
            let isThread = channel?.kind == "thread"
            let parentId = (isThread ? channel?.parentChannelId : nil) ?? message.channelId
            let threadParentMessageId = isThread ? channel?.parentMessageId : nil
            let parentContent = threadParentMessageId.flatMap { parentMessageId in
                humanMessageRows.first { $0.id == parentMessageId }?.content
            }
            let senderName = accounts.values.first { $0.id == message.senderId }?.name
                ?? oauth.agentRuntimeInfo(id: message.senderId)?.name
                ?? (message.senderId == "system" ? "system" : message.senderId)
            let senderType = message.senderType == "agent" ? "agent" : "human"
            let channelType = isThread ? "thread" : (channel?.kind ?? "channel")
            let snippet = Self.searchSnippet(message.content)
            let archivedJSON: String
            if let archivedAt = oauth.channelArchivedAt(id: parentId) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                archivedJSON = jsonString(formatter.string(from: archivedAt))
            } else {
                archivedJSON = "null"
            }
            let threadIdJSON = isThread ? jsonString(message.channelId) : "null"
            let parentMessageIdJSON = threadParentMessageId.map(jsonString) ?? "null"
            let parentContentJSON = parentContent.map(jsonString) ?? "null"
            var row = "{\"id\":\(jsonString(message.id)),\"senderId\":\(jsonString(message.senderId)),\"senderName\":\(jsonString(senderName)),\"senderType\":\(jsonString(senderType)),\"channelId\":\(jsonString(message.channelId)),\"channelType\":\(jsonString(channelType)),\"channelName\":\(jsonString(channel?.name ?? "")),\"parentChannelId\":\(jsonString(parentId)),\"threadId\":\(threadIdJSON),\"parentMessageId\":\(parentMessageIdJSON),\"parentMessageContent\":\(parentContentJSON),\"content\":\(jsonString(message.content)),\"snippet\":\(jsonString(snippet)),\"channelArchivedAt\":\(archivedJSON)}"
            if let task = taskRecords.first(where: { $0.messageId == message.id }) {
                let amendedAt = task.amendedAt.map { jsonString(Self.isoString($0)) } ?? "null"
                let projection = "{\"title\":\(jsonString(task.title)),\"description\":\(task.description.map { jsonString($0) } ?? "null"),\"revision\":\(task.revision),\"superseded\":\(task.superseded ? "true" : "false"),\"amendedAt\":\(amendedAt),\"amendedByType\":\(task.amendedByType.map { jsonString($0) } ?? "null"),\"amendedByName\":\(task.amendedByName.map { jsonString($0) } ?? "null"),\"source\":\"tasks_current_projection\"}"
                row = String(row.dropLast()) + ",\"taskNumber\":\(task.taskNumber),\"taskCurrentProjection\":\(projection)}"
            }
            return row
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"results\":[\(results)],\"hasMore\":\(hasMore ? "true" : "false")}")
    }

    /// `GET /api/messages/search`. Relevance ranks by how often `q` appears. `sort=recent` uses `createdAt`.
    public func agentApiSearch(
        authorization: String?,
        query: String?,
        channelRef: String?,
        senderRef: String?,
        sort: String?,
        limit: String?,
        managedAgentId: String? = nil,
        after: String? = nil,
        before: String? = nil,
        enhanced: Bool = false
    ) -> HTTPReply {
        let agent: OAuthLedger.AgentRuntimeInfo
        if let managedAgentId {
            guard let machineId = machineIdForCredential(authorization: authorization),
                  let info = oauth.agentRuntimeInfo(id: managedAgentId), !info.deleted,
                  info.serverId != "",
                  canMachineServeAgent(machineId: machineId, agent: info)
            else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            agent = info
        } else {
            guard let credential = agentCredentialAgent(authorization),
                  let info = oauth.agentRuntimeInfo(id: credential.agentId), !info.deleted
            else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            guard credential.scopes.contains("read") else {
                return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
            }
            agent = info
        }
        var afterDate: Date?
        var beforeDate: Date?
        for (label, raw) in [("after", after), ("before", before)] {
            guard let raw, !raw.isEmpty else { continue }
            guard raw.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
                return Self.json(400, "{\"error\":\"The \(label) filter is missing a timezone offset (for example +08:00); pass one from the raft CLI\",\"errorCode\":\"INVALID_DATE_FILTER\"}")
            }
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var parsed = parser.date(from: raw)
            if parsed == nil {
                parser.formatOptions = [.withInternetDateTime]
                parsed = parser.date(from: raw)
            }
            guard let parsed else {
                return Self.json(400, "{\"error\":\"Invalid \(label) date filter\",\"errorCode\":\"INVALID_DATE_FILTER\"}")
            }
            if label == "after" { afterDate = parsed } else { beforeDate = parsed }
        }
        let pageLimit = min(max(Int(limit ?? "") ?? 20, 1), 100)
        let tokens = Self.searchTokens((query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let sortMode = sort == "recent" ? "recent" : "relevance"
        lock.lock()
        let channelFilter: String? = {
            guard let channelRef, !channelRef.isEmpty else { return nil }
            if channelRef.lowercased().hasPrefix("dm:@reminders") {
                return agentReminderSurfaceChannels[agent.id]
            }
            let name = channelRef.hasPrefix("#") ? String(channelRef.dropFirst()) : channelRef
            return postableChannels.first { _, channel in
                channel.serverId == agent.serverId && channel.name == name
            }?.key
        }()
        // A sender filter resolves through the member directory first. A name
        // the caller may not see is the same `member_not_found` as an unknown
        // one, so the query cannot enumerate a hidden human directory.
        var senderScope: String?
        if let senderRef, !senderRef.isEmpty {
            let handle = senderRef.hasPrefix("@") ? String(senderRef.dropFirst()) : senderRef
            let directoryHidden = hideHumansFromMembers[agent.serverId] == true
                && oauth.agentRole(serverId: agent.serverId, agentId: agent.id) == "member"
            let agentMatch = oauth.activeAgentIds(serverId: agent.serverId).first {
                oauth.agentRuntimeInfo(id: $0)?.name.lowercased() == handle.lowercased()
            }
            let humanMatches: [String] = directoryHidden
                ? []
                : accounts.values.filter { account in
                    account.name.lowercased() == handle.lowercased()
                        || (account.displayName ?? "").lowercased() == handle.lowercased()
                }.map(\.id)
            if agentMatch != nil && !humanMatches.isEmpty {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Member reference is ambiguous\",\"errorCode\":\"ambiguous_member_ref\"}")
            }
            if humanMatches.count > 1 {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Member reference is ambiguous\",\"errorCode\":\"ambiguous_member_ref\"}")
            }
            let humanMatch = humanMatches.first
            guard let resolvedSender = agentMatch ?? humanMatch else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Member not found\",\"errorCode\":\"member_not_found\"}")
            }
            senderScope = resolvedSender
        }
        var hits: [(message: StoredHumanMessage, score: Int)] = []
        for message in humanMessageRows where messageSearchVisibleLocked(
            messageChannelId: message.channelId,
            serverId: agent.serverId,
            viewer: .agent(agent.id)
        ) {
            if let channelFilter, message.channelId != channelFilter { continue }
            if let senderScope, message.senderId != senderScope { continue }
            if let afterDate, message.createdAt <= afterDate { continue }
            if let beforeDate, message.createdAt >= beforeDate { continue }
            let counts = Self.tokenCounts(message.content)
            if tokens.isEmpty {
                hits.append((message, 0))
            } else if let score = Self.matchScore(counts, tokens, requireAll: true) {
                hits.append((message, score))
            } else if tokens.count > 1, let score = Self.matchScore(counts, tokens, requireAll: false) {
                hits.append((message, score))
            }
        }
        hits.sort { lhs, rhs in
            if sortMode == "recent" { return lhs.message.createdAt > rhs.message.createdAt }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.message.createdAt > rhs.message.createdAt
        }
        let hasMore = hits.count > pageLimit
        let page = hits.prefix(pageLimit)
        let rows = page.map { hit -> String in
            let message = hit.message
            let channel = postableChannels[message.channelId]
            let parentId = (channel?.kind == "thread" ? channel?.parentChannelId : nil) ?? message.channelId
            let senderName: String
            if message.senderType == "agent" {
                let runtime = oauth.agentRuntimeInfo(id: message.senderId)
                senderName = runtime.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? ""
            } else {
                let account = accounts.values.first { $0.id == message.senderId }
                senderName = account.map { ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.name } ?? ""
            }
            let senderType = message.senderType == "agent" ? "agent" : "human"
            let channelName = channel?.name ?? ""
            let snippet = Self.searchSnippet(message.content)
            var row = "{\"id\":\(jsonString(message.id)),\"content\":\(jsonString(message.content)),\"senderName\":\(jsonString(senderName)),\"senderType\":\(jsonString(senderType)),\"senderId\":\(jsonString(message.senderId)),\"channelId\":\(jsonString(message.channelId)),\"channelName\":\(jsonString(channelName)),\"parentChannelId\":\(jsonString(parentId)),\"snippet\":\(jsonString(snippet))}"
            if enhanced {
                let channelType = channel?.kind ?? "channel"
                let threadId = channel?.kind == "thread" ? message.channelId : ""
                let parentMessageId = channel?.kind == "thread" ? (channel?.parentMessageId ?? "") : ""
                let parentContent: String
                if !parentMessageId.isEmpty,
                   let parent = humanMessageRows.first(where: { $0.id == parentMessageId }) {
                    parentContent = parent.content
                } else {
                    parentContent = ""
                }
                row += ",\"channelType\":\(jsonString(channelType)),\"threadId\":\(threadId.isEmpty ? "null" : jsonString(threadId)),\"parentMessageId\":\(parentMessageId.isEmpty ? "null" : jsonString(parentMessageId)),\"parentMessageContent\":\(parentContent.isEmpty ? "null" : jsonString(parentContent))"
                if let task = taskRecords.first(where: { $0.messageId == message.id }) {
                    let amendedAt = task.amendedAt.map { jsonString(Self.isoString($0)) } ?? "null"
                    let projection = "{\"title\":\(jsonString(task.title)),\"description\":\(task.description.map { jsonString($0) } ?? "null"),\"revision\":\(task.revision),\"superseded\":\(task.superseded ? "true" : "false"),\"amendedAt\":\(amendedAt),\"amendedByType\":\(task.amendedByType.map { jsonString($0) } ?? "null"),\"amendedByName\":\(task.amendedByName.map { jsonString($0) } ?? "null"),\"source\":\"tasks_current_projection\"}"
                    row += ",\"taskNumber\":\(task.taskNumber),\"taskCurrentProjection\":\(projection)"
                }
            }
            return row
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"results\":[\(rows)],\"hasMore\":\(hasMore ? "true" : "false")}")
    }

    public func searchHumanMessages(query: String?, sort: String?, limit: String?, authorization: String?, serverId: String?, channelId: String? = nil, senderId: String? = nil, senderType: String? = nil, mentionTarget: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        let sortMode: String
        if let sort, !sort.isEmpty {
            guard sort == "relevance" || sort == "recent" else {
                return Self.json(400, "{\"error\":\"Invalid search sort\"}")
            }
            sortMode = sort
        } else {
            sortMode = "relevance"
        }
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pageLimit: Int
        if let limit, let parsed = Int(limit), parsed > 0 {
            pageLimit = min(parsed, 100)
        } else {
            pageLimit = 20
        }
        let scopedSenderType: String?
        if let senderType, !senderType.isEmpty {
            guard senderType == "user" || senderType == "agent" else {
                return Self.json(400, "{\"error\":\"Invalid sender type\"}")
            }
            scopedSenderType = senderType
        } else {
            scopedSenderType = nil
        }
        let mentionSelf: Bool
        if let mentionTarget, !mentionTarget.isEmpty {
            guard mentionTarget == "self" else {
                return Self.json(400, "{\"error\":\"Invalid mention target\"}")
            }
            mentionSelf = true
        } else {
            mentionSelf = false
        }
        let queryTokens = Self.searchTokens(needle)
        let scopedChannel = (channelId?.isEmpty == false) ? channelId : nil
        let scopedSender = (senderId?.isEmpty == false) ? senderId : nil
        if queryTokens.isEmpty && scopedChannel == nil && scopedSender == nil && scopedSenderType == nil && !mentionSelf {
            return Self.json(200, "{\"results\":[],\"hasMore\":false}")
        }
        let effectiveSort = queryTokens.isEmpty ? "recent" : sortMode
        lock.lock()
        if let scopedChannel {
            guard let channel = postableChannels[scopedChannel],
                  channel.serverId == serverId,
                  channel.deletedAt == nil,
                  channel.kind == "channel" || channel.memberIds.contains(userId)
            else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
        }
        func accepts(_ message: StoredHumanMessage) -> Bool {
            guard messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: serverId, viewer: .user(userId)) else { return false }
            if let scopedSender, message.senderId != scopedSender { return false }
            if let scopedSenderType, message.senderType != scopedSenderType { return false }
            if mentionSelf && !storedMentions.contains(where: { $0.messageId == message.id && $0.targetType == "user" && $0.targetId == userId }) {
                return false
            }
            if let scopedChannel {
                if message.channelId == scopedChannel { return true }
                let channel = postableChannels[message.channelId]
                return channel?.kind == "thread" && channel?.parentChannelId == scopedChannel
            }
            return true
        }
        var strict: [(StoredHumanMessage, Int)] = []
        var relaxed: [(StoredHumanMessage, Int)] = []
        var browse: [(StoredHumanMessage, Int)] = []
        for message in humanMessageRows where accepts(message) {
            if queryTokens.isEmpty {
                browse.append((message, 0))
                continue
            }
            let counts = Self.tokenCounts(message.content)
            if let score = Self.matchScore(counts, queryTokens, requireAll: true) {
                strict.append((message, score))
            } else if queryTokens.count > 1, let score = Self.matchScore(counts, queryTokens, requireAll: false) {
                relaxed.append((message, score))
            }
        }
        let fallbackUsed = !queryTokens.isEmpty && strict.isEmpty && !relaxed.isEmpty
        var hits = queryTokens.isEmpty ? browse : (fallbackUsed ? relaxed : strict)
        if effectiveSort == "recent" {
            hits.sort { $0.0.createdAt > $1.0.createdAt }
        } else {
            hits.sort { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.createdAt > rhs.0.createdAt
            }
        }
        let hasMore = !fallbackUsed && hits.count > pageLimit
        let page = hits.prefix(pageLimit)
        let results = page.map { pair in
            let message = pair.0
            let channel = postableChannels[message.channelId]
            let parentId = (channel?.kind == "thread" ? channel?.parentChannelId : nil) ?? message.channelId
            let snippet = Self.searchSnippet(message.content)
            let archivedJSON: String
            if let archivedAt = oauth.channelArchivedAt(id: parentId) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                archivedJSON = jsonString(formatter.string(from: archivedAt))
            } else {
                archivedJSON = "null"
            }
            return "{\"id\":\(jsonString(message.id)),\"senderId\":\(jsonString(message.senderId)),\"senderType\":\(jsonString(message.senderType)),\"channelId\":\(jsonString(message.channelId)),\"parentChannelId\":\(jsonString(parentId)),\"content\":\(jsonString(message.content)),\"snippet\":\(jsonString(snippet)),\"channelArchivedAt\":\(archivedJSON)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"results\":[\(results)],\"hasMore\":\(hasMore ? "true" : "false")}")
    }


    /// Latin words stay whole. Each CJK character is its own token, so a query that shares no full phrase can still match a character.



    /// Strict mode requires every query token. Relaxed mode sums the tokens that do appear.

    /// Context for a human message that is not in the permalink catalog. A DM short id resolves only for a participant.
    public func humanMessageContext(messageId: String, channelId: String?, authorization: String?, serverId: String?, before: String? = nil, after: String? = nil) -> HTTPReply? {
        guard MessageContext.isShortId(messageId) || ServerScope.isUUID(messageId) else { return nil }
        guard let channelId, ServerScope.isUUID(channelId) else { return nil }
        guard let userId = sessionUserId(authorization: authorization) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil,
              channel.kind == "channel" || channel.memberIds.contains(userId)
        else { return nil }
        let storageChannelId = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId ?? channelId
        let rows = humanMessageRows.filter { $0.channelId == storageChannelId || $0.channelId == channelId }
        let matches = rows.filter { Self.messageIdMatches($0.id, messageId) }
        if matches.count == 1, let message = matches.first, let index = rows.firstIndex(where: { $0.id == message.id }) {
            let beforeCount = Self.contextWindowSide(before)
            let afterCount = Self.contextWindowSide(after)
            let start = max(0, index - beforeCount)
            let end = min(rows.count, index + 1 + afterCount)
            let parts = rows[start..<end].map { row -> String in
                let seq = row.seq
                let commentsVisible = attachmentCommentsEnabled(serverId: serverId ?? "", userId: userId)
                let metadata = forwardMetadataJSONLocked(messageId: row.id, userId: userId, serverId: serverId)
                    ?? actionCardMetadataLocked(messageId: row.id)
                var json = "{\"id\":\(jsonString(row.id)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(row.content)),\"seq\":\(seq),\"attachments\":[\(messageAttachmentsJSONLocked(row.attachmentIds, commentsVisible: commentsVisible))]"
                if let commentRef = commentRefJSONLocked(messageId: row.id), commentsVisible {
                    json += ",\"commentRef\":\(commentRef)"
                }
                if let metadata {
                    json += ",\"actionMetadata\":\(metadata)"
                }
                json += "}"
                return json
            }
            let windowIds = rows[start..<end].map(\.id)
            return Self.contextJSON(
                channelId: channelId,
                message: message,
                seq: message.seq,
                archived: channel.archived,
                canonical: nil,
                messagesJSON: parts.joined(separator: ","),
                hasOlder: start > 0,
                hasNewer: end < rows.count,
                threadSummariesJSON: threadSummariesJSONLocked(parentChannelId: channelId, parentIds: windowIds)
            )
        }
        for link in jointProjections where link.serverId == serverId {
            guard let localThread = postableChannels[link.localChannelId],
                  localThread.kind == "thread",
                  localThread.parentChannelId == channelId,
                  localThread.deletedAt == nil,
                  localThread.memberIds.contains(userId)
            else { continue }
            guard let reply = humanMessageRows.first(where: {
                $0.channelId == link.canonicalChannelId && Self.messageIdMatches($0.id, messageId)
            }) else { continue }
            let canonicalThreadId = link.localChannelId
            let canonical = "{\"kind\":\"thread\",\"channelId\":\(jsonString(channelId)),\"messageId\":\(jsonString(reply.id)),\"threadParentMessageId\":\(jsonString(localThread.parentMessageId ?? "")),\"threadChannelId\":\(jsonString(canonicalThreadId))}"
            return Self.contextJSON(
                channelId: canonicalThreadId,
                message: reply,
                seq: 1,
                archived: localThread.archived,
                canonical: canonical
            )
        }
        let replies = humanMessageRows.filter { row in
            guard Self.messageIdMatches(row.id, messageId),
                  let thread = postableChannels[row.channelId],
                  thread.kind == "thread",
                  thread.serverId == serverId,
                  thread.deletedAt == nil,
                  let parentMessageId = thread.parentMessageId,
                  let parent = humanMessageRows.first(where: { $0.id == parentMessageId }),
                  parent.channelId == channelId
            else { return false }
            return true
        }
        if replies.count == 1, let reply = replies.first, let thread = postableChannels[reply.channelId] {
            let threadRows = humanMessageRows.filter { $0.channelId == reply.channelId }
            let seq = (threadRows.firstIndex { $0.id == reply.id } ?? 0) + 1
            let canonical = "{\"kind\":\"thread\",\"channelId\":\(jsonString(channelId)),\"messageId\":\(jsonString(reply.id)),\"threadParentMessageId\":\(jsonString(thread.parentMessageId ?? "")),\"threadChannelId\":\(jsonString(reply.channelId))}"
            return Self.contextJSON(channelId: reply.channelId, message: reply, seq: seq, archived: thread.archived, canonical: canonical)
        }
        let threadChannels = postableChannels.filter { id, thread in
            thread.kind == "thread"
                && thread.serverId == serverId
                && thread.deletedAt == nil
                && Self.messageIdMatches(id, messageId)
                && thread.parentMessageId.flatMap { parentId in
                    humanMessageRows.first { $0.id == parentId && $0.channelId == channelId }
                } != nil
        }
        guard threadChannels.count == 1,
              let parentMessageId = threadChannels.values.first?.parentMessageId,
              let parent = humanMessageRows.first(where: { $0.id == parentMessageId && $0.channelId == channelId })
        else { return nil }
        let seq = (rows.firstIndex { $0.id == parent.id } ?? 0) + 1
        return Self.contextJSON(channelId: parent.channelId, message: parent, seq: seq, archived: channel.archived, canonical: nil)
    }




    /// Turns on Computer and App references for one server. Installed apps stay empty until recorded separately.
    public func allowComposerResourceReferences(serverId: String) {
        lock.lock()
        composerResourceServers.insert(serverId)
        lock.unlock()
    }

    /// Fixture seam: an unresolved outsider mention authored by an agent.
    public func addPendingAgentMentionForTesting(
        messageId: String,
        channelId: String,
        senderAgentId: String,
        targetType: String,
        targetId: String,
        handle: String,
        createdAt: Date = Date()
    ) -> String {
        lock.lock()
        let id = UUID().uuidString.lowercased()
        storedMentions.append(StoredMention(
            id: id,
            messageId: messageId,
            channelId: channelId,
            senderId: senderAgentId,
            targetType: targetType,
            targetId: targetId,
            handle: handle,
            notifiableAtSend: false,
            createdAt: createdAt,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil
        ))
        lock.unlock()
        return id
    }

    /// Whether a stored mention is still a pending sender-side action.
    func pendingAgentMentionLocked(_ mention: StoredMention, agentId: String) -> Bool {
        guard mention.senderId == agentId,
              mention.notifiedAt == nil,
              !mention.notifiableAtSend,
              Date().timeIntervalSince(mention.createdAt) < 7 * 24 * 60 * 60,
              let channel = postableChannels[mention.channelId],
              channel.serverId == pendingAgentMentionServer(agentId: agentId),
              humanMessageRows.contains(where: { $0.id == mention.messageId })
        else { return false }
        return true
    }

    func pendingAgentMentionServer(agentId: String) -> String? {
        oauth.agentRuntimeInfo(id: agentId)?.serverId
    }

    /// `GET /internal/agent-api/mention-actions/pending`. Sender-side outsider
    /// mentions authored by the bound agent whose delivery was withheld.
    public func agentMentionActionsPending(authorization: String?) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            lock.lock()
            var rows = storedMentions.filter { pendingAgentMentionLocked($0, agentId: agentId) }
            rows.sort { $0.createdAt > $1.createdAt }
            let limit = 50
            let hasMore = rows.count > limit
            let page = rows.prefix(limit).map { mention -> String in
                let channelName = postableChannels[mention.channelId]?.name ?? ""
                return "{\"resolutionId\":\(jsonString(mention.id)),\"messageId\":\(jsonString(mention.messageId)),\"channelId\":\(jsonString(mention.channelId)),\"channelName\":\(jsonString(channelName)),\"targetType\":\(jsonString(mention.targetType)),\"targetId\":\(jsonString(mention.targetId)),\"targetHandle\":\(jsonString(mention.handle)),\"availableActions\":[\"notify\"]}"
            }
            lock.unlock()
            return Self.json(200, "{\"pendingMentionActions\":[\(page.joined(separator: ","))],\"has_more\":\(hasMore)}")
        }
    }

    /// `POST /internal/agent-api/mention-actions/execute`. Every id is
    /// revalidated at action time and returns a typed per-id status.
    public func agentMentionActionsExecute(authorization: String?, body: String) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
            guard let action = object["action"] as? String, action == "notify" || action == "add" else {
                return Self.json(400, "{\"error\":\"action must be notify or add\"}")
            }
            var seen = Set<String>()
            var ids: [String] = []
            let rawIds = (object["resolutionIds"] as? [Any]) ?? (object["ids"] as? [Any]) ?? []
            for raw in rawIds {
                guard let text = raw as? String else { continue }
                let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                ids.append(id)
                if ids.count == 100 { break }
            }
            guard !ids.isEmpty else {
                return Self.json(400, "{\"error\":\"resolutionIds must include at least one id\"}")
            }
            lock.lock()
            defer { lock.unlock() }
            var results: [String] = []
            for id in ids {
                guard let index = storedMentions.firstIndex(where: { $0.id == id }),
                      storedMentions[index].senderId == agentId,
                      postableChannels[storedMentions[index].channelId]?.serverId == agent.serverId,
                      humanMessageRows.contains(where: { $0.id == storedMentions[index].messageId })
                else {
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\(jsonString(action)),\"status\":\"not_found\"}")
                    continue
                }
                if action == "notify" {
                    guard mentionTargetCanReadLocked(
                        channelId: storedMentions[index].channelId,
                        targetType: storedMentions[index].targetType,
                        targetId: storedMentions[index].targetId
                    ) else {
                        results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"no_permission\",\"reason\":\"target_lacks_read_access\"}")
                        continue
                    }
                    let messageId = storedMentions[index].messageId
                    let targetType = storedMentions[index].targetType
                    let targetId = storedMentions[index].targetId
                    var deduped = [id]
                    for other in storedMentions.indices where storedMentions[other].messageId == messageId
                        && storedMentions[other].targetType == targetType
                        && storedMentions[other].targetId == targetId
                        && storedMentions[other].notifiedAt == nil {
                        storedMentions[other].notifiedAt = Date()
                        storedMentions[other].notifiedByType = "agent"
                        storedMentions[other].notifiedById = agentId
                        storedMentions[other].notifiedAction = "notify_only"
                        if storedMentions[other].id != id { deduped.append(storedMentions[other].id) }
                    }
                    let dedupedJSON = deduped.map(jsonString).joined(separator: ",")
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"queued\",\"dedupedResolutionIds\":[\(dedupedJSON)]}")
                } else {
                    let senderStillVisible = mentionSenderStillInChannelLocked(
                        channelId: storedMentions[index].channelId,
                        agentId: agentId
                    )
                    guard senderStillVisible else {
                        results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"no_permission\",\"reason\":\"sender_lacks_channel_access\"}")
                        continue
                    }
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"no_permission\",\"reason\":\"add_requires_human_member_authority\"}")
                }
            }
            return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action)),\"results\":[\(results.joined(separator: ","))]}")
        }
    }

    /// `add` authority is participant-scoped: an agent that only has read
    /// access to a public channel is not a channel member for this action.
    func mentionSenderStillInChannelLocked(channelId: String, agentId: String) -> Bool {
        guard let channel = postableChannels[channelId] else { return false }
        return channel.memberIds.contains(agentId) || oauth.channelAgentIds(channelId: channelId).contains(agentId)
    }

    /// `POST /api/messages/mention-actions/execute`. A resolution id belongs to the sender who wrote the mention.
    public func executeMentionActions(body: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String,
              action == "notify" || action == "add"
        else {
            return Self.json(400, "{\"error\":\"action must be notify or add\"}")
        }
        var seen = Set<String>()
        var resolutionIds: [String] = []
        for id in (object["resolutionIds"] as? [Any])?.compactMap({ $0 as? String }) ?? [] where !seen.contains(id) {
            seen.insert(id)
            resolutionIds.append(id)
            if resolutionIds.count == 100 { break }
        }
        if resolutionIds.isEmpty {
            return Self.json(400, "{\"error\":\"resolutionIds must include at least one id\"}")
        }
        var results: [String] = []
        for id in resolutionIds {
            guard let index = storedMentions.firstIndex(where: { $0.id == id }),
                  postableChannels[storedMentions[index].channelId]?.serverId == serverId,
                  storedMentions[index].senderId == userId
            else {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\(jsonString(action)),\"status\":\"not_found\"}")
                continue
            }
            if action == "notify" {
                if !mentionTargetCanReadLocked(
                    channelId: storedMentions[index].channelId,
                    targetType: storedMentions[index].targetType,
                    targetId: storedMentions[index].targetId
                ) {
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"no_permission\",\"reason\":\"target_lacks_read_access\"}")
                    continue
                }
                if storedMentions[index].notifiedAt == nil {
                    storedMentions[index].notifiedAt = Date()
                    storedMentions[index].notifiedByType = "user"
                    storedMentions[index].notifiedById = userId
                    storedMentions[index].notifiedAction = "notify_only"
                    if storedMentions[index].targetType == "agent" {
                        storedAgentDeliveries.append((
                            agentId: storedMentions[index].targetId,
                            messageId: storedMentions[index].messageId,
                            channelType: "channel"
                        ))
                    }
                }
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"queued\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            } else if storedMentions[index].notifiedAction == "add" {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"delivered\",\"reason\":\"already_delivered\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            } else if !senderStillInChannelLocked(channelId: storedMentions[index].channelId, userId: userId) {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"no_permission\",\"reason\":\"sender_lacks_channel_access\"}")
            } else {
                storedMentions[index].notifiedAt = Date()
                storedMentions[index].notifiedByType = "user"
                storedMentions[index].notifiedById = userId
                storedMentions[index].notifiedAction = "add"
                let targetId = storedMentions[index].targetId
                let mentionChannelId = storedMentions[index].channelId
                if storedMentions[index].targetType == "agent" {
                    var agents = channelAgentMembers[mentionChannelId] ?? []
                    agents.insert(targetId)
                    channelAgentMembers[mentionChannelId] = agents
                    storedAgentDeliveries.append((
                        agentId: targetId,
                        messageId: storedMentions[index].messageId,
                        channelType: "channel"
                    ))
                } else {
                    postableChannels[mentionChannelId]?.memberIds.insert(targetId)
                }
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"delivered\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            }
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action)),\"results\":[\(results.joined(separator: ","))]}")
    }

    /// A removed channel member can no longer add someone through a mention they sent earlier.
    func senderStillInChannelLocked(channelId: String, userId: String) -> Bool {
        guard let stored = postableChannels[channelId] else { return false }
        if stored.kind == "thread", let parentId = stored.parentChannelId, let parent = postableChannels[parentId] {
            return parent.memberIds.contains(userId)
        }
        return stored.memberIds.contains(userId)
    }

    /// Public channels are readable by any signed-in user. Private surfaces and their threads require membership.
    func mentionTargetCanReadLocked(channelId: String, targetType: String, targetId: String) -> Bool {
        guard let stored = postableChannels[channelId] else { return false }
        let surface: PostableChannel
        let surfaceId: String
        if stored.kind == "thread", let parentId = stored.parentChannelId, let parent = postableChannels[parentId] {
            surface = parent
            surfaceId = parentId
        } else {
            surface = stored
            surfaceId = channelId
        }
        if targetType == "agent" {
            if surface.kind == "channel" { return true }
            return channelAgentMembers[surfaceId]?.contains(targetId) == true
                || channelAgentMembers[channelId]?.contains(targetId) == true
        }
        if surface.kind == "channel" { return true }
        return surface.memberIds.contains(targetId) || stored.memberIds.contains(targetId)
    }

    /// `POST /api/messages`. A bad human create body is refused before any message row exists.
    /// An App reference is refused before persistence when that app is not installed on the channel's server.
    public func createHumanMessage(body: String, authorization: String?, serverId: String?, contract: String = "v1") -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        if let serverId, !serverId.isEmpty,
           !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard Self.humanMessageBodyIsValid(body) else {
            return Self.json(400, "{\"error\":\"Invalid message request body\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelId = object["channelId"] as? String,
              let content = object["content"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid message request body\"}")
        }
        if let asTask = object["asTask"], !(asTask is Bool) {
            return Self.json(400, "{\"error\":\"asTask must be a boolean\"}")
        }
        lock.lock()
        let channel = postableChannels[channelId]
        let referencesEnabled = composerResourceServers.contains(channel?.serverId ?? "")
        let installed = installedServerApps[channel?.serverId ?? ""] ?? []
        lock.unlock()
        guard let channel, channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let parentMember = channel.kind == "thread"
            && (channel.parentChannelId.flatMap { postableChannels[$0] }?.memberIds.contains(userId) ?? false)
        guard channel.memberIds.contains(userId) || parentMember else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        // A thread inherits its parent's freeze: no writes under an archived parent.
        let parentArchived = channel.kind == "thread"
            && channel.parentChannelId.flatMap { oauth.channelArchivedAt(id: $0) } != nil
        if channel.archived || parentArchived {
            if oauth.memberRole(serverId: channel.serverId, userId: userId) == "guest" {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
        }
        let appIds = Self.appReferenceIds(content)
        if !appIds.isEmpty {
            if !referencesEnabled {
                return Self.json(400, "{\"error\":\"Computer and App references are not enabled in this server\"}")
            }
            if appIds.contains(where: { !installed.contains($0) }) {
                return Self.json(400, "{\"error\":\"App reference is not installed in this server\"}")
            }
        }
        let attachmentIds = (object["attachmentIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let typedMentions = Self.mentionInputs(object["mentions"])
        if Self.mentionBindingConflict(typedMentions) {
            return Self.json(400, "{\"error\":\"A mention handle is bound to more than one target\",\"code\":\"mention_binding_conflict\"}")
        }
        let mentionResolution = resolvedMessageMentions(
            serverId: serverId ?? "",
            senderId: userId,
            content: content,
            typed: typedMentions,
            warnUnresolved: contract == "v2"
        )
        let mentions = mentionResolution.mentions
        let unresolvedMentionHandles = mentionResolution.unresolved
        let senderTimezone = Self.parseOptionalIanaTimezone(object["timezone"])
        let reply: HTTPReply
        var createdMessage = false
        if object["randomId"] != nil {
            guard let randomId = object["randomId"] as? String, !randomId.isEmpty, randomId.count <= 128 else {
                return Self.json(400, "{\"error\":\"randomId must be a non-empty string with at most 128 characters\"}")
            }
            let stored = storeHumanMessage(channelId: channelId, senderId: userId, content: content, randomId: randomId, attachmentIds: attachmentIds, senderTimezone: senderTimezone, mentions: mentions)
            reply = stored.reply
            createdMessage = stored.created
        } else {
            let stored = storeHumanMessage(channelId: channelId, senderId: userId, content: content, randomId: nil, attachmentIds: attachmentIds, senderTimezone: senderTimezone, mentions: mentions)
            reply = stored.reply
            createdMessage = stored.created
        }
        if createdMessage, reply.status == 200,
           let data = reply.body.data(using: .utf8),
           let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messageId = stored["id"] as? String {
            recordMemberMentionRows(messageId: messageId, channelId: channelId, mentions: mentions)
        }
        if reply.status == 200, channel.kind == "thread", let parentMessageId = channel.parentMessageId {
            lock.lock()
            threadFollows["\(serverId ?? "")\n\(userId)\n\(channelId)"] = (
                serverId: serverId ?? "",
                userId: userId,
                threadChannelId: channelId,
                parentMessageId: parentMessageId
            )
            for mention in mentions where mention.type == "user" || mention.type == "agent" {
                guard ServerScope.isUUID(mention.id), mention.id != userId else { continue }
                let parent = channel.parentChannelId.flatMap { postableChannels[$0] }
                let parentAllowsHuman = parent?.kind == "channel" || parent?.memberIds.contains(mention.id) == true
                let parentAllowsAgent = parent?.kind == "channel"
                    || parent?.agentId == mention.id
                    || channel.parentChannelId.flatMap { channelAgentMembers[$0]?.contains(mention.id) } == true
                let valid: Bool
                if mention.type == "user" {
                    valid = parentAllowsHuman
                        && accounts.values.contains { $0.id == mention.id }
                        && oauth.memberRole(serverId: serverId ?? "", userId: mention.id) != nil
                } else {
                    valid = parentAllowsAgent
                        && oauth.agentRuntimeInfo(id: mention.id)?.serverId == serverId
                }
                if valid {
                    let suppressionKey = "\(serverId ?? "")\n\(mention.id)\n\(channelId)"
                    if threadUnfollows[suppressionKey] != nil {
                        // A direct mention reactivates a suppressed thread only for
                        // a member of the parent channel. An outsider mention stays
                        // hidden; it must not resurrect the follow.
                        guard channel.parentChannelId.flatMap({ postableChannels[$0] })?.memberIds.contains(mention.id) == true else {
                            continue
                        }
                        threadUnfollows.removeValue(forKey: suppressionKey)
                    }
                    threadFollows["\(serverId ?? "")\n\(mention.id)\n\(channelId)"] = (
                        serverId: serverId ?? "",
                        userId: mention.id,
                        threadChannelId: channelId,
                        parentMessageId: parentMessageId
                    )
                }
            }
            lock.unlock()
        }
        if contract == "v2" {
            return v2HumanSend(reply, channelId: channelId, mentions: mentions, unresolvedMentionHandles: unresolvedMentionHandles)
        }
        return withPendingMentionActions(reply, channelId: channelId, mentions: mentions)
    }

    /// `GET /api/messages/forward/enabled`. The rollout flag is retired, so this stays true.
    public func messageForwardEnabled(authorization: String?, serverId: String?) -> HTTPReply {
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let userId):
            guard isEmailVerified(userId: userId) else {
                return Self.json(403, "{\"error\":\"Email verification required\"}")
            }
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        return Self.json(200, "{\"enabled\":true}")
    }

    /// `GET /api/messages/forward/targets/search`. An empty query returns no targets.
    public func searchForwardTargets(query: String?, limit rawLimit: String?, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        lock.lock()
        let retired = accounts.values.first { $0.id == userId }?.retiredAt != nil
        lock.unlock()
        guard !retired else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return Self.json(200, "{\"targets\":[]}")
        }
        let pageLimit: Int
        if let rawLimit, let parsed = Int(rawLimit), parsed > 0 {
            pageLimit = min(parsed, 20)
        } else {
            pageLimit = 20
        }
        lock.lock()
        defer { lock.unlock() }
        let role = serverMemberRoles["\(serverId)\n\(userId)"]
        let isGuest = role == "guest"
        let hideHumans = hideHumansFromMembers[serverId] == true || isGuest
        var results: [(score: Int, title: String, json: String)] = []
        for (id, channel) in postableChannels where channel.serverId == serverId && channel.deletedAt == nil && !channel.archived {
            guard channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint" else { continue }
            let score = Self.forwardTargetScore(q, channel.name.lowercased())
            if score <= 0 { continue }
            let joined = channel.memberIds.contains(userId)
            if isGuest && !joined { continue }
            if channel.kind != "channel" && !joined { continue }
            let canForwardNow = channel.kind != "channel" || joined
            let required = channel.kind == "channel" && !joined ? "join_channel" : nil
            let title = "#\(channel.name)"
            results.append((
                score + (joined ? 50 : 0),
                title,
                Self.forwardTargetJSON(
                    type: "channel",
                    channelType: channel.kind,
                    id: id,
                    title: title,
                    subtitle: "",
                    avatarUrl: nil,
                    channelId: id,
                    joined: joined,
                    dmExists: nil,
                    canForwardNow: canForwardNow,
                    requiredAction: required
                )
            ))
        }
        var dmPeerIds = Set<String>()
        for (id, channel) in postableChannels where channel.serverId == serverId && channel.kind == "dm" && channel.deletedAt == nil && channel.memberIds.contains(userId) {
            let peerId = channel.agentId ?? channel.memberIds.first { $0 != userId }
            guard let peerId else { continue }
            dmPeerIds.insert(peerId)
            let agent = serverAgents[peerId]
            let account = accounts.values.first { $0.id == peerId }
            let label = agent?.name ?? account?.name ?? peerId
            let score = Self.forwardTargetScore(q, label.lowercased())
            if score <= 0 { continue }
            let title = "@\(label)"
            results.append((
                score + 50,
                title,
                Self.forwardTargetJSON(
                    type: "dm",
                    channelType: "dm",
                    id: peerId,
                    title: title,
                    subtitle: agent == nil ? "" : "agent",
                    avatarUrl: agent?.avatarUrl ?? account?.avatarUrl,
                    channelId: id,
                    joined: nil,
                    dmExists: true,
                    canForwardNow: true,
                    requiredAction: nil
                )
            ))
        }
        if !isGuest {
            for agent in serverAgents.values where agent.serverId == serverId && !dmPeerIds.contains(agent.id) {
                let score = Self.forwardTargetScore(q, agent.name.lowercased())
                if score <= 0 { continue }
                let title = "@\(agent.name)"
                results.append((
                    score,
                    title,
                    Self.forwardTargetJSON(
                        type: "agent",
                        channelType: nil,
                        id: agent.id,
                        title: title,
                        subtitle: "agent",
                        avatarUrl: agent.avatarUrl,
                        channelId: nil,
                        joined: nil,
                        dmExists: false,
                        canForwardNow: false,
                        requiredAction: "create_dm"
                    )
                ))
            }
        }
        if !hideHumans {
            for (key, memberRole) in serverMemberRoles {
                let parts = key.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, parts[0] == serverId, memberRole != "guest" else { continue }
                let memberId = parts[1]
                if memberId == userId || dmPeerIds.contains(memberId) { continue }
                guard let account = accounts.values.first(where: { $0.id == memberId }) else { continue }
                let score = Self.forwardTargetScore(q, account.name.lowercased())
                if score <= 0 { continue }
                let title = "@\(account.name)"
                results.append((
                    score,
                    title,
                    Self.forwardTargetJSON(
                        type: "human",
                        channelType: nil,
                        id: memberId,
                        title: title,
                        subtitle: "",
                        avatarUrl: account.avatarUrl,
                        channelId: nil,
                        joined: nil,
                        dmExists: false,
                        canForwardNow: false,
                        requiredAction: "create_dm"
                    )
                ))
            }
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title < rhs.title
        }
        let targets = results.prefix(pageLimit).map(\.json).joined(separator: ",")
        return Self.json(200, "{\"targets\":[\(targets)]}")
    }



    /// `POST /api/messages/forward`. An empty note becomes `Forwarded N message(s)` in the destination.
    public func forwardHumanMessage(body: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let destinationChannelId: String
        if let raw = object["destinationChannelId"] as? String {
            destinationChannelId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let raw = object["channelId"] as? String {
            destinationChannelId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            destinationChannelId = ""
        }
        let note: String?
        if object["note"] == nil || object["note"] is NSNull {
            note = ""
        } else if let raw = object["note"] as? String {
            note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            note = nil
        }
        let sourceIds = Self.forwardSourceIds(object["sourceMessageIds"])
        if object["destinationChannelIds"] != nil {
            guard let sourceIds, let note else {
                return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
            }
            if note.count > 32_000 {
                return Self.json(400, "{\"error\":\"Message content exceeds maximum length of 32000 characters\"}")
            }
            return forwardToMany(
                object: object,
                sourceIds: sourceIds,
                note: note,
                authorization: authorization,
                serverId: serverId
            )
        }
        guard !destinationChannelId.isEmpty, let sourceIds, let note else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        if note.count > 32_000 {
            return Self.json(400, "{\"error\":\"Message content exceeds maximum length of 32000 characters\"}")
        }
        let randomId: String
        if object["randomId"] == nil || object["randomId"] is NSNull {
            randomId = "forward-\(UUID().uuidString.lowercased())"
        } else if let raw = object["randomId"] as? String, !raw.isEmpty, raw.count <= 128 {
            randomId = raw
        } else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let content = note.isEmpty
            ? "Forwarded \(sourceIds.count) message\(sourceIds.count == 1 ? "" : "s")"
            : note
        lock.lock()
        if let existing = humanMessageRows.first(where: { $0.senderId == userId && $0.randomId == randomId }) {
            if existing.channelId == destinationChannelId,
               existing.content == content,
               let record = forwardRecords[existing.id],
               record.sourceIds == sourceIds {
                let snapshot = existing
                lock.unlock()
                return Self.forwardMessageReply(message: snapshot, record: record, outcome: "idempotent_replay")
            }
            lock.unlock()
            return Self.json(409, "{\"error\":\"This forward request id was already used for different content\",\"code\":\"idempotency_conflict\"}")
        }
        guard let destination = postableChannels[destinationChannelId],
              destination.serverId == serverId,
              destination.deletedAt == nil
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard destination.memberIds.contains(userId) else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"You must join this channel to send messages\"}")
        }
        var pending: [PendingForwardSource] = []
        for id in sourceIds {
            guard let message = humanMessageRows.first(where: { $0.id == id }) else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Source message not found\"}")
            }
            let jointLocalId = jointLocalChannelIdLocked(canonicalChannelId: message.channelId, serverId: serverId, userId: userId)
            let channel = jointLocalId.flatMap { postableChannels[$0] }
                ?? (messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: serverId, viewer: .user(userId))
                    ? postableChannels[message.channelId] : nil)
            guard let channel else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Source message not found\"}")
            }
            if message.actionKind == "forwarded-bundle" || forwardedBundles[message.id] != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Forwarded messages can't be forwarded. Select the original message instead.\",\"code\":\"forwarded_source_not_supported\"}")
            }
            if message.messageType != "chat" || message.actionKind != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Only ordinary chat messages can be forwarded\",\"code\":\"unsupported_source_message\"}")
            }
            let attachments = channelAttachments.values
                .filter { $0.messageId == message.id }
                .sorted { ($0.messagePosition ?? 0) < ($1.messagePosition ?? 0) }
            pending.append(PendingForwardSource(
                messageId: message.id,
                content: message.content,
                createdAt: message.createdAt,
                channelId: jointLocalId ?? message.channelId,
                channelKind: channel.kind,
                channelName: channel.name,
                parentChannelId: channel.parentChannelId,
                senderId: message.senderId,
                attachments: attachments
            ))
        }
        let selectedThreads = Set(pending.filter { $0.channelKind == "thread" }.map(\.channelId))
        let prepared = pending.map { source in
            (source, forwardContextLocked(source: source, selectedThreads: selectedThreads))
        }
        if Set(prepared.map { $0.1.bundleSourceId }).count != 1 {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Forwarded bundles must come from a single source\",\"code\":\"cross_source_bundle\"}")
        }
        let ordered = prepared.sorted { lhs, rhs in
            if lhs.1.sourceIsThreadParent != rhs.1.sourceIsThreadParent {
                return lhs.1.sourceIsThreadParent
            }
            if lhs.0.createdAt != rhs.0.createdAt { return lhs.0.createdAt < rhs.0.createdAt }
            return lhs.0.messageId < rhs.0.messageId
        }
        var legacy: [ForwardedSource] = []
        var itemRecords: [ForwardItemRecord] = []
        var projections: [(attachment: ChannelAttachment, id: String, position: Int)] = []
        var position = 0
        for (source, context) in ordered {
            let exposed = context.sourceTargetId != nil
            legacy.append(ForwardedSource(
                sourceServerId: exposed ? serverId : "",
                sourceTargetId: context.sourceTargetId ?? "",
                sourceMessageId: exposed ? source.messageId : "",
                snapshotId: context.snapshotId ?? "",
                snapshotType: context.snapshotType,
                snapshotLabel: context.snapshotLabel,
                snapshotLabelVisibility: context.snapshotLabelVisibility,
                provenanceState: "available"
            ))
            var snapshots: [ForwardAttachmentSnapshot] = []
            for attachment in source.attachments {
                let projectedId = UUID().uuidString.lowercased()
                snapshots.append(ForwardAttachmentSnapshot(
                    id: projectedId,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType ?? "",
                    sizeBytes: attachment.sizeBytes ?? 0,
                    width: attachment.width,
                    height: attachment.height
                ))
                projections.append((attachment, projectedId, position))
                position += 1
            }
            let exposesPointers = context.snapshotLabelVisibility == "public" && context.sourceTargetId != nil
            let uniqueName = accounts.values.first { $0.id == source.senderId }?.name ?? "unknown"
            itemRecords.append(ForwardItemRecord(
                sourceMessageId: source.messageId,
                exposesPointers: exposesPointers,
                sourceAuthorUniqueName: uniqueName,
                sourceIsThreadParent: context.sourceIsThreadParent,
                contentSnapshot: source.content,
                sourceTargetId: context.sourceTargetId,
                sourceThreadId: context.sourceThreadId,
                parentChannelId: context.parentChannelId,
                snapshotId: context.snapshotId,
                snapshotType: context.snapshotType,
                snapshotLabel: context.snapshotLabel,
                snapshotLabelVisibility: context.snapshotLabelVisibility,
                provenanceState: "available",
                attachments: snapshots,
                attachmentPolicy: snapshots.isEmpty ? "excluded" : "projected"
            ))
        }
        let storageChannelId = jointProjections.first { $0.localChannelId == destinationChannelId }?.canonicalChannelId ?? destinationChannelId
        let record = StoredForwardRecord(sourceIds: sourceIds, items: itemRecords, destinationTargetId: destinationChannelId)
        lock.unlock()
        let storedReply = storeHumanMessage(
            channelId: storageChannelId,
            senderId: userId,
            content: content,
            randomId: randomId,
            attachmentIds: []
        ).reply
        guard storedReply.status == 200,
              let data = storedReply.body.data(using: .utf8),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = stored["id"] as? String
        else { return storedReply }
        lock.lock()
        forwardedBundles[messageId] = legacy
        forwardRecords[messageId] = record
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].attachmentIds = projections.map(\.id)
        }
        for projection in projections {
            var copy = projection.attachment
            copy.id = projection.id
            copy.channelId = destinationChannelId
            copy.messageId = messageId
            copy.messagePosition = projection.position
            channelAttachments[copy.id] = copy
        }
        guard var message = humanMessageRows.first(where: { $0.id == messageId }) else {
            lock.unlock()
            return storedReply
        }
        lock.unlock()
        message.channelId = destinationChannelId
        return Self.forwardMessageReply(message: message, record: record, outcome: "success")
    }

}
