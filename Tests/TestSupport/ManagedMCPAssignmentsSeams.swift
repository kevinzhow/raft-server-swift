@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    @discardableResult
    public func addTaskWithDescriptionForTesting(channelId: String, title: String, description: String) -> String {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        let id = UUID().uuidString.lowercased()
        taskRecords.append(TaskRecord(
            id: id, channelId: channelId, title: title, description: description,
            status: "todo", taskNumber: taskNumber, messageId: UUID().uuidString.lowercased(),
            createdAt: Date()
        ))
        lock.unlock()
        return id
    }

    public func lastTaskServerWarningForTesting() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastTaskServerWarning
    }
}
