import Foundation

extension MessagesAndThreadsStore {
    // MARK: - Agent send commit

    /// The message's channel id for the idempotency replay response.
    func channelId(forMessageId messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.humanMessageRows.first { $0.id == messageId }?.channelId
    }

    /// The pre-append attachment policy, as one locked read.
    enum SendAttachmentCheck: Sendable, Equatable {
        case ok
        case duplicate(String)
        case unavailable(String)
        case alreadyLinked(String)
    }

    func validateSendAttachments(
        ids: [String],
        channelId: String,
        uploaderId: String
    ) -> SendAttachmentCheck {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        for id in ids {
            guard seen.insert(id).inserted else { return .duplicate(id) }
            guard let row = storage.channelAttachments[id],
                  row.channelId == channelId,
                  row.uploaderId == uploaderId
            else { return .unavailable(id) }
            if row.messageId != nil { return .alreadyLinked(id) }
        }
        return .ok
    }

    func linkSendAttachments(ids: [String], messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            storage.channelAttachments[id]?.messageId = messageId
        }
    }

    /// The legacy "sending is not reading" cursor rule: the cursor may pass the
    /// own message only when no message from someone else below it is still
    /// unhanded. The decision and the version bump are one critical section.
    func advanceAgentReadCursorAfterSend(channelId: String, agentId: String, ownSeq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        let cursor = storage.agentChannelReadCursors[key]?.seq ?? 0
        let unreadBelow = storage.humanMessageRows.contains { message in
            message.channelId == channelId
                && message.senderId != agentId
                && message.seq > cursor
                && message.seq < ownSeq
        }
        if !unreadBelow, ownSeq > cursor {
            let previous = storage.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            storage.agentChannelReadCursors[key] = (ownSeq, previous.version + 1)
        }
    }

    /// The thread follow rows an agent send writes, in one critical section.
    func ensureThreadFollows(
        _ rows: [(serverId: String, userId: String, threadChannelId: String, parentMessageId: String)]
    ) {
        lock.lock()
        defer { lock.unlock() }
        for row in rows {
            storage.threadFollows["\(row.serverId)\n\(row.userId)\n\(row.threadChannelId)"] = row
        }
    }

    /// The freshness gate's read set from one critical section: every message
    /// row, every mention row and the agent's read frontier.
    struct SendFreshnessSnapshot {
        let rows: [StoredHumanMessage]
        let mentions: [StoredMention]
        let readCursor: (seq: Int, version: Int)
    }

    func sendFreshnessSnapshot(channelId: String, agentId: String) -> SendFreshnessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SendFreshnessSnapshot(
            rows: storage.humanMessageRows,
            mentions: storage.storedMentions,
            readCursor: storage.agentChannelReadCursors["\(channelId)\n\(agentId)"] ?? (seq: 0, version: 0)
        )
    }
}
