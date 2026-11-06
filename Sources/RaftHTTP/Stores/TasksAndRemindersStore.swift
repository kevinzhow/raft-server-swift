import Foundation

/// Owns the task, reminder and assignee-change rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class TasksAndRemindersStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
        var reminderRecords: [ReminderRecord] = []
        var reminderEvents: [ReminderEvent] = []
        var taskRecords: [TaskRecord] = []
        var taskWriteHolds: [String: (seen: Int, latest: Int)] = [:]
        var taskEvents: [(taskId: String, eventType: String, actorType: String)] = []
        var lastTaskServerWarning: String? = nil
        var assigneeChangeEvents: [(taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)] = []
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var reminderRecords: [ReminderRecord] {
        get { state.reminderRecords }
        set { state.reminderRecords = newValue }
    }

    var reminderEvents: [ReminderEvent] {
        get { state.reminderEvents }
        set { state.reminderEvents = newValue }
    }

    var taskRecords: [TaskRecord] {
        get { state.taskRecords }
        set { state.taskRecords = newValue }
    }

    var taskWriteHolds: [String: (seen: Int, latest: Int)] {
        get { state.taskWriteHolds }
        set { state.taskWriteHolds = newValue }
    }

    var taskEvents: [(taskId: String, eventType: String, actorType: String)] {
        get { state.taskEvents }
        set { state.taskEvents = newValue }
    }

    var lastTaskServerWarning: String? {
        get { state.lastTaskServerWarning }
        set { state.lastTaskServerWarning = newValue }
    }

    var assigneeChangeEvents: [(taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)] {
        get { state.assigneeChangeEvents }
        set { state.assigneeChangeEvents = newValue }
    }

    // MARK: - Agent task mutations
    //
    // Each method below is one critical section over the rows it reads and
    // rewrites. The retired handlers held the directory lock for the same
    // span; the service asks for the decision and the write in one call.

    enum TaskDeleteOutcome: Sendable, Equatable {
        case notFound
        case forbidden
        case deleted
    }

    /// `POST …/tasks/delete`: find, authorize the creator/admin check and
    /// remove in one lock.
    func deleteTask(channelId: String, taskNumber: Int, agentId: String, isAdmin: Bool) -> TaskDeleteOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: {
            $0.channelId == channelId && $0.taskNumber == taskNumber
        }) else {
            return .notFound
        }
        guard isAdmin || storage.taskRecords[index].creatorId == agentId else {
            return .forbidden
        }
        storage.taskRecords.remove(at: index)
        return .deleted
    }

    enum TaskConvertOutcome {
        case alreadyTask
        case created(TaskRecord)
    }

    /// `POST …/tasks/convert`: the duplicate scan, the next task number and the
    /// append share one critical section.
    func convertMessage(
        channelId: String,
        messageId: String,
        creatorId: String,
        now: Date
    ) -> TaskConvertOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard !storage.taskRecords.contains(where: { $0.messageId == messageId }) else {
            return .alreadyTask
        }
        var record = TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: "Converted message",
            description: nil,
            status: "todo",
            taskNumber: storage.taskRecords.filter { $0.channelId == channelId }.count + 1,
            messageId: messageId,
            createdAt: now
        )
        record.creatorId = creatorId
        storage.taskRecords.append(record)
        return .created(record)
    }

    /// Appends one posted task batch and returns the created rows in order.
    /// The task-number scan and every append run under the same lock.
    func appendTaskBatch(
        channelId: String,
        titles: [String],
        creatorId: String,
        now: Date
    ) -> [TaskRecord] {
        lock.lock()
        defer { lock.unlock() }
        var created: [TaskRecord] = []
        for title in titles {
            let taskNumber = storage.taskRecords.filter { $0.channelId == channelId }.count + 1
            let record = TaskRecord(
                id: UUID().uuidString.lowercased(),
                channelId: channelId,
                title: title,
                description: nil,
                status: "todo",
                taskNumber: taskNumber,
                messageId: UUID().uuidString.lowercased(),
                createdAt: now,
                creatorId: creatorId
            )
            storage.taskRecords.append(record)
            created.append(record)
        }
        return created
    }

    /// Marks the created tasks that declared `creates_resource`.
    func markRequiresResourceReceipt(taskIds: [String], flags: [Bool]) {
        lock.lock()
        defer { lock.unlock() }
        for (offset, id) in taskIds.enumerated() where offset < flags.count && flags[offset] {
            if let index = storage.taskRecords.firstIndex(where: { $0.id == id }) {
                storage.taskRecords[index].requiresResourceReceipt = true
            }
        }
    }

    /// Applies one assignee to a created batch and returns the updated rows.
    func applyAssignment(
        taskIds: [String],
        assigneeId: String,
        assigneeType: String
    ) -> [TaskRecord] {
        lock.lock()
        defer { lock.unlock() }
        var updated: [TaskRecord] = []
        for id in taskIds {
            guard let index = storage.taskRecords.firstIndex(where: { $0.id == id }) else { continue }
            storage.taskRecords[index].assigneeId = assigneeId
            storage.taskRecords[index].assigneeType = assigneeType
            storage.taskRecords[index].revision += 1
            updated.append(storage.taskRecords[index])
        }
        return updated
    }

    enum TaskAssignOutcome {
        case notFound
        case assigned(TaskRecord)
    }

    /// `POST …/tasks/assign`: the row lookup, the assignee write and the
    /// revision bump are one critical section.
    func assignTask(
        channelId: String,
        taskNumber: Int,
        assigneeId: String,
        assigneeType: String
    ) -> TaskAssignOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: {
            $0.channelId == channelId && $0.taskNumber == taskNumber
        }) else {
            return .notFound
        }
        storage.taskRecords[index].assigneeId = assigneeId
        storage.taskRecords[index].assigneeType = assigneeType
        storage.taskRecords[index].claimedAt = nil
        storage.taskRecords[index].revision += 1
        return .assigned(storage.taskRecords[index])
    }

    enum TaskReceiptOutcome {
        case notFound
        case stored(task: TaskRecord, reminder: ReminderRecord)
    }

    /// `POST …/tasks/resource-receipt`: the receipt lookup, the resource flag
    /// check, the row write and the reminder append are one critical section.
    func storeResourceReceipt(
        channelId: String,
        taskNumber: Int,
        receiptJSON: String,
        reminder: ReminderRecord
    ) -> TaskReceiptOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: {
            $0.channelId == channelId && $0.taskNumber == taskNumber
        }), storage.taskRecords[index].requiresResourceReceipt else {
            return .notFound
        }
        storage.taskRecords[index].resourceReceiptJSON = receiptJSON
        storage.taskRecords[index].revision += 1
        storage.reminderRecords.append(reminder)
        return .stored(task: storage.taskRecords[index], reminder: reminder)
    }

    /// The rows for `ids` in the requested order, from one locked snapshot.
    func tasks(ids: [String]) -> [TaskRecord] {
        lock.lock()
        defer { lock.unlock() }
        return ids.compactMap { id in storage.taskRecords.first { $0.id == id } }
    }

    /// Appends one posted task batch and returns the new ids in order.
    ///
    /// The task-number scan, the append and the next number's base all run in a
    /// single locked critical section: the old helper read and rewrote the row
    /// array through the directory's forwarding accessors, so this is the one
    /// mutation a concurrent batch must not interleave with.
    func appendTasks(
        channelId: String,
        titles: [String],
        descriptions: [String?]?,
        creatorId: String?
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var ids: [String] = []
        for (offset, title) in titles.enumerated() {
            let taskNumber = storage.taskRecords.filter { $0.channelId == channelId }.count + 1
            let id = UUID().uuidString.lowercased()
            storage.taskRecords.append(TaskRecord(
                id: id,
                channelId: channelId,
                title: title,
                description: (descriptions?.count ?? 0) > offset ? (descriptions?[offset] ?? nil) : nil,
                status: "todo",
                taskNumber: taskNumber,
                messageId: UUID().uuidString.lowercased(),
                createdAt: Date(),
                creatorId: creatorId
            ))
            ids.append(id)
        }
        return ids
    }
}
