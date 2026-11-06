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

    /// Closes every open task in a deleted channel and records the system
    /// event in one critical section.
    ///
    /// `DELETE /api/channels/:channelId` used to run this while holding the
    /// directory lock; the task rows and their events belong to this store, so
    /// both writes stay in one locked value.
    func closeOrphanTasks(channelId: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        for index in storage.taskRecords.indices where storage.taskRecords[index].channelId == channelId {
            let status = storage.taskRecords[index].status
            guard status != "done", status != "closed", status != "cancelled" else { continue }
            storage.taskRecords[index].status = "closed"
            storage.taskRecords[index].completedAt = now
            storage.taskRecords[index].closedAt = now
            storage.taskRecords[index].revision += 1
            storage.taskEvents.append((taskId: storage.taskRecords[index].id, eventType: "closed", actorType: "system"))
        }
    }

    /// One task row in the `todo` state. The returned id is the row's own id.
    func addTask(channelId: String, title: String, description: String?) -> String {
        lock.lock()
        defer { lock.unlock() }
        let taskNumber = storage.taskRecords.filter { $0.channelId == channelId }.count + 1
        let id = UUID().uuidString.lowercased()
        storage.taskRecords.append(TaskRecord(
            id: id,
            channelId: channelId,
            title: title,
            description: description,
            status: "todo",
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: Date()
        ))
        return id
    }

    /// One task row with caller-supplied timestamps and status. Used by the
    /// snapshot metrics fixtures; the number scan and append are one section.
    func addTaskSnapshot(
        channelId: String,
        title: String,
        status: String,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date?
    ) {
        lock.lock()
        defer { lock.unlock() }
        let taskNumber = storage.taskRecords.filter { $0.channelId == channelId }.count + 1
        storage.taskRecords.append(TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: title,
            description: nil,
            status: status,
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: createdAt,
            completedAt: completedAt,
            updatedAt: updatedAt
        ))
    }

    /// One completed task row with caller-supplied timestamps.
    func addCompletedTask(channelId: String, title: String, createdAt: Date, completedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        let taskNumber = storage.taskRecords.filter { $0.channelId == channelId }.count + 1
        storage.taskRecords.append(TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: title,
            description: nil,
            status: "done",
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: createdAt,
            completedAt: completedAt
        ))
    }
}

// MARK: - Server task reads, amend and reassignment

extension TasksAndRemindersStore {
    /// The rows of one channel, optionally narrowed to one status, in insertion
    /// order. One locked snapshot.
    func tasks(channelId: String, status: String?) -> [TaskRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage.taskRecords.filter {
            $0.channelId == channelId && (status == nil || $0.status == status)
        }
    }

