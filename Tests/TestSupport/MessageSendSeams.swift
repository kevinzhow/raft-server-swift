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
        lock.lock()
        var channel = PostableChannel(serverId: serverId, memberIds: Set(humanIds), kind: "channel")
        channel.name = name
        for agentId in agentIds { channel.memberIds.insert(agentId) }
        postableChannels[channelId] = channel
        lock.unlock()
        for humanId in humanIds { oauth.addChannelHuman(channelId: channelId, userId: humanId) }
        for agentId in agentIds { oauth.addChannelAgent(channelId: channelId, agentId: agentId) }
    }

    public func softDeletePostableChannelForTesting(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.deletedAt = Date()
        lock.unlock()
    }

    public func removeThreadFollowForTesting(serverId: String, userId: String, threadChannelId: String) {
        lock.lock()
        let key = "\(serverId)\n\(userId)\n\(threadChannelId)"
        threadFollows.removeValue(forKey: key)
        threadUnfollows.removeValue(forKey: key)
        threadFollowStarts.removeValue(forKey: key)
        lock.unlock()
    }

    public func followThreadForTesting(serverId: String, userId: String, threadChannelId: String, parentMessageId: String) {
        lock.lock()
        threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] = (serverId, userId, threadChannelId, parentMessageId)
        lock.unlock()
    }

    public func addTaskForTesting(
        channelId: String,
        title: String,
        messageId: String,
        assigneeType: String?,
        assigneeId: String?
    ) {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        taskRecords.append(TaskRecord(
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
        lock.unlock()
    }
}
