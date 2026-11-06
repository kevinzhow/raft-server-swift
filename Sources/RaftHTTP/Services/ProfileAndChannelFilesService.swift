import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One typed agent-read outcome.
///
/// The third-party delivery operation needs the same credential check the
/// unmigrated `agentReadCredential` helper performs, but as a value it can map
/// to a `DomainError` instead of inheriting a reply value.
public enum ProfileAgentReadOutcome: Sendable, Equatable {
    case success(agentId: String)
    case missingAuthorization
    case invalidCredential
}

/// The not-yet-migrated dependencies this surface still reads.
///
/// Session lookup lives in `AuthCoreService`, the agent read credential and its
/// use throttle in `AgentPrivateSurfaceService`, the capability decision in
/// `FeedbackLocatorService`, and the attachment-comment projections and channel
/// emitter in the integrations/realtime extensions. Each one enters as a
/// closure so this service never calls the directory or builds a reply.
public struct ProfileAndChannelFilesDependencies: Sendable {
    public var sessionUserId: @Sendable (String?) -> String?
    public var agentRead: @Sendable (String?) -> ProfileAgentReadOutcome
    /// The capability name when a live credential lacks it; `nil` when allowed.
    public var capabilityDenial: @Sendable (String?, String) -> String?
    public var emitRealtime: @Sendable (String, String, String?) -> Void
    public var attachmentCommentsEnabled: @Sendable (String, String) -> Bool
    /// Attachment chips from one Messages snapshot, including gated counts.
    public var attachmentChips: @Sendable ([String], Bool) -> [InboxAttachmentChipDTO]
    /// The scoped comment reference, when the message is a comment.
    public var commentRef: @Sendable (String) -> InboxCommentRefDTO?

    public init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        agentRead: @escaping @Sendable (String?) -> ProfileAgentReadOutcome,
        capabilityDenial: @escaping @Sendable (String?, String) -> String?,
        emitRealtime: @escaping @Sendable (String, String, String?) -> Void,
        attachmentCommentsEnabled: @escaping @Sendable (String, String) -> Bool,
        attachmentChips: @escaping @Sendable ([String], Bool) -> [InboxAttachmentChipDTO],
        commentRef: @escaping @Sendable (String) -> InboxCommentRefDTO?
    ) {
        self.sessionUserId = sessionUserId
        self.agentRead = agentRead
        self.capabilityDenial = capabilityDenial
        self.emitRealtime = emitRealtime
        self.attachmentCommentsEnabled = attachmentCommentsEnabled
        self.attachmentChips = attachmentChips
        self.commentRef = commentRef
    }
}

extension ProfileAndChannelFilesDependencies {
    init(
        auth: AuthCoreService,
        lookup: AgentCredentialLookup,
        locator: FeedbackLocatorService,
        realtime: RealtimeRelayService,
        projection: MessageReadProjection
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            agentRead: lookup.profileReadOutcome,
            capabilityDenial: locator.deniedCapability,
            emitRealtime: realtime.emit,
            attachmentCommentsEnabled: { projection.commentsEnabled(serverId: $0, userId: $1) },
            attachmentChips: projection.attachments,
            commentRef: projection.comment
        )
    }
}

