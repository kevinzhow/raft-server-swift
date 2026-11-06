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

    // MARK: - Agent task claim / status surface

    /// The rows one channel's agent task list publishes, in ledger order.
    func taskRows(channelId: String) -> [TaskRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage.taskRecords.filter { $0.channelId == channelId }
    }

    /// One claim pass over the task ledger.
    ///
    /// The lookup, the claimability policy and every mutation run in a single
    /// locked critical section. The legacy handler iterated a directory-locked
    /// `taskRecords` array; splitting the read and the write here would let two
    /// concurrent claimers both observe an unclaimed row.
    enum TaskClaimOutcome: Sendable, Equatable {
        case taskNotFound(taskNumber: Int)
        case taskUnavailable(taskNumber: Int)
        case alreadyClaimedByYou(taskNumber: Int)
        case alreadyClaimed(taskNumber: Int)
        case claimed(taskNumber: Int, messageId: String)
        case messageNotFound(prefix: String)
        case messageAlreadyClaimedByYou(messageId: String, taskNumber: Int)
        case messageAlreadyClaimed(messageId: String, taskNumber: Int)
        case claimedMessage(messageId: String, taskNumber: Int)
    }

    func claimTasks(
        channelId: String,
        agentId: String,
        taskNumbers: [Int],
        messageIds: [String],
        now: Date
    ) -> [TaskClaimOutcome] {
        lock.lock()
        defer { lock.unlock() }
        var results: [TaskClaimOutcome] = []
        for number in taskNumbers {
            guard let index = storage.taskRecords.firstIndex(where: {
                $0.channelId == channelId && $0.taskNumber == number
            }) else {
                results.append(.taskNotFound(taskNumber: number))
                continue
            }
            if !storage.taskRecords[index].hasHostMessage {
                results.append(.taskUnavailable(taskNumber: number))
                continue
            }
            if storage.taskRecords[index].assigneeId == agentId {
                results.append(.alreadyClaimedByYou(taskNumber: number))
                continue
            }
            if let assignee = storage.taskRecords[index].assigneeId, assignee != agentId {
                results.append(.alreadyClaimed(taskNumber: number))
                continue
            }
            storage.taskRecords[index].assigneeId = agentId
            storage.taskRecords[index].assigneeType = "agent"
            storage.taskRecords[index].claimedAt = now
            if storage.taskRecords[index].status == "todo" {
                storage.taskRecords[index].status = "in_progress"
            }
            storage.taskRecords[index].revision += 1
            results.append(.claimed(
                taskNumber: storage.taskRecords[index].taskNumber,
                messageId: storage.taskRecords[index].messageId
            ))
        }
        for prefix in messageIds {
            guard let index = storage.taskRecords.firstIndex(where: {
                $0.channelId == channelId && $0.messageId.hasPrefix(prefix)
            }) else {
                results.append(.messageNotFound(prefix: prefix))
                continue
            }
            let task = storage.taskRecords[index]
            if task.assigneeId == agentId {
                results.append(.messageAlreadyClaimedByYou(
                    messageId: task.messageId,
                    taskNumber: task.taskNumber
                ))
                continue
            }
            if let assignee = task.assigneeId, assignee != agentId {
                results.append(.messageAlreadyClaimed(
                    messageId: task.messageId,
                    taskNumber: task.taskNumber
                ))
                continue
            }
            storage.taskRecords[index].assigneeId = agentId
            storage.taskRecords[index].assigneeType = "agent"
            storage.taskRecords[index].claimedAt = now
            if storage.taskRecords[index].status == "todo" {
                storage.taskRecords[index].status = "in_progress"
            }
            storage.taskRecords[index].revision += 1
            results.append(.claimedMessage(
                messageId: storage.taskRecords[index].messageId,
                taskNumber: storage.taskRecords[index].taskNumber
            ))
        }
        return results
    }

    /// One status write over the task ledger.
    ///
    /// The transition policy, the resource-receipt gate and the write run in a
    /// single locked critical section, matching the legacy directory-locked
    /// read-modify-write.
    enum TaskStatusUpdateOutcome: Sendable {
        case notFound
        case inProgressToTodoForbidden
        case todoToTerminalForbidden(status: String)
        case resourceReceiptRequired
        case updated(TaskRecord)
    }

    func updateTaskStatus(
        channelId: String,
        taskNumber: Int,
        status: String,
        agentId: String,
        isAdmin: Bool,
        now: Date
    ) -> TaskStatusUpdateOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: {
            $0.channelId == channelId && $0.taskNumber == taskNumber
        }), storage.taskRecords[index].hasHostMessage else {
            return .notFound
        }
        let current = storage.taskRecords[index]
        if !isAdmin {
            if status == "todo", current.status == "in_progress", current.assigneeId != agentId {
                return .inProgressToTodoForbidden
            }
            if current.status == "todo",
               ["done", "closed", "in_review", "cancelled"].contains(status) {
                return .todoToTerminalForbidden(status: status)
            }
        }
        if status == "done", storage.taskRecords[index].requiresResourceReceipt,
           storage.taskRecords[index].resourceReceiptJSON == nil {
            return .resourceReceiptRequired
        }
        storage.taskRecords[index].status = status
        if status == "done" || status == "closed" {
            storage.taskRecords[index].completedAt = now
        }
        if status == "in_progress" {
            storage.taskRecords[index].claimedAt = now
        }
        if status == "todo" {
            storage.taskRecords[index].claimedAt = nil
        }
        storage.taskRecords[index].revision += 1
        return .updated(storage.taskRecords[index])
    }

    /// The task-write freshness gate: one decision-and-write over the hold row.
    ///
    /// The newer-message rows are read from the messages store before this
    /// call, then the hold lookup, the equality clear and the hold write all
    /// happen under this store's lock. The legacy handler did the same under
    /// the directory lock.
    enum TaskWriteHoldDecision: Sendable, Equatable {
        case proceed
        case held(latest: Int)
    }

    func decideTaskWriteHold(
        agentId: String,
        channelId: String,
        seen: Int,
        actionKey: String,
        newerMessages: [StoredHumanMessage]
    ) -> TaskWriteHoldDecision {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(agentId)\n\(channelId)\n\(actionKey)"
        if let held = storage.taskWriteHolds[key], seen == held.seen {
            storage.taskWriteHolds.removeValue(forKey: key)
            return .proceed
        }
        guard !newerMessages.isEmpty else { return .proceed }
        let latest = newerMessages.map(\.seq).max() ?? seen
        storage.taskWriteHolds[key] = (latest, latest)
        return .held(latest: latest)
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
