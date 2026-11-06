import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func addBackfilledTaskForTesting(channelId: String, title: String, taskNumber: Int, messageId: String) -> String {
        let id = UUID().uuidString.lowercased()
        tasksAndRemindersStore.mutex.withLock { state in
            state.taskRecords.append(TaskRecord(id: id, channelId: channelId, title: title, description: nil,
                status: "todo", taskNumber: taskNumber, messageId: messageId, createdAt: Date()))
        }
        messagesAndThreadsStore.withState { state in
            if let index = state.humanMessageRows.firstIndex(where: { $0.id == messageId }) {
                state.humanMessageRows[index].taskStatus = "todo"
                state.humanMessageRows[index].taskNumber = taskNumber
            }
        }
        return id
    }

    public func mentionNotifiedActionForTesting(id: String) -> String? {
        messagesAndThreadsStore.withState { state in
            return state.storedMentions.first { $0.id == id }?.notifiedAction
        }
    }

    public func messageAttachmentIdsForTesting(messageId: String) -> [String] {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows.first { $0.id == messageId }?.attachmentIds ?? []
        }
    }

    public func setMessageAttachmentIdsForTesting(messageId: String, attachmentIds: [String]) {
        messagesAndThreadsStore.withState { state in
            if let index = state.humanMessageRows.firstIndex(where: { $0.id == messageId }) {
                state.humanMessageRows[index].attachmentIds = attachmentIds
            }
        }
    }

    public func amendTaskForTesting(taskId: String, title: String, description: String?, amendedByName: String = "user") {
        tasksAndRemindersStore.mutex.withLock { owned in
            if let index = owned.taskRecords.firstIndex(where: { $0.id == taskId }) {
                owned.taskRecords[index].title = title
                if let description { owned.taskRecords[index].description = description }
                owned.taskRecords[index].revision += 1
                owned.taskRecords[index].amendedAt = Date()
                owned.taskRecords[index].amendedByType = "user"
                owned.taskRecords[index].amendedByName = amendedByName
                owned.taskRecords[index].superseded = true
            }
        }
    }

    public func taskNumberForTaskIdForTesting(taskId: String) -> Int? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.first { $0.id == taskId }?.taskNumber
        }
    }

    public func messageChannelIdForTesting(messageId: String) -> String? {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows.first { $0.id == messageId }?.channelId
        }
    }

    public func messageSeqForTesting(messageId: String) -> Int? {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows.first { $0.id == messageId }?.seq
        }
    }

    public func messageCreatedAtForTesting(messageId: String) -> Date? {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows.first { $0.id == messageId }?.createdAt
        }
    }

    public func setMessageCreatedAtForTesting(messageId: String, at date: Date) {
        messagesAndThreadsStore.withState { state in
            if let index = state.humanMessageRows.firstIndex(where: { $0.id == messageId }) {
                state.humanMessageRows[index].createdAt = date
            }
        }
    }

    public func messageCountForTesting(channelId: String) -> Int {
        messagesAndThreadsStore.withState { state in
            return state.humanMessageRows.filter { $0.channelId == channelId }.count
        }
    }

    public func removeMessageForTesting(messageId: String) {
        messagesAndThreadsStore.withState { state in
            state.humanMessageRows.removeAll { $0.id == messageId }
            for key in state.attachmentCommentRecords.keys {
                state.attachmentCommentRecords[key]?.removeAll { $0.id == messageId }
            }
        }
    }

    public func addOrphanTaskForTesting(channelId: String, title: String, taskNumber: Int) -> String {
        return tasksAndRemindersStore.mutex.withLock { owned in
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
            owned.taskRecords.append(record)
            return id
        }
    }

    public func assignTaskForTesting(taskId: String, assigneeId: String?) {
        tasksAndRemindersStore.mutex.withLock { owned in
            if let index = owned.taskRecords.firstIndex(where: { $0.id == taskId }) {
                owned.taskRecords[index].assigneeId = assigneeId
                owned.taskRecords[index].assigneeType = assigneeId == nil ? nil : "agent"
                owned.taskRecords[index].claimedAt = nil
            }
        }
    }

    public func taskAssigneeForTesting(taskId: String) -> String? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.first { $0.id == taskId }?.assigneeId
        }
    }

    public func messageTaskShadowForTesting(messageId: String) -> (status: String, number: Int)? {
        messagesAndThreadsStore.withState { state in
            guard let row = state.humanMessageRows.first(where: { $0.id == messageId }),
                  let status = row.taskStatus, let number = row.taskNumber
            else { return nil }
            return (status, number)
        }
    }

    public func setChannelMessageCreatedAtForTesting(id: String, createdAt: Date) {
        messagesAndThreadsStore.withState { state in
            if let index = state.humanMessageRows.firstIndex(where: { $0.id == id }) {
                state.humanMessageRows[index].createdAt = createdAt
            }
        }
    }
}
