import Foundation

extension MessagesAndThreadsStore {
    // MARK: - Reaction writes

    /// One reaction write: the row change and the viewer/discussion versions
    /// that describe it, copied under the same lock.
    struct ReactionWriteSnapshot {
        let rows: [StoredReaction]
        let viewerVersion: Int
        let discussionVersion: Int
    }

    /// A human add/remove. The idempotency check, the row change, the
    /// viewer-version bump and the discussion-version bump are one critical
    /// section, so two concurrent identical posts cannot both count as a
    /// change and a remove cannot race an add.
    func applyUserReaction(
        messageId: String,
        userId: String,
        emoji: String,
        remove: Bool
    ) -> ReactionWriteSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let before = storage.messageReactions.count
        if remove {
            storage.messageReactions.removeAll {
                $0.messageId == messageId && $0.emoji == emoji
                    && $0.reactorId == userId && $0.reactorType == "user"
            }
        } else if !storage.messageReactions.contains(where: {
            $0.messageId == messageId && $0.emoji == emoji
                && $0.reactorId == userId && $0.reactorType == "user"
        }) {
            storage.messageReactions.append(StoredReaction(
                messageId: messageId,
                emoji: emoji,
                reactorId: userId,
                reactorType: "user"
            ))
        }
        let viewerKey = "\(messageId)\n\(userId)"
        if storage.messageReactions.count != before {
            storage.reactionViewerVersions[viewerKey] =
                (storage.reactionViewerVersions[viewerKey] ?? 0) + 1
            let discussionKey = "\(messageId)\n\(emoji)"
            storage.reactionDiscussionVersions[discussionKey] =
                (storage.reactionDiscussionVersions[discussionKey] ?? 0) + 1
        }
        return ReactionWriteSnapshot(
            rows: storage.messageReactions.filter { $0.messageId == messageId },
            viewerVersion: storage.reactionViewerVersions[viewerKey] ?? 0,
            discussionVersion: storage.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0
        )
    }

    /// The agent variant: same atomic row change, no viewer version (engine
    /// agents have no `reactionViewer` snapshot).
    func applyAgentReaction(
        messageId: String,
        agentId: String,
        emoji: String,
        remove: Bool
    ) -> ReactionWriteSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let before = storage.messageReactions.count
        if remove {
            storage.messageReactions.removeAll {
                $0.messageId == messageId && $0.emoji == emoji
                    && $0.reactorId == agentId && $0.reactorType == "agent"
            }
        } else if !storage.messageReactions.contains(where: {
            $0.messageId == messageId && $0.emoji == emoji
                && $0.reactorId == agentId && $0.reactorType == "agent"
        }) {
            storage.messageReactions.append(StoredReaction(
                messageId: messageId,
                emoji: emoji,
                reactorId: agentId,
                reactorType: "agent"
            ))
        }
        if storage.messageReactions.count != before {
            let discussionKey = "\(messageId)\n\(emoji)"
            storage.reactionDiscussionVersions[discussionKey] =
                (storage.reactionDiscussionVersions[discussionKey] ?? 0) + 1
        }
        return ReactionWriteSnapshot(
            rows: storage.messageReactions.filter { $0.messageId == messageId },
            viewerVersion: 0,
            discussionVersion: storage.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0
        )
    }

    /// One viewer read: the version and the caller's own emojis from the same
    /// locked snapshot.
    struct ReactionViewerSnapshot {
        let viewerVersion: Int
        let reactedEmojis: [String]
    }

    func reactionViewerSnapshot(messageId: String, userId: String) -> ReactionViewerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let emojis = storage.messageReactions
            .filter {
                $0.messageId == messageId && $0.reactorType == "user"
                    && $0.reactorId == userId
            }
            .map(\.emoji)
            .sorted(by: MessageSearchText.utf16Ascending)
        return ReactionViewerSnapshot(
            viewerVersion: storage.reactionViewerVersions["\(messageId)\n\(userId)"] ?? 0,
            reactedEmojis: emojis
        )
    }

    /// One actor-page read: the discussion version and the matching rows from
    /// the same locked snapshot.
    struct ReactionDiscussionSnapshot {
        let discussionVersion: Int
        let rows: [StoredReaction]
    }

    func reactionDiscussionSnapshot(messageId: String, emoji: String) -> ReactionDiscussionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ReactionDiscussionSnapshot(
            discussionVersion: storage.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0,
            rows: storage.messageReactions.filter {
                $0.messageId == messageId && $0.emoji == emoji
            }
        )
    }
}
