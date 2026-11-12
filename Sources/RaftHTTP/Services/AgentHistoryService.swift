import Foundation

/// The not-yet-migrated lookups the history read needs. The thread lookups
/// belong to the action-card helpers, and the read-update hook is set by the
/// application on the notifications store; all enter as closures.
public struct AgentHistoryDependencies: Sendable {
    /// `(parentId, anchorMessageId)` to the live thread channel id.
    var threadByAnchor: @Sendable (_ parentId: String, _ anchorMessageId: String) -> String?
    /// `(parentId, idPrefix)` to the live thread channel id.
    var threadById: @Sendable (_ parentId: String, _ suffix: String) -> String?
    /// `(parentId, anchorPrefix)` to the live thread channel id.
    var threadByAnchorPrefix: @Sendable (_ parentId: String, _ suffix: String) -> String?
    /// Reports a moved read cursor: `(serverId, channelId, agentId, seq)`.
    var agentReadUpdated: @Sendable (_ serverId: String, _ channelId: String, _ agentId: String, _ seq: Int) -> Void
    var now: @Sendable () -> Date

    init(
        threadByAnchor: @escaping @Sendable (String, String) -> String?,
        threadById: @escaping @Sendable (String, String) -> String?,
        threadByAnchorPrefix: @escaping @Sendable (String, String) -> String?,
        agentReadUpdated: @escaping @Sendable (String, String, String, Int) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.threadByAnchor = threadByAnchor
        self.threadById = threadById
        self.threadByAnchorPrefix = threadByAnchorPrefix
        self.agentReadUpdated = agentReadUpdated
        self.now = now
    }
}

