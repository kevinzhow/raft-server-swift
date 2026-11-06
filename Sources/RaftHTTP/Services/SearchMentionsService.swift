import Foundation

/// Domain failure for the search, stored-context and channel-delete surface.
///
/// Every case names one published refusal. The legacy handlers built those
/// bodies by hand; `Respond.swift` now renders them from `errorBody`, so a
/// body whose second key is `errorCode` (not the default `code`) keeps its
/// exact member order and bytes.
public enum SearchMentionsError: DomainError, Equatable, Sendable {
    /// `DELETE /api/channels/:channelId` without a bearer authorization header.
    case missingAuthorization
    /// A bearer header that does not resolve to a live session.
    case invalidAccessToken
    case channelNotFound
    case forbidden
    case invalidSearchSort
    case invalidSenderType
    case invalidMentionTarget
    /// `GET /internal/agent/:agentId/search` without a bearer header.
    case agentSearchMissingAuthorization
    /// The machine key does not belong to the requested agent.
    case agentSearchInvalidToken
    /// A sender handle the caller may not see, or an unknown one.
    case memberNotFound
    /// An agent + human handle collision (`/internal/agent/:id/search`).
    case ambiguousMemberHandle
    /// A human + human or agent + human collision (`/internal/agent-api/search`).
    case ambiguousMemberReference
    /// `after`/`before` without a timezone offset (machine-keyed search).
    case agentSearchMissingOffset(label: String)
    /// `after`/`before` that is not an ISO-8601 instant (machine-keyed search).
    case agentSearchInvalidInstant(label: String)
    /// `after`/`before` without a timezone offset (agent API search).
    case agentApiMissingOffset(label: String)
    /// `after`/`before` that is not an ISO-8601 instant (agent API search).
    case agentApiInvalidDate(label: String)
    /// A credential that lacks the `read` scope.
    case capabilityNotAuthorized

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidAccessToken,
             .agentSearchMissingAuthorization, .agentSearchInvalidToken:
            401
        case .forbidden, .capabilityNotAuthorized:
            403
        case .channelNotFound, .memberNotFound:
            404
        case .ambiguousMemberHandle, .ambiguousMemberReference:
            409
        case .invalidSearchSort, .invalidSenderType, .invalidMentionTarget,
             .agentSearchMissingOffset, .agentSearchInvalidInstant,
             .agentApiMissingOffset, .agentApiInvalidDate:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization, .agentSearchMissingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidAccessToken, .agentSearchInvalidToken:
            "Invalid or expired token"
        case .channelNotFound:
            "Channel not found"
        case .forbidden:
            "Forbidden"
        case .invalidSearchSort:
            "Invalid search sort"
        case .invalidSenderType:
            "Invalid sender type"
        case .invalidMentionTarget:
            "Invalid mention target"
        case .memberNotFound:
            "Member not found"
        case .ambiguousMemberHandle:
            "Member handle is ambiguous"
        case .ambiguousMemberReference:
            "Member reference is ambiguous"
        case .agentSearchMissingOffset(let label):
            "\(label) filter is missing a timezone offset; add an explicit offset such as +08:00 (raft CLI adds it automatically)"
        case .agentSearchInvalidInstant(let label):
            "\(label) filter is not a valid ISO-8601 instant"
        case .agentApiMissingOffset(let label):
            "The \(label) filter is missing a timezone offset (for example +08:00); pass one from the raft CLI"
        case .agentApiInvalidDate(let label):
            "Invalid \(label) date filter"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        }
    }

    /// The auth refusals that always publish `{"error":…,"code":"auth_required"}`.
    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidAccessToken,
             .agentSearchMissingAuthorization, .agentSearchInvalidToken:
            "auth_required"
        case .capabilityNotAuthorized:
            "capability_not_authorized"
        case .channelNotFound, .forbidden, .invalidSearchSort, .invalidSenderType,
             .invalidMentionTarget, .memberNotFound, .ambiguousMemberHandle,
             .ambiguousMemberReference, .agentSearchMissingOffset,
             .agentSearchInvalidInstant, .agentApiMissingOffset, .agentApiInvalidDate:
            nil
        }
    }

    /// Date-filter, member-lookup and member-reference refusals publish their
    /// machine-readable key as `errorCode`, not the default `code`.
    public var errorBody: OrderedJSON? {
        switch self {
        case .memberNotFound:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "member_not_found"),
            ])
        case .ambiguousMemberHandle, .ambiguousMemberReference:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "ambiguous_member_ref"),
            ])
        case .agentSearchMissingOffset, .agentApiMissingOffset,
             .agentSearchInvalidInstant, .agentApiInvalidDate:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "INVALID_DATE_FILTER"),
            ])
        case .missingAuthorization, .invalidAccessToken,
             .agentSearchMissingAuthorization, .agentSearchInvalidToken,
             .channelNotFound, .forbidden, .invalidSearchSort, .invalidSenderType,
             .invalidMentionTarget, .capabilityNotAuthorized:
            return nil
        }
    }
}

