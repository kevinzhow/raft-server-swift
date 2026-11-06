@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    @discardableResult
    public func addTaskWithDescriptionForTesting(channelId: String, title: String, description: String) -> String {
        return tasksAndRemindersStore.mutex.withLock { owned in
            let taskNumber = owned.taskRecords.filter { $0.channelId == channelId }.count + 1
            let id = UUID().uuidString.lowercased()
            owned.taskRecords.append(TaskRecord(
                id: id, channelId: channelId, title: title, description: description,
                status: "todo", taskNumber: taskNumber, messageId: UUID().uuidString.lowercased(),
                createdAt: Date()
            ))
            return id
        }
    }

    public func lastTaskServerWarningForTesting() -> String? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.lastTaskServerWarning
        }
    }
}
