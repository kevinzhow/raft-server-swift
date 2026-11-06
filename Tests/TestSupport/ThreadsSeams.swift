import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    @discardableResult
    public func addHumanMessageForTesting(channelId: String, senderId: String, content: String, messageType: String = "chat", senderType: String = "user", senderTimezone: String? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil,
            messageType: messageType,
            senderType: senderType,
            senderTimezone: senderTimezone
        ))
        lock.unlock()
        return id
    }

    public func addThreadFollowForTesting(serverId: String, userId: String, threadChannelId: String, parentMessageId: String) {
        lock.lock()
        threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] = (
            serverId: serverId, userId: userId,
            threadChannelId: threadChannelId, parentMessageId: parentMessageId
        )
        lock.unlock()
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
        lock.lock()
        let key = "\(serverId)\n\(userId)\n\(threadChannelId)"
        threadFollows.removeValue(forKey: key)
        threadFollowStarts.removeValue(forKey: key)
        threadUnfollows[key] = ThreadUnfollowRecord(
            serverId: serverId,
            userId: userId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId,
            unfollowedAt: Date(),
            latestMessageId: latestMessageId ?? parentMessageId,
            replyCount: 0,
            frozenMessages: []
        )
        lock.unlock()
    }

    public func threadUnfollowSuppressedForTesting(serverId: String, userId: String, threadChannelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return threadUnfollows["\(serverId)\n\(userId)\n\(threadChannelId)"] != nil
    }

    public func inboxDoneFrontierForTesting(userId: String, scopeId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return inboxDoneFrontiers["\(userId)\n\(scopeId)"]
    }

    public func mentionNotificationStateForTesting(messageId: String, targetId: String) -> (notifiableAtSend: Bool, notified: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = storedMentions.first(where: { $0.messageId == messageId && $0.targetId == targetId }) else { return nil }
        return (row.notifiableAtSend, row.notifiedAt != nil)
    }

    @discardableResult
    public func addHumanMessageWithSeqForTesting(channelId: String, senderId: String, content: String, seq: Int) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        _ = appendHumanMessageLocked(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil
        ), seq: seq)
        lock.unlock()
        return id
    }

    public func setServerOnboardingAgentForTesting(serverId: String, agentId: String?) {
        lock.lock()
        let greeting = serverOnboardingSettings[serverId]?.greeting ?? true
        serverOnboardingSettings[serverId] = (agentId: agentId, greeting: greeting)
        lock.unlock()
    }

    public func setMachineMigrationStateForTesting(migrationRef: String, state: String) {
        lock.lock()
        if var record = machineMigrations[migrationRef] {
            record.state = state
            record.updatedAt = Date()
            machineMigrations[migrationRef] = record
        }
        lock.unlock()
    }

    public func userChannelReadCursorForTesting(userId: String, channelId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return userChannelReadCursors["\(userId)\n\(channelId)"]
    }

    public func threadFollowerIdsForTesting(threadChannelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return threadFollows.values
            .filter { $0.threadChannelId == threadChannelId }
            .map(\.userId)
            .sorted()
    }
}
