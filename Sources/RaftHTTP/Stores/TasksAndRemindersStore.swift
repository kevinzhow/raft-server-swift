import Foundation
import Synchronization
import RaftShared

/// Owns the task, reminder and assignee-change rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows in a Mutex-protected State and hands back Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class TasksAndRemindersStore: Sendable {
    /// All mutable rows share one Mutex. Snapshot accessors return values;
    /// transaction methods read and mutate this state in one critical section.
    struct State: Sendable {
        var reminderRecords: [ReminderRecord] = []
        var reminderEvents: [ReminderEvent] = []
        var taskRecords: [TaskRecord] = []
        var taskWriteHolds: [String: (seen: Int, latest: Int)] = [:]
        var taskEvents: [TaskEventRecord] = []
        var lastTaskServerWarning: String? = nil
        var assigneeChangeEvents: [(taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)] = []
    }

    let mutex = TransactionalState(State())

    /// A value snapshot; transaction methods hold the Mutex for their whole decision.
    var state: State {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }

    var reminderRecords: [ReminderRecord] {
        get { mutex.withLock { $0.reminderRecords } }
        set { mutex.withLock { $0.reminderRecords = newValue } }
    }

    var reminderEvents: [ReminderEvent] {
        get { mutex.withLock { $0.reminderEvents } }
        set { mutex.withLock { $0.reminderEvents = newValue } }
    }

    var taskRecords: [TaskRecord] {
        get { mutex.withLock { $0.taskRecords } }
        set { mutex.withLock { $0.taskRecords = newValue } }
    }

    var taskWriteHolds: [String: (seen: Int, latest: Int)] {
        get { mutex.withLock { $0.taskWriteHolds } }
        set { mutex.withLock { $0.taskWriteHolds = newValue } }
    }

    var taskEvents: [TaskEventRecord] {
        get { mutex.withLock { $0.taskEvents } }
        set { mutex.withLock { $0.taskEvents = newValue } }
    }

    var lastTaskServerWarning: String? {
        get { mutex.withLock { $0.lastTaskServerWarning } }
        set { mutex.withLock { $0.lastTaskServerWarning = newValue } }
    }

    var assigneeChangeEvents: [(taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)] {
        get { mutex.withLock { $0.assigneeChangeEvents } }
        set { mutex.withLock { $0.assigneeChangeEvents = newValue } }
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
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: {
                $0.channelId == channelId && $0.taskNumber == taskNumber
            }) else {
                return .notFound
            }
            guard isAdmin || storage.taskRecords[index].creatorId == agentId else {
                return .forbidden
            }
            let removedId = storage.taskRecords[index].id
            storage.taskRecords.remove(at: index)
            storage.taskEvents.removeAll { $0.taskId == removedId }
            storage.assigneeChangeEvents.removeAll { $0.taskId == removedId }
            return .deleted
        }
    }

    enum TaskConvertOutcome: Sendable {
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
        mutex.withLock { storage in
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
            Self.appendTaskEventLocked(state: &storage, taskId: record.id, eventType: "created",
                actorType: "agent", actorId: creatorId,
                payloadJSON: OrderedJSON.object([
                    .init("taskNumber", record.taskNumber),
                    .init("status", record.status),
                    .init("convertedFromMessage", true),
                ]).render(),
                now: now)
            return .created(record)
        }
    }

    /// Canonical creation accepts the already allocated host IDs; task facts do
    /// not write a second task representation into message rows.
    func appendCanonicalTasks(
        channelId: String, drafts: [TaskDraft], hostMessageIds: [String],
        creatorId: String, legacyMessageMaxNumber: Int, now: Date
    ) -> [TaskRecord] {
        precondition(drafts.count == hostMessageIds.count)
        return mutex.withLock { storage in
            var number = max(legacyMessageMaxNumber, storage.taskRecords.filter { $0.channelId == channelId }.map(\.taskNumber).max() ?? 0)
            var created: [TaskRecord] = []
            for (draft, hostId) in zip(drafts, hostMessageIds) {
                number += 1
                let task = TaskRecord(
                    id: UUID().uuidString.lowercased(), channelId: channelId,
                    title: draft.title ?? "", description: draft.description, status: "todo",
                    taskNumber: number, messageId: hostId, createdAt: now, updatedAt: now, creatorId: creatorId)
                storage.taskRecords.append(task)
                Self.appendTaskEventLocked(state: &storage, taskId: task.id, eventType: "created",
                    actorType: "user", actorId: creatorId,
                    payloadJSON: OrderedJSON.object([
                        .init("taskNumber", task.taskNumber),
                        .init("status", task.status),
                        .init("requiresResourceReceipt", task.requiresResourceReceipt),
                    ]).render(),
                    now: now)
                created.append(task)
            }
            return created
        }
    }

    /// Appends one posted task batch and returns the created rows in order.
    /// The task-number scan, every append and the created event run under the
    /// same lock. `resourceReceiptFlags` is the request's `creates_resource`
    /// list; the created payload carries the stored flag like upstream
    /// `createTasks`.
    func appendTaskBatch(
        channelId: String,
        titles: [String],
        creatorId: String,
        resourceReceiptFlags: [Bool] = [],
        now: Date
    ) -> [TaskRecord] {
        mutex.withLock { storage in
            var created: [TaskRecord] = []
            for (offset, title) in titles.enumerated() {
                let taskNumber = storage.taskRecords.filter { $0.channelId == channelId }.count + 1
                var record = TaskRecord(
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
                if offset < resourceReceiptFlags.count { record.requiresResourceReceipt = resourceReceiptFlags[offset] }
                storage.taskRecords.append(record)
                Self.appendTaskEventLocked(state: &storage, taskId: record.id, eventType: "created",
                    actorType: "agent", actorId: creatorId,
                    payloadJSON: OrderedJSON.object([
                        .init("taskNumber", record.taskNumber),
                        .init("status", record.status),
                        .init("requiresResourceReceipt", record.requiresResourceReceipt),
                    ]).render(),
                    now: now)
                created.append(record)
            }
            return created
        }
    }

    /// Marks the created tasks that declared `creates_resource`.
    func markRequiresResourceReceipt(taskIds: [String], flags: [Bool]) {
        mutex.withLock { storage in
            for (offset, id) in taskIds.enumerated() where offset < flags.count && flags[offset] {
                if let index = storage.taskRecords.firstIndex(where: { $0.id == id }) {
                    storage.taskRecords[index].requiresResourceReceipt = true
                }
            }
        }
    }

    /// Applies one assignee to a created batch and returns the updated rows.
    /// Upstream's assigned create records one `assignee_changed` event per row,
    /// attributed to the creating actor.
    func applyAssignment(
        taskIds: [String],
        assigneeId: String,
        assigneeType: String,
        actorId: String,
        now: Date = Date()
    ) -> [TaskRecord] {
        mutex.withLock { storage in
            var updated: [TaskRecord] = []
            for id in taskIds {
                guard let index = storage.taskRecords.firstIndex(where: { $0.id == id }) else { continue }
                storage.taskRecords[index].assigneeId = assigneeId
                storage.taskRecords[index].assigneeType = assigneeType
                storage.taskRecords[index].revision += 1
                Self.appendTaskEventLocked(state: &storage, taskId: id, eventType: "assignee_changed",
                    actorType: "agent", actorId: actorId,
                    payloadJSON: OrderedJSON.object([
                        .init("assigneeType", assigneeType),
                        .init("assigneeId", assigneeId),
                    ]).render(),
                    now: now)
                updated.append(storage.taskRecords[index])
            }
            return updated
        }
    }

    enum TaskAssignOutcome: Sendable {
        case notFound
        case assigned(TaskRecord)
    }

    /// `POST …/tasks/assign`: the row lookup, the assignee write and the
    /// revision bump are one critical section.
    func assignTask(
        channelId: String,
        taskNumber: Int,
        assigneeId: String,
        assigneeType: String,
        actorId: String,
        now: Date = Date()
    ) -> TaskAssignOutcome {
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: {
                $0.channelId == channelId && $0.taskNumber == taskNumber
            }) else {
                return .notFound
            }
            let previousAssigneeId = storage.taskRecords[index].assigneeId
            let previousAssigneeType = storage.taskRecords[index].assigneeType
            storage.taskRecords[index].assigneeId = assigneeId
            storage.taskRecords[index].assigneeType = assigneeType
            storage.taskRecords[index].claimedAt = nil
            storage.taskRecords[index].revision += 1
            Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                eventType: "assignee_changed", actorType: "agent", actorId: actorId,
                payloadJSON: OrderedJSON.object([
                    .init("assigneeType", assigneeType),
                    .init("assigneeId", assigneeId),
                    .init("previousAssigneeType", optional: previousAssigneeType),
                    .init("previousAssigneeId", optional: previousAssigneeId),
                ]).render(),
                now: now)
            return .assigned(storage.taskRecords[index])
        }
    }

    enum TaskReceiptOutcome: Sendable {
        case notFound
        case stored(task: TaskRecord, reminder: ReminderRecord)
    }

    /// `POST …/tasks/resource-receipt`: the receipt lookup, the resource flag
    /// check, the row write and the reminder append are one critical section.
    func storeResourceReceipt(
        channelId: String,
        taskNumber: Int,
        receiptJSON: String,
        reminder: ReminderRecord,
        actorId: String,
        now: Date = Date()
    ) -> TaskReceiptOutcome {
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: {
                $0.channelId == channelId && $0.taskNumber == taskNumber
            }), storage.taskRecords[index].requiresResourceReceipt else {
                return .notFound
            }
            storage.taskRecords[index].resourceReceiptJSON = receiptJSON
            storage.taskRecords[index].revision += 1
            storage.reminderRecords.append(reminder)
            // Upstream resolves the receipt's teardown owner to a live agent
            // and stores that id. This port retains the raw receipt only, so the
            // unresolved owner is published as null instead of an invented id.
            Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                eventType: "resource_receipt_recorded", actorType: "agent", actorId: actorId,
                payloadJSON: OrderedJSON.object([
                    .init("receipt", .raw(receiptJSON)),
                    .init("teardownOwnerAgentId", .null),
                    .init("expiryFollowupId", reminder.id),
                ]).render(),
                now: now)
            return .stored(task: storage.taskRecords[index], reminder: reminder)
        }
    }

    /// The rows for `ids` in the requested order, from one locked snapshot.
    func tasks(ids: [String]) -> [TaskRecord] {
        mutex.withLock { storage in
            return ids.compactMap { id in storage.taskRecords.first { $0.id == id } }
        }
    }

    // MARK: - Agent task claim / status surface

    /// The rows one channel's agent task list publishes, in ledger order.
    func taskRows(channelId: String) -> [TaskRecord] {
        mutex.withLock { storage in
            return storage.taskRecords.filter { $0.channelId == channelId }
        }
    }

    /// The row facts the authoritative claim check observed. `reason` is the
    /// pinned `getTaskClaimConflictReason` prose; the assignee fields are the
    /// same observation, so the service can project `claim_conflict` without a
    /// second read that might describe a different row.
    struct TaskClaimRejectionFacts: Sendable, Equatable {
        var reason: String
        var assigneeType: String?
        var assigneeId: String?
        var status: String
        var claimedAt: Date?
    }

    enum TaskClaimOutcome: Sendable, Equatable {
        case taskNotFound(taskNumber: Int)
        case taskUnavailable(taskNumber: Int)
        case alreadyClaimedByYou(taskNumber: Int)
        /// Any other rejection: a different assignee, a closed task or a done
        /// unassigned task. Carries the writer's own observed facts.
        case rejected(taskNumber: Int?, messageId: String?, facts: TaskClaimRejectionFacts)
        case claimed(taskNumber: Int, messageId: String)
        case messageNotFound(prefix: String)
        case messageAlreadyClaimedByYou(messageId: String, taskNumber: Int)
        case claimedMessage(messageId: String, taskNumber: Int)
    }

    /// Upstream `getTaskClaimConflictReason`, evaluated on the row in the same
    /// critical section as the write. `nil` means the claim may proceed.
    private static func claimRejection(task: TaskRecord, agentId: String) -> TaskClaimRejectionFacts? {
        let facts = TaskClaimRejectionFacts(
            reason: "", assigneeType: task.assigneeType, assigneeId: task.assigneeId,
            status: task.status, claimedAt: task.claimedAt
        )
        func rejecting(_ reason: String) -> TaskClaimRejectionFacts {
            var copy = facts
            copy.reason = reason
            return copy
        }
        if task.status == "closed" { return rejecting("task is closed; reopen it before claiming") }
        if let assigneeId = task.assigneeId {
            let assignedToRequester = task.assigneeType == "agent" && assigneeId == agentId
            // Assignment and work-start are distinct: a todo task preassigned
            // to this agent, not yet claimed, may be claimed once to start it.
            if assignedToRequester, task.status == "todo", task.claimedAt == nil { return nil }
            return rejecting(assignedToRequester ? "already claimed by you" : "already assigned")
        }
        if task.status == "done" { return rejecting("task is done") }
        return nil
    }

    /// One claim pass over the task ledger.
    ///
    /// The lookup, the claimability policy and every mutation run in a single
    /// locked critical section. The legacy handler iterated a directory-locked
    /// `taskRecords` array; splitting the read and the write here would let two
    /// concurrent claimers both observe an unclaimed row.
    func claimTasks(
        channelId: String,
        agentId: String,
        taskNumbers: [Int],
        messageIds: [String],
        now: Date
    ) -> [TaskClaimOutcome] {
        mutex.withLock { storage in
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
                if let rejection = Self.claimRejection(task: storage.taskRecords[index], agentId: agentId) {
                    if rejection.reason == "already claimed by you" {
                        results.append(.alreadyClaimedByYou(taskNumber: number))
                    } else {
                        results.append(.rejected(taskNumber: number, messageId: nil, facts: rejection))
                    }
                    continue
                }
                let previousStatus = storage.taskRecords[index].status
                storage.taskRecords[index].assigneeId = agentId
                storage.taskRecords[index].assigneeType = "agent"
                storage.taskRecords[index].claimedAt = now
                if storage.taskRecords[index].status == "todo" {
                    storage.taskRecords[index].status = "in_progress"
                }
                storage.taskRecords[index].revision += 1
                Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                    eventType: "assignee_changed", actorType: "agent", actorId: agentId,
                    payloadJSON: OrderedJSON.object([
                        .init("assigneeType", "agent"),
                        .init("assigneeId", agentId),
                    ]).render(),
                    now: now)
                if previousStatus != storage.taskRecords[index].status {
                    Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                        eventType: "status_changed", actorType: "agent", actorId: agentId,
                        payloadJSON: OrderedJSON.object([
                            .init("from", previousStatus),
                            .init("to", storage.taskRecords[index].status),
                            .init("forced", false),
                        ]).render(),
                        now: now)
                }
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
                if let rejection = Self.claimRejection(task: task, agentId: agentId) {
                    if rejection.reason == "already claimed by you" {
                        results.append(.messageAlreadyClaimedByYou(
                            messageId: task.messageId,
                            taskNumber: task.taskNumber
                        ))
                    } else {
                        results.append(.rejected(
                            taskNumber: task.taskNumber,
                            messageId: task.messageId,
                            facts: rejection
                        ))
                    }
                    continue
                }
                let previousStatus = storage.taskRecords[index].status
                storage.taskRecords[index].assigneeId = agentId
                storage.taskRecords[index].assigneeType = "agent"
                storage.taskRecords[index].claimedAt = now
                if storage.taskRecords[index].status == "todo" {
                    storage.taskRecords[index].status = "in_progress"
                }
                storage.taskRecords[index].revision += 1
                Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                    eventType: "assignee_changed", actorType: "agent", actorId: agentId,
                    payloadJSON: OrderedJSON.object([
                        .init("assigneeType", "agent"),
                        .init("assigneeId", agentId),
                    ]).render(),
                    now: now)
                if previousStatus != storage.taskRecords[index].status {
                    Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                        eventType: "status_changed", actorType: "agent", actorId: agentId,
                        payloadJSON: OrderedJSON.object([
                            .init("from", previousStatus),
                            .init("to", storage.taskRecords[index].status),
                            .init("forced", false),
                        ]).render(),
                        now: now)
                }
                results.append(.claimedMessage(
                    messageId: storage.taskRecords[index].messageId,
                    taskNumber: storage.taskRecords[index].taskNumber
                ))
            }
            return results
        }
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
        mutex.withLock { storage in
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
            let previousStatus = storage.taskRecords[index].status
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
            Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                eventType: Self.statusEventType(from: previousStatus, to: status),
                actorType: "agent", actorId: agentId,
                payloadJSON: Self.statusEventPayload(from: previousStatus, to: status, forced: false),
                now: now)
            return .updated(storage.taskRecords[index])
        }
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
        mutex.withLock { storage in
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
        mutex.withLock { storage in
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

    /// Closes every open task in a deleted channel and records the system
    /// event in one critical section.
    ///
    /// `DELETE /api/channels/:channelId` used to run this while holding the
    /// directory lock; the task rows and their events belong to this store, so
    /// both writes stay in one locked value.
    func closeOrphanTasks(channelId: String, now: Date) {
        mutex.withLock { storage in
            for index in storage.taskRecords.indices where storage.taskRecords[index].channelId == channelId {
                let status = storage.taskRecords[index].status
                guard status != "done", status != "closed", status != "cancelled" else { continue }
                storage.taskRecords[index].status = "closed"
                storage.taskRecords[index].completedAt = now
                storage.taskRecords[index].closedAt = now
                storage.taskRecords[index].revision += 1
                let taskId = storage.taskRecords[index].id
                Self.appendTaskEventLocked(state: &storage, taskId: taskId, eventType: "closed",
                    actorType: "system", actorId: nil,
                    payloadJSON: OrderedJSON.object([
                        .init("status", "closed"),
                        .init("reason", "channel_deleted"),
                        .init("channelId", channelId),
                    ]).render(),
                    now: now)
            }
        }
    }

    /// One task row in the `todo` state. The returned id is the row's own id.
    func addTask(channelId: String, title: String, description: String?) -> String {
        mutex.withLock { storage in
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
        mutex.withLock { storage in
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
    }

    /// One completed task row with caller-supplied timestamps.
    func addCompletedTask(channelId: String, title: String, createdAt: Date, completedAt: Date) {
        mutex.withLock { storage in
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
}

// MARK: - App reminder ledger (ManagedMCPAgentCatalogService)

/// Result of one version-bound reminder write. The store decides; the service
/// maps a refusal to its published status and body.
enum ReminderMutationOutcome: Sendable {
    case ok(version: Int)
    case notFound
    case conflict(currentVersion: Int)
    case invalid(String)
}

/// The columns the reminder summary projections print.
struct ReminderRow: Sendable, Equatable {
    var id: String
    var status: String
    var version: Int
    var title: String
    var fireAt: Date
}

extension TasksAndRemindersStore {
    /// A plain scheduled reminder without an event row (the legacy list seed).
    func addReminder(serverId: String, ownerAgentId: String, title: String, fireAt: Date) {
        mutex.withLock { storage in
            storage.reminderRecords.append(ReminderRecord(
                id: UUID().uuidString.lowercased(),
                serverId: serverId,
                ownerAgentId: ownerAgentId,
                title: title,
                fireAt: fireAt
            ))
        }
    }

    /// Appends one scheduled reminder and its `scheduled` event in one critical
    /// section and returns the new id.
    func createReminder(
        serverId: String, ownerAgentId: String, title: String, fireAt: Date,
        notes: String? = nil, recurrenceJSON: String? = nil,
        channelId: String? = nil, threadId: String? = nil,
        actorType: String = "agent", actorId: String? = nil
    ) -> String {
        mutex.withLock { storage in
            let reminder = ReminderRecord(
                id: UUID().uuidString.lowercased(), serverId: serverId, ownerAgentId: ownerAgentId,
                title: title, fireAt: fireAt, status: "scheduled", version: 1, notes: notes,
                recurrenceJSON: recurrenceJSON, channelId: channelId, threadId: threadId,
                createdAt: Date(), updatedAt: Date()
            )
            let stamped = Self.appendReminderEventLocked(state: &storage, reminder, type: "scheduled", actorType: actorType, actorId: actorId)
            storage.reminderRecords.append(stamped)
            return reminder.id
        }
    }

    func reminderRow(id: String) -> ReminderRow? {
        mutex.withLock { storage in
            guard let reminder = storage.reminderRecords.first(where: { $0.id == id }) else { return nil }
            return ReminderRow(
                id: reminder.id, status: reminder.status, version: reminder.version,
                title: reminder.title, fireAt: reminder.fireAt
            )
        }
    }

    func ownerAgentId(reminderId: String) -> String? {
        mutex.withLock { storage in
            return storage.reminderRecords.first(where: { $0.id == reminderId })?.ownerAgentId
        }
    }

    func reminders(ownedBy agentIds: Set<String>) -> [ReminderRecord] {
        mutex.withLock { storage in
            return storage.reminderRecords.filter { agentIds.contains($0.ownerAgentId) }
        }
    }

    /// Reminders of one owner on one server; `statuses == nil` lists every status.
    func reminders(serverId: String, ownerAgentId: String, statuses: Set<String>?) -> [ReminderRow] {
        mutex.withLock { storage in
            return storage.reminderRecords.filter { reminder in
                reminder.serverId == serverId && reminder.ownerAgentId == ownerAgentId
                    && (statuses == nil || statuses!.contains(reminder.status))
            }.map {
                ReminderRow(id: $0.id, status: $0.status, version: $0.version, title: $0.title, fireAt: $0.fireAt)
            }
        }
    }

    /// Event types and versions, newest first.
    func reminderEventLog(reminderId: String) -> [(eventType: String, version: Int)] {
        mutex.withLock { storage in
            return storage.reminderEvents.filter { $0.reminderId == reminderId }
                .sorted { $0.createdAt > $1.createdAt }
                .map { ($0.type, $0.version) }
        }
    }

    func cancelReminder(reminderId: String, ownerAgentId: String, expectedVersion: Int?) -> ReminderMutationOutcome {
        mutateReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "canceled") { reminder in
            reminder.status = "canceled"
        }
    }

    func snoozeReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int?, fireAt: Date
    ) -> ReminderMutationOutcome {
        mutateReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "snoozed") { reminder in
            reminder.status = "scheduled"
            reminder.fireAt = fireAt
        }
    }

    func updateReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int?,
        title: String?, fireAt: Date?, notes: String?
    ) -> ReminderMutationOutcome {
        guard title != nil || fireAt != nil || notes != nil else {
            return .invalid("no update fields")
        }
        return mutateReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "updated") { reminder in
            if let title { reminder.title = title }
            if let fireAt { reminder.fireAt = fireAt }
            if let notes { reminder.notes = notes }
        }
    }

    /// The version-bound write: owner match, status refusals, version compare,
    /// mutation and event append are one critical section. A `nil`
    /// `expectedVersion` binds to the row's current version, so the check and
    /// the write cannot be split by a concurrent mutation.
    func mutateReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int?, type: String,
        mutate: (inout ReminderRecord) -> Void
    ) -> ReminderMutationOutcome {
        mutex.withLock { storage in
            guard let index = storage.reminderRecords.firstIndex(where: { $0.id == reminderId && $0.ownerAgentId == ownerAgentId }) else {
                return .notFound
            }
            if type == "updated", storage.reminderRecords[index].status == "fired" {
                return .invalid("cannot update a fired reminder; snooze it back to scheduled first")
            }
            if type == "snoozed", storage.reminderRecords[index].status == "canceled" {
                return .invalid("cannot snooze a canceled reminder")
            }
            guard (expectedVersion ?? storage.reminderRecords[index].version) == storage.reminderRecords[index].version else {
                return .conflict(currentVersion: storage.reminderRecords[index].version)
            }
            var reminder = storage.reminderRecords[index]
            mutate(&reminder)
            reminder.version += 1
            let updated = Self.appendReminderEventLocked(state: &storage, reminder, type: type, actorType: "agent", actorId: ownerAgentId)
            storage.reminderRecords[index] = updated
            return .ok(version: updated.version)
        }
    }

    /// Appends the event row for `reminder` and returns the stamped record.
    /// The caller holds the Mutex and passes its state; this helper never locks.
    private static func appendReminderEventLocked(
        state: inout State,
        _ reminder: ReminderRecord, type: String, actorType: String, actorId: String? = nil,
        fireAt: Date? = nil
    ) -> ReminderRecord {
        var updated = reminder
        updated.updatedAt = Date()
        state.reminderEvents.append(ReminderEvent(
            reminderId: reminder.id, serverId: reminder.serverId, ownerAgentId: reminder.ownerAgentId,
            type: type, version: updated.version, actorType: actorType, actorId: actorId,
            createdAt: updated.updatedAt, fireAt: fireAt
        ))
        return updated
    }
}

// MARK: - Agent delete cleanup

extension TasksAndRemindersStore {
    /// Drops the agent's reminders and returns its claimed tasks to the pool, in
    /// one critical section.
    func releaseAgentWork(agentId: String, now: Date = Date()) {
        mutex.withLock { storage in
            storage.reminderRecords.removeAll { $0.ownerAgentId == agentId }
            for index in storage.taskRecords.indices where
                storage.taskRecords[index].assigneeType == "agent" && storage.taskRecords[index].assigneeId == agentId {
                storage.taskRecords[index].assigneeId = nil
                storage.taskRecords[index].assigneeType = nil
                storage.taskRecords[index].claimedAt = nil
                storage.taskRecords[index].revision += 1
                // Upstream agent deletion releases claims with a system event
                // that names the reason and the deleted agent.
                Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                    eventType: "assignee_changed", actorType: "system", actorId: nil,
                    payloadJSON: OrderedJSON.object([
                        .init("assigneeType", .null),
                        .init("assigneeId", .null),
                        .init("reason", "assignee_agent_deleted"),
                        .init("agentId", agentId),
                    ]).render(),
                    now: now)
            }
        }
    }
}