// MARK: - Injected dependencies

// MARK: - Service

/// The search and mentions boundary: human and agent message search, the
/// stored message-context fallback, the shared message-visibility policy and
/// the channel soft-delete that hides a channel from search.
///
/// Every operation returns a published DTO or throws a `SearchMentionsError`;
/// the service builds no HTTP reply, header set or JSON string. The channel
/// soft-delete takes one `ServersAndChannelsStore` critical section for the
/// row it owns, then one `TasksAndRemindersStore` critical section for the
/// task rows that store owns.
public struct SearchMentionsService: Sendable {
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let profiles: AuthProfileStore
    private let machines: MachinesAndComputersStore
    private let agents: AgentsRuntimeStore
    private let tasks: TasksAndRemindersStore
    private let feedback: FeedbackStore
    private let oauth: OAuthLedger
    private let dependencies: SearchMentionsDependencies

    init(
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        profiles: AuthProfileStore,
        machines: MachinesAndComputersStore,
        agents: AgentsRuntimeStore,
        tasks: TasksAndRemindersStore,
        feedback: FeedbackStore,
        oauth: OAuthLedger,
        dependencies: SearchMentionsDependencies
    ) {
        self.channels = channels
        self.messages = messages
        self.profiles = profiles
        self.machines = machines
        self.agents = agents
        self.tasks = tasks
        self.feedback = feedback
        self.oauth = oauth
        self.dependencies = dependencies
    }

    // MARK: - Shared visibility policy

    /// A public channel is searchable by anyone on the server. A thread
    /// follows its parent, and a deleted parent hides the thread. Archived
    /// channels stay searchable.
    ///
    /// This is the policy the agent-send, integrations and human-message
    /// domains call through the directory accessor; it used to live in the
    /// search extension.
    func messageVisible(messageChannelId: String, serverId: String?, viewer: SearchViewer) -> Bool {
        return Self.visible(
            messageChannelId: messageChannelId,
            serverId: serverId,
            viewer: viewer,
            channels: channels.state.postableChannels,
            channelAgentMembers: agents.channelAgentMembers,
            oauth: oauth
        )
    }

