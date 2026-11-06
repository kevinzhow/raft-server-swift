import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    @discardableResult
    public func addHumanMessageForTesting(channelId: String, senderId: String, content: String, messageType: String = "chat", senderType: String = "user", senderTimezone: String? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        messagesAndThreadsStore.appendMessage(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil,
            messageType: messageType,
            senderType: senderType,
            senderTimezone: senderTimezone
        ), ledger: .init(oauth: oauth))
        return id
    }

    public func addThreadFollowForTesting(serverId: String, userId: String, threadChannelId: String, parentMessageId: String) {
        messagesAndThreadsStore.withState { state in
            state.threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] = (
                serverId: serverId, userId: userId,
                threadChannelId: threadChannelId, parentMessageId: parentMessageId
            )
        }
    }

    /// Fixture seam: the unfollow suppression row an HTTP unfollow would write,
    /// without depending on a prior follow or on frozen messages.
    public func unfollowThreadForTesting(
        serverId: String,
        userId: String,
        threadChannelId: String,
        parentMessageId: String,
        latestMessageId: String? = nil
    ) {
        messagesAndThreadsStore.withState { state in
            let key = "\(serverId)\n\(userId)\n\(threadChannelId)"
            state.threadFollows.removeValue(forKey: key)
            state.threadFollowStarts.removeValue(forKey: key)
            state.threadUnfollows[key] = ThreadUnfollowRecord(
                serverId: serverId,
                userId: userId,
                threadChannelId: threadChannelId,
                parentMessageId: parentMessageId,
                unfollowedAt: Date(),
                latestMessageId: latestMessageId ?? parentMessageId,
                replyCount: 0,
                frozenMessages: []
            )
        }
    }

    public func threadUnfollowSuppressedForTesting(serverId: String, userId: String, threadChannelId: String) -> Bool {
        messagesAndThreadsStore.withState { state in
            return state.threadUnfollows["\(serverId)\n\(userId)\n\(threadChannelId)"] != nil
        }
    }

    public func inboxDoneFrontierForTesting(userId: String, scopeId: String) -> Int? {
        messagesAndThreadsStore.withState { state in
            return state.inboxDoneFrontiers["\(userId)\n\(scopeId)"]
        }
    }

    public func mentionNotificationStateForTesting(messageId: String, targetId: String) -> (notifiableAtSend: Bool, notified: Bool)? {
        messagesAndThreadsStore.withState { state in
            guard let row = state.storedMentions.first(where: { $0.messageId == messageId && $0.targetId == targetId }) else { return nil }
            return (row.notifiableAtSend, row.notifiedAt != nil)
        }
    }

    @discardableResult
    public func addHumanMessageWithSeqForTesting(channelId: String, senderId: String, content: String, seq: Int) -> String {
        let id = UUID().uuidString.lowercased()
        let ledger = MessageLedgerPort(oauth: oauth)
        messagesAndThreadsStore.withState { state in
            let message = StoredHumanMessage(id: id, channelId: channelId, senderId: senderId,
                content: content, seq: seq, randomId: nil)
            state.humanMessageRows.append(message)
            // Preserve the approved Messages -> OAuth commit boundary even for
            // this explicit-sequence fixture; the concrete port has no callback.
            ledger.mirror(message)
        }
        return id
    }

    public func setServerOnboardingAgentForTesting(serverId: String, agentId: String?) {
        serversAndChannelsStore.mutex.withLock { state in
            let greeting = state.serverOnboardingSettings[serverId]?.greeting ?? true
            state.serverOnboardingSettings[serverId] = (agentId: agentId, greeting: greeting)
        }
    }

    public func setMachineMigrationStateForTesting(migrationRef: String, state: String) {
        agentsRuntimeStore.withState { owned in
            if var record = owned.machineMigrations[migrationRef] {
                record.state = state
                record.updatedAt = Date()
                owned.machineMigrations[migrationRef] = record
            }
        }
    }

    public func userChannelReadCursorForTesting(userId: String, channelId: String) -> Int? {
        messagesAndThreadsStore.withState { state in
            return state.userChannelReadCursors["\(userId)\n\(channelId)"]
        }
    }

    public func threadFollowerIdsForTesting(threadChannelId: String) -> [String] {
        messagesAndThreadsStore.withState { state in
            return state.threadFollows.values
                .filter { $0.threadChannelId == threadChannelId }
                .map(\.userId)
                .sorted()
        }
    }
}
