@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func agentMuteStateForTesting(channelId: String, agentId: String) -> (serverId: String, muteFromSeq: Int)? {
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: agentId)
        guard prefs.activityMuted, let muteFromSeq = prefs.muteFromSeq else { return nil }
        return (oauth.channelServerId(channelId) ?? "", muteFromSeq)
    }

    public func setAgentReadCursorForTesting(agentId: String, channelId: String, seq: Int, version: Int = 1) {
        lock.lock()
        agentChannelReadCursors["\(channelId)\n\(agentId)"] = (seq, version)
        lock.unlock()
    }

    public func setChannelHumanRoleForTesting(channelId: String, userId: String, role: String) {
        lock.lock()
        channelHumanRoles["\(channelId)\n\(userId)"] = role
        lock.unlock()
    }

    public func setAccountDescriptionForTesting(userId: String, description: String?) {
        lock.lock()
        if let index = accounts.values.firstIndex(where: { $0.id == userId }) {
            var account = accounts.values[index]
            account.description = description
            accounts.values[index] = account
        }
        lock.unlock()
    }

    public func seedDMForTesting(serverId: String, humanUserId: String, agentId: String, name: String = "dm") -> String {
        let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: humanUserId, secondUserId: agentId)
        addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "dm", name: name)
        addPostableChannel(serverId: serverId, channelId: channelId, memberId: humanUserId, kind: "dm", name: name)
        oauth.addChannelHuman(channelId: channelId, userId: humanUserId)
        return channelId
    }

    public func channelCardRevisionForTesting(channelId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return actionCardPrepare.channelCardSnapshot(channelId: channelId)?.rev
    }

    public func mentionsForTesting(messageId: String) -> [(targetType: String, targetId: String, handle: String)] {
        lock.lock(); defer { lock.unlock() }
        return storedMentions.filter { $0.messageId == messageId }.map { ($0.targetType, $0.targetId, $0.handle) }
    }

    public func addStoredMentionForTesting(
        channelId: String,
        messageId: String,
        targetId: String,
        targetType: String = "user",
        handle: String = "peer",
        terminalCode: String? = nil
    ) {
        lock.lock()
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: messageId,
            channelId: channelId,
            senderId: "peer",
            targetType: targetType,
            targetId: targetId,
            handle: handle,
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil,
            terminalCode: terminalCode
        ))
        lock.unlock()
    }

    @discardableResult
    public func setAnnouncementAudienceForTesting(id: String, serverIds: [String]) {
        lock.lock()
        if let index = announcements.firstIndex(where: { $0.id == id }) {
            announcements[index].audienceServerIds = serverIds
        }
        lock.unlock()
    }
}
