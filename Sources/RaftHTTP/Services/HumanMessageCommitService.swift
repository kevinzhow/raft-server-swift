import Foundation

/// Human-send policy and wire projection around the message owner's typed
/// transaction. The emitter is called only after commit releases Messages.
struct HumanMessageCommitService: Sendable {
    let messages: MessagesAndThreadsStore
    let channels: ServersAndChannelsStore
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
        let kind = channels.postableChannel(id: channelId)?.kind
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
            let body = HumanMessagePayload(message).jsonBody.render()
            emit("channel:\(channelId)", "message:new", body)
            return HumanMessageWrite(status: 200, body: body, created: true)
        case .replayed(let message):
            return HumanMessageWrite(status: 200, body: HumanMessagePayload(message).jsonBody.render(), created: false)
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
