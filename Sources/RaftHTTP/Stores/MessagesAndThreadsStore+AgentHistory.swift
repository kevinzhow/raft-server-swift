import Foundation

// MARK: - Agent history reads (AgentHistoryService)

/// One locked read of an agent's unread position in a channel.
struct AgentUnreadPosition: Sendable, Equatable {
    var priorSeq: Int
    var settleMs: Int
    var pendingDeferred: Int?
}

/// The per-page facts a history row projects from the human message rows.
struct AgentHistoryAnnotations: Sendable {
    var external: [String: (messageId: String?, provider: String?, actor: String?)]
    var mentionedIds: Set<String>
}

extension MessagesAndThreadsStore {
    /// The agent's read cursor for one channel (0 before the first read).
    func agentReadSeq(channelId: String, agentId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0
    }

    /// Cursor, settle window and any deferred advance, read together.
    func agentUnreadPosition(channelId: String, agentId: String) -> AgentUnreadPosition {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        return AgentUnreadPosition(
            priorSeq: storage.agentChannelReadCursors[key]?.seq ?? 0,
            settleMs: storage.readPositionSettleMs,
            pendingDeferred: storage.deferredUnreadAdvance[key]
        )
    }

    /// Moves the cursor to `seq` and bumps its version in one critical section.
    /// The history read writes the page maximum as given (no `max` against the
    /// previous value); callers decide whether the move is admissible.
    func setAgentReadCursor(channelId: String, agentId: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        let version = storage.agentChannelReadCursors[key]?.version ?? 0
        storage.agentChannelReadCursors[key] = (seq, version + 1)
    }

    /// Settles a deferred advance: the cursor moves and the deferred mark is
    /// cleared in one critical section.
    func commitDeferredUnreadAdvance(channelId: String, agentId: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        let version = storage.agentChannelReadCursors[key]?.version ?? 0
        storage.agentChannelReadCursors[key] = (seq, version + 1)
        storage.deferredUnreadAdvance.removeValue(forKey: key)
    }

    func clearDeferredUnreadAdvance(channelId: String, agentId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.deferredUnreadAdvance.removeValue(forKey: "\(channelId)\n\(agentId)")
    }

    func deferUnreadAdvance(channelId: String, agentId: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage.deferredUnreadAdvance["\(channelId)\n\(agentId)"] = seq
    }

    /// External-projection facts and agent mentions for one history page, from
    /// one snapshot of the rows.
    func historyAnnotations(messageIds: Set<String>, agentId: String) -> AgentHistoryAnnotations {
        lock.lock()
        defer { lock.unlock() }
        let external: [String: (messageId: String?, provider: String?, actor: String?)] = Dictionary(
            uniqueKeysWithValues: storage.humanMessageRows.filter { messageIds.contains($0.id) }.map {
                ($0.id, ($0.externalMessageId, $0.externalProvider, $0.externalSenderName))
            }
        )
        let mentioned = Set(
            storage.storedMentions
                .filter { $0.targetType == "agent" && $0.targetId == agentId }
                .map(\.messageId)
        )
        return AgentHistoryAnnotations(external: external, mentionedIds: mentioned)
    }
}
