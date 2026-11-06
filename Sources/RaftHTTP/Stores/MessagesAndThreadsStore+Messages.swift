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
