import Foundation

extension MessagesAndThreadsStore {
    // MARK: - Reaction writes

    /// One reaction write: the row change and the viewer/discussion versions
    /// that describe it, copied under the same lock.
    struct ReactionWriteSnapshot: Sendable {
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
        withState { state in
            let before = state.messageReactions.count
            if remove {
                state.messageReactions.removeAll {
                    $0.messageId == messageId && $0.emoji == emoji
                        && $0.reactorId == userId && $0.reactorType == "user"
                }
            } else if !state.messageReactions.contains(where: {
                $0.messageId == messageId && $0.emoji == emoji
                    && $0.reactorId == userId && $0.reactorType == "user"
            }) {
                state.messageReactions.append(StoredReaction(
                    messageId: messageId,
                    emoji: emoji,
                    reactorId: userId,
                    reactorType: "user"
                ))
            }
            let viewerKey = "\(messageId)\n\(userId)"
            if state.messageReactions.count != before {
                state.reactionViewerVersions[viewerKey] =
                    (state.reactionViewerVersions[viewerKey] ?? 0) + 1
                let discussionKey = "\(messageId)\n\(emoji)"
                state.reactionDiscussionVersions[discussionKey] =
                    (state.reactionDiscussionVersions[discussionKey] ?? 0) + 1
            }
            return ReactionWriteSnapshot(
                rows: state.messageReactions.filter { $0.messageId == messageId },
                viewerVersion: state.reactionViewerVersions[viewerKey] ?? 0,
                discussionVersion: state.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0
            )
        }
    }

    /// The agent variant: same atomic row change, no viewer version (engine
    /// agents have no `reactionViewer` snapshot).
    func applyAgentReaction(
        messageId: String,
        agentId: String,
        emoji: String,
        remove: Bool
    ) -> ReactionWriteSnapshot {
        withState { state in
            let before = state.messageReactions.count
            if remove {
                state.messageReactions.removeAll {
                    $0.messageId == messageId && $0.emoji == emoji
                        && $0.reactorId == agentId && $0.reactorType == "agent"
                }
            } else if !state.messageReactions.contains(where: {
                $0.messageId == messageId && $0.emoji == emoji
                    && $0.reactorId == agentId && $0.reactorType == "agent"
            }) {
                state.messageReactions.append(StoredReaction(
                    messageId: messageId,
                    emoji: emoji,
                    reactorId: agentId,
                    reactorType: "agent"
                ))
            }
            if state.messageReactions.count != before {
                let discussionKey = "\(messageId)\n\(emoji)"
                state.reactionDiscussionVersions[discussionKey] =
                    (state.reactionDiscussionVersions[discussionKey] ?? 0) + 1
            }
            return ReactionWriteSnapshot(
                rows: state.messageReactions.filter { $0.messageId == messageId },
                viewerVersion: 0,
                discussionVersion: state.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0
            )
        }
    }

    /// One viewer read: the version and the caller's own emojis from the same
    /// locked snapshot.
    struct ReactionViewerSnapshot: Sendable {
        let viewerVersion: Int
        let reactedEmojis: [String]
    }

    func reactionViewerSnapshot(messageId: String, userId: String) -> ReactionViewerSnapshot {
        withState { state in
            let emojis = state.messageReactions
                .filter {
                    $0.messageId == messageId && $0.reactorType == "user"
                        && $0.reactorId == userId
                }
                .map(\.emoji)
                .sorted(by: MessageSearchText.utf16Ascending)
            return ReactionViewerSnapshot(
                viewerVersion: state.reactionViewerVersions["\(messageId)\n\(userId)"] ?? 0,
                reactedEmojis: emojis
            )
        }
    }

    /// One actor-page read: the discussion version and the matching rows from
    /// the same locked snapshot.
    struct ReactionDiscussionSnapshot: Sendable {
        let discussionVersion: Int
        let rows: [StoredReaction]
    }

    func reactionDiscussionSnapshot(messageId: String, emoji: String) -> ReactionDiscussionSnapshot {
        withState { state in
            return ReactionDiscussionSnapshot(
                discussionVersion: state.reactionDiscussionVersions["\(messageId)\n\(emoji)"] ?? 0,
                rows: state.messageReactions.filter {
                    $0.messageId == messageId && $0.emoji == emoji
                }
            )
        }
    }
}
