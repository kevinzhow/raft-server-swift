import Foundation

/// One conversation an agent reads: the id it is addressed by and the channel
/// its messages are stored under (a joint channel stores under the canonical
/// channel).
struct AgentInboxConversation: Sendable, Equatable {
    var id: String
    var storage: String
}

/// A message an agent has not read yet, with the conversation it was found in.
struct AgentPendingMessage: Sendable {
    var seq: Int
    var message: StoredHumanMessage
    var conversationIndex: Int
}

/// What one agent inbox drain handed out and what it advanced.
struct AgentInboxDrain: Sendable {
    var selected: [AgentPendingMessage]
    var hasMore: Bool
    var mentionedMessageIds: Set<String>
}

/// The slice of the message ledger the Activity page projects from, copied in
/// one critical section so a page never mixes two versions of the ledger.
struct InboxReadSnapshot: Sendable {
    var doneScopes: Set<String>
    var mentions: [StoredMention]
    var followKeys: Set<String>
    var unfollows: [String: ThreadUnfollowRecord]
    var humanRows: [StoredHumanMessage]
}

/// One scope the read-all write marked.
struct InboxReadAllMark: Equatable, Sendable {
    var scopeId: String
    var maxReadSeq: Int
    var readStateVersion: Int
}

/// Inbox Done state, read versions and agent read cursors. Each
/// read-modify-write here is one critical section on the store's lock.
extension MessagesAndThreadsStore {
    func inboxReadSnapshot() -> InboxReadSnapshot {
        withState { state in
            InboxReadSnapshot(
                doneScopes: state.inboxDoneScopes,
                mentions: state.storedMentions,
                followKeys: Set(state.threadFollows.keys),
                unfollows: state.threadUnfollows,
                humanRows: state.humanMessageRows
            )
        }
    }

    /// Marks one scope Done: the scope, its Done time and its frontier change
    /// together.
    func markInboxDone(userId: String, scopeId: String, frontier: Int, at date: Date) {
        withState { state in
            let key = "\(userId)\n\(scopeId)"
            state.inboxDoneScopes.insert(key)
            state.inboxDoneAt[key] = date
            state.inboxDoneFrontiers[key] = frontier
        }
    }

    /// Reopens one scope: scope, Done time and frontier are removed together.
    func clearInboxDone(userId: String, scopeId: String) {
        withState { state in
            let key = "\(userId)\n\(scopeId)"
            state.inboxDoneScopes.remove(key)
            state.inboxDoneAt.removeValue(forKey: key)
            state.inboxDoneFrontiers.removeValue(forKey: key)
        }
    }

    /// The facts a deleted thread's Done needs from the message ledger: whether
    /// the viewer still follows it and the sequence of their latest owned fact.
    func deletedThreadScope(
        serverId: String?,
        userId: String,
        threadId: String,
        latestOwnedMessageId: String?
    ) -> (followed: Bool, ownedMessageSeq: Int?) {
        withState { state in
            let followed = state.threadFollows["\(serverId ?? "")\n\(userId)\n\(threadId)"] != nil
            let seq = latestOwnedMessageId.flatMap { id in
                state.humanMessageRows.first { $0.id == id }?.seq
            }
            return (followed, seq)
        }
    }

    /// Read-all: every scope with a fact (`factScopeIds`) or a follow on the
    /// server is marked Done, its frontier set to the latest activity, its
    /// read cursor committed and its read-state version bumped, all inside one
    /// critical section so two concurrent read-alls can never lose a version
    /// increment. `commitReadCursor` writes the OAuth read cursor and returns
    /// the latest sequence; it must not touch this store.
    func markAllInboxDone(
        userId: String,
        serverId: String,
        factScopeIds: Set<String>,
        now: Date,
        commitReadCursor: (String) -> Int
    ) -> [InboxReadAllMark] {
        withState { state in
            var scopeIds = factScopeIds
            scopeIds.formUnion(
                state.threadFollows.values
                    .filter { $0.serverId == serverId && $0.userId == userId }
                    .map(\.threadChannelId)
            )
            var marks: [InboxReadAllMark] = []
            for scopeId in scopeIds.sorted() {
                let doneKey = "\(userId)\n\(scopeId)"
                state.inboxDoneScopes.insert(doneKey)
                state.inboxDoneAt[doneKey] = now
                let latest = commitReadCursor(scopeId)
                state.inboxDoneFrontiers[doneKey] = latest
                let versionKey = "\(scopeId)\n\(userId)"
                let version = (state.channelReadVersions[versionKey] ?? 0) + 1
                state.channelReadVersions[versionKey] = version
                marks.append(InboxReadAllMark(scopeId: scopeId, maxReadSeq: latest, readStateVersion: version))
            }
            return marks
        }
    }

