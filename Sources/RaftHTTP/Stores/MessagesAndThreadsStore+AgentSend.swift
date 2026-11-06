import Foundation

extension MessagesAndThreadsStore {
    // MARK: - Agent send commit

    /// The message's channel id for the idempotency replay response.
    func channelId(forMessageId messageId: String) -> String? {
        withState { state in
            return state.humanMessageRows.first { $0.id == messageId }?.channelId
        }
    }

    /// The pre-append attachment policy, as one locked read.
    enum SendAttachmentCheck: Sendable, Equatable {
        case ok
        case duplicate(String)
        case unavailable(String)
        case alreadyLinked(String)
    }

    /// The thread follow rows an agent send writes, in one critical section.
    func ensureThreadFollows(
        _ rows: [(serverId: String, userId: String, threadChannelId: String, parentMessageId: String)]
    ) {
        withState { state in
            for row in rows {
                state.threadFollows["\(row.serverId)\n\(row.userId)\n\(row.threadChannelId)"] = row
            }
        }
    }

    /// The freshness gate's read set from one critical section: every message
    /// row, every mention row and the agent's read frontier.
    struct SendFreshnessSnapshot: Sendable {
        let rows: [StoredHumanMessage]
        let mentions: [StoredMention]
        let readCursor: (seq: Int, version: Int)
    }

    func sendFreshnessSnapshot(channelId: String, agentId: String) -> SendFreshnessSnapshot {
        withState { state in
            return SendFreshnessSnapshot(
                rows: state.humanMessageRows,
                mentions: state.storedMentions,
                readCursor: state.agentChannelReadCursors["\(channelId)\n\(agentId)"] ?? (seq: 0, version: 0)
            )
        }
    }
}
