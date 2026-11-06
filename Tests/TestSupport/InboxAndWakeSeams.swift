import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func addBackfilledTaskForTesting(channelId: String, title: String, taskNumber: Int, messageId: String) -> String {
        lock.lock()
        let id = UUID().uuidString.lowercased()
        taskRecords.append(TaskRecord(
            id: id,
            channelId: channelId,
            title: title,
            description: nil,
            status: "todo",
            taskNumber: taskNumber,
            messageId: messageId,
            createdAt: Date()
        ))
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].taskStatus = "todo"
            humanMessageRows[index].taskNumber = taskNumber
        }
        lock.unlock()
        return id
    }

    public func mentionNotifiedActionForTesting(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedMentions.first { $0.id == id }?.notifiedAction
    }

    public func messageAttachmentIdsForTesting(messageId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.attachmentIds ?? []
    }

    public func setMessageAttachmentIdsForTesting(messageId: String, attachmentIds: [String]) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].attachmentIds = attachmentIds
        }
        lock.unlock()
    }

    public func amendTaskForTesting(taskId: String, title: String, description: String?, amendedByName: String = "user") {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].title = title
            if let description { taskRecords[index].description = description }
            taskRecords[index].revision += 1
            taskRecords[index].amendedAt = Date()
            taskRecords[index].amendedByType = "user"
            taskRecords[index].amendedByName = amendedByName
            taskRecords[index].superseded = true
        }
        lock.unlock()
    }

    public func taskNumberForTaskIdForTesting(taskId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.taskNumber
    }

    public func messageChannelIdForTesting(messageId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.channelId
    }

    public func messageSeqForTesting(messageId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.seq
    }

    public func messageCreatedAtForTesting(messageId: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.createdAt
    }

    public func setMessageCreatedAtForTesting(messageId: String, at date: Date) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].createdAt = date
        }
        lock.unlock()
    }

    public func messageCountForTesting(channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.filter { $0.channelId == channelId }.count
    }

    public func removeMessageForTesting(messageId: String) {
        lock.lock()
        humanMessageRows.removeAll { $0.id == messageId }
        for key in attachmentCommentRecords.keys {
            attachmentCommentRecords[key]?.removeAll { $0.id == messageId }
        }
        lock.unlock()
    }

    public func addOrphanTaskForTesting(channelId: String, title: String, taskNumber: Int) -> String {
        lock.lock()
        let id = UUID().uuidString.lowercased()
        var record = TaskRecord(
            id: id,
            channelId: channelId,
            title: title,
            description: nil,
            status: "todo",
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: Date()
        )
        record.hasHostMessage = false
        taskRecords.append(record)
        lock.unlock()
        return id
    }

    public func assignTaskForTesting(taskId: String, assigneeId: String?) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].assigneeId = assigneeId
            taskRecords[index].assigneeType = assigneeId == nil ? nil : "agent"
            taskRecords[index].claimedAt = nil
        }
        lock.unlock()
    }

    public func taskAssigneeForTesting(taskId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.assigneeId
    }

    public func messageTaskShadowForTesting(messageId: String) -> (status: String, number: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = humanMessageRows.first(where: { $0.id == messageId }),
              let status = row.taskStatus, let number = row.taskNumber
        else { return nil }
        return (status, number)
    }

    public func setChannelMessageCreatedAtForTesting(id: String, createdAt: Date) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == id }) {
            humanMessageRows[index].createdAt = createdAt
        }
        lock.unlock()
    }
}
