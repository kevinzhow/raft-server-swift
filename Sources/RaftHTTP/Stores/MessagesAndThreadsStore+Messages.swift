import Foundation

extension MessagesAndThreadsStore {
    // MARK: - Socket room membership

    /// Human message rows after `lastSeq`, copied under one lock. The caller
    /// sorts the page; the store only owns the read.
    func messagesForResume(afterSeq: Int) -> [StoredHumanMessage] {
        withState { state in
            return state.humanMessageRows.filter { $0.seq > afterSeq }
        }
    }

    /// Highest message sequence among `channelIds`, read under one lock.
    /// This is the retained fact behind the application `heartbeat` and the
    /// same `seq` space as `messagesForResume`; it does not allocate a
    /// transport-side counter.
    func maxMessageSeq(channelIds: Set<String>) -> Int {
        withState { state in
            var maxSeq = 0
            for message in state.humanMessageRows where channelIds.contains(message.channelId) {
                if message.seq > maxSeq { maxSeq = message.seq }
            }
            return maxSeq
        }
    }

    // MARK: - Action-card reply rows

    /// The first human-message id in `channelId` that starts with `idPrefix`,
    /// in one critical section. The action-card DM-thread resolver uses it as
    /// the legacy `humanMessageRows.first` anchor lookup.
    func humanMessageId(channelId: String, idPrefix: String) -> String? {
        withState { state in
            return state.humanMessageRows.first {
                $0.channelId == channelId && $0.id.hasPrefix(idPrefix)
            }?.id
        }
    }

    /// Appends one mention row under the store lock.
    func appendMention(_ mention: StoredMention) {
        withState { state in
            state.storedMentions.append(mention)
        }
    }

    /// One message row by id, in one critical section.
    func humanMessageRow(id: String) -> StoredHumanMessage? {
        withState { state in
            return state.humanMessageRows.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        }
    }
}
