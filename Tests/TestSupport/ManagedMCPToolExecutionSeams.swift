@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func enableReadReceiptsForServer(_ serverId: String) {
        serversAndChannelsStore.enableReadReceipts(serverId: serverId)
    }

    public func agentReadCursor(channelId: String, agentId: String) -> Int {
        messagesAndThreadsStore.agentChannelReadSeq(channelId: channelId, agentId: agentId)
    }

    public func humanReadCursor(channelId: String, userId: String) -> Int {
        oauth.channelReadCursor(channelId: channelId, userId: userId)
    }

    public func systemMessageContents(channelId: String) -> [String] {
        messagesAndThreadsStore.withState { state in
            state.humanMessageRows
                .filter { $0.channelId == channelId && $0.messageType == "system" }
                .map(\.content)
        }
    }

    public func humanMessageSequence(id: String) -> Int? {
        messagesAndThreadsStore.humanMessageRow(id: id)?.seq
    }

    public func agentMuteStateForTesting(channelId: String, agentId: String) -> (serverId: String, muteFromSeq: Int)? {
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: agentId)
        guard prefs.activityMuted, let muteFromSeq = prefs.muteFromSeq else { return nil }
        return (oauth.channelServerId(channelId) ?? "", muteFromSeq)
    }

    public func setAgentReadCursorForTesting(agentId: String, channelId: String, seq: Int, version: Int = 1) {
        messagesAndThreadsStore.withState { state in
            state.agentChannelReadCursors["\(channelId)\n\(agentId)"] = (seq, version)
        }
    }

    public func setChannelHumanRoleForTesting(channelId: String, userId: String, role: String) {
        serversAndChannelsStore.mutex.withLock { state in
            state.channelHumanRoles["\(channelId)\n\(userId)"] = role
        }
    }

    public func setAccountDescriptionForTesting(userId: String, description: String?) {
        authProfileStore.state.withLock { state in
            if let index = state.accountSurface.accounts.values.firstIndex(where: { $0.id == userId }) {
                var account = state.accountSurface.accounts.values[index]
                account.description = description
                state.accountSurface.accounts.values[index] = account
            }
        }
    }

    public func seedDMForTesting(serverId: String, humanUserId: String, agentId: String, name: String = "dm") -> String {
        let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: humanUserId, secondUserId: agentId)
        oauth.removeChannelHuman(channelId: channelId, userId: agentId)
        oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        serversAndChannelsStore.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "dm", name: name)
        serversAndChannelsStore.addPostableChannel(serverId: serverId, channelId: channelId, memberId: humanUserId, kind: "dm", name: name)
        oauth.addChannelHuman(channelId: channelId, userId: humanUserId)
        return channelId
    }

    public func channelCardRevisionForTesting(channelId: String) -> String? {
        actionCardPrepare.channelCardSnapshot(channelId: channelId)?.rev
    }

    public func mentionsForTesting(messageId: String) -> [(targetType: String, targetId: String, handle: String)] {
        messagesAndThreadsStore.withState { state in
            return state.storedMentions.filter { $0.messageId == messageId }.map { ($0.targetType, $0.targetId, $0.handle) }
        }
    }

    public func addStoredMentionForTesting(
        channelId: String,
        messageId: String,
        targetId: String,
        targetType: String = "user",
        handle: String = "peer",
        terminalCode: String? = nil
    ) {
        messagesAndThreadsStore.withState { state in
            state.storedMentions.append(StoredMention(
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
        }
    }

    @discardableResult
    public func setAnnouncementAudienceForTesting(id: String, serverIds: [String]) {
        notificationsStore.storage.withLock { owned in
            if let index = owned.announcements.firstIndex(where: { $0.id == id }) {
                owned.announcements[index].audienceServerIds = serverIds
            }
        }
    }
}
