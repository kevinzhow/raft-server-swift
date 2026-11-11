import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Service

/// Saved messages, direct channels, channel detail, read state and the agent
/// channel archive/mute surface.
///
/// The service owns the orchestration and returns the published `Codable` /
/// `JSONBodyConvertible` DTOs; every refusal is a `ChannelMembershipError` (the
/// shared channel refusals), a `FeedbackLocatorError` (a missing agent
/// capability) or a `ManagedMCPToolExecutionError`. It builds no HTTP reply.
/// The read-state writes are `MessagesAndThreadsStore` critical sections (the
/// frontier comparison and version bump, the agent cursor advance, the
/// Done-inbox stamp) and the DM row is one `ServersAndChannelsStore` write.
public struct ManagedMCPToolExecutionService: Sendable {
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let agents: AgentsRuntimeStore
    private let profiles: AuthProfileStore
    private let notifications: NotificationsStore
    private let inboxFacts: InboxFactStore
    private let oauth: OAuthLedger
    private let feedbackLocators: FeedbackLocatorService
    private let auth: AuthCoreService
    private let realtime: RealtimeRelayService
    private let taskCredentials: AgentTaskCredentials
    private let credentialLookup: AgentCredentialLookup
    private let suppression: MessageSuppressionService
    private let now: @Sendable () -> Date

    init(
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        agents: AgentsRuntimeStore,
        profiles: AuthProfileStore,
        notifications: NotificationsStore,
        inboxFacts: InboxFactStore,
        oauth: OAuthLedger,
        feedbackLocators: FeedbackLocatorService,
        auth: AuthCoreService,
        realtime: RealtimeRelayService,
        taskCredentials: AgentTaskCredentials,
        credentialLookup: AgentCredentialLookup,
        suppression: MessageSuppressionService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.channels = channels
        self.messages = messages
        self.agents = agents
        self.profiles = profiles
        self.notifications = notifications
        self.inboxFacts = inboxFacts
        self.oauth = oauth
        self.feedbackLocators = feedbackLocators
        self.auth = auth
        self.realtime = realtime
        self.taskCredentials = taskCredentials
        self.credentialLookup = credentialLookup
        self.suppression = suppression
        self.now = now
    }

    private var visibility: ManagedMCPChannelVisibility {
        ManagedMCPChannelVisibility(oauth: oauth, channels: channels)
    }

    private func requireSession(_ authorization: String?) throws -> String {
        guard let userId = try? auth.authenticate(authorization) else {
            throw ManagedMCPToolExecutionError.unauthorized
        }
        return userId
    }

