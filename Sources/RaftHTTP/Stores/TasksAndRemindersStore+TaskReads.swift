import Foundation

// MARK: - Server task reads, amend and reassignment

extension TasksAndRemindersStore {
    /// The rows of one channel, optionally narrowed to one status, in insertion
    /// order. One locked snapshot.
    func tasks(channelId: String, status: String?) -> [TaskRecord] {
        mutex.withLock { storage in
            return storage.taskRecords.filter {
                $0.channelId == channelId && (status == nil || $0.status == status)
            }
        }
    }

    func task(channelId: String, taskNumber: Int) -> TaskRecord? {
        mutex.withLock { storage in
            return storage.taskRecords.first { $0.channelId == channelId && $0.taskNumber == taskNumber }
        }
    }

    func task(id: String) -> TaskRecord? {
        mutex.withLock { storage in
            return storage.taskRecords.first { $0.id == id }
        }
    }

    func task(messageId: String) -> TaskRecord? {
        mutex.withLock { $0.taskRecords.first { $0.messageId == messageId } }
    }

    // MARK: - Human task routes (managed-MCP assignments)

    /// `DELETE /api/tasks/:taskId`: removes the row by id and returns it. The
    /// legacy handler removed by an index it had read earlier; removing by id
    /// in one section cannot drop a neighbour when rows move in between.
    func removeTask(id: String) -> TaskRecord? {
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: { $0.id == id }) else { return nil }
            storage.taskEvents.removeAll { $0.taskId == id }
            storage.assigneeChangeEvents.removeAll { $0.taskId == id }
            return storage.taskRecords.remove(at: index)
        }
    }

    enum HumanClaimOutcome: Sendable {
        case notFound
        case channelDeleted
        case rejected(String)
        case alreadyAssigned(TaskRecord)
        case claimed(TaskRecord)
    }

    /// `PATCH /api/tasks/:taskId/claim`: the row lookup, the deleted-channel
    /// refusal and the claim write are one critical section.
    func claimForUser(taskId: String, userId: String, channelDeletion: TaskChannelDeletionQuery, now: Date) -> HumanClaimOutcome {
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: { $0.id == taskId }) else { return .notFound }
            guard !channelDeletion.isDeleted(channelId: storage.taskRecords[index].channelId) else { return .channelDeleted }
            let current = storage.taskRecords[index]
            if current.status == "closed" { return .rejected("task is closed; reopen it before claiming") }
            if let assignee = current.assigneeId {
                let selfAssigned = current.assigneeType == "user" && assignee == userId
                if !(selfAssigned && current.status == "todo" && current.claimedAt == nil) {
                    return selfAssigned ? .rejected("already claimed by you") : .alreadyAssigned(current)
                }
            } else if current.status == "done" { return .rejected("task is done") }
            let previousStatus = storage.taskRecords[index].status
            storage.taskRecords[index].updatedAt = now
            storage.taskRecords[index].assigneeId = userId
            storage.taskRecords[index].assigneeType = "user"
            storage.taskRecords[index].claimedAt = now
            storage.taskRecords[index].revision += 1
            if storage.taskRecords[index].status == "todo" { storage.taskRecords[index].status = "in_progress" }
            let taskId = storage.taskRecords[index].id
            Self.appendTaskEventLocked(state: &storage, taskId: taskId, eventType: "assignee_changed",
                actorType: "user", actorId: userId,
                payloadJSON: OrderedJSON.object([
                    .init("assigneeType", "user"),
                    .init("assigneeId", userId),
                ]).render(),
                now: now)
            if previousStatus != storage.taskRecords[index].status {
                Self.appendTaskEventLocked(state: &storage, taskId: taskId, eventType: "status_changed",
                    actorType: "user", actorId: userId,
                    payloadJSON: OrderedJSON.object([
                        .init("from", previousStatus),
                        .init("to", storage.taskRecords[index].status),
                        .init("forced", false),
                    ]).render(),
                    now: now)
            }
            return .claimed(storage.taskRecords[index])
        }
    }

    /// `PATCH /api/tasks/:taskId/unclaim`: the assignee clear, the revision
    /// bump and the assignee-change event are one critical section.
    enum HumanUnclaimOutcome: Sendable {
        case notFound
        case done
        case unassigned
        case unclaimed(TaskRecord)
    }

    func unclaimForUser(taskId: String, userId: String, now: Date = Date()) -> HumanUnclaimOutcome {
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: { $0.id == taskId }) else { return .notFound }
            guard storage.taskRecords[index].status != "done" else { return .done }
            guard storage.taskRecords[index].assigneeId != nil else { return .unassigned }
            let previousAssigneeId = storage.taskRecords[index].assigneeId
            let previousAssigneeType = storage.taskRecords[index].assigneeType
            storage.taskRecords[index].assigneeId = nil
            storage.taskRecords[index].assigneeType = nil
            storage.taskRecords[index].claimedAt = nil
            storage.taskRecords[index].updatedAt = now
            storage.taskRecords[index].revision += 1
            storage.assigneeChangeEvents.append((
                taskId: taskId, assigneeId: nil, assigneeType: nil,
                previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType,
                actorType: "user", actorId: userId
            ))
            Self.appendTaskEventLocked(state: &storage, taskId: taskId, eventType: "assignee_changed",
                actorType: "user", actorId: userId,
                payloadJSON: OrderedJSON.object([
                    .init("assigneeType", .null),
                    .init("assigneeId", .null),
                    .init("previousAssigneeType", optional: previousAssigneeType),
                    .init("previousAssigneeId", optional: previousAssigneeId),
                ]).render(),
                now: now)
            return .unclaimed(storage.taskRecords[index])
        }
    }

    /// `POST /internal/agent-api/tasks/unclaim`: upstream `writeCanonicalUnclaim`.
    /// The read, the guards and the write are one critical section; unclaim is
    /// member-level (any agent that can post may release the task), so the
    /// current assignee is not part of the predicate. The event records the
    /// requester as actor and the displaced assignee in the payload.
    enum AgentUnclaimOutcome: Sendable {
        case notFound
        case done
        case unassigned
        case changedConcurrently
        case unclaimed(TaskRecord)
    }

    func unclaimForAgent(taskId: String, agentId: String, now: Date = Date()) -> AgentUnclaimOutcome {
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: { $0.id == taskId }) else {
                return .notFound
            }
            guard storage.taskRecords[index].status != "done" else { return .done }
            guard storage.taskRecords[index].assigneeId != nil else { return .unassigned }
            // `canonicalRevisionCas` + `claimedById IS NOT NULL` + status guard:
            // any of them missing would mean the row moved after the read, but
            // the whole decision is inside this lock so the predicates hold.
            let previousAssigneeId = storage.taskRecords[index].assigneeId
            let previousAssigneeType = storage.taskRecords[index].assigneeType
            storage.taskRecords[index].assigneeId = nil
            storage.taskRecords[index].assigneeType = nil
            storage.taskRecords[index].claimedAt = nil
            storage.taskRecords[index].updatedAt = now
            storage.taskRecords[index].revision += 1
            storage.assigneeChangeEvents.append((
                taskId: taskId, assigneeId: nil, assigneeType: nil,
                previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType,
                actorType: "agent", actorId: agentId
            ))
            Self.appendTaskEventLocked(state: &storage, taskId: taskId, eventType: "assignee_changed",
                actorType: "agent", actorId: agentId,
                payloadJSON: OrderedJSON.object([
                    .init("assigneeType", .null),
                    .init("assigneeId", .null),
                    .init("previousAssigneeType", optional: previousAssigneeType),
                    .init("previousAssigneeId", optional: previousAssigneeId),
                ]).render(),
                now: now)
            return .unclaimed(storage.taskRecords[index])
        }
    }

    /// `POST /internal/agent-api/tasks/amend`: the row lookup, the title and
    /// description write, the revision bump and the amend markers are one
    /// critical section. `nil` means the task does not exist.
    func amendTask(
        channelId: String,
        taskNumber: Int,
        title: String,
        description: String?,
        actorId: String,
        amendedByName: String,
        now: Date
    ) -> TaskRecord? {
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: {
                $0.channelId == channelId && $0.taskNumber == taskNumber
            }) else { return nil }
            let previousTitle = storage.taskRecords[index].title
            let previousDescription = storage.taskRecords[index].description
            storage.taskRecords[index].title = title
            if let description { storage.taskRecords[index].description = description }
            storage.taskRecords[index].revision += 1
            storage.taskRecords[index].updatedAt = now
            storage.taskRecords[index].amendedAt = now
            storage.taskRecords[index].amendedByType = "agent"
            storage.taskRecords[index].amendedByName = amendedByName
            storage.taskRecords[index].superseded = true
            var changes: [OrderedJSONField] = []
            if title != previousTitle {
                changes.append(.init("title", .object([
                    .init("from", previousTitle),
                    .init("to", title),
                ])))
            }
            if let description, description != previousDescription {
                changes.append(.init("description", .object([
                    .init("from", optional: previousDescription),
                    .init("to", description),
                ])))
            }
            // Upstream returns "task amendment makes no changes" without an
            // event. The store still stamps the row, but history must not
            // claim a change that did not happen.
            if !changes.isEmpty {
                Self.appendTaskEventLocked(state: &storage, taskId: storage.taskRecords[index].id,
                    eventType: "amended", actorType: "agent", actorId: actorId,
                    payloadJSON: OrderedJSON.object([
                        .init("revision", storage.taskRecords[index].revision),
                        .init("changes", .object(changes)),
                    ]).render(),
                    now: now)
            }
            return storage.taskRecords[index]
        }
    }

    enum ReassignOutcome: Sendable {
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
        actorId: String,
        now: Date = Date()
    ) -> ReassignOutcome {
        mutex.withLock { storage in
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
            storage.taskRecords[index].updatedAt = now
            storage.taskRecords[index].revision += 1
            storage.assigneeChangeEvents.append((
                taskId: taskId, assigneeId: assigneeId, assigneeType: assigneeType,
                previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType,
                actorType: "user", actorId: actorId
            ))
            Self.appendTaskEventLocked(state: &storage, taskId: taskId, eventType: "assignee_changed",
                actorType: "user", actorId: actorId,
                payloadJSON: OrderedJSON.object([
                    .init("assigneeType", optional: assigneeType),
                    .init("assigneeId", optional: assigneeId),
                    .init("previousAssigneeType", optional: previousAssigneeType),
                    .init("previousAssigneeId", optional: previousAssigneeId),
                ]).render(),
                now: now)
            return .reassigned(storage.taskRecords[index])
        }
    }
}