/// The message-reaction surface: the human add/remove ACK, the viewer and actor
/// pages, the two agent reaction routes, and the managed-daemon third-party
/// delivery report.
///
/// Reaction rows, versions and forwarded bundles live in
/// `MessagesAndThreadsStore`; channels, roles and joint links in
/// `ServersAndChannelsStore`; accounts in `AuthProfileStore`; machine keys in
/// `MachinesAndComputersStore`; agent credentials/rows in `AgentsRuntimeStore`.
/// Every reaction write is one store critical section. The service returns
/// ordered DTOs and throws `ProfileAndChannelFilesError`; it never builds a
/// reply, header set or ad-hoc dictionary.
public struct ProfileAndChannelFilesService: Sendable {
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let accounts: AuthProfileStore
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let oauth: OAuthLedger
    private let dependencies: ProfileAndChannelFilesDependencies

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        accounts: AuthProfileStore,
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        oauth: OAuthLedger,
        dependencies: ProfileAndChannelFilesDependencies
    ) {
        self.messages = messages
        self.channels = channels
        self.accounts = accounts
        self.agents = agents
        self.machines = machines
        self.oauth = oauth
        self.dependencies = dependencies
    }

    /// `POST /api/messages/:messageId/reactions`.
    public func addMessageReaction(
        messageId: String,
        emoji: String?,
        authorization: String?,
        serverId: String?
    ) throws -> ReactionMutationResponseDTO {
        try mutateUserReaction(
            messageId: messageId,
            emoji: emoji,
            authorization: authorization,
            serverId: serverId,
            remove: false
        )
    }

    /// `DELETE /api/messages/:messageId/reactions`.
    public func removeMessageReaction(
        messageId: String,
        emoji: String?,
        authorization: String?,
        serverId: String?
    ) throws -> ReactionMutationResponseDTO {
        try mutateUserReaction(
            messageId: messageId,
            emoji: emoji,
            authorization: authorization,
            serverId: serverId,
            remove: true
        )
    }

    /// `GET /api/messages/:messageId/reactions/viewer`.
    public func reactionViewer(
        messageId: String,
        authorization: String?,
        serverId: String?
    ) throws -> ReactionViewerResponseDTO {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ProfileAndChannelFilesError.authRequired(
                bearerPresent: authorization?.hasPrefix("Bearer ") == true
            )
        }
        let state = channelState()
        switch resolveReactionTarget(
            messageId: messageId,
            userId: userId,
            serverId: serverId,
            rows: messages.humanMessageRows,
            state: state
        ) {
        case .missing:
            throw ProfileAndChannelFilesError.messageNotFound
        case .ambiguous:
            throw ProfileAndChannelFilesError.ambiguousShortId
        case .message(let message, let channel, _):
            guard message.messageType != "system" else {
                throw ProfileAndChannelFilesError.systemMessage
            }
            guard !channel.archived else {
                throw ProfileAndChannelFilesError.channelArchived
            }
            let snapshot = messages.reactionViewerSnapshot(messageId: message.id, userId: userId)
            return ReactionViewerResponseDTO(
                serverId: serverId ?? "",
                messageId: message.id,
                viewerVersion: snapshot.viewerVersion,
                reactedEmojis: snapshot.reactedEmojis
            )
        }
    }

    /// `GET /api/messages/:messageId/reactions/actors`.
    public func listReactionActors(
        messageId: String,
        authorization: String?,
        serverId: String?,
        emoji: String?,
        limit: String?,
        cursor: String?
    ) throws -> ReactionActorsResponseDTO {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ProfileAndChannelFilesError.authRequired(
                bearerPresent: authorization?.hasPrefix("Bearer ") == true
            )
        }
        guard let emoji, let validEmoji = MessagePageCursor.validReactionEmoji(emoji) else {
            throw ProfileAndChannelFilesError.invalidActorEmoji
        }
        let pageLimit: Int
        if let limit {
            guard let parsed = Int(limit), parsed >= 1, parsed <= 100, String(parsed) == limit else {
                throw ProfileAndChannelFilesError.invalidActorLimit
            }
            pageLimit = parsed
        } else {
            pageLimit = 50
        }
        let state = channelState()
        let message: StoredHumanMessage
        let channel: PostableChannel
        let localChannelId: String
        switch resolveReactionTarget(
            messageId: messageId,
            userId: userId,
            serverId: serverId,
            rows: messages.humanMessageRows,
            state: state
        ) {
        case .missing:
            throw ProfileAndChannelFilesError.messageNotFound
        case .ambiguous:
            throw ProfileAndChannelFilesError.ambiguousShortId
        case .message(let resolved, let resolvedChannel, let resolvedLocalId):
            guard resolved.messageType != "system" else {
                throw ProfileAndChannelFilesError.systemMessage
            }
            guard !resolvedChannel.archived else {
                throw ProfileAndChannelFilesError.channelArchived
            }
            message = resolved
            channel = resolvedChannel
            localChannelId = resolvedLocalId
        }
        let discussion = messages.reactionDiscussionSnapshot(messageId: message.id, emoji: validEmoji)
        let currentVersion = discussion.discussionVersion
        var afterKind: String?
        var afterId: String?
        if let cursor {
            guard let decoded = MessagePageCursor.decodeActorCursor(cursor) else {
                throw ProfileAndChannelFilesError.invalidActorCursor
            }
            guard decoded.principalId == userId,
                  decoded.serverId == (serverId ?? ""),
                  decoded.messageId == message.id,
                  decoded.emoji == validEmoji
            else {
                throw ProfileAndChannelFilesError.invalidActorCursor
            }
            let visibility = reactionActorVisibility(
                channelId: localChannelId,
                requesterId: userId,
                state: state
            )
            guard decoded.visibilityHash == visibility.hash else {
                throw ProfileAndChannelFilesError.actorVisibilityChanged
            }
            guard decoded.discussionVersion == currentVersion else {
                throw ProfileAndChannelFilesError.discussionVersionChanged(currentVersion: currentVersion)
            }
            afterKind = decoded.actorKind
            afterId = decoded.actorId
        }
        let visibility = reactionActorVisibility(
            channelId: localChannelId,
            requesterId: userId,
            state: state
        )
        var actors: [ProfileReactionActor] = discussion.rows
            .filter { row in
                (row.reactorType == "user" && visibility.humans.contains(row.reactorId))
                    || (row.reactorType == "agent" && visibility.agents.contains(row.reactorId))
            }
            .map { ProfileReactionActor(kind: $0.reactorType, id: $0.reactorId) }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
                return lhs.id < rhs.id
            }
        if let afterKind, let afterId {
            actors = actors.filter {
                $0.kind > afterKind || ($0.kind == afterKind && $0.id > afterId)
            }
        }
        let hasMore = actors.count > pageLimit
        let page = Array(actors.prefix(pageLimit))
        let nextCursor: String?
        if hasMore, let last = page.last {
            nextCursor = MessagePageCursor.encodeActorCursor(ActorCursor(
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
        let scopeKind = channel.kind == "thread" ? "thread" : "channel"
        let localServer = serverId ?? ""
        let discussionBody = OrderedJSON.object([
            OrderedJSONField("root", .object([
                OrderedJSONField("kind", "message"),
                OrderedJSONField("serverId", localServer),
                OrderedJSONField("id", message.id),
            ])),
            OrderedJSONField("relation", .object([
                OrderedJSONField("kind", "reactionActors"),
                OrderedJSONField("emoji", validEmoji),
            ])),
            OrderedJSONField("parentScope", .object([
                OrderedJSONField("serverId", localServer),
                OrderedJSONField("scopeKind", scopeKind),
                OrderedJSONField("scopeId", localChannelId),
            ])),
        ])
        return ReactionActorsResponseDTO(
            discussion: discussionBody,
            discussionVersion: currentVersion,
            actors: page,
            nextCursor: nextCursor
        )
    }

    /// `POST|DELETE /internal/agent/:agentId/messages/:messageId/reactions`.
    /// The legacy machine key must belong to that agent and the agent must be in
    /// the channel.
    public func mutateAgentMessageReaction(
        agentId: String,
        messageId: String,
        emoji: String?,
        authorization: String?,
        remove: Bool
    ) throws -> ReactionMutationResponseDTO {
        guard let emoji, let validEmoji = MessagePageCursor.validReactionEmoji(emoji) else {
            throw ProfileAndChannelFilesError.invalidEmoji
        }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ProfileAndChannelFilesError.agentAuthRequired(
                message: "Missing or invalid Authorization header"
            )
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let machine = machines.machineKeys[token], machine.agentId == agentId else {
            throw ProfileAndChannelFilesError.agentAuthRequired(message: "Invalid or expired token")
        }
        let state = channelState()
        let rows = messages.humanMessageRows
        guard let message = rows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }),
              state.channels[message.channelId]?.serverId == machine.serverId,
              state.agentMembers[message.channelId]?.contains(agentId) == true
        else {
            throw ProfileAndChannelFilesError.messageNotFound
        }
        let written = messages.applyAgentReaction(
            messageId: message.id,
            agentId: agentId,
            emoji: validEmoji,
            remove: remove
        )
        return mutationResponse(
            message: message,
            rows: written.rows,
            actorId: agentId,
            serverId: machine.serverId,
            state: state,
            viewerVersion: nil
        )
    }

    /// `POST|DELETE /internal/agent-api/messages/:messageId/reactions`.
    /// The credential must include `reactions`; visibility follows the agent's
    /// channel membership and the parent thread rule.
    public func mutateAgentApiMessageReaction(
        messageId: String,
        emoji: String?,
        authorization: String?,
        remove: Bool
    ) throws -> ReactionMutationResponseDTO {
        if let denied = dependencies.capabilityDenial(authorization, "reactions") {
            throw ProfileAndChannelFilesError.capabilityNotAuthorized(capability: denied)
        }
        guard let emoji, let validEmoji = MessagePageCursor.validReactionEmoji(emoji) else {
            throw ProfileAndChannelFilesError.invalidEmoji
        }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ProfileAndChannelFilesError.agentAuthRequired(
                message: "Missing or invalid Authorization header"
            )
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let state = channelState()
        guard let credential = agents.agentCredentials[token],
              credential.scopes.contains("reactions")
        else {
            throw ProfileAndChannelFilesError.agentAuthRequired(message: "Invalid or expired token")
        }
        let agentId = credential.agentId
        let agentServerId: String?
        if let agent = agents.serverAgents[agentId] {
            agentServerId = agent.serverId
        } else if let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted {
            agentServerId = agent.serverId
        } else {
            agentServerId = nil
        }
        guard let agentServerId else {
            throw ProfileAndChannelFilesError.messageNotFound
        }
        let isUUID = ServerScope.isUUID(messageId)
        let isShortId = messageId.count == 8 && messageId.allSatisfy { $0.isHexDigit }
        guard isUUID || isShortId else {
            throw ProfileAndChannelFilesError.invalidMessageId
        }
        func visibleToAgent(_ message: StoredHumanMessage) -> Bool {
            guard let channel = state.channels[message.channelId],
                  channel.serverId == agentServerId
            else { return false }
            if channel.kind == "channel" { return true }
            if channel.kind == "thread",
               let parentId = channel.parentChannelId,
               let parent = state.channels[parentId],
               parent.serverId == agentServerId {
                if parent.kind == "channel" { return true }
                if parent.memberIds.contains(agentId)
                    || state.agentMembers[parentId]?.contains(agentId) == true {
                    return true
                }
            }
            return channel.memberIds.contains(agentId)
                || state.agentMembers[message.channelId]?.contains(agentId) == true
        }
        let candidates = messages.humanMessageRows.filter { message in
            if isUUID {
                return message.id.caseInsensitiveCompare(messageId) == .orderedSame
            }
            return message.id.lowercased().hasPrefix(messageId.lowercased())
        }.filter { visibleToAgent($0) }
        guard let message = candidates.first else {
            throw ProfileAndChannelFilesError.messageNotFound
        }
        guard candidates.count == 1 else {
            throw ProfileAndChannelFilesError.ambiguousShortIdAgentApi
        }
        let written = messages.applyAgentReaction(
            messageId: message.id,
            agentId: agentId,
            emoji: validEmoji,
            remove: remove
        )
        return mutationResponse(
            message: message,
            rows: written.rows,
            actorId: agentId,
            serverId: agentServerId,
            state: state,
            viewerVersion: nil
        )
    }

    /// `POST /internal/agent-api/third-party-events/delivered`.
    public func reportThirdPartyEventsDelivered(
        authorization: String?,
        eventIds: [JSONValue]?
    ) throws -> ThirdPartyEventDeliveryResponseDTO {
        let agentId: String
        switch dependencies.agentRead(authorization) {
        case .missingAuthorization:
            throw ProfileAndChannelFilesError.agentAuthRequired(
                message: "Missing or invalid Authorization header"
            )
        case .invalidCredential:
            throw ProfileAndChannelFilesError.agentAuthRequired(message: "Invalid or expired token")
        case .success(let id):
            agentId = id
        }
        guard let eventIds, !eventIds.isEmpty else {
            throw ProfileAndChannelFilesError.eventIdsNotEmpty
        }
        var ids: [String] = []
        for item in eventIds {
            guard case .string(let text) = item,
                  text.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
            else {
                throw ProfileAndChannelFilesError.eventIdsInvalid
            }
            ids.append(text.lowercased())
        }
        let delivered = oauth.markThirdPartyEventsDelivered(agentId: agentId, ids: ids)
        return ThirdPartyEventDeliveryResponseDTO(delivered: delivered)
    }

    // MARK: - Human reaction write

    private func mutateUserReaction(
        messageId: String,
        emoji: String?,
        authorization: String?,
        serverId: String?,
        remove: Bool
    ) throws -> ReactionMutationResponseDTO {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ProfileAndChannelFilesError.authRequired(
                bearerPresent: authorization?.hasPrefix("Bearer ") == true
            )
        }
        guard let emoji, let validEmoji = MessagePageCursor.validReactionEmoji(emoji) else {
            throw ProfileAndChannelFilesError.invalidEmoji
        }
        let state = channelState()
        switch resolveReactionTarget(
            messageId: messageId,
            userId: userId,
            serverId: serverId,
            rows: messages.humanMessageRows,
            state: state
        ) {
        case .missing:
            throw ProfileAndChannelFilesError.messageNotFound
        case .ambiguous:
            throw ProfileAndChannelFilesError.ambiguousShortId
        case .message(let message, let channel, _):
            guard message.messageType != "system" else {
                throw ProfileAndChannelFilesError.systemMessage
            }
            guard channel.memberIds.contains(userId) else {
                throw ProfileAndChannelFilesError.notChannelMember
            }
            guard !channel.archived else {
                throw ProfileAndChannelFilesError.channelArchived
            }
            let written = messages.applyUserReaction(
                messageId: message.id,
                userId: userId,
                emoji: validEmoji,
                remove: remove
            )
            return mutationResponse(
                message: message,
                rows: written.rows,
                actorId: userId,
                serverId: serverId,
                state: state,
                viewerVersion: written.viewerVersion
            )
        }
    }

    // MARK: - Projection

    /// The channel/role/joint snapshot one request reads. It is not one store
    /// lock because those rows belong to `ServersAndChannelsStore`; the write it
    /// guards is still one `MessagesAndThreadsStore` critical section.
    private struct ChannelState {
        let channels: [String: PostableChannel]
        let jointProjections: [JointChannelLink]
        let memberRoles: [String: String]
        let hiddenServers: [String: Bool]
        let agentMembers: [String: Set<String>]
    }

    private func channelState() -> ChannelState {
        ChannelState(
            channels: channels.postableChannels,
            jointProjections: channels.jointProjections,
            memberRoles: channels.serverMemberRoles,
            hiddenServers: channels.hideHumansFromMembers,
            agentMembers: agents.channelAgentMembers
        )
    }

    private enum ReactionTargetResolution {
        case missing
        case ambiguous
        case message(StoredHumanMessage, PostableChannel, String)
    }

    private func resolveReactionTarget(
        messageId: String,
        userId: String,
        serverId: String?,
        rows: [StoredHumanMessage],
        state: ChannelState
    ) -> ReactionTargetResolution {
        if MessageContext.isShortId(messageId) {
            let matches = rows.filter {
                MessageSearchText.messageIdHasShortPrefix($0.id, prefix: messageId)
                    && reactionMessageVisible($0, userId: userId, serverId: serverId, state: state)
            }
            if matches.count > 1 { return .ambiguous }
            if let message = matches.first, let channel = state.channels[message.channelId] {
                return .message(message, channel, message.channelId)
            }
            return .missing
        }
        guard let message = rows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }) else {
            return .missing
        }
        if reactionMessageVisible(message, userId: userId, serverId: serverId, state: state),
           let channel = state.channels[message.channelId] {
            return .message(message, channel, message.channelId)
        }
        if state.channels[message.channelId]?.deletedAt == nil,
           let localId = jointLocalChannelId(
               canonicalChannelId: message.channelId,
               serverId: serverId,
               userId: userId,
               state: state
           ),
           let local = state.channels[localId],
           local.deletedAt == nil {
            return .message(message, local, localId)
        }
        return .missing
    }

    private func jointLocalChannelId(
        canonicalChannelId: String,
        serverId: String?,
        userId: String,
        state: ChannelState
    ) -> String? {
        guard let serverId else { return nil }
        return state.jointProjections.first { link in
            link.canonicalChannelId == canonicalChannelId
                && link.serverId == serverId
                && state.channels[link.localChannelId]?.memberIds.contains(userId) == true
        }?.localChannelId
    }

    /// Members of every local projection of one joint channel; nil when this
    /// channel is not joint.
    private func jointRoster(channelId: String, state: ChannelState) -> Set<String>? {
        let canonical = state.jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId
            ?? (state.jointProjections.contains { $0.canonicalChannelId == channelId } ? channelId : nil)
        guard let canonical else { return nil }
        var ids = state.channels[canonical]?.memberIds ?? []
        for link in state.jointProjections where link.canonicalChannelId == canonical {
            ids.formUnion(state.channels[link.localChannelId]?.memberIds ?? [])
        }
        return ids
    }

    private func reactionMessageVisible(
        _ message: StoredHumanMessage,
        userId: String,
        serverId: String?,
        state: ChannelState
    ) -> Bool {
        guard let channel = state.channels[message.channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return false }
        if channel.kind == "channel" { return true }
        return channel.memberIds.contains(userId)
    }

    /// On #all, a member of a hidden human directory sees only themself. Agents
    /// stay visible. Owners are not hidden.
    private func reactionActorVisibility(
        channelId: String,
        requesterId: String,
        state: ChannelState
    ) -> (humans: Set<String>, agents: Set<String>, hash: String) {
        guard let channel = state.channels[channelId] else { return ([], [], "") }
        let requesterRole = state.memberRoles["\(channel.serverId)\n\(requesterId)"]
            ?? oauth.memberRole(serverId: channel.serverId, userId: requesterId)
        let hiddenDirectory = state.hiddenServers[channel.serverId] == true
            && requesterRole == "member"
            && channel.name == "all"
            && (channel.kind == "channel" || channel.kind == "private")
        let roster = jointRoster(channelId: channelId, state: state) ?? channel.memberIds
        let humans = hiddenDirectory ? roster.filter { $0 == requesterId } : roster
        let agents = state.agentMembers[channelId] ?? []
        let hash = humans.sorted().joined(separator: ",")
            + "|" + agents.sorted().joined(separator: ",")
        return (humans, agents, hash)
    }

    /// One ACK body plus the `message:updated` frame the legacy writer emitted.
    ///
    /// `viewerVersion` is non-nil only for the human routes, which append the
    /// caller's `reactionViewer` snapshot.
    private func mutationResponse(
        message: StoredHumanMessage,
        rows: [StoredReaction],
        actorId: String,
        serverId: String?,
        state: ChannelState,
        viewerVersion: Int?
    ) -> ReactionMutationResponseDTO {
        let buckets = reactionBuckets(rows: rows)
        let commentsVisible = dependencies.attachmentCommentsEnabled(serverId ?? "", actorId)
        let commentRef = commentsVisible
            ? dependencies.commentRef(message.id)?.jsonBody
            : nil
        let attachments = OrderedJSON.array(dependencies.attachmentChips(message.attachmentIds, commentsVisible).map(\.jsonBody))
        let actionMetadata = forwardedBundleJSON(
            messageId: message.id,
            userId: actorId,
            serverId: serverId,
            scrub: false,
            state: state
        )
        let socketMetadata = forwardedBundleJSON(
            messageId: message.id,
            userId: actorId,
            serverId: serverId,
            scrub: true,
            state: state
        )
        let viewer: OrderedJSON?
        if let viewerVersion {
            let emojis = rows
                .filter {
                    $0.reactorType == "user" && $0.reactorId == actorId
                }
                .map(\.emoji)
                .sorted(by: MessageSearchText.utf16Ascending)
            var body = OrderedJSONObject()
            body.append("serverId", serverId ?? "")
            body.append("messageId", message.id)
            body.append("viewerVersion", viewerVersion)
            body.append("reactedEmojis", .array(emojis.map(OrderedJSON.string)))
            viewer = body.json
        } else {
            viewer = nil
        }

        var payload = OrderedJSONObject()
        payload.append("id", message.id)
        payload.append("channelId", message.channelId)
        payload.append("content", message.content)
        payload.append("senderName", senderName(message.senderId))
        payload.append("commentRef", OrderedJSON.null)
        payload.append("reactions", .array(buckets.map(\.jsonBody)))
        payload.append("actionMetadata", ifPresent: socketMetadata)
        dependencies.emitRealtime(
            "channel:\(message.channelId)",
            "message:updated",
            payload.json.render()
        )
        // The legacy writer published the caller's versioned viewer snapshot on
        // the caller's own room after the channel frame. Agent routes carry no
        // viewer snapshot and therefore emit no viewer frame.
        if let viewer {
            dependencies.emitRealtime(
                "user:\(actorId)",
                "reaction_viewer:updated",
                viewer.render()
            )
        }

        return ReactionMutationResponseDTO(
            reactions: buckets,
            commentRef: commentRef,
            attachments: attachments,
            actionMetadata: actionMetadata,
            reactionViewer: viewer
        )
    }

    /// Emoji buckets in first-reaction order, ids/names in row order.
    private func reactionBuckets(rows: [StoredReaction]) -> [ProfileReactionBucket] {
        var order: [String] = []
        var ids: [String: [String]] = [:]
        var names: [String: [String]] = [:]
        for row in rows {
            if ids[row.emoji] == nil {
                order.append(row.emoji)
                ids[row.emoji] = []
                names[row.emoji] = []
            }
            ids[row.emoji, default: []].append(row.reactorId)
            names[row.emoji, default: []].append(reactionName(row))
        }
        return order.map { emoji in
            ProfileReactionBucket(
                emoji: emoji,
                reactorIds: ids[emoji] ?? [],
                reactorNames: names[emoji] ?? []
            )
        }
    }

    private func reactionName(_ row: StoredReaction) -> String {
        if row.reactorType == "agent" {
            if let runtime = oauth.agentRuntimeInfo(id: row.reactorId) {
                return runtime.displayName.isEmpty ? runtime.name : runtime.displayName
            }
            return agents.serverAgents[row.reactorId]?.name ?? "Unknown agent"
        }
        return accounts.accounts.values.first { $0.id == row.reactorId }
            .map { $0.displayName ?? $0.name } ?? "Unknown user"
    }

    private func senderName(_ senderId: String) -> String {
        accounts.accounts.values.first { $0.id == senderId }?.name ?? "Unknown user"
    }

    /// The HTTP body keeps a forwarded source the viewer can read; the channel
    /// broadcast always strips it.
    private func forwardedBundleJSON(
        messageId: String,
        userId: String,
        serverId: String?,
        scrub: Bool,
        state: ChannelState
    ) -> OrderedJSON? {
        guard let items = messages.forwardedBundles[messageId], !items.isEmpty else { return nil }
        let rendered = items.map { item -> OrderedJSON in
            let readable = !scrub
                && viewerCanReadForwardedSource(item, userId: userId, serverId: serverId, state: state)
            if readable {
                return .object([
                    OrderedJSONField("sourceServerId", item.sourceServerId),
                    OrderedJSONField("sourceTargetId", item.sourceTargetId),
                    OrderedJSONField("sourceMessageId", item.sourceMessageId),
                    OrderedJSONField("sourceTargetSnapshot", .object([
                        OrderedJSONField("id", item.snapshotId),
                        OrderedJSONField("type", item.snapshotType),
                        OrderedJSONField("label", item.snapshotLabel),
                        OrderedJSONField("labelVisibility", item.snapshotLabelVisibility),
                    ])),
                    OrderedJSONField("provenanceState", item.provenanceState),
                ])
            }
            let type = item.snapshotType.isEmpty ? "channel" : item.snapshotType
            return .object([
                OrderedJSONField("sourceMessageId", .null),
                OrderedJSONField("sourceServerId", .null),
                OrderedJSONField("sourceTargetId", .null),
                OrderedJSONField("sourceTargetSnapshot", .object([
                    OrderedJSONField("id", .null),
                    OrderedJSONField("type", type),
                    OrderedJSONField("label", ""),
                    OrderedJSONField("labelVisibility", "restricted"),
                ])),
                OrderedJSONField("provenanceState", "original_unavailable"),
            ])
        }
        return .object([
            OrderedJSONField("kind", "forwarded-bundle"),
            OrderedJSONField("forwardedItems", .array(rendered)),
        ])
    }

    private func viewerCanReadForwardedSource(
        _ item: ForwardedSource,
        userId: String,
        serverId: String?,
        state: ChannelState
    ) -> Bool {
        guard item.sourceServerId == serverId,
              let channel = state.channels[item.sourceTargetId],
              channel.serverId == serverId
        else { return false }
        if channel.kind == "channel" { return true }
        return channel.memberIds.contains(userId)
    }
}