/// The agent history read and the machine channel join/leave.
///
/// The read cursors and deferred-advance marks live in
/// `MessagesAndThreadsStore`; each cursor move is one critical section there.
public struct AgentHistoryService: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let machines: MachinesAndComputersStore
    let agents: AgentsRuntimeStore
    let accounts: AuthProfileStore
    let feedback: FeedbackStore
    let oauth: OAuthLedger
    let actionCardPrepare: ActionCardPrepareService
    let channelMembership: ChannelMembershipService
    let dependencies: AgentHistoryDependencies

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        machines: MachinesAndComputersStore,
        agents: AgentsRuntimeStore,
        accounts: AuthProfileStore,
        feedback: FeedbackStore,
        oauth: OAuthLedger,
        actionCardPrepare: ActionCardPrepareService,
        channelMembership: ChannelMembershipService,
        dependencies: AgentHistoryDependencies
    ) {
        self.messages = messages
        self.channels = channels
        self.machines = machines
        self.agents = agents
        self.accounts = accounts
        self.feedback = feedback
        self.oauth = oauth
        self.actionCardPrepare = actionCardPrepare
        self.channelMembership = channelMembership
        self.dependencies = dependencies
    }

    // MARK: - History

    public func history(
        authorization: String?,
        agentId: String? = nil,
        channelRef: String?,
        before: String?,
        after: String?,
        around: String? = nil,
        limit: String?,
        consume: String? = nil,
        unread: Bool = false
    ) throws -> AgentHistoryResponse {
        let agent = try historyAgent(authorization: authorization, requestedAgentId: agentId)
        let reference = (channelRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { throw AgentHistoryError.channelRequired }
        if reference.hasPrefix("agent-event:") {
            return try thirdPartyEvent(agent: agent, ref: String(reference.dropFirst("agent-event:".count)))
        }
        let postable = channels.postableChannels
        let resolved = try resolveChannel(reference: reference, agent: agent, postable: postable)
        guard let channelId = resolved.channelId, isVisible(channelId, to: agent, postable: postable) else {
            throw AgentHistoryError.channelNotVisible
        }
        let channelCard = channelCard(channelId: channelId, postable: postable)
        let peerCard = actionCardPrepare.peerCardJSON(channelId: channelId, agentId: agent.id)
        let rows = oauth.historyMessages(channelId: channelId)
        let pageLimit = min(max(Int(limit ?? "") ?? 50, 1), 100)
        // `consume=false`: return the page without marking it read, for reads
        // whose output may never reach the model.
        let consumeValue = (consume ?? "true").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard consumeValue == "true" || consumeValue == "false" else { throw AgentHistoryError.invalidConsume }
        let target = resolved.canonicalTarget ?? reference
        if unread {
            guard (after ?? "").isEmpty, (before ?? "").isEmpty, (around ?? "").isEmpty else {
                throw AgentHistoryError.unreadWithAnchor(target: target)
            }
            return .unread(unreadPage(
                agent: agent, channelId: channelId, rows: rows, pageLimit: pageLimit, target: target
            ))
        }
        return .page(try regularPage(
            agent: agent, channelId: channelId, rows: rows, pageLimit: pageLimit,
            reference: reference, target: target, before: before, after: after, around: around,
            consume: consumeValue == "true", scope: resolved.consumptionScope,
            channelCard: channelCard, peerCard: peerCard
        ))
    }

    /// The agent behind a bearer agent credential (needs `read`) or a machine
    /// key naming one of its server's agents.
    private func historyAgent(authorization: String?, requestedAgentId: String?) throws -> OAuthLedger.AgentRuntimeInfo {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentHistoryError.missingAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let credential = agents.agentCredential(token: token)
        let machine = machines.machine(apiKey: token)
        let resolvedAgentId: String
        if let credential {
            guard credential.scopes.contains("read") else { throw AgentHistoryError.invalidToken }
            resolvedAgentId = credential.agentId
        } else if let machine, let requestedAgentId,
                  let candidate = oauth.agentRuntimeInfo(id: requestedAgentId),
                  !candidate.deleted,
                  candidate.serverId == machine.serverId {
            resolvedAgentId = requestedAgentId
        } else {
            throw AgentHistoryError.invalidToken
        }
        guard let agent = oauth.agentRuntimeInfo(id: resolvedAgentId), !agent.deleted else {
            throw AgentHistoryError.invalidToken
        }
        return agent
    }

    private func thirdPartyEvent(agent: OAuthLedger.AgentRuntimeInfo, ref: String) throws -> AgentHistoryResponse {
        switch oauth.readThirdPartyAgentEventForAgent(agentId: agent.id, ref: ref) {
        case .ambiguous:
            throw AgentHistoryError.eventAddressAmbiguous
        case .expired:
            throw AgentHistoryError.eventExpired
        case .absent:
            throw AgentHistoryError.channelNotVisible
        case .found(let message):
            return .thirdPartyEvent(AgentHistoryThirdPartyEvent(
                id: message.id,
                content: message.content,
                clientKey: message.clientKey,
                clientName: message.clientName,
                createdAt: message.createdAt,
                kind: message.kind,
                externalEventId: message.externalEventId,
                payloadHash: message.payloadHash,
                payloadJSON: message.payloadJSON.isEmpty ? "{}" : message.payloadJSON,
                expiresAt: message.expiresAt
            ))
        }
    }

    // MARK: - Channel resolution

    private struct ResolvedChannel {
        var channelId: String?
        var canonicalTarget: String?
        var consumptionScope: AgentHistoryConsumptionScope?
    }

    private func resolveChannel(
        reference: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        postable: [String: PostableChannel]
    ) throws -> ResolvedChannel {
        var resolved = ResolvedChannel()
        // The one suffix rule (pinned `parseChannelRef`): only a full 8-hex
        // suffix is a thread id. Any other `:...` stays part of the base ref,
        // so it fails as a channel/peer lookup instead of opening a thread.
        let parsedRef = AgentChannelRef.parse(reference)
        if reference.hasPrefix("#") {
            let name = String(parsedRef.baseRef.dropFirst())
            let suffix = parsedRef.threadShortId
            var parentId: String?
            let candidates = postable.filter { _, channel in
                channel.serverId == agent.serverId
                    && channel.name == name
                    && channel.deletedAt == nil
                    && (channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint")
            }
            for (id, channel) in candidates {
                if channel.kind == "channel" {
                    parentId = id
                    break
                }
                if channel.memberIds.contains(agent.id) {
                    parentId = id
                    break
                }
                if oauth.channelAgentIds(channelId: id).contains(agent.id) {
                    parentId = id
                    break
                }
            }
            guard let parentId else { throw AgentHistoryError.channelNotVisible }
            guard let suffix, !suffix.isEmpty else {
                resolved.channelId = parentId
                resolved.canonicalTarget = "#\(name)"
                return resolved
            }
            let lowerSuffix = suffix.lowercased()
            let anchor = oauth.historyMessages(channelId: parentId).first {
                $0.id.lowercased().hasPrefix(lowerSuffix)
            }
            var threadId: String?
            if let anchor {
                threadId = dependencies.threadByAnchor(parentId, anchor.id)
                if threadId == nil {
                    throw AgentHistoryError.noThreadOnMessage(suffix: suffix, channelName: name)
                }
            } else {
                threadId = dependencies.threadById(parentId, lowerSuffix)
                if threadId == nil {
                    threadId = dependencies.threadByAnchorPrefix(parentId, lowerSuffix)
                }
                if threadId == nil { throw AgentHistoryError.channelNotVisible }
            }
            if let threadId, let thread = postable[threadId] {
                resolved.channelId = threadId
                let parentName = postable[parentId]?.name ?? name
                let anchorShort = thread.parentMessageId.map { String($0.prefix(8)) } ?? suffix
                resolved.canonicalTarget = "#\(parentName):\(anchorShort)"
            }
            return resolved
        }
        if reference.hasPrefix("dm:@") || reference.hasPrefix("DM:@") {
            let rawPeer = String(parsedRef.baseRef.dropFirst(4))
            let suffix = parsedRef.threadShortId
            // Pinned `resolveDMByPeerName` checks the reserved reminders handle
            // on the exact raw peer, case-insensitively, BEFORE parsing `~kind`
            // and only on the non-thread arm. `dm:@remindersX` is an ordinary
            // peer and `dm:@reminders~agent` is an agent named reminders; only
            // the exact word names the agent's own private surface.
            if suffix == nil, rawPeer.lowercased() == AgentChannelRef.remindersPeer {
                guard let surface = feedback.agentReminderSurfaceChannels[agent.id],
                      isVisible(surface, to: agent, postable: postable) else {
                    throw AgentHistoryError.channelNotVisible
                }
                let target = AgentChannelRef.dmRef(name: AgentChannelRef.remindersPeer, kind: nil)
                resolved.channelId = surface
                resolved.canonicalTarget = target
                resolved.consumptionScope = AgentHistoryConsumptionScope(
                    agentId: agent.id, channelId: surface, channelType: "dm", target: target
                )
                return resolved
            }
            let peer: (name: String, kind: String?)
            switch AgentChannelRef.parsePeer(rawPeer) {
            case .unknownKind(let invalid):
                // Pinned `resolveChannelByName` refuses a malformed peer kind
                // even when a thread suffix follows.
                throw AgentHistoryError.dmTargetInvalidPeerKind(rawPeer: rawPeer, suffix: invalid)
            case .emptyName:
                throw AgentHistoryError.channelNotVisible
            case .ok(let name, let kind):
                peer = (name, kind)
            }
            let resolution = actionCardPrepare.resolveDMPeer(
                serverId: agent.serverId, agentId: agent.id, name: peer.name, kind: peer.kind
            )
            switch resolution {
            case .ambiguous(let name):
                throw AgentHistoryError.dmTargetAmbiguous(name: name)
            case .invalidKind(let kind, _):
                throw AgentHistoryError.dmTargetInvalidPeerKind(rawPeer: rawPeer, suffix: kind)
            case .notFound:
                throw AgentHistoryError.channelNotVisible
            case .resolved(let peerId, let peerKind, let peerName):
                guard let dmId = actionCardPrepare.dmChannelId(
                    serverId: agent.serverId, agentId: agent.id, peerId: peerId, peerKind: peerKind, peerName: peerName
                ), isVisible(dmId, to: agent, postable: postable) else {
                    throw AgentHistoryError.channelNotVisible
                }
                // The published target is the DM's own canonical peer label,
                // never the caller's spelling (pinned
                // `resolveAgentFacingChannelRef`), so it carries `~kind` for a
                // cross-kind twin and collapses case variants.
                let dmTarget = canonicalDMRef(channelId: dmId, agent: agent, postable: postable)
                    ?? parsedRef.baseRef
                guard let suffix, !suffix.isEmpty else {
                    resolved.channelId = dmId
                    resolved.canonicalTarget = dmTarget
                    resolved.consumptionScope = AgentHistoryConsumptionScope(
                        agentId: agent.id, channelId: dmId, channelType: "dm", target: dmTarget
                    )
                    return resolved
                }
                let lowerSuffix = suffix.lowercased()
                let anchor = oauth.historyMessages(channelId: dmId).first {
                    $0.id.lowercased().hasPrefix(lowerSuffix)
                }
                var threadId = anchor.flatMap { found in
                    dependencies.threadByAnchor(dmId, found.id)
                }
                if threadId == nil { threadId = dependencies.threadById(dmId, lowerSuffix) }
                guard let threadId else { throw AgentHistoryError.channelNotVisible }
                let anchorShort = postable[threadId]?.parentMessageId.map { String($0.prefix(8)) } ?? suffix
                let threadTarget = "\(dmTarget):\(anchorShort)"
                resolved.channelId = threadId
                resolved.canonicalTarget = threadTarget
                resolved.consumptionScope = AgentHistoryConsumptionScope(
                    agentId: agent.id, channelId: threadId, channelType: "thread", target: threadTarget
                )
                return resolved
            }
        }
        resolved.channelId = postable.keys.first { $0 == reference }
        return resolved
    }

    /// The canonical agent-facing target of one DM channel. The pinned history
    /// route publishes `resolveAgentFacingChannelRef(...)`, so a twinned peer
    /// reads as `dm:@name~agent` / `dm:@name~human` and the reminder surface
    /// reads as `dm:@reminders`.
    private func canonicalDMRef(
        channelId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        postable: [String: PostableChannel]
    ) -> String? {
        guard let channel = postable[channelId], channel.kind == "dm" else { return nil }
        return actionCardPrepare.dmPeerResolver.canonicalRef(
            serverId: agent.serverId,
            agentId: agent.id,
            channelId: channelId,
            channel: channel,
            reminderSurfaceId: feedback.agentReminderSurfaceChannels[agent.id]
        )
    }

    private func isVisible(
        _ channelId: String, to agent: OAuthLedger.AgentRuntimeInfo, postable: [String: PostableChannel]
    ) -> Bool {
        _ = postable
        return AgentChannelAccessQuery(channels: channels, messages: messages, oauth: oauth)
            .canAccess(channelId: channelId, serverId: agent.serverId, agentId: agent.id)
    }

    private func channelCard(channelId: String, postable: [String: PostableChannel]) -> AgentHistoryChannelCard? {
        guard let channel = postable[channelId], channel.kind != "dm" else { return nil }
        let cardId: String
        if channel.kind == "thread", let parent = channel.parentChannelId {
            cardId = parent
        } else {
            cardId = channelId
        }
        guard let info = oauth.channelInfo(id: cardId) else { return nil }
        return AgentHistoryChannelCard(
            id: cardId,
            name: info.name,
            type: oauth.channelType(id: cardId) ?? "channel",
            description: info.description,
            archived: oauth.channelArchivedAt(id: cardId) != nil || postable[cardId]?.archived == true
        )
    }

    // MARK: - Pages

    private func senderName(_ senderId: String, isAgent: Bool) -> String {
        if isAgent { return oauth.agentRuntimeInfo(id: senderId)?.name ?? senderId }
        guard let account = accounts.account(userId: senderId) else { return senderId }
        return AgentSenderNaming.humanName(account)
    }

    /// The agent-facing attachment envelope for one stored message. The row's
    /// link order is the published order; MIME follows the same filename
    /// fallback the pinned server applies to a stored attachment.
    private func attachments(for message: OAuthLedger.HistoryMessage) -> [AgentHistoryMessage.Attachment] {
        guard let stored = messages.humanMessageRows.first(where: { $0.id == message.id }) else { return [] }
        let commentsVisible = channels.postableChannel(id: stored.channelId).map {
            agents.evaluateFeatureFlag(key: "attachment_comments_v0", userId: "", serverId: $0.serverId,
                platform: nil, client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)).enabled
        } ?? false
        let comments = messages.state.attachmentCommentRecords
        return messages.orderedAttachmentRows(for: stored).compactMap { entry in
            guard let row = entry.row, row.messageId == stored.id else { return nil }
            let metadata = CanonicalMessagePayload.Attachment(row)
            return AgentHistoryMessage.Attachment(
                id: metadata.id, filename: metadata.filename, mimeType: metadata.mimeType,
                sizeBytes: metadata.sizeBytes, width: metadata.width, height: metadata.height,
                thumbnailUrl: metadata.thumbnailUrl,
                commentCount: commentsVisible ? (comments[row.id]?.filter { $0.hostMessageId == stored.id }.count ?? 0) : 0
            )
        }
    }

    private func unreadPage(
        agent: OAuthLedger.AgentRuntimeInfo,
        channelId: String,
        rows: [OAuthLedger.HistoryMessage],
        pageLimit: Int,
        target: String
    ) -> AgentHistoryUnreadPage {
        let position = messages.agentUnreadPosition(channelId: channelId, agentId: agent.id)
        let priorSeq = position.priorSeq
        var priorBoundary = priorSeq
        let settledCutoff = dependencies.now().addingTimeInterval(-Double(position.settleMs) / 1000)
        if let pendingDeferred = position.pendingDeferred {
            var advanced = priorSeq
            for message in rows
            where message.seq > priorSeq && message.seq <= pendingDeferred && message.createdAt <= settledCutoff {
                advanced = max(advanced, message.seq)
            }
            if advanced > priorSeq {
                messages.commitDeferredUnreadAdvance(channelId: channelId, agentId: agent.id, seq: advanced)
                dependencies.agentReadUpdated(agent.serverId, channelId, agent.id, advanced)
                priorBoundary = advanced
            } else if rows.contains(where: { $0.seq == pendingDeferred && $0.createdAt <= settledCutoff }) {
                messages.clearDeferredUnreadAdvance(channelId: channelId, agentId: agent.id)
            }
        }
        let candidates = rows.filter { $0.seq > priorBoundary }
        let visible = candidates.filter { $0.senderId != agent.id }
        let page = Array(visible.prefix(pageLimit))
        let hasNewer = visible.count > page.count
        var advanceSeq = priorBoundary
        let boundary = page.map(\.seq).max() ?? priorBoundary
        for message in candidates where message.seq <= boundary && message.createdAt <= settledCutoff {
            advanceSeq = max(advanceSeq, message.seq)
        }
        if advanceSeq == priorBoundary, !page.isEmpty, let lastSeq = page.map(\.seq).max() {
            messages.deferUnreadAdvance(channelId: channelId, agentId: agent.id, seq: lastSeq)
        }
        if advanceSeq > priorBoundary {
            messages.setAgentReadCursor(channelId: channelId, agentId: agent.id, seq: advanceSeq)
            dependencies.agentReadUpdated(agent.serverId, channelId, agent.id, advanceSeq)
        }
        let projected = page.map { message -> AgentHistoryMessage in
            let isAgent = message.senderId == agent.id || message.senderType == "agent"
            return AgentHistoryMessage(
                id: message.id, channelId: channelId, content: message.content, seq: message.seq,
                senderType: isAgent ? "agent" : "user",
                senderId: message.senderId,
                senderName: senderName(message.senderId, isAgent: isAgent),
                senderTimezone: nil,
                createdAt: message.createdAt,
                attachments: self.attachments(for: message),
                mentioned: nil,
                external: nil
            )
        }
        return AgentHistoryUnreadPage(
            messages: projected,
            hasNewer: hasNewer,
            lastReadSeq: priorSeq,
            modelSeenUpToSeq: page.map(\.seq).max() ?? advanceSeq,
            target: target
        )
    }

    private func regularPage(
        agent: OAuthLedger.AgentRuntimeInfo,
        channelId: String,
        rows: [OAuthLedger.HistoryMessage],
        pageLimit: Int,
        reference: String,
        target: String,
        before: String?,
        after: String?,
        around: String?,
        consume: Bool,
        scope: AgentHistoryConsumptionScope?,
        channelCard: AgentHistoryChannelCard?,
        peerCard: String?
    ) throws -> AgentHistoryPage {
        var beforeSeq: Int?
        if let before, !before.isEmpty {
            beforeSeq = try resolveAnchor(
                channelId: channelId, anchor: before, channelRef: reference, purpose: .pagination
            )
        }
        var afterSeq: Int?
        if let after, !after.isEmpty {
            afterSeq = try resolveAnchor(
                channelId: channelId, anchor: after, channelRef: reference, purpose: .pagination
            )
        }
        var page: [OAuthLedger.HistoryMessage] = []
        var hasOlder = false
        var hasNewer = false
        var isAroundPage = false
        if let around, !around.isEmpty {
            let seq = try resolveAnchor(channelId: channelId, anchor: around, channelRef: reference, purpose: .around)
            guard let index = rows.firstIndex(where: { $0.seq == seq }) else {
                throw AgentHistoryError.anchorNotFound("Message not found in \(reference): \(around)")
            }
            let beforeCount = (pageLimit - 1) / 2
            let afterCount = pageLimit - beforeCount - 1
            let start = max(0, index - beforeCount)
            let end = min(rows.count, index + afterCount + 1)
            page = Array(rows[start..<end])
            hasOlder = start > 0
            hasNewer = end < rows.count
            isAroundPage = true
        } else {
            var filtered = rows
            if let beforeSeq { filtered = filtered.filter { $0.seq < beforeSeq } }
            if let afterSeq { filtered = filtered.filter { $0.seq > afterSeq } }
            let probed = filtered.count > pageLimit
            if afterSeq != nil {
                page = Array(filtered.prefix(pageLimit))
                hasOlder = false
                hasNewer = probed
            } else {
                page = Array(filtered.suffix(pageLimit))
                hasOlder = probed
                hasNewer = false
            }
        }
        let priorSeq = messages.agentReadSeq(channelId: channelId, agentId: agent.id)

        // A read may advance the read position only when its window joins the
        // prior boundary without a hidden gap: an `after` page only when its
        // exclusive anchor is at/below the cursor, a latest/before page only
        // when it reaches the oldest row or overlaps the cursor. Otherwise the
        // bodies remain useful but earlier unseen rows stay unread.
        var modelSeenSeq: Int?
        if consume, !isAroundPage, let maximum = page.map(\.seq).max(), maximum > 0 {
            let minimum = page.map(\.seq).min() ?? maximum
            let canAdvance = afterSeq.map { $0 <= priorSeq } ?? (!hasOlder || minimum <= priorSeq)
            if canAdvance, maximum > priorSeq {
                messages.setAgentReadCursor(channelId: channelId, agentId: agent.id, seq: maximum)
                modelSeenSeq = maximum
                dependencies.agentReadUpdated(agent.serverId, channelId, agent.id, maximum)
            }
        }

        let annotations = messages.historyAnnotations(messageIds: Set(page.map(\.id)), agentId: agent.id)
        let projected = page.map { message -> AgentHistoryMessage in
            let senderType: String
            if message.messageType == "system" || message.senderId == "system" {
                senderType = "system"
            } else if message.senderType == "external_projection" {
                senderType = "third_party_app"
            } else if message.senderId == agent.id || message.senderType == "agent" {
                senderType = "agent"
            } else {
                senderType = "user"
            }
            var external: AgentHistoryMessage.External?
            if senderType == "third_party_app", let facts = annotations.external[message.id] {
                external = AgentHistoryMessage.External(
                    messageId: facts.messageId, provider: facts.provider, actorName: facts.actor
                )
            }
            return AgentHistoryMessage(
                id: message.id, channelId: channelId, content: message.content, seq: message.seq,
                senderType: senderType,
                senderId: message.senderId,
                senderName: senderName(message.senderId, isAgent: senderType == "agent"),
                senderTimezone: message.senderTimezone,
                createdAt: message.createdAt,
                attachments: self.attachments(for: message),
                mentioned: annotations.mentionedIds.contains(message.id),
                external: external
            )
        }
        return AgentHistoryPage(
            messages: projected,
            hasOlder: hasOlder,
            hasNewer: hasNewer,
            lastReadSeq: priorSeq,
            modelSeenUpToSeq: modelSeenSeq,
            target: target,
            consumptionScope: scope,
            channelCard: channelCard,
            peerCardJSON: peerCard
        )
    }

    // MARK: - Anchors

    private enum AnchorPurpose {
        case pagination
        case around
    }

    /// History anchors accept a sequence number, a full message UUID, or the
    /// 8-character short id. `pagination` keeps decimal values as seqs even at
    /// short-id width; `around` is a locator and prefers the short id first.
    private func resolveAnchor(
        channelId: String, anchor: String, channelRef: String, purpose: AnchorPurpose
    ) throws -> Int {
        let trimmed = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitsOnly = !trimmed.isEmpty && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
        let shortIdShape = trimmed.count == 8 && trimmed.allSatisfy { $0.isHexDigit }
        let uuidShape = ServerScope.isUUID(trimmed)
        let rows = oauth.historyMessages(channelId: channelId)
        let notFound = AgentHistoryError.anchorNotFound("Message not found in \(channelRef): \(trimmed)")

        if purpose == .pagination, digitsOnly, let value = Int(trimmed) {
            return value
        }
        if shortIdShape {
            let matches = rows.filter { $0.id.lowercased().hasPrefix(trimmed.lowercased()) }
            if matches.count > 1 {
                throw AgentHistoryError.anchorAmbiguous("Message anchor is ambiguous in \(channelRef): \(trimmed)")
            }
            if let match = matches.first { return match.seq }
            throw notFound
        }
        if digitsOnly, let value = Int(trimmed) {
            return value
        }
        if uuidShape {
            if let match = rows.first(where: { $0.id.lowercased() == trimmed.lowercased() }) {
                return match.seq
            }
            throw notFound
        }
        if purpose == .around {
            throw AgentHistoryError.anchorInvalid(
                "Message anchor must be a seq, full UUID, or 8-character short id in \(channelRef): \(trimmed)"
            )
        }
        throw notFound
    }

    // MARK: - Machine channel membership

    /// `POST /internal/agent/:agentId/channels/:channelId/{join,leave}` with a
    /// machine key.
    public func agentChannelMembershipFromMachine(
        authorization: String?, agentId: String, channelId: String, join: Bool
    ) throws -> OkResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentHistoryError.missingAuthorization
        }
        let credential = machines.machineCredential(
            apiKey: String(authorization.dropFirst("Bearer ".count)), agentId: nil
        )
        guard let machineServerId = credential.machine?.serverId ?? credential.legacy?.serverId else {
            throw AgentHistoryError.invalidToken
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machineServerId else {
            throw AgentHistoryError.agentNotFound
        }
        if join {
            return try channelMembership.joinPublicChannel(
                agentId: agent.id, serverId: agent.serverId, channelId: channelId
            )
        }
        return try channelMembership.leaveChannel(agentId: agent.id, serverId: agent.serverId, channelId: channelId)
    }
}
