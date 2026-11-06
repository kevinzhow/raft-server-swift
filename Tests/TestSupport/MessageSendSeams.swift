import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func createMigrationReceiptDmForTesting(agentId: String, supportRef: String) -> String? {
        guard let serverId = oauth.agentRuntimeInfo(id: agentId)?.serverId else { return nil }
        return messageSend.createMigrationReceiptDm(
            agentId: agentId,
            serverId: serverId,
            supportRef: supportRef
        )
    }

    public func seedPostableChannelForTesting(
        serverId: String, channelId: String, name: String,
        humanIds: [String], agentIds: [String]
    ) {
        serversAndChannelsStore.mutex.withLock { state in
            var channel = PostableChannel(serverId: serverId, memberIds: Set(humanIds), kind: "channel")
            channel.name = name
            for agentId in agentIds { channel.memberIds.insert(agentId) }
            state.postableChannels[channelId] = channel
        }
        for humanId in humanIds { oauth.addChannelHuman(channelId: channelId, userId: humanId) }
        for agentId in agentIds { oauth.addChannelAgent(channelId: channelId, agentId: agentId) }
    }

    public func softDeletePostableChannelForTesting(channelId: String) {
        serversAndChannelsStore.mutex.withLock { state in
            state.postableChannels[channelId]?.deletedAt = Date()
        }
    }

    public func removeThreadFollowForTesting(serverId: String, userId: String, threadChannelId: String) {
        messagesAndThreadsStore.withState { state in
            let key = "\(serverId)\n\(userId)\n\(threadChannelId)"
            state.threadFollows.removeValue(forKey: key)
            state.threadUnfollows.removeValue(forKey: key)
            state.threadFollowStarts.removeValue(forKey: key)
        }
    }

    public func followThreadForTesting(serverId: String, userId: String, threadChannelId: String, parentMessageId: String) {
        messagesAndThreadsStore.withState { state in
            state.threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] = (serverId, userId, threadChannelId, parentMessageId)
        }
    }

    public func addTaskForTesting(
        channelId: String,
        title: String,
        messageId: String,
        assigneeType: String?,
        assigneeId: String?
    ) {
        tasksAndRemindersStore.mutex.withLock { owned in
            let taskNumber = owned.taskRecords.filter { $0.channelId == channelId }.count + 1
            owned.taskRecords.append(TaskRecord(
                id: UUID().uuidString.lowercased(),
                channelId: channelId,
                title: title,
                description: nil,
                status: "in_progress",
                taskNumber: taskNumber,
                messageId: messageId,
                createdAt: Date(),
                assigneeId: assigneeId,
                assigneeType: assigneeType
            ))
        }
    }
}
