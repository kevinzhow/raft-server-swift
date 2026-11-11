import Foundation

/// One conversation an agent reads, with what its wake hint is addressed to.
private struct AgentConversation {
    var id: String
    var storage: String
    var name: String
    var kind: String
}

/// The agent-facing reads: the mentions feed, the content-free wake hints and
/// the event drain.
extension ReactionsRealtimeService {
    /// The most messages one conversation hands out per event drain.
    static let agentInboxPullCap = 5

    // MARK: - GET /internal/agent-api/mentions

    /// Outsider rows stay hidden until they were notifiable at send or later
    /// notified.
    public func agentMentionInbox(
        authorization: String?,
        limit rawLimit: String? = nil
    ) throws -> AgentMentionInboxResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ReactionsRealtimeError.agentAuthorizationMissing
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = dependencies.agentCredential(token),
              credential.scopes.contains("mentions")
        else {
            throw ReactionsRealtimeError.agentTokenInvalid
        }
        let rows = messages.agentMentionRows(agentId: credential.agentId)
        let page = Array(rows.reversed().prefix(MessagePageCursor.messagePageLimit(rawLimit)))
        return AgentMentionInboxResponse(
            messageIds: page.map(\.messageId),
            hasMore: rows.count > page.count
        )
    }

    // MARK: - GET /internal/agent-api/wake-hints

    /// A content-free peek at pending messages: it repeats until `/events`
    /// drains them, never advances a cursor, and never returns message bodies.
    /// `since` is a numeric seq or `latest`; `limit` bounds the batch. A read
    /// credential also sees the undrained third-party events as wake hints.
    public func agentWakeHints(
        authorization: String?,
        since: String?,
        limit: String? = nil
    ) throws -> AgentWakeHintsResponse {
        let (agentId, agent) = try agentIdentity(authorization)
        let rawSince = (since ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var sinceSeq: Int?
        if !rawSince.isEmpty, rawSince != "latest" {
            guard let value = Int(rawSince), value >= 0 else {
                throw ReactionsRealtimeError.sinceInvalid
            }
            sinceSeq = value
        }
        let hintLimit = min(max(Int(limit ?? "") ?? 100, 1), 500)
        let pending = pendingWakeHints(agentId: agentId, agent: agent, sinceSeq: sinceSeq, limit: hintLimit)
        var hints = pending.hints
        for event in oauth.pendingThirdPartyEventMessages(agentId: agentId) {
            hints.append(AgentWakeHint(seq: nil, messageId: event.id, target: nil))
        }
        return AgentWakeHintsResponse(
            hints: hints,
            lastHintSeq: pending.hints.last?.seq,
            hasMore: pending.hasMore
        )
    }

    /// Pending, content-free wake hints for one agent, ordered by server seq.
    /// The peek route and the SSE stream share this projection so both surfaces
    /// agree on the hint set and ordering.
    func pendingWakeHints(
        agentId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        sinceSeq: Int?,
        limit: Int
    ) -> (hints: [AgentWakeHint], hasMore: Bool) {
        let postable = channels.postableChannels
        let conversations = agentConversations(agentId: agentId, agent: agent, postable: postable)
        let pending = messages.pendingAgentMessages(
            conversations: conversations.map { AgentInboxConversation(id: $0.id, storage: $0.storage) },
            agentId: agentId,
            sinceSeq: sinceSeq,
            prefs: notificationPrefs(agentId: agentId, conversations: conversations)
        )
        let targets = conversations.map { wakeTarget($0, agentId: agentId, postable: postable) }
        let hints = pending.prefix(limit).map { entry in
            AgentWakeHint(seq: entry.seq, messageId: entry.message.id, target: targets[entry.conversationIndex])
        }
        return (hints, pending.count > limit)
    }

    /// What a hint for this conversation is addressed to.
    private func wakeTarget(
        _ conversation: AgentConversation,
        agentId: String,
        postable: [String: PostableChannel]
    ) -> String {
        switch conversation.kind {
        case "dm":
            let peer = postable[conversation.id]?.memberIds.first { $0 != agentId }
                .flatMap { dependencies.userName($0) }
            return "dm:@\(peer ?? conversation.name)"
        case "thread":
            if let channel = postable[conversation.id],
               let parentId = channel.parentChannelId,
               let parentName = postable[parentId]?.name {
                let parentShort = channel.parentMessageId.map { String($0.prefix(8)) }
                return "#\(parentName):\(parentShort ?? "")"
            }
            return "#\(conversation.name)"
        default:
            return "#\(conversation.name)"
        }
    }

    // MARK: - GET /internal/agent-api/events

    /// Drains the agent's pending events: unread messages (advancing its read
    /// cursors), queued action replies and third-party app events.
    public func agentThirdPartyEvents(authorization: String?) throws -> AgentEventsResponse {
        let (agentId, agent) = try agentIdentity(authorization)
        let actionEvents = cards.takePendingActionMessageEvents(agentId: agentId)
        let postable = channels.postableChannels
        let conversations = agentConversations(agentId: agentId, agent: agent, postable: postable)
        let drain = messages.drainAgentInbox(
            conversations: conversations.map { AgentInboxConversation(id: $0.id, storage: $0.storage) },
            agentId: agentId,
            prefs: notificationPrefs(agentId: agentId, conversations: conversations),
            pullCap: Self.agentInboxPullCap
        )

        var events: [AgentEventEntry] = []
        var nextSeq = 0
        for row in drain.selected.sorted(by: { $0.seq < $1.seq }) {
            nextSeq = max(nextSeq, row.seq)
            let message = row.message
            let conversation = conversations[row.conversationIndex]
            let senderName = message.externalSenderName
                ?? dependencies.userName(message.senderId)
                ?? (message.senderId == "system" ? "system" : message.senderId)
            let senderType: String
            if message.senderType == "external_projection" {
                senderType = "third_party_app"
            } else if message.messageType == "system" || message.senderId == "system" {
                senderType = "system"
            } else if message.senderType == "agent" {
                senderType = "agent"
            } else {
                senderType = "human"
            }
            events.append(.message(
                seq: row.seq,
                messageId: message.id,
                senderId: message.senderId,
                senderName: senderName,
                senderType: senderType,
                content: message.content,
                mentioned: drain.mentionedMessageIds.contains(message.id),
                channelId: conversation.id,
                channelName: conversation.name,
                channelType: conversation.kind == "dm" ? "dm" : "channel",
                timestamp: DateText.isoString(message.createdAt),
                attachments: attachments(for: message),
                external: senderType == "third_party_app"
                    ? AgentEventEntry.ExternalMessage(
                        messageId: message.externalMessageId,
                        provider: message.externalProvider,
                        actorName: message.externalSenderName
                    )
                    : nil
            ))
        }
        for event in actionEvents {
            nextSeq += 1
            events.append(.action(seq: nextSeq, messageId: event.messageId, content: event.content))
        }
        for message in oauth.takeThirdPartyEventMessages(agentId: agentId) {
            nextSeq += 1
            events.append(.thirdParty(
                seq: nextSeq,
                messageId: message.id,
                content: Self.inertThirdPartyMentions(message.summary),
                kind: message.kind,
                summary: message.summary,
                source: AgentEventEntry.ThirdPartySource(
                    clientId: message.clientKey,
                    clientName: message.clientName,
                    oauthClientId: message.clientRecordId,
                    resource: "urn:raft:server:\(message.serverId):agent-inbound"
                )
            ))
        }
        return AgentEventsResponse(events: events, hasMore: drain.hasMore)
    }

    // MARK: - Shared

    /// The agent read credential plus the live agent behind it.
    private func agentIdentity(
        _ authorization: String?
    ) throws -> (agentId: String, agent: OAuthLedger.AgentRuntimeInfo) {
        switch dependencies.agentReadOutcome(authorization) {
        case .missingAuthorization:
            throw ReactionsRealtimeError.agentAuthorizationMissing
        case .invalidCredential:
            throw ReactionsRealtimeError.agentTokenInvalid
        case .success(let agentId):
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
                throw ReactionsRealtimeError.agentTokenInvalid
            }
            return (agentId, agent)
        }
    }

    /// Every visible conversation of the agent's server, keyed by the channel
    /// the agent reads, in channel id order.
    private func agentConversations(
        agentId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        postable: [String: PostableChannel]
    ) -> [AgentConversation] {
        let joint = channels.jointProjections
        var conversations: [AgentConversation] = []
        for (id, channel) in postable.sorted(by: { $0.key < $1.key }) {
            guard channel.serverId == agent.serverId, channel.deletedAt == nil else { continue }
            let visible: Bool
            if channel.kind == "dm" || channel.kind == "thread" || channel.kind == "private" {
                visible = channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
            } else {
                visible = true
            }
            guard visible else { continue }
            let storage = joint.first { $0.localChannelId == id }?.canonicalChannelId ?? id
            conversations.append(AgentConversation(id: id, storage: storage, name: channel.name, kind: channel.kind))
        }
        return conversations
    }

    /// The agent's notification preferences for every channel its messages are
    /// stored under.
    private func notificationPrefs(
        agentId: String,
        conversations: [AgentConversation]
    ) -> [String: OAuthLedger.ChannelNotificationPrefs] {
        var prefs: [String: OAuthLedger.ChannelNotificationPrefs] = [:]
        for conversation in conversations where prefs[conversation.storage] == nil {
            prefs[conversation.storage] = oauth.notificationPrefs(channelId: conversation.storage, userId: agentId)
        }
        return prefs
    }

    /// `@name` in a third-party summary is made inert so it cannot mention.
    private static func inertThirdPartyMentions(_ text: String) -> String {
        text.replacingOccurrences(
            of: "@([A-Za-z0-9_.-]+)",
            with: "user:$1",
            options: .regularExpression
        )
    }
}

extension ReactionsRealtimeService {
    /// The agent-facing attachment envelope for one drained message.
    func attachments(for message: StoredHumanMessage) -> [AgentHistoryMessage.Attachment] {
        messages.orderedAttachmentRows(for: message).compactMap { entry in
            guard let row = entry.row, row.channelId == message.channelId else { return nil }
            return AgentHistoryMessage.Attachment(
                id: row.id,
                filename: row.filename,
                mimeType: ChannelFileRules.resolveAttachmentMimeType(filename: row.filename, stored: row.mimeType),
                sizeBytes: row.sizeBytes
            )
        }
    }
}
