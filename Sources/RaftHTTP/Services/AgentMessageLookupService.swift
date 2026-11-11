import Foundation

/// Domain failure for the agent message lookups.
///
/// Two of the published bodies are not the default `{"error": …}` object: the
/// not-joinable refusal is `{"status":"NOT_JOINABLE"}`, and the lookup refusals
/// carry `errorCode` (and a hint) instead of `code`. The two lookup messages
/// interpolate the caller's `messageRef` into the JSON text unescaped, as the
/// retired handlers did, so their bodies enter as `OrderedJSON.raw` to keep the
/// bytes.
public enum AgentMessageLookupError: DomainError, Equatable {
    case authRequired
    case capabilityNotAuthorized
    case notJoinable
    case messageNotFound(String)
    case ambiguousMessageId(String)

    public var status: UInt {
        switch self {
        case .authRequired:
            401
        case .capabilityNotAuthorized:
            403
        case .notJoinable, .messageNotFound:
            404
        case .ambiguousMessageId:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .authRequired:
            "Invalid or expired token"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .notJoinable:
            "NOT_JOINABLE"
        case .messageNotFound(let reference):
            "Message not found: \(reference)"
        case .ambiguousMessageId(let reference):
            "Ambiguous message id: \(reference)"
        }
    }

    public var errorCode: String? {
        switch self {
        case .authRequired:
            "auth_required"
        case .capabilityNotAuthorized, .notJoinable, .messageNotFound, .ambiguousMessageId:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .capabilityNotAuthorized:
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "capability_not_authorized"),
                OrderedJSONField("requiredCapability", "read"),
            ])
        case .notJoinable:
            .object([OrderedJSONField("status", "NOT_JOINABLE")])
        case .messageNotFound(let reference):
            .raw("{\"error\":\"Message not found: \(reference)\",\"errorCode\":\"NOT_FOUND\"}")
        case .ambiguousMessageId(let reference):
            .raw("{\"error\":\"Ambiguous message id: \(reference)\",\"errorCode\":\"AMBIGUOUS_ID\",\"suggestedNextAction\":\"Retry with the full message UUID.\"}")
        case .authRequired:
            nil
        }
    }
}

// MARK: - Injected dependencies

/// The agent credential lookup (unmigrated agent-api domain) and the shared
/// message-visibility rule that the migrated search service owns.
struct AgentMessageLookupDependencies: Sendable {
    var agentCredential: @Sendable (String?) -> (agentId: String, scopes: [String])?
    var messageVisible: @Sendable (_ channelId: String, _ serverId: String, _ agentId: String) -> Bool
}

extension AgentMessageLookupDependencies {
    init(lookup: AgentCredentialLookup, search: SearchMentionsService) {
        self.init(
            agentCredential: lookup.agentCredentialAgent,
            messageVisible: { channelId, serverId, agentId in
                search.messageVisible(messageChannelId: channelId, serverId: serverId, viewer: .agent(agentId))
            }
        )
    }
}

// MARK: - Service

