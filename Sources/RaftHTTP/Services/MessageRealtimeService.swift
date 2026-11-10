import Foundation

/// One socket frame a committed chat message produces, with the deterministic
/// identity a durable publication needs.
struct MessageRealtimeFrame: Sendable, Equatable {
    let room: String
    let event: String
    let identity: String
    let payload: String
}

/// Upstream `emitPersistedMessageToFrontend` for an ordinary persisted chat
/// row (`packages/server/src/services/messageService.ts`).
///
/// Before returning the frames this service performs the same ordered side
/// effects: clear the thread's Done scopes, record the reply sender and the
/// parent author, and grant the thread (or DM) room to every eligible human's
/// server-scoped sockets. Frame order is upstream's: `message:new`, then
/// `dm:new` or `thread:updated`.
///
/// The canonical projection is `CanonicalMessagePayload`: the committed row,
/// its sender facts and retained attachments, plus the socket-only
/// `conversationContext`. The `thread:updated` `latestReply` reuses that
/// projection and appends the display label/avatar the Web's reply previews
/// read.
struct MessageRealtimeService: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    /// The human account authority; agent senders resolve their label from the
    /// OAuth ledger, so a sender-path without a profile store still projects
    /// the canonical agent fields.
    let profiles: AuthProfileStore?
    let oauth: OAuthLedger

    func frames(
        for message: StoredHumanMessage,
        actionMetadata: OrderedJSON? = nil
    ) -> [MessageRealtimeFrame] {
        let state = channels.state
        guard let channel = state.postableChannels[message.channelId] else {
            // Upstream still publishes the row when the channel read is
            // missing, using the ordinary channel context.
            return [MessageRealtimeFrame(
                room: "channel:\(message.channelId)", event: "message:new", identity: message.id,
                payload: canonicalPayload(message, conversationContext: .object([
                    OrderedJSONField("channelType", "channel"),
                ]), actionMetadata: actionMetadata)
            )]
        }
        switch channel.kind {
        case "dm":
            return dmFrames(message, channel: channel, actionMetadata: actionMetadata)
        case "thread":
            return threadFrames(message, channel: channel, state: state, actionMetadata: actionMetadata)
        default:
            let context = messageConversationContext(channel: channel, channels: state.postableChannels)
            return [MessageRealtimeFrame(
                room: "channel:\(message.channelId)", event: "message:new", identity: message.id,
                payload: canonicalPayload(message, conversationContext: context, actionMetadata: actionMetadata)
            )]
        }
    }

    /// Upstream `broadcastSystemMessage`: a persisted system row joins the DM
    /// humans or thread followers first, then publishes `message:new` (and
    /// `dm:new` for a DM). Unlike an ordinary reply it records no thread
    /// follows, clears no Done scope and publishes no `thread:updated`.
    func systemFrames(for message: StoredHumanMessage) -> [MessageRealtimeFrame] {
        let state = channels.state
        guard let channel = state.postableChannels[message.channelId] else {
            return [MessageRealtimeFrame(
                room: "channel:\(message.channelId)", event: "message:new", identity: message.id,
                payload: canonicalPayload(message, conversationContext: .object([
                    OrderedJSONField("channelType", "channel"),
                ]))
            )]
        }
        switch channel.kind {
        case "dm":
            return dmFrames(message, channel: channel)
        case "thread":
            return systemThreadFrames(message, channel: channel, state: state)
        default:
            let context = messageConversationContext(channel: channel, channels: state.postableChannels)
            return [MessageRealtimeFrame(
                room: "channel:\(message.channelId)", event: "message:new", identity: message.id,
                payload: canonicalPayload(message, conversationContext: context)
            )]
        }
    }

    /// The audience of a `message:updated` frame: reaction/edit producers use
    /// the channel room, while an action-card carrier in a thread uses the
    /// authority-filtered follower user rooms.
    enum MessageUpdateAudience: Sendable {
        case channel
        case threadFollowers
    }

    /// Upstream `getMessageContext` update projection: the same canonical row
    /// as `message:new` without the creation-time `conversationContext`, with
    /// the retained reaction buckets, forwarded/action-card metadata and the
    /// shared-broadcast comment scrub (null).
    func messageUpdatedFrames(
        for message: StoredHumanMessage,
        actionMetadata: OrderedJSON? = nil,
        reactions: [OrderedJSON] = [],
        commentRef: OrderedJSON? = nil,
        audience: MessageUpdateAudience = .channel
    ) -> [MessageRealtimeFrame] {
        let payload = canonicalPayload(
            message, conversationContext: nil, actionMetadata: actionMetadata,
            reactions: reactions, commentRef: commentRef
        )
        switch audience {
        case .channel:
            return [MessageRealtimeFrame(
                room: "channel:\(message.channelId)", event: "message:updated", identity: message.id, payload: payload
            )]
        case .threadFollowers:
            let state = channels.state
            guard let channel = state.postableChannels[message.channelId], channel.kind == "thread" else {
                return [MessageRealtimeFrame(
                    room: "channel:\(message.channelId)", event: "message:updated", identity: message.id, payload: payload
                )]
            }
            let followerIds = ThreadFollowerRealtimeService(messages: messages, channels: channels, oauth: oauth)
                .humanFollowerIds(threadChannelId: message.channelId, serverId: channel.serverId)
            return followerIds.map { userId in
                MessageRealtimeFrame(
                    room: "user:\(userId)", event: "message:updated", identity: message.id, payload: payload
                )
            }
        }
    }

    // MARK: - DM

    /// Upstream joins the DM's humans, publishes `message:new` to the channel
    /// room, then publishes `dm:new` for the DM list to the room and to each
    /// human's own room.
    private func dmFrames(
        _ message: StoredHumanMessage,
        channel: PostableChannel,
        actionMetadata: OrderedJSON? = nil
    ) -> [MessageRealtimeFrame] {
        let relay = RealtimeRelayService(messages: messages)
        let humans = oauth.channelHumanIds(channelId: message.channelId)
        for userId in humans {
            relay.joinUserServerSessions(userId, channel.serverId, "channel:\(message.channelId)")
        }
        let context = messageConversationContext(channel: channel, channels: channels.state.postableChannels)
        var frames = [MessageRealtimeFrame(
            room: "channel:\(message.channelId)", event: "message:new", identity: message.id,
            payload: canonicalPayload(message, conversationContext: context, actionMetadata: actionMetadata)
        )]
        let dmPayload = OrderedJSON.object([OrderedJSONField("channelId", message.channelId)]).render()
        frames.append(MessageRealtimeFrame(
            room: "channel:\(message.channelId)", event: "dm:new", identity: message.id, payload: dmPayload
        ))
        for userId in humans {
            frames.append(MessageRealtimeFrame(
                room: "user:\(userId)", event: "dm:new", identity: message.id, payload: dmPayload
            ))
        }
        return frames
    }

    // MARK: - Thread

    /// Upstream's persisted thread reply: reactivate the sender's follow,
    /// ensure an eligible parent author's follow, clear Done for every
    /// follower, grant the thread room, then publish `message:new` (room for a
    /// public parent, follower user rooms otherwise) and finally the parent
    /// channel's `thread:updated` summary.
    private func threadFrames(
        _ message: StoredHumanMessage,
        channel: PostableChannel,
        state: ServersAndChannelsStore.State,
        actionMetadata: OrderedJSON? = nil
    ) -> [MessageRealtimeFrame] {
        guard let parentMessageId = channel.parentMessageId else {
            let context = messageConversationContext(channel: channel, channels: state.postableChannels)
            return [MessageRealtimeFrame(
                room: "channel:\(message.channelId)", event: "message:new", identity: message.id,
                payload: canonicalPayload(message, conversationContext: context, actionMetadata: actionMetadata)
            )]
        }
        // The human writer already clears Done inside its message transaction;
        // agent sends reach the same upstream step here.
        if message.senderType != "user" {
            messages.clearThreadDone(threadChannelId: message.channelId)
        }
        let parent = messages.humanMessageRows.first { $0.id == parentMessageId }
        messages.recordThreadReplyJoinFollows(
            serverId: channel.serverId,
            threadChannelId: message.channelId,
            parentMessageId: parentMessageId,
            senderId: message.senderId,
            parentAuthorId: ThreadFollowerRealtimeService.parentAuthorId(
                of: parent, replyingSenderId: message.senderId
            )
        )
        let followerService = ThreadFollowerRealtimeService(messages: messages, channels: channels, oauth: oauth)
        let followerIds = followerService.humanFollowerIds(threadChannelId: message.channelId, serverId: channel.serverId)
        let relay = RealtimeRelayService(messages: messages)
        for userId in followerIds {
            relay.joinUserServerSessions(userId, channel.serverId, "channel:\(message.channelId)")
        }

        let parentChannel = channel.parentChannelId.flatMap { state.postableChannels[$0] }
        let context = messageConversationContext(channel: channel, channels: state.postableChannels)
        let messagePayload = canonicalPayload(message, conversationContext: context, actionMetadata: actionMetadata)
        var frames: [MessageRealtimeFrame] = []
        if parentChannel?.kind == "channel" {
            frames.append(MessageRealtimeFrame(
                room: "channel:\(message.channelId)", event: "message:new", identity: message.id,
                payload: messagePayload
            ))
        } else {
            // A private/DM/joint parent uses the authority-filtered follower
            // audience instead of the thread room.
            for userId in followerIds {
                frames.append(MessageRealtimeFrame(
                    room: "user:\(userId)", event: "message:new", identity: message.id,
                    payload: messagePayload
                ))
            }
        }

        guard let parent else { return frames }
        let info = threadInfo(threadChannelId: message.channelId)
        let latestReply = latestReplyPayload(message, conversationContext: context)
        let updated = threadUpdatedPayload(
            parentMessageId: parentMessageId,
            threadChannelId: message.channelId,
            replyCount: info.replyCount,
            lastReplyAt: info.lastReplyAt,
            participantIds: info.participantIds,
            serverId: channel.serverId,
            parentChannelId: parent.channelId,
            parentChannelKind: parentChannel?.kind,
            latestReply: latestReply
        )
        if parentChannel?.kind == "private" || parentChannel?.kind == "dm" {
            for humanId in oauth.channelHumanIds(channelId: parent.channelId) {
                frames.append(MessageRealtimeFrame(
                    room: "user:\(humanId)", event: "thread:updated", identity: message.id, payload: updated
                ))
            }
        } else {
            frames.append(MessageRealtimeFrame(
                room: "channel:\(parent.channelId)", event: "thread:updated", identity: message.id,
                payload: updated
            ))
        }
        return frames
    }

    /// A persisted system row in a thread: join the follower audience, then
    /// publish `message:new` to the thread room for a public parent or each
    /// follower's own room for a private/DM parent. No follow write and no
    /// `thread:updated` summary (upstream `broadcastSystemMessage`).
    private func systemThreadFrames(
        _ message: StoredHumanMessage,
        channel: PostableChannel,
        state: ServersAndChannelsStore.State
    ) -> [MessageRealtimeFrame] {
        let followerIds = ThreadFollowerRealtimeService(messages: messages, channels: channels, oauth: oauth)
            .humanFollowerIds(threadChannelId: message.channelId, serverId: channel.serverId)
        let relay = RealtimeRelayService(messages: messages)
        for userId in followerIds {
            relay.joinUserServerSessions(userId, channel.serverId, "channel:\(message.channelId)")
        }
        let parentChannel = channel.parentChannelId.flatMap { state.postableChannels[$0] }
        let context = messageConversationContext(channel: channel, channels: state.postableChannels)
        let payload = canonicalPayload(message, conversationContext: context)
        if parentChannel?.kind == "channel" {
            return [MessageRealtimeFrame(
                room: "channel:\(message.channelId)", event: "message:new", identity: message.id, payload: payload
            )]
        }
        return followerIds.map { userId in
            MessageRealtimeFrame(
                room: "user:\(userId)", event: "message:new", identity: message.id, payload: payload
            )
        }
    }

    /// The retained `getThreadInfo` read: every message row in the thread,
    /// including system rows, with the parent author not invented as a
    /// participant unless they replied.
    private func threadInfo(threadChannelId: String) -> (
        replyCount: Int, lastReplyAt: String?, participantIds: [String]
    ) {
        let replies = messages.humanMessageRows.filter { $0.channelId == threadChannelId }
        let lastReplyAt = replies.map(\.createdAt).max().map {
            ISO8601DateFormatter().string(from: $0)
        }
        return (
            replies.count,
            lastReplyAt,
            Array(Set(replies.map(\.senderId))).sorted()
        )
    }

    // MARK: - Projection

    /// The canonical message manifest plus the sender facts the row itself
    /// cannot carry. Agent labels come from the OAuth ledger; human labels from
    /// the account store.
    func canonicalPayload(
        _ message: StoredHumanMessage,
        conversationContext: OrderedJSON?,
        actionMetadata: OrderedJSON? = nil,
        reactions: [OrderedJSON] = [],
        commentRef: OrderedJSON? = nil
    ) -> String {
        let account = profiles?.account(userId: message.senderId)
        let agent = message.senderType == "agent" ? oauth.agentRuntimeInfo(id: message.senderId) : nil
        let name: String
        let description: String?
        switch message.senderType {
        case "agent":
            name = agent.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "Agent"
            description = agent?.description.flatMap { $0.isEmpty ? nil : $0 }
        case "system":
            name = "System"
            description = nil
        default:
            name = account.map { $0.displayName?.isEmpty == false ? ($0.displayName ?? $0.name) : $0.name } ?? "User"
            description = account?.description.flatMap { $0.isEmpty ? nil : $0 }
        }
        let sender = CanonicalMessagePayload.Sender(
            name: name,
            description: description,
            membershipStatus: message.senderType == "user" && message.messageType != "system" ? "active" : nil
        )
        let attachments = messages.orderedAttachmentRows(for: message)
            .compactMap { $0.row }
            .map(CanonicalMessagePayload.Attachment.init)
        return CanonicalMessagePayload(
            message: message,
            sender: sender,
            attachments: attachments,
            mentions: message.mentions,
            conversationContext: conversationContext,
            actionMetadata: actionMetadata,
            reactions: reactions,
            commentRef: commentRef
        ).jsonBody.render()
    }

    /// `projectThreadLatestReplyPayload`: the canonical socket projection plus
    /// `senderDisplayName` and `senderAvatarUrl`.
    private func latestReplyPayload(_ message: StoredHumanMessage, conversationContext: OrderedJSON?) -> OrderedJSON {
        let account = profiles?.account(userId: message.senderId)
        let agent = message.senderType == "agent" ? oauth.agentRuntimeInfo(id: message.senderId) : nil
        let name: String
        let description: String?
        switch message.senderType {
        case "agent":
            name = agent.map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "Agent"
            description = agent?.description.flatMap { $0.isEmpty ? nil : $0 }
        case "system":
            name = "System"
            description = nil
        default:
            name = account.map { $0.displayName?.isEmpty == false ? ($0.displayName ?? $0.name) : $0.name } ?? "User"
            description = account?.description.flatMap { $0.isEmpty ? nil : $0 }
        }
        let sender = CanonicalMessagePayload.Sender(
            name: name,
            description: description,
            membershipStatus: message.senderType == "user" && message.messageType != "system" ? "active" : nil
        )
        let attachments = messages.orderedAttachmentRows(for: message)
            .compactMap { $0.row }
            .map(CanonicalMessagePayload.Attachment.init)
        var body = CanonicalMessagePayload(
            message: message,
            sender: sender,
            attachments: attachments,
            mentions: message.mentions,
            conversationContext: conversationContext
        ).orderedObject
        body.append("senderDisplayName", name)
        body.append("senderAvatarUrl", .null)
        return body.json
    }

    /// `thread:updated`: the retained parent summary, the replies sync-window
    /// envelope and the latest reply. Member order is upstream's spread order.
    private func threadUpdatedPayload(
        parentMessageId: String,
        threadChannelId: String,
        replyCount: Int,
        lastReplyAt: String?,
        participantIds: [String],
        serverId: String,
        parentChannelId: String,
        parentChannelKind: String?,
        latestReply: OrderedJSON
    ) -> String {
        let root = OrderedJSON.object([
            OrderedJSONField("kind", "message"),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("id", parentMessageId),
        ])
        let discussion = OrderedJSON.object([
            OrderedJSONField("root", root),
            OrderedJSONField("relation", .object([OrderedJSONField("kind", "replies")])),
            OrderedJSONField("parentScopeKey", .object([
                OrderedJSONField("serverId", serverId),
                OrderedJSONField("scopeKind", parentChannelKind ?? "channel"),
                OrderedJSONField("scopeId", parentChannelId),
            ])),
            OrderedJSONField("backing", "sync-scope"),
        ])
        let window = OrderedJSON.object([
            OrderedJSONField("kind", "sync-scope-window"),
            OrderedJSONField("scopeCursor", .null),
            OrderedJSONField("epoch", .null),
        ])
        let envelope = OrderedJSON.object([
            OrderedJSONField("producer", "message-service.thread-replies-window.v1"),
            OrderedJSONField("discussion", discussion),
            OrderedJSONField("window", window),
        ])
        var body = OrderedJSONObject()
        body.append("parentMessageId", parentMessageId)
        body.append("threadChannelId", threadChannelId)
        body.append("replyCount", replyCount)
        body.append("lastReplyAt", optional: lastReplyAt)
        body.append("participantIds", .array(participantIds.map(OrderedJSON.string)))
        body.append("syncCoreReplyWindow", envelope)
        body.append("latestReply", latestReply)
        return body.json.render()
    }
}
