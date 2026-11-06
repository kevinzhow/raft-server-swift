import Foundation
@testable import RaftHTTP
import Testing

/// `TasksAndRemindersStore.appendTasks` is one locked read-modify-write: the
/// task-number scan and the append cannot interleave, so concurrent batches
/// allocate every number exactly once.
@Test func concurrentTaskBatchesAllocateEveryTaskNumberOnce() async {
    let accounts = EmailLoginDirectory()
    let channelId = "11111111-1111-4111-8111-111111773001"
    let batches = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
        for _ in 0..<25 {
            group.addTask {
                accounts.taskCatalog.addTasks(channelId: channelId, titles: ["first", "second"])
            }
        }
        var collected: [[String]] = []
        for await ids in group { collected.append(ids) }
        return collected
    }

    let ids = batches.flatMap { $0 }
    #expect(ids.count == 50)
    #expect(Set(ids).count == 50)
    let numbers = accounts.tasksAndRemindersStore.tasks(channelId: channelId, status: nil).map(\.taskNumber)
    #expect(numbers.count == 50)
    #expect(Set(numbers).count == 50)
    #expect(Set(numbers) == Set(1...50))
}
