import Foundation

extension TasksAndRemindersStore {
    /// Capture under the owner borrow; construct and encode the private DTO outside it.
    /// Call under the coordinator's exclusive gate for a multi-owner consistent cut.
    func exportPersistenceData() throws -> Data {
        let captured = mutex.withLock { $0 }
        return try CollaborationPersistenceCoding.encode(CPTasksSnapshot(captured), format: "raft.tasks-and-reminders")
    }

    /// Fully decode and validate before the short business-field replacement borrow.
    /// Preserves this owner instance and does not publish any callbacks or frames.
    func restorePersistenceData(_ data: Data) throws {
        let decoded = try CollaborationPersistenceCoding.decode(CPTasksSnapshot.self, from: data, format: "raft.tasks-and-reminders")
        let restored = decoded.restored()
        mutex.withLock { current in
            current.reminderRecords = restored.reminderRecords
            current.reminderEvents = restored.reminderEvents
            current.taskRecords = restored.taskRecords
            current.taskWriteHolds = restored.taskWriteHolds
            current.taskEvents = restored.taskEvents
            current.lastTaskServerWarning = restored.lastTaskServerWarning
            current.assigneeChangeEvents = restored.assigneeChangeEvents
        }
    }
}

private struct CPTasksSnapshot: Codable {
    var reminderRecords: [CPReminder]
    var reminderEvents: [CPReminderEvent]
    var taskRecords: [CPTask]
    var taskWriteHolds: [String: CPTaskWriteHold]
    var taskEvents: [CPTaskEvent]
    var lastTaskServerWarning: String?
    var assigneeChangeEvents: [CPAssigneeEvent]

    init(_ value: TasksAndRemindersStore.State) {
        reminderRecords = value.reminderRecords.map(CPReminder.init)
        reminderEvents = value.reminderEvents.map(CPReminderEvent.init)
        taskRecords = value.taskRecords.map(CPTask.init)
        taskWriteHolds = value.taskWriteHolds.mapValues(CPTaskWriteHold.init)
        taskEvents = value.taskEvents.map(CPTaskEvent.init)
        lastTaskServerWarning = value.lastTaskServerWarning
        assigneeChangeEvents = value.assigneeChangeEvents.map(CPAssigneeEvent.init)
    }

    func restored() -> TasksAndRemindersStore.State {
        var value = TasksAndRemindersStore.State()
        value.reminderRecords = reminderRecords.map { $0.restored() }
        value.reminderEvents = reminderEvents.map { $0.restored() }
        value.taskRecords = taskRecords.map { $0.restored() }
        value.taskWriteHolds = taskWriteHolds.mapValues { $0.restored() }
        value.taskEvents = taskEvents.map { $0.restored() }
        value.lastTaskServerWarning = lastTaskServerWarning
        value.assigneeChangeEvents = assigneeChangeEvents.map { $0.restored() }
        return value
    }
}

private struct CPReminder: Codable {
    var id: String
    var serverId: String
    var ownerAgentId: String
    var title: String
    var fireAt: Date
    var status: String
    var version: Int
    var notes: String?
    var recurrenceJSON: String?
    var channelId: String?
    var threadId: String?
    var createdAt: Date
    var updatedAt: Date

    init(_ value: ReminderRecord) {
        id = value.id
        serverId = value.serverId
        ownerAgentId = value.ownerAgentId
        title = value.title
        fireAt = value.fireAt
        status = value.status
        version = value.version
        notes = value.notes
        recurrenceJSON = value.recurrenceJSON
        channelId = value.channelId
        threadId = value.threadId
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }

    func restored() -> ReminderRecord {
        ReminderRecord(id: id, serverId: serverId, ownerAgentId: ownerAgentId, title: title, fireAt: fireAt, status: status, version: version, notes: notes, recurrenceJSON: recurrenceJSON, channelId: channelId, threadId: threadId, createdAt: createdAt, updatedAt: updatedAt)
    }
}

private struct CPReminderEvent: Codable {
    var reminderId: String
    var serverId: String
    var ownerAgentId: String
    var type: String
    var version: Int
    var actorType: String
    var actorId: String?
    var createdAt: Date
    var fireAt: Date?

    init(_ value: ReminderEvent) {
        reminderId = value.reminderId
        serverId = value.serverId
        ownerAgentId = value.ownerAgentId
        type = value.type
        version = value.version
        actorType = value.actorType
        actorId = value.actorId
        createdAt = value.createdAt
        fireAt = value.fireAt
    }

    func restored() -> ReminderEvent {
        ReminderEvent(reminderId: reminderId, serverId: serverId, ownerAgentId: ownerAgentId, type: type, version: version, actorType: actorType, actorId: actorId, createdAt: createdAt, fireAt: fireAt)
    }
}

