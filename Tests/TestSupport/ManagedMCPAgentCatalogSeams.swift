@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func taskRevisionForTesting(taskId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first(where: { $0.id == taskId })?.revision
    }

    public func taskClaimedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first(where: { $0.id == taskId })?.claimedAt
    }

    public func setTaskStatusForTesting(taskId: String, status: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].status = status
        }
        lock.unlock()
    }

    public func taskCountForTesting(channelId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return taskRecords.filter { $0.channelId == channelId }.count
    }

    public func actionCardCountForTesting(agentId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return actionCardRecords.values.filter { $0.requesterAgentId == agentId }.count
    }

    public func agentApiIdempotencyKeysForTesting(agentId: String, route: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return agentApiIdempotencyKeys.filter { $0.agentId == agentId && $0.route == route }.map(\.key)
    }

    public func ageAgentApiIdempotencyKeysForTesting(agentId: String, seconds: TimeInterval) {
        lock.lock()
        for index in agentApiIdempotencyKeys.indices where agentApiIdempotencyKeys[index].agentId == agentId {
            agentApiIdempotencyKeys[index].createdAt = agentApiIdempotencyKeys[index].createdAt.addingTimeInterval(-seconds)
        }
        lock.unlock()
    }

    public func assigneeChangeEventsForTesting(taskId: String) -> [(
        assigneeId: String?, assigneeType: String?, previousAssigneeId: String?,
        previousAssigneeType: String?, actorType: String, actorId: String
    )] {
        lock.lock()
        defer { lock.unlock() }
        return assigneeChangeEvents.filter { $0.taskId == taskId }.map {
            ($0.assigneeId, $0.assigneeType, $0.previousAssigneeId, $0.previousAssigneeType, $0.actorType, $0.actorId)
        }
    }

    public func taskMessageIdForTesting(taskId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.messageId
    }

    public func taskStatusForTesting(taskId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.status
    }

    public func taskCompletedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.completedAt
    }

    public func taskClosedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.closedAt
    }

    public func setTaskAssigneeForTesting(taskId: String, type: String, id: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].assigneeType = type
            taskRecords[index].assigneeId = id
            taskRecords[index].claimedAt = Date()
        }
        lock.unlock()
    }

    public func reopenTaskForTesting(taskId: String, status: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].status = status
            taskRecords[index].completedAt = nil
            taskRecords[index].closedAt = nil
        }
        lock.unlock()
    }

    public func taskEventTypesForTesting(taskId: String) -> [(eventType: String, actorType: String)] {
        lock.lock()
        defer { lock.unlock() }
        return taskEvents.filter { $0.taskId == taskId }.map { ($0.eventType, $0.actorType) }
    }

    public func appReminderEventsForTesting(reminderId: String) -> [(type: String, version: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return reminderEvents.filter { $0.reminderId == reminderId }.map { ($0.type, $0.version) }
    }

    public func fireAppReminderForTesting(reminderId: String) -> ReminderMutationOutcome {
        mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentIdForReminder(reminderId) ?? "",
                          expectedVersion: appReminderRow(id: reminderId)?.version ?? 0, type: "fired") { reminder in
            reminder.status = "fired"
        }
    }
}
