import Foundation

extension MessagesAndThreadsStore {
    /// `DELETE /api/tasks/:taskId`: clears the task shadow a host message
    /// carried, in one critical section.
    func clearTaskShadow(messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let shadow = storage.humanMessageRows.firstIndex(where: { $0.id == messageId }) else { return }
        storage.humanMessageRows[shadow].taskStatus = nil
        storage.humanMessageRows[shadow].taskNumber = nil
        storage.humanMessageRows[shadow].taskAssigneeType = nil
        storage.humanMessageRows[shadow].taskAssigneeId = nil
        storage.humanMessageRows[shadow].taskClaimedAt = nil
        storage.humanMessageRows[shadow].taskCompletedAt = nil
    }

    // MARK: - Agent task and inbox reads

    /// The first message row whose id is exactly `prefix` or starts with it,
    /// but only when it belongs to `channelId`.
    ///
    /// The retired converter called `humanMessageRows.first(where:)` with the
    /// id predicate and then compared the channel, so a prefix that first
    /// matches a row in another channel is a miss rather than a second lookup.
    func messageForConvert(prefix: String, channelId: String) -> StoredHumanMessage? {
        lock.lock()
        defer { lock.unlock() }
        guard let message = storage.humanMessageRows.first(where: {
            $0.id == prefix || $0.id.hasPrefix(prefix)
        }), message.channelId == channelId else {
            return nil
        }
        return message
    }

    /// One locked snapshot of every ledger the agent inbox projection reads:
    /// message rows, mentions, read cursors and the followed-thread rows.
    struct InboxSnapshot {
        let messages: [StoredHumanMessage]
        let mentions: [StoredMention]
        let readCursors: [String: (seq: Int, version: Int)]
        let threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)]
        let threadFollowStarts: [String: Date]
    }

    func inboxSnapshot() -> InboxSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return InboxSnapshot(
            messages: storage.humanMessageRows,
            mentions: storage.storedMentions,
            readCursors: storage.agentChannelReadCursors,
            threadFollows: storage.threadFollows,
            threadFollowStarts: storage.threadFollowStarts
        )
    }
}
