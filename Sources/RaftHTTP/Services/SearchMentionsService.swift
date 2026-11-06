import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The message-search boundary: the human search route, the managed-agent
/// search route, the machine-keyed agent search and the fallback message
/// context, plus the channel soft-delete that hides a channel from search.
///
/// The state transitions stay on `EmailLoginDirectory` with unchanged
/// signatures, so every existing caller and test compiles untouched. This type
/// is the `Service` boundary the routes call.
public struct SearchMentionsService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// `GET /api/messages/search`.
    public func searchHumanMessages(
        query: String?,
        sort: String?,
        limit: String?,
        authorization: String?,
        serverId: String?,
        channelId: String? = nil,
        senderId: String? = nil,
        senderType: String? = nil,
        mentionTarget: String? = nil
    ) -> HTTPReply {
        directory.searchHumanMessages(
            query: query,
            sort: sort,
            limit: limit,
            authorization: authorization,
            serverId: serverId,
            channelId: channelId,
            senderId: senderId,
            senderType: senderType,
            mentionTarget: mentionTarget
        )
    }

    /// `GET /internal/agent/:agentId/search`.
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
        directory.searchAgentMessages(
            agentId: agentId,
            query: query,
            limit: limit,
            authorization: authorization,
            sender: sender,
            after: after,
            before: before,
            sort: sort
        )
    }

    /// `GET /internal/agent-api/search`.
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
        directory.agentApiSearch(
            authorization: authorization,
            query: query,
            channelRef: channelRef,
            senderRef: senderRef,
            sort: sort,
            limit: limit,
            managedAgentId: managedAgentId,
            after: after,
            before: before,
            enhanced: enhanced
        )
    }

    /// `GET /api/messages/context/:messageId` fallback when the permalink
    /// catalog has no row for the id.
    public func humanMessageContext(
        messageId: String,
        channelId: String?,
        authorization: String?,
        serverId: String?,
        before: String? = nil,
        after: String? = nil
    ) -> HTTPReply? {
        directory.humanMessageContext(
            messageId: messageId,
            channelId: channelId,
            authorization: authorization,
            serverId: serverId,
            before: before,
            after: after
        )
    }

    /// `DELETE /api/channels/:channelId`.
    public func deleteChannel(
        channelId: String,
        authorization: String?,
        serverId: String?
    ) -> HTTPReply {
        directory.deleteChannel(
            channelId: channelId,
            authorization: authorization,
            serverId: serverId
        )
    }
}

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




}