private struct CPTask: Codable {
    var id: String
    var channelId: String
    var title: String
    var description: String?
    var status: String
    var taskNumber: Int
    var messageId: String
    var createdAt: Date
    var completedAt: Date?
    var updatedAt: Date?
    var creatorId: String?
    var assigneeId: String?
    var assigneeType: String?
    var claimedAt: Date?
    var revision: Int
    var closedAt: Date?
    var hasHostMessage: Bool
    var amendedAt: Date?
    var amendedByType: String?
    var amendedByName: String?
    var superseded: Bool
    var requiresResourceReceipt: Bool
    var resourceReceiptJSON: String?

    init(_ value: TaskRecord) {
        id = value.id
        channelId = value.channelId
        title = value.title
        description = value.description
        status = value.status
        taskNumber = value.taskNumber
        messageId = value.messageId
        createdAt = value.createdAt
        completedAt = value.completedAt
        updatedAt = value.updatedAt
        creatorId = value.creatorId
        assigneeId = value.assigneeId
        assigneeType = value.assigneeType
        claimedAt = value.claimedAt
        revision = value.revision
        closedAt = value.closedAt
        hasHostMessage = value.hasHostMessage
        amendedAt = value.amendedAt
        amendedByType = value.amendedByType
        amendedByName = value.amendedByName
        superseded = value.superseded
        requiresResourceReceipt = value.requiresResourceReceipt
        resourceReceiptJSON = value.resourceReceiptJSON
    }

    func restored() -> TaskRecord {
        TaskRecord(id: id, channelId: channelId, title: title, description: description, status: status, taskNumber: taskNumber, messageId: messageId, createdAt: createdAt, completedAt: completedAt, updatedAt: updatedAt, creatorId: creatorId, assigneeId: assigneeId, assigneeType: assigneeType, claimedAt: claimedAt, revision: revision, closedAt: closedAt, hasHostMessage: hasHostMessage, amendedAt: amendedAt, amendedByType: amendedByType, amendedByName: amendedByName, superseded: superseded, requiresResourceReceipt: requiresResourceReceipt, resourceReceiptJSON: resourceReceiptJSON)
    }
}

private struct CPTaskWriteHold: Codable {
    var seen: Int
    var latest: Int

    init(_ value: (seen: Int, latest: Int)) {
        seen = value.seen
        latest = value.latest
    }

    func restored() -> (seen: Int, latest: Int) {
        (seen: seen, latest: latest)
    }
}

private struct CPTaskEvent: Codable {
    var taskId: String
    var eventType: String
    var actorType: String
    /// The canonical event group. Absent on a snapshot written before the task
    /// history contract existed and restores as a pre-canonical row; a present
    /// group is strict because it is one upstream `task_events` insert.
    var history: CPTaskEventHistory?

    init(_ value: TaskEventRecord) {
        taskId = value.taskId
        eventType = value.eventType
        actorType = value.actorType
        history = value.history.map(CPTaskEventHistory.init)
    }

    func restored() -> TaskEventRecord {
        TaskEventRecord(taskId: taskId, eventType: eventType, actorType: actorType,
                        history: history?.restored())
    }
}

private struct CPTaskEventHistory: Codable {
    var id: String
    var seq: Int
    var actorId: String?
    var payloadJSON: String
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, seq, actorId, payloadJSON, createdAt
    }

    /// A present group is strict: every member key must exist. `actorId` is a
    /// required nullable member, not an optional one, so a missing key rejects
    /// the snapshot instead of silently restoring an absent actor.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        seq = try container.decode(Int.self, forKey: .seq)
        guard container.contains(.actorId) else {
            throw DecodingError.keyNotFound(CodingKeys.actorId, .init(
                codingPath: decoder.codingPath,
                debugDescription: "Canonical task event history requires actorId"))
        }
        actorId = try container.decodeIfPresent(String.self, forKey: .actorId)
        payloadJSON = try container.decode(String.self, forKey: .payloadJSON)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    init(_ value: TaskEventRecord.History) {
        id = value.id
        seq = value.seq
        actorId = value.actorId
        payloadJSON = value.payloadJSON
        createdAt = value.createdAt
    }

    func restored() -> TaskEventRecord.History {
        TaskEventRecord.History(id: id, seq: seq, actorId: actorId,
                                payloadJSON: payloadJSON, createdAt: createdAt)
    }
}

private struct CPAssigneeEvent: Codable {
    var taskId: String
    var assigneeId: String?
    var assigneeType: String?
    var previousAssigneeId: String?
    var previousAssigneeType: String?
    var actorType: String
    var actorId: String

    init(_ value: (taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)) {
        taskId = value.taskId
        assigneeId = value.assigneeId
        assigneeType = value.assigneeType
        previousAssigneeId = value.previousAssigneeId
        previousAssigneeType = value.previousAssigneeType
        actorType = value.actorType
        actorId = value.actorId
    }

    func restored() -> (taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String) {
        (taskId: taskId, assigneeId: assigneeId, assigneeType: assigneeType, previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType, actorType: actorType, actorId: actorId)
    }
}

