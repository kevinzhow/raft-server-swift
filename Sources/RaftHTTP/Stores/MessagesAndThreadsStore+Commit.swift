import Foundation

/// The only ledger dependency invoked while a message State is borrowed.
/// It holds no callbacks and only enters OAuthLedger's own record Mutex.
/// The lock order is Messages -> OAuth; OAuth never calls the message store.
struct MessageLedgerPort: Sendable {
    private let oauth: OAuthLedger

    init(oauth: OAuthLedger) {
        self.oauth = oauth
    }

    func mirror(_ message: StoredHumanMessage, systemMetadata: Bool = false) {
        oauth.appendMessageCommitMirror(OAuthLedger.ChannelMessageRecord(
            id: message.id,
            channelId: message.channelId,
            content: message.content,
            createdAt: message.createdAt,
            senderId: message.senderId,
            seq: message.seq,
            senderTimezone: message.senderTimezone,
            senderType: message.senderType,
            messageType: message.messageType,
            systemSubtype: systemMetadata ? message.systemSubtype : nil,
            causalActorType: systemMetadata ? message.causalActorType : nil,
            causalActorId: systemMetadata ? message.causalActorId : nil
        ))
    }

    func advanceSenderReadCursor(channelId: String, senderId: String, seq: Int) {
        oauth.advanceReadCursorAfterMessageCommit(channelId: channelId, userId: senderId, seq: seq)
    }
}

/// Values decided by the human-send policy before entering the message owner.
struct HumanMessageCommitRequest: Sendable {
    let channelId: String
    let senderId: String
    let content: String
    let randomId: String?
    let attachmentIds: [String]
    let senderTimezone: String?
    let mentions: [StoredMessageMention]
    let isThread: Bool
}

enum HumanMessageCommitOutcome: Sendable {
    case created(StoredHumanMessage)
    case replayed(StoredHumanMessage)
    case randomIdConflict
    case attachmentReplayConflict
    case attachmentFailure(MessagesAndThreadsStore.SendAttachmentCheck)
}

extension MessagesAndThreadsStore {
    /// Every ordinary writer shares this sequence allocator and mirror commit.
    /// A notice's born-read write stays in this same Messages transaction.
    @discardableResult
    func appendMessage(
        _ message: StoredHumanMessage,
        ledger: MessageLedgerPort,
        bornReadAgentId: String? = nil,
        mirrorSystemMetadata: Bool = false
    ) -> Int {
        withState { state in
            let seq = state.appendMessage(message, ledger: ledger, systemMetadata: mirrorSystemMetadata)
            if let bornReadAgentId {
                let key = "\(message.channelId)\n\(bornReadAgentId)"
                let previous = state.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
                state.agentChannelReadCursors[key] = (max(previous.seq, seq), previous.version + 1)
            }
            return seq
        }
    }

    /// Replay, validation, binding, append/mirror, done cleanup and the sender
    /// frontier are one transaction. A refusal returns before the first write.
    func commitHumanMessage(
        _ request: HumanMessageCommitRequest,
        ledger: MessageLedgerPort
    ) -> HumanMessageCommitOutcome {
        withState { state in
            if let randomId = request.randomId,
               let existing = state.humanMessageRows.first(where: {
                   $0.senderId == request.senderId && $0.randomId == randomId
               }) {
                guard existing.channelId == request.channelId else { return .randomIdConflict }
                guard state.attachmentOrderMatches(
                    message: existing,
                    ids: request.attachmentIds,
                    uploaderId: request.senderId
                ) else { return .attachmentReplayConflict }
                return .replayed(existing)
            }
            let check = state.validateSendAttachments(
                ids: request.attachmentIds,
                channelId: request.channelId,
                uploaderId: request.senderId
            )
            guard check == .ok else { return .attachmentFailure(check) }
            var message = StoredHumanMessage(
                id: UUID().uuidString.lowercased(),
                channelId: request.channelId,
                senderId: request.senderId,
                content: request.content,
                randomId: request.randomId,
                attachmentIds: request.attachmentIds,
                senderTimezone: request.senderTimezone,
                mentions: request.mentions
            )
            // Human sends historically bind positions before append/mirror.
            for (position, id) in request.attachmentIds.enumerated() {
                state.channelAttachments[id]?.messageId = message.id
                state.channelAttachments[id]?.messagePosition = position
            }
            let seq = state.appendMessage(message, ledger: ledger)
            message.seq = seq
            if request.isThread {
                state.inboxDoneScopes = state.inboxDoneScopes.filter { !$0.hasSuffix("\n\(request.channelId)") }
                state.inboxDoneFrontiers = state.inboxDoneFrontiers.filter { !$0.key.hasSuffix("\n\(request.channelId)") }
            }
            ledger.advanceSenderReadCursor(channelId: request.channelId, senderId: request.senderId, seq: seq)
            return .created(message)
        }
    }

