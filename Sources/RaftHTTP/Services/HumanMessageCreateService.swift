import Foundation
import RaftShared

/// One human-message insert as the message write reports it: the status and
/// published row body (or the refusal body) and whether this call created the
/// row.
struct HumanMessageWrite: Sendable {
    var status: Int
    var body: String
    var created: Bool
}

/// The mention handles a send resolved and, for a v2 send, the ones it could
/// not.
struct ResolvedMentions: Sendable {
    var mentions: [MentionInput]
    var unresolved: [String]
    var registrations: [ResolvedMentionRegistration] = []
    var bindingConflict: Bool = false
}

/// The v1/v2 contract the create route answers with.
public enum HumanMessageContract: Sendable, Equatable {
    case v1
    case v2
}

/// The human-message create boundary: the v1/v2 create route, the sender-side
/// mention actions it leaves pending, the forward lookup and the forward write
/// (`HumanMessageForwardService.swift`).
///
/// Cross-domain policies use owner snapshots. The message commit deliberately
/// nests only its concrete Messages -> OAuth leaf port, preserving mirror order;
/// it invokes no Service callback while State is borrowed. Routes decode the
/// body and project the returned DTO or thrown DomainError.
public struct HumanMessageCreateService: Sendable {
    /// Required startup closure: load the packaged mature parser and execute it
    /// before the server accepts message writes. This creates no business state.
    public static func validateMessageParserRuntime() throws {
        _ = try MessageMentionMarkdown.parse("")
    }

    let channels: ServersAndChannelsStore
    let messages: MessagesAndThreadsStore
    let agents: AgentsRuntimeStore
    let profiles: AuthProfileStore
    let oauth: OAuthLedger
    let dependencies: HumanMessageCreateDependencies
    let machines: MachinesAndComputersStore?
    let execution: AgentExecutionService?

    init(
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        agents: AgentsRuntimeStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        dependencies: HumanMessageCreateDependencies,
        machines: MachinesAndComputersStore? = nil,
        execution: AgentExecutionService? = nil
    ) {
        self.channels = channels
        self.messages = messages
        self.agents = agents
        self.profiles = profiles
        self.oauth = oauth
        self.dependencies = dependencies
        self.machines = machines
        self.execution = execution
    }

    public func bindingExecution(_ execution: AgentExecutionService?) -> Self {
        Self(channels: channels, messages: messages, agents: agents, profiles: profiles,
             oauth: oauth, dependencies: dependencies, machines: machines, execution: execution)
    }

    // MARK: - Session helpers

    /// The user a bearer header resolves to; nil for a missing header, an
    /// unknown token or a revoked session family.
    func sessionUserId(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return profiles.userId(forAccessToken: String(authorization.dropFirst("Bearer ".count)))
    }