    private static func visible(
        messageChannelId: String,
        serverId: String?,
        viewer: SearchViewer,
        channels: [String: PostableChannel],
        channelAgentMembers: [String: Set<String>],
        oauth: OAuthLedger
    ) -> Bool {
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
        guard let channel = channels[messageChannelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return false }
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId,
                  let parent = channels[parentId],
                  parent.serverId == serverId,
                  parent.deletedAt == nil
            else { return false }
            return parent.kind == "channel" || isMember(parentId, parent) || isMember(messageChannelId, channel)
        }
        return channel.kind == "channel" || channel.kind == "joint" || isMember(messageChannelId, channel)
    }

    // MARK: - GET /api/messages/search

    /// Relevance ranks by how often `q` appears. `sort=recent` uses
    /// `createdAt`. A query with no tokens and no filter returns an empty page.
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
    ) throws -> HumanMessageSearchResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw authorization?.hasPrefix("Bearer ") == true
                ? SearchMentionsError.invalidAccessToken
                : SearchMentionsError.missingAuthorization
        }
        let sortMode: String
        if let sort, !sort.isEmpty {
            guard sort == "relevance" || sort == "recent" else {
                throw SearchMentionsError.invalidSearchSort
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
                throw SearchMentionsError.invalidSenderType
            }
            scopedSenderType = senderType
        } else {
            scopedSenderType = nil
        }
        let mentionSelf: Bool
        if let mentionTarget, !mentionTarget.isEmpty {
            guard mentionTarget == "self" else {
                throw SearchMentionsError.invalidMentionTarget
            }
            mentionSelf = true
        } else {
            mentionSelf = false
        }
        let queryTokens = MessageSearchText.searchTokens(needle)
        let scopedChannel = (channelId?.isEmpty == false) ? channelId : nil
        let scopedSender = (senderId?.isEmpty == false) ? senderId : nil
        if queryTokens.isEmpty && scopedChannel == nil && scopedSender == nil && scopedSenderType == nil && !mentionSelf {
            return HumanMessageSearchResponse(results: [], hasMore: false)
        }
        let effectiveSort = queryTokens.isEmpty ? "recent" : sortMode
        let channelState = channels.state
        let messageState = messages.state
        if let scopedChannel {
            guard let channel = channelState.postableChannels[scopedChannel],
                  channel.serverId == serverId,
                  channel.deletedAt == nil,
                  channel.kind == "channel" || channel.memberIds.contains(userId)
            else {
                throw SearchMentionsError.channelNotFound
            }
        }
        let channelAgentMembers = agents.channelAgentMembers
        func accepts(_ message: StoredHumanMessage) -> Bool {
            guard Self.visible(
                messageChannelId: message.channelId,
                serverId: serverId,
                viewer: .user(userId),
                channels: channelState.postableChannels,
                channelAgentMembers: channelAgentMembers,
                oauth: oauth
            ) else { return false }
            if let scopedSender, message.senderId != scopedSender { return false }
            if let scopedSenderType, message.senderType != scopedSenderType { return false }
            if mentionSelf && !messageState.storedMentions.contains(where: {
                $0.messageId == message.id && $0.targetType == "user" && $0.targetId == userId
            }) {
                return false
            }
            if let scopedChannel {
                if message.channelId == scopedChannel { return true }
                let channel = channelState.postableChannels[message.channelId]
                return channel?.kind == "thread" && channel?.parentChannelId == scopedChannel
            }
            return true
        }
        var strict: [(StoredHumanMessage, Int)] = []
        var relaxed: [(StoredHumanMessage, Int)] = []
        var browse: [(StoredHumanMessage, Int)] = []
        for message in messageState.humanMessageRows where accepts(message) {
            if queryTokens.isEmpty {
                browse.append((message, 0))
                continue
            }
            let counts = MessageSearchText.tokenCounts(message.content)
            if let score = MessageSearchText.matchScore(counts, queryTokens, requireAll: true) {
                strict.append((message, score))
            } else if queryTokens.count > 1, let score = MessageSearchText.matchScore(counts, queryTokens, requireAll: false) {
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let results = page.map { pair -> HumanMessageSearchRowDTO in
            let message = pair.0
            let channel = channelState.postableChannels[message.channelId]
            let parentId = (channel?.kind == "thread" ? channel?.parentChannelId : nil) ?? message.channelId
            let snippet = MessageSearchText.searchSnippet(message.content)
            let archivedAt = oauth.channelArchivedAt(id: parentId).map { formatter.string(from: $0) }
            return HumanMessageSearchRowDTO(
                id: message.id,
                senderId: message.senderId,
                senderType: message.senderType,
                channelId: message.channelId,
                parentChannelId: parentId,
                content: message.content,
                snippet: snippet,
                channelArchivedAt: archivedAt
            )
        }
        return HumanMessageSearchResponse(results: results, hasMore: hasMore)
    }

    // MARK: - GET /internal/agent/:agentId/search

    /// The machine key must belong to that agent. Public channels on its server
    /// are visible; `after`/`before` require an explicit timezone offset and
    /// compare absolute instants.
    public func searchAgentMessages(
        agentId: String,
        query: String?,
        limit: String?,
        authorization: String?,
        sender: String? = nil,
        after: String? = nil,
        before: String? = nil,
        sort: String? = nil
    ) throws -> AgentMessageSearchResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw SearchMentionsError.agentSearchMissingAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let pageLimit: Int
        if let limit, let parsed = Int(limit), parsed > 0 {
            pageLimit = min(parsed, 100)
        } else {
            pageLimit = 20
        }
        let queryTokens = MessageSearchText.searchTokens((query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        if queryTokens.isEmpty {
            return AgentMessageSearchResponse(results: [], hasMore: false)
        }
        func parseBoundary(_ raw: String?, label: String) throws -> Date? {
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasZone = trimmed.hasSuffix("Z")
                || trimmed.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
            guard hasZone else {
                throw SearchMentionsError.agentSearchMissingOffset(label: label)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: trimmed) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: trimmed) { return date }
            throw SearchMentionsError.agentSearchInvalidInstant(label: label)
        }
        let afterBoundary = try parseBoundary(after, label: "after")
        let beforeBoundary = try parseBoundary(before, label: "before")
        let channelState = channels.state
        let messageState = messages.state
        guard let machine = machines.machineKeys[token], machine.agentId == agentId else {
            throw SearchMentionsError.agentSearchInvalidToken
        }
        let serverId = machine.serverId
        var senderScope: String?
        if let sender, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let handle = sender.hasPrefix("@") ? String(sender.dropFirst()) : sender
            let directoryHidden = channelState.hideHumansFromMembers[serverId] == true
                && oauth.agentRole(serverId: serverId, agentId: agentId) == "member"
            let humans = directoryHidden ? [] : profiles.accounts.values.filter { account in
                oauth.memberRole(serverId: serverId, userId: account.id) != nil
                    && (account.name.caseInsensitiveCompare(handle) == .orderedSame
                        || (account.displayName ?? "").caseInsensitiveCompare(handle) == .orderedSame)
            }.map(\.id)
            let agents = oauth.activeAgentIds(serverId: serverId).filter {
                oauth.agentRuntimeInfo(id: $0)?.name.caseInsensitiveCompare(handle) == .orderedSame
            }
            let matches = humans + agents
            if matches.isEmpty {
                throw SearchMentionsError.memberNotFound
            }
            if matches.count > 1 {
                throw SearchMentionsError.ambiguousMemberHandle
            }
            senderScope = matches[0]
        }
        let channelAgentMembers = agents.channelAgentMembers
        var strict: [(StoredHumanMessage, Int)] = []
        var relaxed: [(StoredHumanMessage, Int)] = []
        for message in messageState.humanMessageRows where Self.visible(
            messageChannelId: message.channelId,
            serverId: serverId,
            viewer: .agent(agentId),
            channels: channelState.postableChannels,
            channelAgentMembers: channelAgentMembers,
            oauth: oauth
        ) {
            if let senderScope, message.senderId != senderScope { continue }
            if let afterBoundary, message.createdAt <= afterBoundary { continue }
            if let beforeBoundary, message.createdAt >= beforeBoundary { continue }
            let counts = MessageSearchText.tokenCounts(message.content)
            if let score = MessageSearchText.matchScore(counts, queryTokens, requireAll: true) {
                strict.append((message, score))
            } else if queryTokens.count > 1, let score = MessageSearchText.matchScore(counts, queryTokens, requireAll: false) {
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
        let taskRows = tasks.taskRecords
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let results = page.map { pair -> AgentMessageSearchRowDTO in
            let message = pair.0
            let channel = channelState.postableChannels[message.channelId]
            let isThread = channel?.kind == "thread"
            let parentId = (isThread ? channel?.parentChannelId : nil) ?? message.channelId
            let threadParentMessageId = isThread ? channel?.parentMessageId : nil
            let parentContent = threadParentMessageId.flatMap { parentMessageId in
                messageState.humanMessageRows.first { $0.id == parentMessageId }?.content
            }
            let senderName = profiles.accounts.values.first { $0.id == message.senderId }?.name
                ?? oauth.agentRuntimeInfo(id: message.senderId)?.name
                ?? (message.senderId == "system" ? "system" : message.senderId)
            let senderType = message.senderType == "agent" ? "agent" : "human"
            let channelType = isThread ? "thread" : (channel?.kind ?? "channel")
            let snippet = MessageSearchText.searchSnippet(message.content)
            let archivedAt = oauth.channelArchivedAt(id: parentId).map { formatter.string(from: $0) }
            let task = taskRows.first { $0.messageId == message.id }
            return AgentMessageSearchRowDTO(
                id: message.id,
                senderId: message.senderId,
                senderName: senderName,
                senderType: senderType,
                channelId: message.channelId,
                channelType: channelType,
                channelName: channel?.name ?? "",
                parentChannelId: parentId,
                threadId: isThread ? message.channelId : nil,
                parentMessageId: threadParentMessageId,
                parentMessageContent: parentContent,
                content: message.content,
                snippet: snippet,
                channelArchivedAt: archivedAt,
                taskNumber: task?.taskNumber,
                taskCurrentProjection: task.map(Self.taskProjection)
            )
        }
        return AgentMessageSearchResponse(results: results, hasMore: hasMore)
    }

    // MARK: - GET /internal/agent-api/search

    /// The credential is bound to one managed agent (or the machine is bound to
    /// the requested one). Relevance ranks by token count; `sort=recent` uses
    /// `createdAt`. `enhanced` appends the thread projection and the host
    /// message's current task projection.
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
    ) throws -> AgentApiSearchResponse {
        let agent: OAuthLedger.AgentRuntimeInfo
        if let managedAgentId {
            guard let machineId = dependencies.machineIdForCredential(authorization),
                  let info = oauth.agentRuntimeInfo(id: managedAgentId), !info.deleted,
                  info.serverId != "",
                  dependencies.canMachineServeAgent(machineId, info)
            else {
                throw SearchMentionsError.agentSearchInvalidToken
            }
            agent = info
        } else {
            guard let credential = dependencies.agentCredential(authorization),
                  let info = oauth.agentRuntimeInfo(id: credential.agentId), !info.deleted
            else {
                throw SearchMentionsError.agentSearchInvalidToken
            }
            guard credential.scopes.contains("read") else {
                throw SearchMentionsError.capabilityNotAuthorized
            }
            agent = info
        }
        var afterDate: Date?
        var beforeDate: Date?
        for (label, raw) in [("after", after), ("before", before)] {
            guard let raw, !raw.isEmpty else { continue }
            guard raw.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
                throw SearchMentionsError.agentApiMissingOffset(label: label)
            }
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var parsed = parser.date(from: raw)
            if parsed == nil {
                parser.formatOptions = [.withInternetDateTime]
                parsed = parser.date(from: raw)
            }
            guard let parsed else {
                throw SearchMentionsError.agentApiInvalidDate(label: label)
            }
            if label == "after" { afterDate = parsed } else { beforeDate = parsed }
        }
        let pageLimit = min(max(Int(limit ?? "") ?? 20, 1), 100)
        let tokens = MessageSearchText.searchTokens((query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let sortMode = sort == "recent" ? "recent" : "relevance"
        let channelState = channels.state
        let messageState = messages.state
        let channelFilter: String? = {
            guard let channelRef, !channelRef.isEmpty else { return nil }
            if channelRef.lowercased().hasPrefix("dm:@reminders") {
                return feedback.agentReminderSurfaceChannels[agent.id]
            }
            let name = channelRef.hasPrefix("#") ? String(channelRef.dropFirst()) : channelRef
            return channelState.postableChannels.first { _, channel in
                channel.serverId == agent.serverId && channel.name == name
            }?.key
        }()
        // A sender filter resolves through the member directory first. A name
        // the caller may not see is the same `member_not_found` as an unknown
        // one, so the query cannot enumerate a hidden human directory.
        var senderScope: String?
        if let senderRef, !senderRef.isEmpty {
            let handle = senderRef.hasPrefix("@") ? String(senderRef.dropFirst()) : senderRef
            let directoryHidden = channelState.hideHumansFromMembers[agent.serverId] == true
                && oauth.agentRole(serverId: agent.serverId, agentId: agent.id) == "member"
            let agentMatch = oauth.activeAgentIds(serverId: agent.serverId).first {
                oauth.agentRuntimeInfo(id: $0)?.name.lowercased() == handle.lowercased()
            }
            let humanMatches: [String] = directoryHidden
                ? []
                : profiles.accounts.values.filter { account in
                    account.name.lowercased() == handle.lowercased()
                        || (account.displayName ?? "").lowercased() == handle.lowercased()
                }.map(\.id)
            if agentMatch != nil && !humanMatches.isEmpty {
                throw SearchMentionsError.ambiguousMemberReference
            }
            if humanMatches.count > 1 {
                throw SearchMentionsError.ambiguousMemberReference
            }
            let humanMatch = humanMatches.first
            guard let resolvedSender = agentMatch ?? humanMatch else {
                throw SearchMentionsError.memberNotFound
            }
            senderScope = resolvedSender
        }
        let channelAgentMembers = agents.channelAgentMembers
        var hits: [(message: StoredHumanMessage, score: Int)] = []
        for message in messageState.humanMessageRows where Self.visible(
            messageChannelId: message.channelId,
            serverId: agent.serverId,
            viewer: .agent(agent.id),
            channels: channelState.postableChannels,
            channelAgentMembers: channelAgentMembers,
            oauth: oauth
        ) {
            if let channelFilter, message.channelId != channelFilter { continue }
            if let senderScope, message.senderId != senderScope { continue }
            if let afterDate, message.createdAt <= afterDate { continue }
            if let beforeDate, message.createdAt >= beforeDate { continue }
            let counts = MessageSearchText.tokenCounts(message.content)
            if tokens.isEmpty {
                hits.append((message, 0))
            } else if let score = MessageSearchText.matchScore(counts, tokens, requireAll: true) {
                hits.append((message, score))
            } else if tokens.count > 1, let score = MessageSearchText.matchScore(counts, tokens, requireAll: false) {
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
        let taskRows = tasks.taskRecords
        let results = page.map { hit -> AgentApiSearchRowDTO in
            let message = hit.message
            let channel = channelState.postableChannels[message.channelId]
            let parentId = (channel?.kind == "thread" ? channel?.parentChannelId : nil) ?? message.channelId
            let senderName: String
            if message.senderType == "agent" {
                let runtime = oauth.agentRuntimeInfo(id: message.senderId)
                senderName = runtime.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? ""
            } else {
                let account = profiles.accounts.values.first { $0.id == message.senderId }
                senderName = account.map { ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.name } ?? ""
            }
            let senderType = message.senderType == "agent" ? "agent" : "human"
            let channelName = channel?.name ?? ""
            let snippet = MessageSearchText.searchSnippet(message.content)
            let isThread = channel?.kind == "thread"
            let threadId = isThread ? message.channelId : nil
            let parentMessageId = (isThread ? channel?.parentMessageId : nil).flatMap {
                $0.isEmpty ? nil : $0
            }
            let parentContent: String?
            if let parentMessageId,
               let parent = messageState.humanMessageRows.first(where: { $0.id == parentMessageId }),
               !parent.content.isEmpty {
                parentContent = parent.content
            } else {
                parentContent = nil
            }
            let task = enhanced ? taskRows.first { $0.messageId == message.id } : nil
            return AgentApiSearchRowDTO(
                id: message.id,
                content: message.content,
                senderName: senderName,
                senderType: senderType,
                senderId: message.senderId,
                channelId: message.channelId,
                channelName: channelName,
                parentChannelId: parentId,
                snippet: snippet,
                enhanced: enhanced,
                channelType: enhanced ? (channel?.kind ?? "channel") : nil,
                threadId: threadId,
                parentMessageId: parentMessageId,
                parentMessageContent: parentContent,
                taskNumber: task?.taskNumber,
                taskCurrentProjection: task.map(Self.taskProjection)
            )
        }
        return AgentApiSearchResponse(results: results, hasMore: hasMore)
    }

    // MARK: - GET /api/messages/context/:messageId stored fallback

    /// Context for a human message that is not in the permalink catalog. A DM
    /// short id resolves only for a participant. Returns `nil` when the stored
    /// fallback has no row, which lets the route keep the catalog's reply.
    public func humanMessageContext(
        messageId: String,
        channelId: String?,
        authorization: String?,
        serverId: String?,
        before: String? = nil,
        after: String? = nil
    ) -> StoredMessageContextResponse? {
        guard MessageContext.isShortId(messageId) || ServerScope.isUUID(messageId) else { return nil }
        guard let channelId, ServerScope.isUUID(channelId) else { return nil }
        guard let userId = dependencies.sessionUserId(authorization) else { return nil }
        let channelState = channels.state
        let rows = messages.humanMessageRows
        guard let channel = channelState.postableChannels[channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil,
              channel.kind == "channel" || channel.memberIds.contains(userId)
        else { return nil }
        let storageChannelId = channelState.jointProjections.first {
            $0.localChannelId == channelId
        }?.canonicalChannelId ?? channelId
        let scopedRows = rows.filter { $0.channelId == storageChannelId || $0.channelId == channelId }
        let matches = scopedRows.filter { MessageSearchText.messageIdMatches($0.id, messageId) }
        if matches.count == 1,
           let message = matches.first,
           let index = scopedRows.firstIndex(where: { $0.id == message.id }) {
            let beforeCount = MessageSearchText.contextWindowSide(before)
            let afterCount = MessageSearchText.contextWindowSide(after)
            let start = max(0, index - beforeCount)
            let end = min(scopedRows.count, index + 1 + afterCount)
            let parts = scopedRows[start..<end].map { row in
                let commentsVisible = dependencies.attachmentCommentsEnabled(
                    serverId ?? "",
                    userId
                )
                let metadata = dependencies.forwardMetadata(row.id, userId, serverId)
                    ?? dependencies.actionCardMetadataJSON(row.id).map(OrderedJSON.raw)
                return MessageContextMessageDTO(
                    id: row.id,
                    channelId: channelId,
                    content: row.content,
                    seq: row.seq,
                    attachmentChips: dependencies.attachmentChips(row.attachmentIds, commentsVisible),
                    commentRef: commentsVisible ? dependencies.commentRef(row.id) : nil,
                    actionMetadata: metadata
                )
            }
            let windowIds = scopedRows[start..<end].map(\.id)
            return StoredMessageContextResponse(
                channelId: channelId,
                targetMessageId: message.id,
                hasOlder: start > 0,
                hasNewer: end < scopedRows.count,
                messages: parts,
                canonicalTarget: nil,
                threadSummariesByParentMessageId: dependencies.threadSummaries(channelId, windowIds),
                channelArchived: channel.archived
            )
        }
        for link in channelState.jointProjections where link.serverId == serverId {
            guard let localThread = channelState.postableChannels[link.localChannelId],
                  localThread.kind == "thread",
                  localThread.parentChannelId == channelId,
                  localThread.deletedAt == nil,
                  localThread.memberIds.contains(userId)
            else { continue }
            guard let reply = rows.first(where: {
                $0.channelId == link.canonicalChannelId && MessageSearchText.messageIdMatches($0.id, messageId)
            }) else { continue }
            let canonicalThreadId = link.localChannelId
            return StoredMessageContextResponse(
                channelId: canonicalThreadId,
                targetMessageId: reply.id,
                hasOlder: false,
                hasNewer: false,
                messages: [Self.singleMessage(reply, channelId: canonicalThreadId, seq: 1)],
                canonicalTarget: MessageContextCanonicalTargetDTO(
                    kind: "thread",
                    channelId: channelId,
                    messageId: reply.id,
                    threadParentMessageId: localThread.parentMessageId ?? "",
                    threadChannelId: canonicalThreadId
                ),
                threadSummariesByParentMessageId: .object([]),
                channelArchived: localThread.archived
            )
        }
        let replies = rows.filter { row in
            guard MessageSearchText.messageIdMatches(row.id, messageId),
                  let thread = channelState.postableChannels[row.channelId],
                  thread.kind == "thread",
                  thread.serverId == serverId,
                  thread.deletedAt == nil,
                  let parentMessageId = thread.parentMessageId,
                  let parent = rows.first(where: { $0.id == parentMessageId }),
                  parent.channelId == channelId
            else { return false }
            return true
        }
        if replies.count == 1,
           let reply = replies.first,
           let thread = channelState.postableChannels[reply.channelId] {
            let threadRows = rows.filter { $0.channelId == reply.channelId }
            let seq = (threadRows.firstIndex { $0.id == reply.id } ?? 0) + 1
            return StoredMessageContextResponse(
                channelId: reply.channelId,
                targetMessageId: reply.id,
                hasOlder: false,
                hasNewer: false,
                messages: [Self.singleMessage(reply, channelId: reply.channelId, seq: seq)],
                canonicalTarget: MessageContextCanonicalTargetDTO(
                    kind: "thread",
                    channelId: channelId,
                    messageId: reply.id,
                    threadParentMessageId: thread.parentMessageId ?? "",
                    threadChannelId: reply.channelId
                ),
                threadSummariesByParentMessageId: .object([]),
                channelArchived: thread.archived
            )
        }
        let threadChannels = channelState.postableChannels.filter { id, thread in
            thread.kind == "thread"
                && thread.serverId == serverId
                && thread.deletedAt == nil
                && MessageSearchText.messageIdMatches(id, messageId)
                && thread.parentMessageId.flatMap { parentId in
                    rows.first { $0.id == parentId && $0.channelId == channelId }
                } != nil
        }
        guard threadChannels.count == 1,
              let parentMessageId = threadChannels.values.first?.parentMessageId,
              let parent = rows.first(where: { $0.id == parentMessageId && $0.channelId == channelId })
        else { return nil }
        let seq = (scopedRows.firstIndex { $0.id == parent.id } ?? 0) + 1
        return StoredMessageContextResponse(
            channelId: parent.channelId,
            targetMessageId: parent.id,
            hasOlder: false,
            hasNewer: false,
            messages: [Self.singleMessage(parent, channelId: parent.channelId, seq: seq)],
            canonicalTarget: nil,
            threadSummariesByParentMessageId: .object([]),
            channelArchived: channel.archived
        )
    }

    // MARK: - DELETE /api/channels/:channelId

    /// A member soft-deletes the channel. Search then hides it and threads under
    /// it. The channel row and the orphan-task closure each run as one store
    /// critical section.
    public func deleteChannel(
        channelId: String,
        authorization: String?,
        serverId: String?
    ) throws -> DeleteChannelResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw authorization?.hasPrefix("Bearer ") == true
                ? SearchMentionsError.invalidAccessToken
                : SearchMentionsError.missingAuthorization
        }
        let role = oauth.memberRole(serverId: serverId ?? "", userId: userId)
        let now = dependencies.now()
        switch channels.softDeleteChannel(
            channelId: channelId,
            serverId: serverId,
            userId: userId,
            memberRole: role,
            now: now
        ) {
        case .notFound:
            throw SearchMentionsError.channelNotFound
        case .forbidden:
            throw SearchMentionsError.forbidden
        case .deleted:
            tasks.closeOrphanTasks(channelId: channelId, now: now)
            return DeleteChannelResponse()
        }
    }

    // MARK: - Projection helpers

    private static func taskProjection(_ task: TaskRecord) -> TaskCurrentProjectionDTO {
        TaskCurrentProjectionDTO(
            title: task.title,
            description: task.description,
            revision: task.revision,
            superseded: task.superseded,
            amendedAt: task.amendedAt.map { DateText.isoString($0) },
            amendedByType: task.amendedByType,
            amendedByName: task.amendedByName
        )
    }

    /// The single-message window the joint/thread fallbacks publish. It carries
    /// no attachment, comment or action-metadata members, matching the legacy
    /// `contextJSON` single-message path.
    private static func singleMessage(
        _ message: StoredHumanMessage,
        channelId: String,
        seq: Int
    ) -> MessageContextMessageDTO {
        MessageContextMessageDTO(
            id: message.id,
            channelId: channelId,
            content: message.content,
            seq: seq,
            attachmentChips: nil,
            commentRef: nil,
            actionMetadata: nil
        )
    }
}