/// The two read-only message lookups an agent runs on its own sends and on a
/// message reference it was handed: the mention-delivery outcomes of a message
/// the agent authored, and the resolution of a full or prefixed message id into
/// its channel and sender context.
///
/// Both read one `MessagesAndThreadsStore` snapshot (rows and mention rows in
/// the same critical section) and one channel snapshot; nothing is written.
public struct AgentMessageLookupService: Sendable {
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let dependencies: AgentMessageLookupDependencies

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        dependencies: AgentMessageLookupDependencies
    ) {
        self.messages = messages
        self.channels = channels
        self.profiles = profiles
        self.oauth = oauth
        self.dependencies = dependencies
    }

    private func requireReadingAgent(_ authorization: String?) throws -> OAuthLedger.AgentRuntimeInfo {
        guard let credential = dependencies.agentCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentMessageLookupError.authRequired
        }
        guard credential.scopes.contains("read") else {
            throw AgentMessageLookupError.capabilityNotAuthorized
        }
        return agent
    }

    /// `GET /internal/agent-api/messages/:messageId/mention-deliveries`.
    public func agentMentionDeliveries(
        authorization: String?,
        messageRef: String
    ) throws -> AgentMentionDeliveriesResponse {
        let agent = try requireReadingAgent(authorization)
        let state = messages.state
        guard let message = state.humanMessageRows.first(where: { $0.id == messageRef }),
              message.senderType == "agent",
              message.senderId == agent.id,
              dependencies.messageVisible(message.channelId, agent.serverId, agent.id)
        else {
            throw AgentMessageLookupError.notJoinable
        }
        // Upstream lists the occurrence rows themselves, so a row whose mention
        // has since been deleted from the projection is still reported; the
        // authored handle comes from the mention record (`handleAtSendTime`).
        let deliveries = state.storedMentions
            .filter { $0.messageId == message.id && $0.mentionDeliveryOccurrence != nil }
            .sorted { $0.id < $1.id }
            .map { mention in
                AgentMentionDeliveriesResponse.Delivery(
                    targetHandle: mention.handle,
                    outcome: MentionDeliverySenderProjection.outcome(
                        occurrence: mention.mentionDeliveryOccurrence))
            }
        return AgentMentionDeliveriesResponse(messageId: message.id, deliveries: deliveries)
    }

    /// `GET /internal/agent-api/messages/:messageId/resolve`.
    public func agentMessageResolve(
        authorization: String?,
        messageRef: String
    ) throws -> AgentMessageResolveResponse {
        let agent = try requireReadingAgent(authorization)
        return try messageResolve(agent: agent, messageRef: messageRef)
    }

    /// The resolution itself, after an owner has established the acting agent.
    /// The legacy machine route and the credential route publish the same body;
    /// only the credential check in front of them differs.
    func messageResolve(
        agent: OAuthLedger.AgentRuntimeInfo,
        messageRef: String
    ) throws -> AgentMessageResolveResponse {
        let state = messages.state
        let channelState = channels.state
        let postableChannels = channelState.postableChannels
        let jointProjections = channelState.jointProjections

        let candidates = state.humanMessageRows.filter { message in
            message.id == messageRef || message.id.hasPrefix(messageRef.lowercased())
        }
        var matches: [(message: StoredHumanMessage, storageChannelId: String, localChannelId: String?)] = []
        for message in candidates {
            if dependencies.messageVisible(message.channelId, agent.serverId, agent.id) {
                matches.append((message, message.channelId, nil))
                continue
            }
            let storageChannelId = message.channelId
            let canonicalId: String?
            if let link = jointProjections.first(where: { $0.localChannelId == storageChannelId }) {
                canonicalId = link.canonicalChannelId
            } else if jointProjections.contains(where: { $0.canonicalChannelId == storageChannelId }) {
                canonicalId = storageChannelId
            } else {
                canonicalId = nil
            }
            if let canonicalId,
               let localId = jointLocalChannelId(
                   canonicalChannelId: canonicalId,
                   serverId: agent.serverId,
                   agentId: agent.id,
                   jointProjections: jointProjections,
                   postableChannels: postableChannels
               ),
               dependencies.messageVisible(localId, agent.serverId, agent.id) {
                matches.append((message, storageChannelId, localId))
            }
        }
        guard !matches.isEmpty else { throw AgentMessageLookupError.messageNotFound(messageRef) }
        guard matches.count == 1, let matched = matches.first else {
            throw AgentMessageLookupError.ambiguousMessageId(messageRef)
        }
        let message = matched.message
        let effectiveChannelId = matched.localChannelId ?? matched.storageChannelId
        let channel = postableChannels[effectiveChannelId]
        let kind = channel?.kind ?? "channel"
        let channelType = kind == "dm" ? "dm" : (kind == "thread" ? "thread" : "channel")
        let channelName: String
        if kind == "dm" {
            let humans = oauth.channelHumanIds(channelId: effectiveChannelId).filter { $0 != agent.id }
            let agents = oauth.channelAgentIds(channelId: effectiveChannelId).filter { $0 != agent.id }
            if let humanId = humans.first, let account = profiles.account(userId: humanId) {
                channelName = account.name
            } else if let peerAgentId = agents.first, let peer = oauth.agentRuntimeInfo(id: peerAgentId) {
                channelName = peer.name
            } else {
                channelName = channel?.name ?? ""
            }
        } else if kind == "thread", let parentId = channel?.parentChannelId, let parent = postableChannels[parentId] {
            channelName = parent.name
        } else {
            channelName = channel?.name ?? ""
        }
        let senderType: String
        let senderName: String
        if message.senderType == "system" || message.senderId == "system" {
            senderType = "system"
            senderName = "system"
        } else if message.senderType == "agent" || oauth.agentRuntimeInfo(id: message.senderId) != nil {
            senderType = "agent"
            senderName = oauth.agentRuntimeInfo(id: message.senderId)?.name ?? ""
        } else {
            senderType = "human"
            senderName = profiles.account(userId: message.senderId)?.name ?? ""
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let mentioned = state.storedMentions.contains {
            $0.messageId == message.id && $0.targetType == "agent" && $0.targetId == agent.id
        }
        return AgentMessageResolveResponse(
            messageId: message.id,
            channelId: effectiveChannelId,
            channelName: channelName,
            channelType: channelType,
            senderType: senderType,
            senderName: senderName,
            content: message.content,
            createdAt: formatter.string(from: message.createdAt),
            senderTimezone: message.senderTimezone,
            mentioned: mentioned,
            attachments: attachments(for: message),
            externalMessage: message.senderType == "external_projection"
                ? AgentMessageResolveResponse.ExternalMessage(
                    messageId: message.externalMessageId,
                    provider: message.externalProvider,
                    actorName: message.externalSenderName
                )
                : nil
        )
    }

    private func attachments(for message: StoredHumanMessage) -> [AgentHistoryMessage.Attachment] {
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

    /// The local channel of a joint canonical channel the agent can act in.
    private func jointLocalChannelId(
        canonicalChannelId: String,
        serverId: String,
        agentId: String,
        jointProjections: [JointChannelLink],
        postableChannels: [String: PostableChannel]
    ) -> String? {
        jointProjections.first { link in
            link.canonicalChannelId == canonicalChannelId
                && link.serverId == serverId
                && (postableChannels[link.localChannelId]?.kind == "joint"
                    || postableChannels[link.localChannelId]?.kind == "channel"
                    || postableChannels[link.localChannelId]?.memberIds.contains(agentId) == true
                    || oauth.channelAgentIds(channelId: link.localChannelId).contains(agentId))
        }?.localChannelId
    }
}
