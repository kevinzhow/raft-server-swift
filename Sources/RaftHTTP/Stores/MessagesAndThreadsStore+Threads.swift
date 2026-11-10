import Foundation

extension MessagesAndThreadsStore {
    /// Follow/unfollow keys as one snapshot so the recursive parent-visibility
    /// check does not take the store lock once per thread.
    struct ThreadFollowSnapshot: Sendable {
        let follows: Set<String>
        let unfollows: Set<String>
    }

    func threadFollowSnapshot() -> ThreadFollowSnapshot {
        withState { state in
            return ThreadFollowSnapshot(
                follows: Set(state.threadFollows.keys),
                unfollows: Set(state.threadUnfollows.keys)
            )
        }
    }

    /// Removes every follow row for `keys` in one critical section.
    func removeThreadFollows(keys: [String]) {
        guard !keys.isEmpty else { return }
        withState { state in
            for key in keys {
                state.threadFollows.removeValue(forKey: key)
                state.threadUnfollows.removeValue(forKey: key)
                state.threadFollowStarts.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Thread follow ledger

    /// One `(thread, parent message)` follow row, copied out of the ledger.
    struct ThreadFollowRow: Sendable, Equatable {
        let threadChannelId: String
        let parentMessageId: String
    }

    /// The thread a parent message already follows, searched across the whole
    /// ledger exactly as the legacy resolver did.
    func threadId(serverId: String, parentMessageId: String) -> String? {
        withState { state in
            return state.threadFollows.values.first {
                $0.serverId == serverId && $0.parentMessageId == parentMessageId
            }?.threadChannelId
        }
    }

    /// A user's active follows on one server, with inbox-done scopes filtered
    /// out under the same lock that reads the rows.
    func activeThreadFollows(serverId: String, userId: String) -> [ThreadFollowRow] {
        withState { state in
            return state.threadFollows.values
                .filter {
                    $0.serverId == serverId
                        && $0.userId == userId
                        && !state.inboxDoneScopes.contains("\(userId)\n\($0.threadChannelId)")
                }
                .map { ThreadFollowRow(threadChannelId: $0.threadChannelId, parentMessageId: $0.parentMessageId) }
        }
    }

    func isThreadFollowed(serverId: String, userId: String, threadChannelId: String) -> Bool {
        withState { state in
            return state.threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] != nil
        }
    }

    /// Unread-eligible personal mention ids for one user. The followed-thread
    /// projection intersects these with the thread's unread replies.
    func unreadMentionMessageIds(userId: String) -> Set<String> {
        withState { state in
            return Set(state.storedMentions.lazy.filter {
                $0.targetType == "user" && $0.targetId == userId && $0.notifiableAtSend
            }.map(\.messageId))
        }
    }

    /// One user's unfollow suppression rows on a server, newest first is left
    /// to the caller.
    func threadUnfollowRecords(serverId: String, userId: String) -> [ThreadUnfollowRecord] {
        withState { state in
            return state.threadUnfollows.values.filter {
                $0.serverId == serverId && $0.userId == userId
            }
        }
    }

    /// The follow/unfollow write: follow row, follow start and the unfollow
    /// suppression row change in one critical section. The legacy handler read
    /// the follow start, filtered the frozen replies and wrote the suppression
    /// row under the directory lock; splitting those reads here would let two
    /// concurrent writes interleave a follow and a suppression row.
    func applyThreadFollow(
        serverId: String,
        userId: String,
        threadChannelId: String,
        parentMessageId: String,
        follow: Bool,
        now: Date
    ) {
        withState { state in
            Self.applyThreadFollow(in: &state, serverId: serverId, userId: userId,
                threadChannelId: threadChannelId, parentMessageId: parentMessageId, follow: follow, now: now)
        }
    }

    /// A new real follow/unfollow transition makes every earlier managed undo
    /// token for this recipient obsolete. No timestamp or schema is invented.
    static func retireManagedThreadFollowerRemovals(in state: inout State,
        serverId: String, threadId: String, agentId: String) {
        let tokens = state.threadFollowerRemovals.compactMap { token, record in
            record.serverId == serverId && record.threadChannelId == threadId && record.agentId == agentId ? token : nil
        }
        for token in tokens {
            state.threadFollowerRemovals.removeValue(forKey: token)
            state.staleThreadFollowerUndoTokens.insert(token)
        }
    }

    private static func applyThreadFollow(in state: inout State, serverId: String, userId: String,
        threadChannelId: String, parentMessageId: String, follow: Bool, now: Date) {
        let key = "\(serverId)\n\(userId)\n\(threadChannelId)"
        retireManagedThreadFollowerRemovals(in: &state, serverId: serverId, threadId: threadChannelId, agentId: userId)
        if follow {
            state.threadFollows[key] = (
                serverId: serverId,
                userId: userId,
                threadChannelId: threadChannelId,
                parentMessageId: parentMessageId
            )
            if state.threadFollowStarts[key] == nil {
                state.threadFollowStarts[key] = now
            }
            state.threadUnfollows.removeValue(forKey: key)
            return
        }
        state.threadFollows.removeValue(forKey: key)
        let startedAt = state.threadFollowStarts.removeValue(forKey: key) ?? .distantPast
        let frozen = state.humanMessageRows
            .filter { $0.channelId == threadChannelId && $0.createdAt >= startedAt }
            .map { (id: $0.id, content: $0.content) }
        state.threadUnfollows[key] = ThreadUnfollowRecord(
            serverId: serverId,
            userId: userId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId,
            unfollowedAt: now,
            latestMessageId: frozen.last?.id ?? parentMessageId,
            replyCount: frozen.count,
            frozenMessages: frozen
        )
    }

    /// The reply-path follows that upstream writes before the frontend emit:
    /// the sender always reactivates (a new reply is an explicit re-follow),
    /// while the parent author is only ensured and never overrides an explicit
    /// unfollow (`recordThreadFollow(..., "authored")` without reactivation).
    ///
    /// This runs inside the caller's Messages transaction, so the join
    /// audience computed by the send path already contains both rows.
    func recordThreadReplyJoinFollows(
        serverId: String,
        threadChannelId: String,
        parentMessageId: String,
        senderId: String,
        parentAuthorId: String?
    ) {
        withState { state in
            let senderKey = "\(serverId)\n\(senderId)\n\(threadChannelId)"
            state.threadUnfollows.removeValue(forKey: senderKey)
            Self.retireManagedThreadFollowerRemovals(in: &state, serverId: serverId,
                threadId: threadChannelId, agentId: senderId)
            state.threadFollows[senderKey] = (
                serverId: serverId,
                userId: senderId,
                threadChannelId: threadChannelId,
                parentMessageId: parentMessageId
            )
            guard let parentAuthorId, parentAuthorId != senderId else { return }
            let authorKey = "\(serverId)\n\(parentAuthorId)\n\(threadChannelId)"
            guard state.threadUnfollows[authorKey] == nil else { return }
            state.threadFollows[authorKey] = (
                serverId: serverId,
                userId: parentAuthorId,
                threadChannelId: threadChannelId,
                parentMessageId: parentMessageId
            )
        }
    }

    /// Follows the creator (and, when a different live member wrote the
    /// parent, the parent author) of a freshly created thread in one critical
    /// section.
    func followCreatedThread(
        serverId: String,
        userId: String,
        threadChannelId: String,
        parentMessageId: String,
        parentAuthorId: String?
    ) {
        withState { state in
            state.threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] =
                (serverId, userId, threadChannelId, parentMessageId)
            if let parentAuthorId {
                state.threadFollows["\(serverId)\n\(parentAuthorId)\n\(threadChannelId)"] =
                    (serverId, parentAuthorId, threadChannelId, parentMessageId)
            }
        }
    }

    /// The decision and the write of `DELETE …/threads/:threadId/followers/agents/:agentId`.
    enum ThreadFollowerRemovalWrite: Sendable, Equatable {
        /// A row for this thread/agent pair already exists; its token is returned.
        case replay(undoToken: String)
        /// This request inserted the row.
        case created(undoToken: String)
    }

    /// One locked critical section over the undo ledger: an existing removal for
    /// the thread/agent pair replays its token, otherwise `undoToken` is
    /// inserted. Two concurrent removals therefore issue exactly one token.
    func beginThreadFollowerRemoval(
        serverId: String,
        threadId: String,
        agentId: String,
        undoToken: String,
        now: Date = Date()
    ) -> ThreadFollowerRemovalWrite {
        withState { state in
            let key = "\(serverId)\n\(agentId)\n\(threadId)"
            if let existing = state.threadFollowerRemovals.first(where: {
                $0.value.serverId == serverId && $0.value.threadChannelId == threadId && $0.value.agentId == agentId
            }) {
                if state.threadFollows[key] == nil || state.threadUnfollows[key] != nil {
                    return .replay(undoToken: existing.key)
                }
                // A retained active follow supersedes an older compatibility token.
                Self.retireManagedThreadFollowerRemovals(in: &state, serverId: serverId, threadId: threadId, agentId: agentId)
            }
            if let follow = state.threadFollows[key] {
                Self.applyThreadFollow(in: &state, serverId: serverId, userId: agentId,
                    threadChannelId: threadId, parentMessageId: follow.parentMessageId, follow: false, now: now)
            }
            // Legacy rows without a retained follow keep their existing token/body
            // contract; no canonical parent/follow is manufactured for them.
            state.threadFollowerRemovals[undoToken] = (
                serverId: serverId,
                threadChannelId: threadId,
                agentId: agentId
            )
            return .created(undoToken: undoToken)
        }
    }

    /// The decision and the write of the restore route.
    enum ThreadFollowerRestoreWrite: Sendable, Equatable {
        /// The token was live for this thread/agent pair and is now consumed.
        case restored
        /// Unknown, already consumed, or issued for another thread/agent pair.
        case notRemoved
    }

    /// One locked critical section: the token is consumed and marked stale
    /// together, so a token can restore at most once.
    func restoreThreadFollower(
        threadId: String,
        agentId: String,
        undoToken: String,
        now: Date = Date()
    ) -> ThreadFollowerRestoreWrite {
        withState { state in
            guard let record = state.threadFollowerRemovals[undoToken],
                  record.threadChannelId == threadId,
                  record.agentId == agentId
            else { return .notRemoved }
            let key = "\(record.serverId)\n\(agentId)\n\(threadId)"
            if let unfollow = state.threadUnfollows[key] {
                Self.applyThreadFollow(in: &state, serverId: record.serverId, userId: agentId,
                    threadChannelId: threadId, parentMessageId: unfollow.parentMessageId, follow: true, now: now)
            } else if state.threadFollows[key] != nil {
                // An actual reply/mention/manual follow already reactivated this
                // recipient; an earlier removal cannot restore a later state.
                return .notRemoved
            }
            state.threadFollowerRemovals.removeValue(forKey: undoToken)
            state.staleThreadFollowerUndoTokens.insert(undoToken)
            return .restored
        }
    }
}