    /// Agent sends keep their original append/mirror -> attachment link ->
    /// local read-cursor order, without releasing the Messages borrow.
    func commitAgentSend(
        _ message: StoredHumanMessage,
        attachmentIds: [String],
        channelId: String,
        uploaderId: String,
        ledger: MessageLedgerPort
    ) -> AgentSendAppendOutcome {
        withState { state in
            switch state.validateSendAttachments(ids: attachmentIds, channelId: channelId, uploaderId: uploaderId) {
            case .ok: break
            case .duplicate(let id): return .duplicate(id)
            case .unavailable(let id): return .unavailable(id)
            case .alreadyLinked(let id): return .alreadyLinked(id)
            }
            let seq = state.appendMessage(message, ledger: ledger)
            for id in attachmentIds { state.channelAttachments[id]?.messageId = message.id }
            state.advanceAgentReadCursorAfterSend(channelId: channelId, agentId: message.senderId, ownSeq: seq)
            return .committed(seq: seq)
        }
    }
}

extension MessagesAndThreadsStore.State {
    /// Called only with the caller's existing Messages borrow; never reacquires it.
    mutating func appendMessage(
        _ message: StoredHumanMessage,
        ledger: MessageLedgerPort,
        systemMetadata: Bool = false
    ) -> Int {
        var stored = message
        stored.seq = humanMessageRows.count + 1
        humanMessageRows.append(stored)
        ledger.mirror(stored, systemMetadata: systemMetadata)
        return stored.seq
    }

    func attachmentOrderMatches(message: StoredHumanMessage, ids: [String], uploaderId: String) -> Bool {
        guard message.attachmentIds.count == ids.count else { return false }
        for (index, id) in ids.enumerated() {
            guard message.attachmentIds[index] == id,
                  let row = channelAttachments[id],
                  row.messageId == message.id,
                  row.messagePosition == index,
                  row.uploaderId == uploaderId
            else { return false }
        }
        return true
    }

    func validateSendAttachments(ids: [String], channelId: String, uploaderId: String) -> MessagesAndThreadsStore.SendAttachmentCheck {
        var seen = Set<String>()
        for id in ids {
            guard seen.insert(id).inserted else { return .duplicate(id) }
            guard let row = channelAttachments[id], row.channelId == channelId, row.uploaderId == uploaderId
            else { return .unavailable(id) }
            if row.messageId != nil { return .alreadyLinked(id) }
        }
        return .ok
    }

    mutating func advanceAgentReadCursorAfterSend(channelId: String, agentId: String, ownSeq: Int) {
        let key = "\(channelId)\n\(agentId)"
        let cursor = agentChannelReadCursors[key]?.seq ?? 0
        let unreadBelow = humanMessageRows.contains { message in
            message.channelId == channelId && message.senderId != agentId
                && message.seq > cursor && message.seq < ownSeq
        }
        if !unreadBelow, ownSeq > cursor {
            let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            agentChannelReadCursors[key] = (ownSeq, previous.version + 1)
        }
    }
}
