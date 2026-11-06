import Foundation

extension MessagesAndThreadsStore {
    /// `DELETE /api/tasks/:taskId`: clears the task shadow a host message
    /// carried, in one critical section.
    func clearTaskShadow(messageId: String) {
        withState { state in
            guard let shadow = state.humanMessageRows.firstIndex(where: { $0.id == messageId }) else { return }
            state.humanMessageRows[shadow].taskStatus = nil
            state.humanMessageRows[shadow].taskNumber = nil
            state.humanMessageRows[shadow].taskAssigneeType = nil
            state.humanMessageRows[shadow].taskAssigneeId = nil
            state.humanMessageRows[shadow].taskClaimedAt = nil
            state.humanMessageRows[shadow].taskCompletedAt = nil
        }
    }

    // MARK: - Agent task and inbox reads

    /// The first message row whose id is exactly `prefix` or starts with it,
    /// but only when it belongs to `channelId`.
    ///
    /// The retired converter called `humanMessageRows.first(where:)` with the
    /// id predicate and then compared the channel, so a prefix that first
    /// matches a row in another channel is a miss rather than a second lookup.
    func messageForConvert(prefix: String, channelId: String) -> StoredHumanMessage? {
        withState { state in
            guard let message = state.humanMessageRows.first(where: {
                $0.id == prefix || $0.id.hasPrefix(prefix)
            }), message.channelId == channelId else {
                return nil
            }
            return message
        }
    }

    /// One locked snapshot of every ledger the agent inbox projection reads:
    /// message rows, mentions, read cursors and the followed-thread rows.
    struct InboxSnapshot: Sendable {
        let messages: [StoredHumanMessage]
        let mentions: [StoredMention]
        let readCursors: [String: (seq: Int, version: Int)]
        let threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)]
        let threadFollowStarts: [String: Date]
    }

    func inboxSnapshot() -> InboxSnapshot {
        withState { state in
            return InboxSnapshot(
                messages: state.humanMessageRows,
                mentions: state.storedMentions,
                readCursors: state.agentChannelReadCursors,
                threadFollows: state.threadFollows,
                threadFollowStarts: state.threadFollowStarts
            )
        }
    }
}