    private func requireMember(serverId: String, userId: String) throws -> String {
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.notAMember
        }
        return role
    }

    private func requireNotArchived(_ channelId: String) throws {
        guard oauth.channelArchivedAt(id: channelId) == nil else {
            throw ChannelMembershipError.channelArchived
        }
    }

    /// Human channel-read authority. A thread is readable through its parent
    /// message's channel, the same recursion `canUserAccessChannel` applies
    /// (`channelService.ts:4994-5016`).
    private func canReadChannel(channelId: String, serverId: String, userId: String) -> Bool {
        if HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: agents)
            .authority(channelId: channelId, serverId: serverId, userId: userId) != nil { return true }
        guard channels.postableChannel(id: channelId) == nil else { return false }
        return LedgerChannelReadFallback.canReadHuman(
            channelId: channelId, serverId: serverId, userId: userId, oauth: oauth)
    }

    /// The agent credential must carry the capability; a missing one is the
    /// published `capability_not_authorized` refusal.
    private func requireCapability(_ authorization: String?, _ capability: String) throws {
        if case .denied(let denied) = feedbackLocators.capabilityDecision(
            authorization: authorization,
            capability: capability
        ) {
            throw FeedbackLocatorError.capabilityNotAuthorized(capability: denied)
        }
    }

    private func isoFractional(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - POST /api/channels/saved/check

    public func checkSavedMessages(
        authorization: String?,
        serverId: String,
        body: SavedCheckRequest?
    ) throws -> SavedCheckResponse {
        let userId = try requireSession(authorization)
        guard let messageIds = body?.messageIds else {
            throw ManagedMCPToolExecutionError.invalidSavedCheckRequest
        }
        var savedEntries: [String: OAuthLedger.SavedMessageInfo] = [:]
        for entry in oauth.savedMessages(userId: userId) where savedEntries[entry.messageId] == nil {
            savedEntries[entry.messageId] = entry
        }
        let postable = channels.state.postableChannels
        let visible = messageIds.filter { id in
            guard let entry = savedEntries[id] else { return false }
            if let scope = postable[entry.channelId] {
                guard scope.serverId == serverId, scope.deletedAt == nil, !scope.archived else { return false }
                return scope.kind == "channel" || scope.memberIds.contains(userId)
            }
            return true
        }
        return SavedCheckResponse(savedIds: visible)
    }

    // MARK: - DELETE /api/channels/saved/:messageId

    /// Upstream deletes the caller's saved row without verifying that the
    /// message still exists or is visible to this server, so an already-unsaved
    /// or unknown id is the same success as a removed row.
    public func unsaveMessage(
        authorization: String?,
        messageId: String
    ) throws -> OkResponse {
        let userId = try requireSession(authorization)
        oauth.unsaveMessage(userId: userId, messageId: messageId)
        return OkResponse()
    }

    // MARK: - Channel conversion routes

    /// The pinned default gate for `convert-to-joint` and the three
    /// conversion-job routes: the flag is absent or off, so the request is
    /// refused before any channel/job lookup with the documented 404. This port
    /// does not implement joint conversion.
    public func conversionDisabled(
        authorization: String?,
        serverId: String
    ) throws -> OkResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        throw ChannelConversionError.disabled
    }

    // MARK: - GET /api/channels/saved

    public func listSavedMessages(
        authorization: String?,
        serverId: String,
        query: String?,
        channelId: String?,
        sort: String?,
        limit: Int,
        offset: Int
    ) throws -> SavedMessagesResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        let postable = channels.state.postableChannels
        var entries = oauth.savedMessages(userId: userId).filter { entry in
            if let scope = postable[entry.channelId] {
                guard scope.serverId == serverId, scope.deletedAt == nil, !scope.archived else { return false }
                if scope.kind == "channel" { return true }
                return scope.memberIds.contains(userId)
            }
            if let parentChannelId = entry.parentChannelId, let parent = postable[parentChannelId] {
                guard parent.serverId == serverId, parent.deletedAt == nil, !parent.archived else { return false }
                return parent.kind == "channel" || parent.memberIds.contains(userId)
            }
            return true
        }
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
        return SavedMessagesResponse(
            saved: page.map {
                SavedMessageRowDTO(
                    messageId: $0.messageId,
                    channelId: $0.channelId,
                    channelType: $0.channelType,
                    content: $0.content,
                    parentChannelId: $0.parentChannelId,
                    parentMessageId: $0.parentMessageId,
                    parentMessagePreview: $0.parentMessagePreview,
                    replyCount: $0.replyCount
                )
            },
            total: total,
            hasMore: offset + page.count < total
        )
    }

    // MARK: - POST /api/channels/system/all/hide|restore

    public func setAllChannelVisibility(
        authorization: String?,
        serverId: String,
        visible: Bool
    ) throws -> AllChannelVisibilityResponse {
        let userId = try requireSession(authorization)
        let role = try requireMember(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else { throw ChannelMembershipError.forbidden }
        guard let allChannelId = oauth.allChannelId(serverId: serverId) else {
            throw ChannelMembershipError.channelNotFound
        }
        _ = oauth.setChannelType(id: allChannelId, type: visible ? "channel" : "private")
        return AllChannelVisibilityResponse(id: allChannelId, visible: visible)
    }

    // MARK: - POST /api/channels/dm

    public func createDirectChannel(
        authorization: String?,
        serverId: String,
        body: DirectChannelRequest?
    ) throws -> DirectChannelResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        guard let body else { throw ManagedMCPToolExecutionError.invalidDirectMessagePeer }
        if let agentId = body.agentId {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
                throw ManagedMCPToolExecutionError.agentNotFoundInServer
            }
            let peer = DirectChannelPeerFacts(
                peerId: agent.id,
                peerName: agent.name,
                peerDisplayName: agent.displayName,
                peerDescription: agent.description,
                peerGravatarHash: nil,
                peerAvatarUrl: agent.avatarUrl,
                peerType: "agent"
            )
            let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: agentId, secondKind: .agent)
            oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            channels.upsertDirectChannel(serverId: serverId, channelId: channelId, memberIds: [userId, agentId])
            let payload = OrderedJSON.object([OrderedJSONField("channelId", channelId)]).render()
            realtime.emit("channel:\(channelId)", "dm:new", payload)
            realtime.emit("user:\(userId)", "dm:new", payload)
            return directChannelResponse(channelId: channelId, peer: peer)
        }
        guard let peerId = body.userId, oauth.memberRole(serverId: serverId, userId: peerId) != nil else {
            throw ManagedMCPToolExecutionError.invalidDirectMessagePeer
        }
        // Upstream's user-DM row projects the peer account; the refusal runs
        // before any membership/sidebar write instead of leaving a partial DM.
        guard let peer = directPeerFacts(peerId: peerId, peerType: "user") else {
            throw ManagedMCPToolExecutionError.invalidDirectMessagePeer
        }
        let existingDm = oauth.channelsForServer(serverId: serverId, userId: userId).first { channel in
            channel.type == "dm"
                && oauth.channelHumanIds(channelId: channel.id).contains(userId)
                && oauth.channelHumanIds(channelId: channel.id).contains(peerId)
        }
        let hiddenDirectory = channels.hideHumansFromMembers[serverId] == true
        if existingDm == nil, hiddenDirectory, peerId != userId {
            throw ManagedMCPToolExecutionError.directMessageTargetNotFound
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
        channels.upsertDirectChannel(serverId: serverId, channelId: channelId, memberIds: [userId, peerId])
        return directChannelResponse(channelId: channelId, peer: peer)
    }

    // MARK: - GET /api/channels/dm

    public func listDirectChannels(authorization: String?, serverId: String) throws -> DirectChannelListResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        let rows = messages.humanMessageRows
        let rowFacts = ChannelRowFacts(oauth: oauth, messages: messages)
        struct Candidate {
            let kind: Int
            let index: Int
            let row: DirectChannelListRowDTO
            let lastMessageAt: Date?
            let createdAt: Date?
        }
        var candidates: [Candidate] = []
        for (index, channel) in oauth.channelsForServer(serverId: serverId, userId: userId).enumerated() {
            guard channel.type == "dm" else { continue }
            let agentIds = oauth.channelAgentIds(channelId: channel.id)
            let humanIds = oauth.channelHumanIds(channelId: channel.id)
            let peer: DirectChannelPeerFacts
            let kind: Int
            if let agentId = agentIds.first(where: { $0 != userId }) {
                // A deleted agent peer stays hydratable by detail id but must
                // not reappear in the normal DM list.
                if oauth.agentRuntimeInfo(id: agentId)?.deleted == true { continue }
                // Upstream inner-joins the agent table; a membership naming a
                // missing agent row is not a directory row.
                guard let facts = directPeerFacts(peerId: agentId, peerType: "agent") else { continue }
                peer = facts
                kind = 0
            } else if let humanId = humanIds.first(where: { $0 != userId }) {
                guard let facts = directPeerFacts(peerId: humanId, peerType: "user") else { continue }
                peer = facts
                kind = 1
            } else {
                guard let facts = directPeerFacts(peerId: userId, peerType: "user") else { continue }
                peer = facts
                kind = 2
            }
            let lastRow = rows.filter { $0.channelId == channel.id }.max { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.seq < rhs.seq
            }
            let lastMessageAt = lastRow?.createdAt ?? channel.lastMessageAt
            let muted = channel.activityMuted && channel.muteFromSeq != nil
            let displayPrefs = oauth.channelDisplayPrefs(channelId: channel.id, userId: userId)
            let readState = rowFacts.readState(channelId: channel.id, userId: userId)
            let row = DirectChannelListRowDTO(
                id: channel.id,
                name: channel.name,
                description: channel.description,
                createdAt: channel.createdAt.map(isoFractional),
                peer: peer,
                activityMuted: muted,
                muteFromSeq: muted ? channel.muteFromSeq : nil,
                prefsVersion: channel.prefsVersion,
                collapseLongMessages: displayPrefs.collapseLongMessages,
                displayPrefsVersion: displayPrefs.prefsVersion,
                maxReadSeq: readState.maxReadSeq,
                readStateVersion: readState.readStateVersion,
                readState: readState,
                lastMessageAt: lastMessageAt.map(isoFractional),
                lastMessagePreview: lastRow.flatMap { ChannelLastMessageSummary.preview($0.content) },
                lastMessageSenderName: lastRow.flatMap(lastMessageSenderName)
            )
            candidates.append(Candidate(
                kind: kind, index: index, row: row, lastMessageAt: lastMessageAt, createdAt: channel.createdAt
            ))
        }
        // Upstream: most recent message first, then creation time for DMs with
        // no messages; equal keys keep the agent, user, self order and the
        // original row order. A restored row without a creation time is not
        // ordered by an invented date: it sorts after the known rows.
        candidates.sort { a, b in
            if let aLast = a.lastMessageAt, let bLast = b.lastMessageAt {
                if aLast != bLast { return aLast > bLast }
            } else if a.lastMessageAt == nil, b.lastMessageAt != nil {
                return false
            } else if a.lastMessageAt != nil, b.lastMessageAt == nil {
                return true
            } else {
                let aCreated = a.createdAt ?? .distantFuture
                let bCreated = b.createdAt ?? .distantFuture
                if aCreated != bCreated { return aCreated < bCreated }
            }
            if a.kind != b.kind { return a.kind < b.kind }
            return a.index < b.index
        }
        return DirectChannelListResponse(rows: candidates.map(\.row))
    }

    /// Upstream `attachLastMessageSummary`'s sender resolution:
    /// `COALESCE(NULLIF(display_name,''), name, NULLIF(agent.display_name,''),
    /// agent.name, external_author.display_name)`. The non-uuid `system`
    /// sender has no user/agent row and publishes null.
    private func lastMessageSenderName(_ row: StoredHumanMessage) -> String? {
        if row.senderId == "system" { return nil }
        switch row.senderType {
        case "agent":
            guard let agent = oauth.agentRuntimeInfo(id: row.senderId) else { return nil }
            if !agent.displayName.isEmpty { return agent.displayName }
            return agent.name
        case "external_projection":
            return row.externalSenderName
        default:
            guard let account = profiles.account(userId: row.senderId) else { return nil }
            if let displayName = account.displayName, !displayName.isEmpty { return displayName }
            return account.name
        }
    }

    /// The DM peer block projected from the retained agent or account facts.
    /// Agent DMs never carry a gravatar hash; human/self peers hash the stored
    /// email exactly like upstream (`sha256(trim(lower(email)))`).
    private func directPeerFacts(peerId: String, peerType: String) -> DirectChannelPeerFacts? {
        if peerType == "agent" {
            guard let agent = oauth.agentRuntimeInfo(id: peerId) else { return nil }
            return DirectChannelPeerFacts(
                peerId: agent.id,
                peerName: agent.name,
                peerDisplayName: agent.displayName,
                peerDescription: agent.description,
                peerGravatarHash: nil,
                peerAvatarUrl: agent.avatarUrl,
                peerType: "agent"
            )
        }
        guard let account = profiles.account(userId: peerId) else { return nil }
        return DirectChannelPeerFacts(
            peerId: account.id,
            peerName: account.name,
            peerDisplayName: account.displayName,
            peerDescription: account.description,
            peerGravatarHash: Self.gravatarHash(email: account.email),
            peerAvatarUrl: account.avatarUrl,
            peerType: "user"
        )
    }

    private static func gravatarHash(email: String) -> String {
        AuthTokenCodec.sha256Hex(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The `POST /api/channels/dm` row: the same DM channel row upstream's
    /// `findOrCreateDM`/`findOrCreateUserDM` return, without the list-only
    /// joined/read/prefs fields.
    private func directChannelResponse(channelId: String, peer: DirectChannelPeerFacts) -> DirectChannelResponse {
        let info = oauth.channelInfo(id: channelId)
        return DirectChannelResponse(
            id: channelId,
            name: info?.name ?? "",
            description: info?.description,
            createdAt: oauth.channelCreatedAt(id: channelId).map(isoFractional),
            peer: peer
        )
    }

    // MARK: - Read receipts

    /// Replaces the read-update observer; invocation uses the owner's slot
    /// snapshot after its Mutex has been released.
    public func installReadUpdateObserver(_ observer: (@Sendable (String, String, String, Int) -> Void)?) {
        notifications.onAgentReadUpdated = observer
    }

    /// Whether read receipts are enabled for the server.
    public func readReceiptsEnabled(serverId: String) -> Bool {
        channels.readReceiptsEnabled(serverId: serverId)
    }

    /// The startup transport's original, stricter read-receipt filter.
    public func shouldEmitStartupScopeRead(serverId: String, channelId: String, agentId: String) -> Bool {
        guard channels.readReceiptsEnabled(serverId: serverId),
              let channel = oauth.channelInfo(id: channelId),
              channel.serverId == serverId,
              channel.name != "all",
              let type = oauth.channelType(id: channelId),
              ["channel", "private", "dm"].contains(type),
              oauth.channelAgentIds(channelId: channelId).contains(agentId)
        else { return false }
        return true
    }

    /// Publishes `scope_read:updated` for an agent's read of a channel it is a
    /// member of, when the server has read receipts enabled.
    public func emitAgentScopeRead(serverId: String, channelId: String, agentId: String, maxReadSeq: Int) {
        let enabled = channels.readReceiptsEnabled(serverId: serverId)
        let peer = oauth.channelAgentIds(channelId: channelId).contains(agentId)
        guard enabled, peer else { return }
        let payload = OrderedJSON.object([
            OrderedJSONField("scopeId", channelId),
            OrderedJSONField("peerKind", "agent"),
            OrderedJSONField("peerId", agentId),
            OrderedJSONField("maxReadSeq", maxReadSeq),
        ]).render()
        realtime.emit("channel:\(channelId)", "scope_read:updated", payload)
    }

    /// Activity suppression is a fact-only query shared with execute and inbox.
    func agentMessageSuppressed(_ message: StoredHumanMessage, agentId: String) -> Bool {
        suppression.isSuppressed(message, agentId: agentId)
    }

    // MARK: - POST /internal/agent-api/channels/archive|unarchive

    /// The mute is keyed by the agent receiver, not the channel, and only
    /// channel members may set it.
    public func agentChannelArchive(
        authorization: String?,
        body: AgentChannelArchiveRequest?,
        archive: Bool
    ) throws -> AgentChannelArchiveResponse {
        try requireCapability(authorization, "channels")
        guard let writer = taskCredentials.writer(authorization: authorization, legacyAgentId: nil) else {
            throw ChannelMembershipError.agentTokenInvalid
        }
        guard let target = body?.target,
              let channelId = taskCredentials.channel(serverId: writer.serverId, agentId: writer.agentId, reference: target)
        else {
            throw ManagedMCPToolExecutionError.invalidChannelTarget
        }
        channels.setArchivedFlag(channelId: channelId, archived: archive)
        return AgentChannelArchiveResponse(archived: archive)
    }

    // MARK: - POST /internal/agent-api/channels/:channelId/mute|unmute

    public func agentSetChannelMute(
        authorization: String?,
        channelId: String,
        muted: Bool
    ) throws -> AgentChannelMuteResponse {
        try requireCapability(authorization, "channels")
        guard let writer = credentialLookup.agentWriterAndRole(authorization: authorization, legacyAgentId: nil, scopes: [])?.agent,
              let agent = oauth.agentRuntimeInfo(id: writer.id), !agent.deleted
        else {
            throw ChannelMembershipError.agentTokenInvalid
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        let isMember = channels.postableChannel(id: channelId)?.memberIds.contains(agent.id) == true
            || agents.channelAgentMembers[channelId]?.contains(agent.id) == true
            || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
        guard isMember else { throw ManagedMCPToolExecutionError.agentNotChannelMember }
        let latest = messages.humanMessageRows.filter { $0.channelId == channelId }.map(\.seq).max() ?? 0
        let state = oauth.setActivityMuted(
            channelId: channelId,
            receiverId: agent.id,
            muted: muted,
            muteFromSeq: muted ? latest + 1 : nil
        )
        return AgentChannelMuteResponse(
            muted: muted,
            muteFromSeq: muted ? (state.prefs.muteFromSeq ?? (latest + 1)) : nil,
            channelId: channelId,
            channelName: channel.name
        )
    }

    // MARK: - GET /api/channels/:channelId

    public func channelDetail(
        authorization: String?,
        serverId: String,
        channelId: String
    ) throws -> ChannelDetailResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        if visibility.guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            throw ChannelMembershipError.channelNotFound
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        // A thread is visible to whoever can see its parent; a private parent
        // must not leak its child thread's existence or metadata.
        let threadParentId = type == "thread" ? oauth.channelParentChannelId(id: channelId) : nil
        let canSee = threadParentId.map { parentId in
            oauth.channelInfo(id: parentId)?.serverId == serverId
                && visibility.actorCanSee(channelId: parentId, userId: userId)
        } ?? visibility.actorCanSee(channelId: channelId, userId: userId)
        guard canSee else { throw ChannelMembershipError.channelNotFound }
        let snapshot = channels.state
        let joined = channel.name == "all"
            || snapshot.postableChannels[channelId]?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: channelId).contains(userId)
        let receiptsEnabled = snapshot.readReceiptsServers.contains(serverId)
        let peerSeqs = oauth.channelAgentIds(channelId: channelId).map { agentId in
            (agentId, messages.agentChannelReadSeq(channelId: channelId, agentId: agentId))
        }
        let serverRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        let localRole = snapshot.channelHumanRoles["\(channelId)\n\(userId)"]
        let authorityRevision = snapshot.channelAuthorityRevisions[channelId] ?? 1
        let basis: String? = localRole == "admin" ? "channel_role"
            : ((serverRole == "owner" || serverRole == "admin") ? "server_role" : nil)
        let serverAdmin = serverRole == "owner" || serverRole == "admin"
        let capability = basis != nil
        let isJoint = snapshot.jointProjections.contains { $0.localChannelId == channelId }
        var peerReadState: ChannelDetailResponse.PeerReadState?
        if receiptsEnabled {
            if peerSeqs.count > 50 {
                var counts: [Int: Int] = [:]
                for (_, seq) in peerSeqs { counts[seq, default: 0] += 1 }
                peerReadState = .summary(
                    peerCount: peerSeqs.count,
                    readCountAtSeq: counts.keys.sorted().map { (seq: $0, count: counts[$0] ?? 0) }
                )
            } else {
                peerReadState = .states(peerSeqs.map { (peerId: $0.0, maxReadSeq: $0.1) })
            }
        }
        let displayPrefs = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        let readState = ChannelRowFacts(oauth: oauth, messages: messages)
            .readState(channelId: channelId, userId: userId)
        var directPeer: DirectChannelPeerFacts?
        if type == "dm" {
            let agentIds = oauth.channelAgentIds(channelId: channelId)
            let humanIds = oauth.channelHumanIds(channelId: channelId)
            if let agentId = agentIds.first(where: { $0 != userId }) {
                if let agent = oauth.agentRuntimeInfo(id: agentId) {
                    directPeer = DirectChannelPeerFacts(
                        peerId: agent.id,
                        peerName: agent.name,
                        peerDisplayName: agent.displayName,
                        peerDescription: agent.description,
                        peerGravatarHash: nil,
                        peerAvatarUrl: agent.avatarUrl,
                        peerType: "agent"
                    )
                } else {
                    // Upstream keeps a participant DM hydratable when the peer
                    // agent row is gone: `COALESCE(agents.name, channels.name,
                    // 'Agent')`.
                    directPeer = DirectChannelPeerFacts(
                        peerId: agentId,
                        peerName: channel.name.isEmpty ? "Agent" : channel.name,
                        peerDisplayName: nil,
                        peerDescription: nil,
                        peerGravatarHash: nil,
                        peerAvatarUrl: nil,
                        peerType: "agent"
                    )
                }
            } else if let peerId = humanIds.first(where: { $0 != userId }) {
                directPeer = directPeerFacts(peerId: peerId, peerType: "user")
            } else if humanIds.contains(userId) {
                directPeer = directPeerFacts(peerId: userId, peerType: "user")
            }
        }
        return ChannelDetailResponse(
            id: channelId,
            serverId: channel.serverId,
            name: channel.name,
            description: channel.description,
            type: type,
            createdAt: oauth.channelCreatedAt(id: channelId).map(isoFractional),
            directPeer: directPeer,
            joined: joined,
            collapseLongMessages: displayPrefs.collapseLongMessages,
            displayPrefsVersion: displayPrefs.prefsVersion,
            maxReadSeq: readState.maxReadSeq,
            readStateVersion: readState.readStateVersion,
            readState: readState,
            activityMuteSupported: ChannelActivityMuteSupport.supports(type),
            channelRole: basis == nil ? "member" : "admin",
            channelAdminBasis: basis,
            capabilities: .init(
                editChannelMetadata: capability,
                archiveChannels: capability && !isJoint,
                addChannelMembers: capability && !isJoint,
                removeChannelMembers: capability && !isJoint,
                changeChannelMemberRoles: capability,
                manageGuestAccess: serverAdmin && !isJoint,
                deleteChannels: serverAdmin,
                changeChannelVisibility: serverAdmin,
                federateChannels: serverAdmin
            ),
            channelAuthorityRevision: authorityRevision,
            peerReadState: peerReadState
        )
    }

    // MARK: - GET|PATCH /api/channels/:channelId/message-display-settings

    private func requireDisplayPrefsAccess(userId: String, serverId: String, channelId: String) throws {
        if oauth.channelType(id: channelId) == "thread" {
            throw ManagedMCPToolExecutionError.displayPreferencesOnParentChannel
        }
        guard oauth.canAccessChannelPrefs(channelId: channelId, userId: userId, serverId: serverId) else {
            throw ChannelMembershipError.channelNotFound
        }
    }

    public func channelDisplaySettings(
        authorization: String?,
        serverId: String,
        channelId: String
    ) throws -> ChannelDisplaySettingsResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        try requireDisplayPrefsAccess(userId: userId, serverId: serverId, channelId: channelId)
        let prefs = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        return ChannelDisplaySettingsResponse(
            collapseLongMessages: prefs.collapseLongMessages,
            prefsVersion: prefs.prefsVersion
        )
    }

    public func patchChannelDisplaySettings(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: ChannelDisplayPatchRequest?
    ) throws -> ChannelDisplaySettingsResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        try requireDisplayPrefsAccess(userId: userId, serverId: serverId, channelId: channelId)
        try requireNotArchived(channelId)
        guard let collapse = body?.collapseLongMessages else {
            throw ManagedMCPToolExecutionError.collapseLongMessagesNotBoolean
        }
        let prefs = oauth.setCollapseLongMessages(channelId: channelId, userId: userId, collapse: collapse)
        return ChannelDisplaySettingsResponse(
            collapseLongMessages: prefs.collapseLongMessages,
            prefsVersion: prefs.prefsVersion
        )
    }

    // MARK: - POST /api/channels/:channelId/read

    public func updateChannelReadState(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: ChannelReadRequest?
    ) throws -> ChannelReadStateResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        if visibility.guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            throw ChannelMembershipError.channelNotFound
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        guard canReadChannel(channelId: channelId, serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.channelNotFound
        }
        guard let seq = body?.seq, seq >= 0 else { throw ManagedMCPToolExecutionError.invalidReadSeq }
        switch messages.advanceChannelRead(
            channelId: channelId,
            userId: userId,
            seq: seq,
            maxReadSeq: { oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq }
        ) {
        case .unchanged(let maxReadSeq, let version):
            return ChannelReadStateResponse(maxReadSeq: maxReadSeq, readStateVersion: version)
        case .advanced(let version):
            oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: seq)
            return ChannelReadStateResponse(maxReadSeq: seq, readStateVersion: version)
        }
    }

    // MARK: - POST /api/channels/:channelId/resume-all-agents

    /// Sends an optional resume prompt to every agent in the channel (or the
    /// explicit `agentIds` subset) and reports an agent whose start was skipped
    /// instead of counting it resumed. A `nil` body is a body that is not a JSON
    /// object; a blank body is an empty request.
    public func resumeAllAgents(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: ResumeAllAgentsRequest?
    ) async throws -> ResumeAllAgentsResponse {
        let userId = try requireSession(authorization)
        _ = try requireMember(serverId: serverId, userId: userId)
        guard let body else { throw ManagedMCPToolExecutionError.invalidResumeRequest }
        var requestedAgentIds: Set<String>?
        switch body.agentIds {
        case .absent: break
        case .invalid: throw ManagedMCPToolExecutionError.agentIdsNotArray
        case .ids(let ids): requestedAgentIds = Set(ids)
        }
        guard let channel = channels.postableChannel(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        guard canReadChannel(channelId: channelId, serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.channelNotFound
        }
        let channelAgentIds = Array(agents.channelAgentMembers[channelId] ?? []).sorted()
        let targets = requestedAgentIds.map { requested in channelAgentIds.filter { requested.contains($0) } }
            ?? channelAgentIds
        let dispatch = agents.agentStartDispatch
        var results: [ResumeAllAgentsResponse.Result] = []
        var started = 0
        for agentId in targets {
            var dispatched = false
            var skipReason: String?
            if let dispatch {
                do {
                    switch try await dispatch(agentId, body.prompt) {
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
            results.append(ResumeAllAgentsResponse.Result(agentId: agentId, skipReason: skipReason))
        }
        return ResumeAllAgentsResponse(started: started, total: targets.count, results: results)
    }

    // MARK: - POST /api/channels/:channelId/read-all

    public func markChannelReadAll(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: ChannelReadAllRequest?
    ) throws -> ChannelReadAllResponse {
        let userId = try requireSession(authorization)
        let role = try requireMember(serverId: serverId, userId: userId)
        if visibility.guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            throw ChannelMembershipError.channelNotFound
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        // A kinded receiver delegates the read to that agent. Authority is the
        // server role or the agent's creator, never the caller's own membership:
        // the human caller's read state must stay untouched.
        if let receiver = body?.receiver {
            guard receiver.kind == "agent",
                  let agent = oauth.agentRuntimeInfo(id: receiver.id),
                  agent.serverId == serverId
            else {
                throw ChannelMembershipError.forbidden
            }
            let canDelegate = role == "owner" || role == "admin" || agent.creatorUserId == userId
            guard canDelegate, oauth.channelAgentIds(channelId: channelId).contains(agent.id) else {
                throw ChannelMembershipError.forbidden
            }
            let latestSeq = oauth.channelUnreadInfo(channelId: channelId, userId: userId).latestSeq ?? 0
            let advance = messages.advanceAgentChannelRead(
                channelId: channelId,
                agentId: receiver.id,
                latestSeq: latestSeq
            )
            if advance.advanced {
                notifications.onAgentReadUpdated?(serverId, channelId, receiver.id, latestSeq)
            }
            return ChannelReadAllResponse(seq: advance.seq, readStateVersion: max(advance.version, 1))
        }
        let deletedInboxResidueRead = channels.postableChannel(id: channelId)?.deletedAt != nil
            && oauth.channelType(id: channelId) != "dm"
        let readableAll = deletedInboxResidueRead
            || canReadChannel(channelId: channelId, serverId: serverId, userId: userId)
        guard readableAll else {
            let facts = inboxFacts.all().filter {
                $0.receiverType == "user" && $0.receiverId == userId
                    && $0.channelId == channelId && $0.serverId == serverId
            }
            var ownedSeq = oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq
            if let lastFact = facts.last,
               let owned = oauth.historyMessages(channelId: channelId).first(where: { $0.id == lastFact.messageId }) {
                ownedSeq = max(ownedSeq, owned.seq)
            }
            guard ownedSeq > 0 else { throw ChannelMembershipError.channelNotFound }
            oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: ownedSeq)
            let version = messages.markInboxScopeDone(channelId: channelId, userId: userId, at: now())
            return ChannelReadAllResponse(seq: ownedSeq, readStateVersion: version)
        }
        let latest = oauth.channelUnreadInfo(channelId: channelId, userId: userId).latestSeq ?? 0
        let version = messages.bumpChannelReadVersion(channelId: channelId, userId: userId)
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: latest)
        return ChannelReadAllResponse(seq: latest, readStateVersion: version)
    }
}