    func task(channelId: String, taskNumber: Int) -> TaskRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.taskRecords.first { $0.channelId == channelId && $0.taskNumber == taskNumber }
    }

    func task(id: String) -> TaskRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.taskRecords.first { $0.id == id }
    }

    // MARK: - Human task routes (managed-MCP assignments)

    /// `DELETE /api/tasks/:taskId`: removes the row by id and returns it. The
    /// legacy handler removed by an index it had read earlier; removing by id
    /// in one section cannot drop a neighbour when rows move in between.
    func removeTask(id: String) -> TaskRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: { $0.id == id }) else { return nil }
        return storage.taskRecords.remove(at: index)
    }

    enum HumanClaimOutcome {
        case notFound
        case channelDeleted
        case claimed(TaskRecord)
    }

    /// `PATCH /api/tasks/:taskId/claim`: the row lookup, the deleted-channel
    /// refusal and the claim write are one critical section.
    func claimForUser(taskId: String, userId: String, channelDeleted: (String) -> Bool, now: Date) -> HumanClaimOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: { $0.id == taskId }) else { return .notFound }
        guard !channelDeleted(storage.taskRecords[index].channelId) else { return .channelDeleted }
        storage.taskRecords[index].assigneeId = userId
        storage.taskRecords[index].assigneeType = "user"
        storage.taskRecords[index].claimedAt = now
        storage.taskRecords[index].revision += 1
        if storage.taskRecords[index].status == "todo" { storage.taskRecords[index].status = "in_progress" }
        return .claimed(storage.taskRecords[index])
    }

    /// `PATCH /api/tasks/:taskId/unclaim`: the assignee clear, the revision
    /// bump and the assignee-change event are one critical section.
    func unclaimForUser(taskId: String, userId: String) -> TaskRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: { $0.id == taskId }) else { return nil }
        let previousAssigneeId = storage.taskRecords[index].assigneeId
        let previousAssigneeType = storage.taskRecords[index].assigneeType
        storage.taskRecords[index].assigneeId = nil
        storage.taskRecords[index].assigneeType = nil
        storage.taskRecords[index].claimedAt = nil
        storage.taskRecords[index].revision += 1
        storage.assigneeChangeEvents.append((
            taskId: taskId, assigneeId: nil, assigneeType: nil,
            previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType,
            actorType: "user", actorId: userId
        ))
        return storage.taskRecords[index]
    }

    enum HumanStatusOutcome {
        case notFound
        case channelDeletedTerminalOnly
        case onlyAssigneeCanReturnToTodo
        case updated(TaskRecord)
    }

    /// `PATCH /api/tasks/:taskId/status`: the refusals and the status write
    /// (with its completion, close and claim stamps) are one critical section.
    func applyHumanStatus(
        taskId: String,
        status: String,
        userId: String,
        channelDeleted: (String) -> Bool,
        now: Date
    ) -> HumanStatusOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: { $0.id == taskId }) else { return .notFound }
        let current = storage.taskRecords[index]
        if channelDeleted(current.channelId), !["done", "closed", "cancelled"].contains(status) {
            return .channelDeletedTerminalOnly
        }
        if status == "todo", current.status == "in_progress", current.assigneeId != userId {
            return .onlyAssigneeCanReturnToTodo
        }
        storage.taskRecords[index].status = status
        if status == "done", storage.taskRecords[index].completedAt == nil {
            storage.taskRecords[index].completedAt = now
        }
        if status == "closed" || status == "cancelled" {
            storage.taskRecords[index].closedAt = now
        }
        if status == "in_progress", storage.taskRecords[index].claimedAt == nil {
            storage.taskRecords[index].claimedAt = now
        }
        if status == "todo" {
            storage.taskRecords[index].claimedAt = nil
        }
        storage.taskRecords[index].revision += 1
        return .updated(storage.taskRecords[index])
    }

    /// `POST /api/tasks/convert-message`: one `Converted message` task whose
    /// host message is the converted one. The task-number scan, the append and
    /// the message link are one critical section.
    func appendConvertedMessageTask(channelId: String, messageId: String, creatorId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID().uuidString.lowercased()
        storage.taskRecords.append(TaskRecord(
            id: id,
            channelId: channelId,
            title: "Converted message",
            description: nil,
            status: "todo",
            taskNumber: storage.taskRecords.filter { $0.channelId == channelId }.count + 1,
            messageId: messageId,
            createdAt: Date(),
            creatorId: creatorId
        ))
        return id
    }

    /// `POST /internal/agent-api/tasks/amend`: the row lookup, the title and
    /// description write, the revision bump and the amend markers are one
    /// critical section. `nil` means the task does not exist.
    func amendTask(
        channelId: String,
        taskNumber: Int,
        title: String,
        description: String?,
        amendedByName: String,
        now: Date
    ) -> TaskRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: {
            $0.channelId == channelId && $0.taskNumber == taskNumber
        }) else { return nil }
        storage.taskRecords[index].title = title
        if let description { storage.taskRecords[index].description = description }
        storage.taskRecords[index].revision += 1
        storage.taskRecords[index].updatedAt = now
        storage.taskRecords[index].amendedAt = now
        storage.taskRecords[index].amendedByType = "agent"
        storage.taskRecords[index].amendedByName = amendedByName
        storage.taskRecords[index].superseded = true
        return storage.taskRecords[index]
    }

    enum ReassignOutcome {
        case notFound
        case done
        case conflict(currentRevision: Int)
        case unchanged(TaskRecord)
        case reassigned(TaskRecord)
    }

    /// `PATCH /api/tasks/:taskId/assignee`: the done check, the expected
    /// revision check, the same-assignee short circuit, the assignee write, the
    /// revision bump and the assignee-change event are one critical section, so
    /// two concurrent requests cannot both accept the same expected revision.
    func reassign(
        taskId: String,
        assigneeId: String?,
        assigneeType: String?,
        expectedRevision: Int?,
        actorId: String
    ) -> ReassignOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.taskRecords.firstIndex(where: { $0.id == taskId }) else {
            return .notFound
        }
        guard storage.taskRecords[index].status != "done" else { return .done }
        let currentRevision = storage.taskRecords[index].revision
        if let expectedRevision, expectedRevision != currentRevision {
            return .conflict(currentRevision: currentRevision)
        }
        if storage.taskRecords[index].assigneeId == assigneeId
            && storage.taskRecords[index].assigneeType == assigneeType {
            return .unchanged(storage.taskRecords[index])
        }
        let previousAssigneeId = storage.taskRecords[index].assigneeId
        let previousAssigneeType = storage.taskRecords[index].assigneeType
        storage.taskRecords[index].assigneeId = assigneeId
        storage.taskRecords[index].assigneeType = assigneeType
        storage.taskRecords[index].claimedAt = nil
        storage.taskRecords[index].revision += 1
        storage.assigneeChangeEvents.append((
            taskId: taskId, assigneeId: assigneeId, assigneeType: assigneeType,
            previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType,
            actorType: "user", actorId: actorId
        ))
        return .reassigned(storage.taskRecords[index])
    }
}
