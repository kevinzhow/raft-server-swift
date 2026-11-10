import Foundation

/// Human-send policy and wire projection around the message owner's typed
/// transaction. The emitter is called only after commit releases Messages.
///
/// The acknowledgement and the `message:new` frame are the canonical message
/// projection: the committed row plus its sender and retained attachments. The
/// frame additionally carries the creation-time `conversationContext`, which
/// upstream never publishes on the HTTP row.
struct HumanMessageCommitService: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
    let profiles: AuthProfileStore
    let catalog: TaskCatalogService
    let oauth: OAuthLedger
    let ledger: MessageLedgerPort
    let emit: @Sendable (String, String, String?) -> Void

    func store(
        channelId: String,
        senderId: String,
        content: String,
        randomId: String?,
        attachmentIds: [String],
        senderTimezone: String?,
        mentions: [MentionInput],
        asTask: Bool
    ) throws -> HumanMessageWrite {
        let channel = channels.postableChannel(id: channelId)
        let kind = channel?.kind
        let request = HumanMessageCommitRequest(
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: randomId,
            attachmentIds: attachmentIds,
            senderTimezone: senderTimezone,
            mentions: kind == "dm" ? [] : mentions.map { StoredMessageMention(type: $0.type, id: $0.id, name: $0.name) },
            isThread: kind == "thread"
        )
        switch messages.commitHumanMessage(request, ledger: ledger) {
        case .created(let message):
            // The DM/thread room grants and reply follows run before publishing
            // (`emitPersistedMessageToFrontend`); the single persisted-frontend
            // publisher then emits `message:new` with its `conversationContext`,
            // `dm:new` or the parent `thread:updated`.
            //
            // `asTask`: the host message stays a plain chat row; the canonical
            // task is created in this same request transaction, before the
            // acknowledgement and before agent delivery is staged, so the task
            // board frame and the message payload carry real task facts. A
            // thread message can never become a task (upstream logs and
            // continues); the plain message is still accepted.
            var createdTask: TaskRecord?
            var taskCreated = false
            if asTask, kind != "thread" {
                let ensured = catalog.ensureSentTask(
                    channelId: channelId, messageId: message.id, title: message.content,
                    creatorId: message.senderId, hasLegacyTask: message.taskStatus != nil, now: Date()
                )
                createdTask = ensured?.task
                taskCreated = ensured?.created == true
            }
            let taskFacts = createdTask.map(CanonicalMessagePayload.TaskFacts.init)
            let body = payload(message, task: taskFacts, conversationContext: nil)
            let realtime = MessageRealtimeService(
                messages: messages, channels: channels, profiles: profiles, oauth: oauth
            )
            for frame in realtime.frames(for: message, task: taskFacts) {
                emit(frame.room, frame.event, frame.payload)
            }
            // Publish the board frame after the host `message:new`, as upstream
            // does. The publication is staged in this transaction; a staging
            // failure discards the message and task together.
            if taskCreated, let createdTask, let channel {
                try catalog.publishSentTask(createdTask, channelId: channelId, serverId: channel.serverId)
            }
            return HumanMessageWrite(status: 200, body: body, created: true)
        case .replayed(let message):
            // Upstream `broadcastAndDeliver` builds the enriched row and calls
            // `emitPersistedMessageToFrontend` on every send, including a
            // randomId replay, so the frames re-emit through the same publisher
            // and `task:created` follows whenever the send's canonical task
            // resolved (created or replayed).
            var replayedTask: TaskRecord?
            if asTask, kind != "thread" {
                replayedTask = catalog.ensureSentTask(
                    channelId: channelId, messageId: message.id, title: message.content,
                    creatorId: message.senderId, hasLegacyTask: message.taskStatus != nil, now: Date()
                )?.task
            }
            let taskFacts = replayedTask.map(CanonicalMessagePayload.TaskFacts.init)
            let realtime = MessageRealtimeService(
                messages: messages, channels: channels, profiles: profiles, oauth: oauth
            )
            for frame in realtime.frames(for: message, task: taskFacts) {
                emit(frame.room, frame.event, frame.payload)
            }
            if let replayedTask, let channel {
                try catalog.publishSentTask(replayedTask, channelId: channelId, serverId: channel.serverId)
            }
            return HumanMessageWrite(
                status: 200,
                body: payload(message, task: taskFacts, conversationContext: nil),
                created: false
            )
        case .randomIdConflict:
            return refusal(status: 409, error: "randomId has already been used for a different message", code: "random_id_conflict")
        case .attachmentReplayConflict:
            return refusal(error: "This idempotent send was already committed with a different ordered attachment set.", code: "attachment_replay_conflict")
        case .attachmentFailure(let check):
            switch check {
            case .duplicate(let id):
                return refusal(error: "Attachment \(id) was requested more than once. Send each attachment ID exactly once.", code: "attachment_duplicate")
            case .unavailable(let id):
                return refusal(error: "Attachment \(id) is not available for this sender. Re-upload the file and send the new attachment ID.", code: "attachment_not_found")
            case .alreadyLinked(let id):
                return refusal(error: "Attachment \(id) is already attached to another message. Re-upload the file and send the new attachment ID.", code: "attachment_already_linked")
            case .ok:
                preconditionFailure("A successful attachment check cannot be a commit refusal")
            }
        }
    }

    // MARK: - Projection

    /// The committed row through the canonical message manifest. Attachment
    /// metadata and the sender label/description are the retained facts; a
    /// just-created row has no reactions, comment ref or external author.
    private func payload(_ message: StoredHumanMessage, task: CanonicalMessagePayload.TaskFacts?,
                         conversationContext: OrderedJSON?) -> String {
        let account = profiles.account(userId: message.senderId)
        let displayName: String? = account.map { $0.displayName?.isEmpty == false ? $0.displayName : $0.name } ?? nil
        let description = account?.description.flatMap { $0.isEmpty ? nil : $0 }
        let sender = CanonicalMessagePayload.Sender(
            name: displayName ?? "User",
            description: description,
            // Upstream publishes the sender's own just-committed membership as
            // active for a user chat row and null for a system row.
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
            task: task
        ).jsonBody.render()
    }

    /// The channel's kind and, for a thread reply, the parent message's
    /// coordinates. The HTTP row never carries this creation-time identity.
    private func conversationContext(channelId: String) -> OrderedJSON? {
        let state = channels.state
        guard let channel = state.postableChannels[channelId] else { return nil }
        return messageConversationContext(channel: channel, channels: state.postableChannels)
    }

    private func refusal(status: Int = 400, error: String, code: String) -> HumanMessageWrite {
        HumanMessageWrite(
            status: status,
            body: OrderedJSON.object([
                OrderedJSONField("error", error),
                OrderedJSONField("code", code),
            ]).render(),
            created: false
        )
    }
}