    // MARK: - Agent inbox

    /// The agent mention rows an agent may see: outsider rows stay hidden
    /// until they were notifiable at send or later notified.
    func agentMentionRows(agentId: String) -> [StoredMention] {
        withState { state in
            state.storedMentions.filter {
                $0.targetType == "agent"
                    && $0.targetId == agentId
                    && ($0.notifiableAtSend || $0.notifiedAt != nil)
            }
        }
    }

    /// A muted conversation suppresses a message from its mute point on unless
    /// the message mentions the agent.
    static func agentMessageSuppressed(
        _ message: StoredHumanMessage,
        agentId: String,
        prefs: OAuthLedger.ChannelNotificationPrefs,
        mentions: [StoredMention]
    ) -> Bool {
        guard prefs.activityMuted, let from = prefs.muteFromSeq, message.seq >= from else {
            return false
        }
        let mentioned = mentions.contains {
            $0.messageId == message.id && $0.targetType == "agent" && $0.targetId == agentId
        }
        return !mentioned
    }

    /// The unread, unsuppressed messages of an agent across its conversations,
    /// ordered by sequence, read in one critical section. The peek route and
    /// the wake-hint stream share it.
    func pendingAgentMessages(
        conversations: [AgentInboxConversation],
        agentId: String,
        sinceSeq: Int?,
        prefs: [String: OAuthLedger.ChannelNotificationPrefs]
    ) -> [AgentPendingMessage] {
        withState { state in
            var pending: [AgentPendingMessage] = []
            for (index, conversation) in conversations.enumerated() {
                let cursor = state.agentChannelReadCursors["\(conversation.id)\n\(agentId)"]?.seq ?? 0
                for message in state.humanMessageRows
                where message.channelId == conversation.storage
                    && message.seq > cursor
                    && message.senderId != agentId
                    && (sinceSeq.map { message.seq > $0 } ?? true)
                    && !Self.agentMessageSuppressed(
                        message,
                        agentId: agentId,
                        prefs: prefs[message.channelId] ?? OAuthLedger.ChannelNotificationPrefs(),
                        mentions: state.storedMentions
                    ) {
                    pending.append(AgentPendingMessage(seq: message.seq, message: message, conversationIndex: index))
                }
            }
            pending.sort { $0.seq < $1.seq }
            return pending
        }
    }

    /// Drains up to `pullCap` unread messages per conversation and advances
    /// the agent's read cursors past them. Selection and cursor advance are one
    /// critical section: two concurrent drains can never hand out the same
    /// message twice.
    func drainAgentInbox(
        conversations: [AgentInboxConversation],
        agentId: String,
        prefs: [String: OAuthLedger.ChannelNotificationPrefs],
        pullCap: Int
    ) -> AgentInboxDrain {
        withState { state in
            var selected: [AgentPendingMessage] = []
            var seenMessages = Set<String>()
            var hasMore = false
            for (index, conversation) in conversations.enumerated() {
                let key = "\(conversation.id)\n\(agentId)"
                let cursor = state.agentChannelReadCursors[key]?.seq ?? 0
                let pending = state.humanMessageRows.filter { message in
                    message.channelId == conversation.storage
                        && message.seq > cursor
                        && message.senderId != agentId
                        && !Self.agentMessageSuppressed(
                            message,
                            agentId: agentId,
                            prefs: prefs[message.channelId] ?? OAuthLedger.ChannelNotificationPrefs(),
                            mentions: state.storedMentions
                        )
                }
                if pending.count > pullCap { hasMore = true }
                for message in pending.prefix(pullCap) {
                    guard seenMessages.insert(message.id).inserted else { continue }
                    selected.append(AgentPendingMessage(seq: message.seq, message: message, conversationIndex: index))
                }
                if let last = pending.prefix(pullCap).last {
                    let previous = state.agentChannelReadCursors[key] ?? (seq: 0, version: 0)
                    let newSeq = max(previous.seq, last.seq)
                    state.agentChannelReadCursors[key] = (newSeq, previous.version + (newSeq > previous.seq ? 1 : 0))
                }
            }
            let mentionedIds = Set(state.storedMentions.filter {
                $0.targetType == "agent" && $0.targetId == agentId
            }.map(\.messageId))
            return AgentInboxDrain(selected: selected, hasMore: hasMore, mentionedMessageIds: mentionedIds)
        }
    }
}
