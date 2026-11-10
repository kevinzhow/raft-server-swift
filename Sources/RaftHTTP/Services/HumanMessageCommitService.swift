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
    let ledger: MessageLedgerPort
    let emit: @Sendable (String, String, String?) -> Void

    func store(
        channelId: String,
        senderId: String,
        content: String,
        randomId: String?,
        attachmentIds: [String],
        senderTimezone: String?,
        mentions: [MentionInput]
    ) -> HumanMessageWrite {
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
            // A new DM has no room members yet. Join every participant's live
            // sockets before publishing so the first frame is not lost
            // (upstream `emitPersistedMessageToFrontend`).
            if kind == "dm", let channel {
                for participantId in channel.memberIds {
                    messages.realtimeRoomJoinerStorage?(participantId, "channel:\(channelId)")
                }
            }
            let body = payload(message, conversationContext: nil)
            emit("channel:\(channelId)", "message:new",
                 payload(message, conversationContext: conversationContext(channelId: channelId)))
            return HumanMessageWrite(status: 200, body: body, created: true)
        case .replayed(let message):
            return HumanMessageWrite(
                status: 200,
                body: payload(message, conversationContext: nil),
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
    private func payload(_ message: StoredHumanMessage, conversationContext: OrderedJSON?) -> String {
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
            conversationContext: conversationContext
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