    /// The forward and lookup routes' bearer check: a missing header and an
    /// unknown token publish different bodies.
    func requireUser(_ authorization: String?) throws -> String {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw HumanMessageCreateError.missingAuthorization
        }
        guard let userId = profiles.userId(forAccessToken: String(authorization.dropFirst("Bearer ".count))) else {
            throw HumanMessageCreateError.invalidToken
        }
        return userId
    }

    /// The create and mention-action routes' check: both refusals share the
    /// public `auth_required` shape.
    func requirePublicUser(_ authorization: String?) throws -> String {
        guard let userId = sessionUserId(authorization) else {
            throw HumanMessageCreateError.authRequired(bearerPresent: authorization?.hasPrefix("Bearer ") == true)
        }
        return userId
    }

    // MARK: - POST /api/messages, POST /api/v2/messages

    /// A bad human create body is refused before any message row exists. An App
    /// reference is refused before persistence when that app is not installed on
    /// the channel's server.
    public func createHumanMessage(
        _ request: HumanMessageCreateRequest?,
        authorization: String?,
        serverId: String?,
        contract: HumanMessageContract = .v1
    ) throws -> HumanMessageCreatedResponse {
        let userId = try requirePublicUser(authorization)
        guard profiles.isEmailVerified(userId: userId) else {
            throw HumanMessageCreateError.emailVerificationRequired
        }
        if let serverId, !serverId.isEmpty,
           !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil {
            throw HumanMessageCreateError.notServerMember
        }
        guard let request, Self.isValidCreateBody(request),
              case .string(let channelId)? = request.channelId,
              case .string(let content)? = request.content
        else {
            throw HumanMessageCreateError.invalidMessageBody
        }
        let channelState = channels.state
        let channel = channelState.postableChannels[channelId]
        let referencesEnabled = channelState.composerResourceServers.contains(channel?.serverId ?? "")
        let installed = channelState.installedServerApps[channel?.serverId ?? ""] ?? []
        guard let channel, channel.serverId == serverId else {
            throw HumanMessageCreateError.channelNotFound
        }
        let parentMember = channel.kind == "thread"
            && (channel.parentChannelId.flatMap { channelState.postableChannels[$0] }?.memberIds.contains(userId) ?? false)
        guard channel.memberIds.contains(userId) || parentMember else {
            throw HumanMessageCreateError.forbidden
        }
        // A thread inherits its parent's freeze: no writes under an archived parent.
        let parentArchived = channel.kind == "thread"
            && channel.parentChannelId.flatMap { oauth.channelArchivedAt(id: $0) } != nil
        if channel.archived || parentArchived {
            if oauth.memberRole(serverId: channel.serverId, userId: userId) == "guest" {
                throw HumanMessageCreateError.forbidden
            }
            throw HumanMessageCreateError.channelArchived
        }
        let producer = execution.map {
            AgentExecutionHumanMessageProducer(channels: channels, messages: messages, oauth: oauth, execution: $0)
        }
        try producer?.requireSupportedSurface(channelId: channelId)
        let appIds = Self.appReferenceIds(content)
        if !appIds.isEmpty {
            if !referencesEnabled { throw HumanMessageCreateError.referencesNotEnabled }
            if appIds.contains(where: { !installed.contains($0) }) {
                throw HumanMessageCreateError.appNotInstalled
            }
        }
        let attachmentIds = Self.strings(in: request.attachmentIds)
        let typedMentions = AgentSendMessageRequest.mentions(Self.array(request.mentions))
        let resolution = try dependencies.resolveMentions(
            serverId ?? "",
            channelId,
            userId,
            content,
            typedMentions,
            contract == .v2
        )
        if resolution.bindingConflict { throw HumanMessageCreateError.mentionBindingConflict }
        let mentions = resolution.mentions
        let senderTimezone = Self.optionalIanaTimezone(request.timezone)
        var randomId: String?
        if let raw = request.randomId {
            guard case .string(let value) = raw, !value.isEmpty, value.count <= 128 else {
                throw HumanMessageCreateError.invalidRandomId
            }
            randomId = value
        }
        let written = try dependencies.storeHumanMessage(
            channelId, userId, content, randomId, attachmentIds, senderTimezone, mentions,
            Self.asTaskValue(request.asTask)
        )
        guard written.status == 200 else {
            throw HumanMessageCreateError.messageWriteRejected(status: UInt(written.status), body: written.body)
        }
        let messageId = Self.messageId(in: written.body)
        var wakeSuppressedAgentIds: [String] = []
        if written.created, let messageId {
            dependencies.recordMemberMentionRows(messageId, channelId, resolution)
            if channel.kind == "thread", channel.parentMessageId != nil {
                dependencies.recordThreadReplyFollows(messageId, channelId, serverId ?? "", userId, resolution)
            }
            wakeSuppressedAgentIds = try producer?.deliverCreated(messageId: messageId, channelId: channelId) ?? []
        }
        guard let messageId else {
            return HumanMessageCreatedResponse(
                messageJSON: written.body,
                nested: false,
                pendingMentionActions: [],
                deliveryWarnings: [],
                unresolvedMentionHandles: []
            )
        }
        let pending = written.created ? pendingMentionActions(channelId: channelId, messageId: messageId) : []
        if contract == .v2 {
            return HumanMessageCreatedResponse(
                messageJSON: written.body,
                nested: true,
                pendingMentionActions: pending,
                deliveryWarnings: stoppedAgentDeliveryWarnings(channelId: channelId, messageId: messageId,
                                                               wakeSuppressedAgentIds: wakeSuppressedAgentIds),
                unresolvedMentionHandles: resolution.unresolved
            )
        }
        return HumanMessageCreatedResponse(
            messageJSON: written.body,
            nested: !pending.isEmpty,
            pendingMentionActions: pending,
            deliveryWarnings: [],
            unresolvedMentionHandles: []
        )
    }

    /// Outsider mentions on a new human send are returned beside the message,
    /// not inside it. The resolution rows are written in one store critical
    /// section.
    private func pendingMentionActions(channelId: String, messageId: String) -> [PendingMentionAction] {
        guard let channel = channels.postableChannel(id: channelId),
              channel.kind == "channel" || channel.kind == "thread" else { return [] }
        return messages.state.storedMentions.filter {
            $0.messageId == messageId && $0.channelId == channelId && !$0.notifiableAtSend && $0.notifiedAt == nil
        }.map { mention in
            PendingMentionAction(resolutionId: mention.id, messageId: mention.messageId,
                targetType: mention.targetType, targetHandle: mention.handle,
                targetAvatarUrl: mention.targetType == "user" ? profiles.account(userId: mention.targetId)?.avatarUrl
                    : oauth.agentRuntimeInfo(id: mention.targetId)?.avatarUrl,
                expiresAt: MessageMentionRules.expiry(mention.createdAt))
        }
    }

    /// A DM delivery whose wake the server suppressed is reported to the v2
    /// sender as upstream `agent_stopped`. The manual-stop status and the
    /// execution owner's real recovery refusal both produce that warning; the
    /// message itself stays committed in either case.
    private func stoppedAgentDeliveryWarnings(channelId: String, messageId: String,
                                              wakeSuppressedAgentIds: [String]) -> [MessageDeliveryWarning] {
        guard let channel = channels.state.postableChannels[channelId],
              channel.kind == "dm",
              let agentId = channel.agentId else { return [] }
        if agents.recordStoppedAgentDelivery(agentId: agentId, messageId: messageId, channelType: channel.kind) {
            return [MessageDeliveryWarning(agentId: agentId)]
        }
        guard wakeSuppressedAgentIds.contains(agentId) else { return [] }
        agents.recordSuppressedAgentDelivery(agentId: agentId, messageId: messageId, channelType: channel.kind)
        return [MessageDeliveryWarning(agentId: agentId)]
    }

    // MARK: - POST /api/messages/mention-actions/execute

    /// A resolution id belongs to the sender who wrote the mention.
    public func executeMentionActions(
        _ request: MentionActionsRequest?,
        authorization: String?,
        serverId: String?
    ) throws -> MentionActionsResponse {
        let userId = try requirePublicUser(authorization)
        guard let request, case .string(let action)? = request.action,
              action == "notify" || action == "add"
        else {
            throw HumanMessageCreateError.actionMustBeNotifyOrAdd
        }
        var seen = Set<String>()
        var resolutionIds: [String] = []
        for raw in Self.strings(in: request.resolutionIds) + Self.strings(in: request.ids) {
            let id = MessageMentionRules.trimmingJavaScriptWhitespace(raw)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            resolutionIds.append(id)
            if resolutionIds.count == 100 { break }
        }
        if resolutionIds.isEmpty { throw HumanMessageCreateError.resolutionIdsRequired }
        guard let serverId, !serverId.isEmpty else { throw MessageSendError.missingServerId }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else { throw MessageSendError.notServerMember }
        return MentionActionsResponse(action: action, results: try mentionActions.execute(
            ids: resolutionIds, action: action, serverId: serverId, actorType: "user", actorId: userId))
    }

    private var mentionActions: MessageMentionActionsService {
        MessageMentionActionsService(channels: channels, messages: messages, agents: agents,
            profiles: profiles, oauth: oauth, machines: machines, execution: execution, now: dependencies.now)
    }

    // MARK: - GET /internal/agent-api/mention-actions/pending

    /// Sender-side outsider mentions authored by the bound agent whose delivery
    /// was withheld.
    public func agentMentionActionsPending(authorization: String?, limit: String? = nil) throws -> AgentPendingMentionActionsResponse {
        let agentId = try requireAgent(authorization)
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
            throw HumanMessageCreateError.invalidToken
        }
        return mentionActions.pending(serverId: agent.serverId, agentId: agentId, limit: limit)
    }

    // MARK: - POST /internal/agent-api/mention-actions/execute

    /// Every id is revalidated at action time and returns a typed per-id status.
    public func agentMentionActionsExecute(
        authorization: String?,
        _ request: MentionActionsRequest?
    ) throws -> MentionActionsResponse {
        let agentId = try requireAgent(authorization)
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
            throw HumanMessageCreateError.invalidToken
        }
        guard let request, case .string(let action)? = request.action,
              action == "notify" || action == "add"
        else {
            throw HumanMessageCreateError.actionMustBeNotifyOrAdd
        }
        var seen = Set<String>()
        var ids: [String] = []
        let rawIds = Self.array(request.resolutionIds) ?? Self.array(request.ids) ?? []
        for raw in rawIds {
            guard case .string(let text) = raw else { continue }
            let id = MessageMentionRules.trimmingJavaScriptWhitespace(text)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            ids.append(id)
            if ids.count == 100 { break }
        }
        guard !ids.isEmpty else { throw HumanMessageCreateError.resolutionIdsRequired }
        return MentionActionsResponse(action: action, results: try mentionActions.execute(
            ids: ids, action: action, serverId: agent.serverId, actorType: "agent", actorId: agentId))
    }

    private func requireAgent(_ authorization: String?) throws -> String {
        switch dependencies.agentReadOutcome(authorization) {
        case .success(let agentId):
            return agentId
        case .missingAuthorization:
            throw HumanMessageCreateError.missingAuthorization
        case .invalidCredential:
            throw HumanMessageCreateError.invalidToken
        case .capabilityNotAuthorized:
            throw FeedbackLocatorError.capabilityNotAuthorized(capability: "mentions")
        }
    }

    // MARK: - GET /api/messages/forward/enabled

    /// The rollout flag is retired, so this stays true.
    public func messageForwardEnabled(authorization: String?, serverId: String?) throws -> MessageForwardEnabledResponse {
        let userId = try requireUser(authorization)
        guard profiles.isEmailVerified(userId: userId) else {
            throw HumanMessageCreateError.emailVerificationRequired
        }
        guard let serverId, !serverId.isEmpty else { throw HumanMessageCreateError.missingServerIdHeader }
        return MessageForwardEnabledResponse()
    }

    // MARK: - GET /api/messages/forward/targets/search

    /// An empty query returns no targets.
    public func searchForwardTargets(
        query: String?,
        limit rawLimit: String?,
        authorization: String?,
        serverId: String?
    ) throws -> ForwardTargetsResponse {
        let userId = try requireUser(authorization)
        guard profiles.account(userId: userId)?.retiredAt == nil else {
            throw HumanMessageCreateError.unauthorized
        }
        guard profiles.isEmailVerified(userId: userId) else {
            throw HumanMessageCreateError.emailVerificationRequired
        }
        guard let serverId, !serverId.isEmpty else { throw HumanMessageCreateError.missingServerIdHeader }
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return ForwardTargetsResponse(targets: []) }
        let pageLimit: Int
        if let rawLimit, let parsed = Int(rawLimit), parsed > 0 {
            pageLimit = min(parsed, 20)
        } else {
            pageLimit = 20
        }
        let channelState = channels.state
        let serverAgents = agents.serverAgents
        let accounts = profiles.accounts
        let accountsById = Dictionary(accounts.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let role = channelState.serverMemberRoles["\(serverId)\n\(userId)"]
        let isGuest = role == "guest"
        let hideHumans = channelState.hideHumansFromMembers[serverId] == true || isGuest
        var results: [(score: Int, title: String, target: ForwardTarget)] = []
        for (id, channel) in channelState.postableChannels
        where channel.serverId == serverId && channel.deletedAt == nil && !channel.archived {
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
                ForwardTarget(
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
        for (id, channel) in channelState.postableChannels
        where channel.serverId == serverId && channel.kind == "dm" && channel.deletedAt == nil
            && channel.memberIds.contains(userId) {
            let peerId = channel.agentId ?? channel.memberIds.first { $0 != userId }
            guard let peerId else { continue }
            dmPeerIds.insert(peerId)
            let agent = serverAgents[peerId]
            let account = accountsById[peerId]
            let label = agent?.name ?? account?.name ?? peerId
            let score = Self.forwardTargetScore(q, label.lowercased())
            if score <= 0 { continue }
            let title = "@\(label)"
            results.append((
                score + 50,
                title,
                ForwardTarget(
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
                    ForwardTarget(
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
            for (key, memberRole) in channelState.serverMemberRoles {
                let parts = key.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, parts[0] == serverId, memberRole != "guest" else { continue }
                let memberId = parts[1]
                if memberId == userId || dmPeerIds.contains(memberId) { continue }
                guard let account = accountsById[memberId] else { continue }
                let score = Self.forwardTargetScore(q, account.name.lowercased())
                if score <= 0 { continue }
                let title = "@\(account.name)"
                results.append((
                    score,
                    title,
                    ForwardTarget(
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
        return ForwardTargetsResponse(targets: results.prefix(pageLimit).map(\.target))
    }

    // MARK: - Pure policy and parsing helpers

    /// Public channels are readable by any signed-in user. Private surfaces and
    /// their threads require membership.
    static func targetCanRead(
        channels: [String: PostableChannel],
        agentMembers: [String: Set<String>],
        channelId: String,
        targetType: String,
        targetId: String
    ) -> Bool {
        guard let stored = channels[channelId] else { return false }
        let surface: PostableChannel
        let surfaceId: String
        if stored.kind == "thread", let parentId = stored.parentChannelId, let parent = channels[parentId] {
            surface = parent
            surfaceId = parentId
        } else {
            surface = stored
            surfaceId = channelId
        }
        if targetType == "agent" {
            if surface.kind == "channel" { return true }
            return agentMembers[surfaceId]?.contains(targetId) == true
                || agentMembers[channelId]?.contains(targetId) == true
        }
        if surface.kind == "channel" { return true }
        return surface.memberIds.contains(targetId) || stored.memberIds.contains(targetId)
    }

    /// A removed channel member can no longer add someone through a mention they
    /// sent earlier.
    static func userStillInChannel(channels: [String: PostableChannel], channelId: String, userId: String) -> Bool {
        guard let stored = channels[channelId] else { return false }
        if stored.kind == "thread", let parentId = stored.parentChannelId, let parent = channels[parentId] {
            return parent.memberIds.contains(userId)
        }
        return stored.memberIds.contains(userId)
    }

    static func forwardTargetScore(_ query: String, _ candidate: String) -> Int {
        if candidate.isEmpty { return 0 }
        if candidate == query { return 400 }
        if candidate.hasPrefix(query) { return 300 }
        if candidate.range(of: " \(query)") != nil { return 250 }
        if let range = candidate.range(of: query) {
            let index = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            return max(1, 150 - index)
        }
        return 0
    }

    /// The seven-day window a pending outsider mention stays actionable, as an
    /// ISO-8601 instant without fractional seconds.
    static func pendingMentionExpiry(from now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(7 * 24 * 60 * 60))
    }

    static func appReferenceIds(_ content: String) -> [String] {
        var ids: [String] = []
        for match in content.matches(of: /<app:([a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+)>/) {
            let id = String(match.1)
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// The optional `asTask` flag: the body check already refused a present
    /// non-boolean value, and an absent flag is the ordinary send.
    static func asTaskValue(_ value: JSONValue?) -> Bool {
        if case .bool(let flag)? = value { return flag }
        return false
    }

    /// The legacy body check: a UUID `channelId`, an `attachmentIds` that is an
    /// array of UUID strings when present (a `null` is not an array) and an
    /// `asTask` that is a boolean when present. `content` is checked by the
    /// caller together with the channel id so both failures share the refusal.
    static func isValidCreateBody(_ request: HumanMessageCreateRequest) -> Bool {
        guard case .string(let channelId)? = request.channelId, ServerScope.isUUID(channelId) else { return false }
        if let attachments = request.attachmentIds {
            guard case .array(let ids) = attachments else { return false }
            for id in ids {
                guard case .string(let string) = id, ServerScope.isUUID(string) else { return false }
            }
        }
        if let asTask = request.asTask {
            guard case .bool = asTask else { return false }
        }
        return true
    }

    /// The optional IANA zone a sender reports: a trimmed `UTC` or `Area/City`
    /// name Foundation recognizes, canonicalized; anything else is dropped.
    static func optionalIanaTimezone(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 128 { return nil }
        if trimmed != "UTC" && !trimmed.contains("/") { return nil }
        if trimmed == "UTC" { return "UTC" }
        guard let zone = TimeZone(identifier: trimmed) else { return nil }
        let canonical = zone.identifier
        if canonical != "UTC" && !canonical.contains("/") { return nil }
        return canonical
    }

    static func array(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let items)? = value else { return nil }
        return items
    }

    /// The string entries of an array value; a non-array yields none.
    static func strings(in value: JSONValue?) -> [String] {
        (array(value) ?? []).compactMap {
            guard case .string(let string) = $0 else { return nil }
            return string
        }
    }

    private struct StoredMessageId: Decodable {
        var id: String
    }

    /// The `id` of a stored row's published body.
    static func messageId(in body: String) -> String? {
        (try? JSONDecoder().decode(StoredMessageId.self, from: Data(body.utf8)))?.id
    }
}
