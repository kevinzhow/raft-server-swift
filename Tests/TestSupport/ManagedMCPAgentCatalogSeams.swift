@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func taskRevisionForTesting(taskId: String) -> Int? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.first(where: { $0.id == taskId })?.revision
        }
    }

    public func taskClaimedAtForTesting(taskId: String) -> Date? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.first(where: { $0.id == taskId })?.claimedAt
        }
    }

    public func setTaskStatusForTesting(taskId: String, status: String) {
        tasksAndRemindersStore.mutex.withLock { owned in
            if let index = owned.taskRecords.firstIndex(where: { $0.id == taskId }) {
                owned.taskRecords[index].status = status
            }
        }
    }

    public func taskCountForTesting(channelId: String) -> Int {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.filter { $0.channelId == channelId }.count
        }
    }

    public func actionCardCountForTesting(agentId: String) -> Int {
        return managedMCPAndCardsStore.storage.withLock { owned in
            return owned.actionCardRecords.values.filter { $0.requesterAgentId == agentId }.count
        }
    }

    public func agentApiIdempotencyKeysForTesting(agentId: String, route: String) -> [String] {
        return managedMCPAndCardsStore.storage.withLock { owned in
            return owned.agentApiIdempotencyKeys.filter { $0.agentId == agentId && $0.route == route }.map(\.key)
        }
    }

    public func ageAgentApiIdempotencyKeysForTesting(agentId: String, seconds: TimeInterval) {
        managedMCPAndCardsStore.storage.withLock { owned in
            for index in owned.agentApiIdempotencyKeys.indices where owned.agentApiIdempotencyKeys[index].agentId == agentId {
                owned.agentApiIdempotencyKeys[index].createdAt = owned.agentApiIdempotencyKeys[index].createdAt.addingTimeInterval(-seconds)
            }
        }
    }

    public func assigneeChangeEventsForTesting(taskId: String) -> [(
        assigneeId: String?, assigneeType: String?, previousAssigneeId: String?,
        previousAssigneeType: String?, actorType: String, actorId: String
    )] {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.assigneeChangeEvents.filter { $0.taskId == taskId }.map {
                ($0.assigneeId, $0.assigneeType, $0.previousAssigneeId, $0.previousAssigneeType, $0.actorType, $0.actorId)
            }
        }
    }

    public func taskMessageIdForTesting(taskId: String) -> String? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.first { $0.id == taskId }?.messageId
        }
    }

    public func taskStatusForTesting(taskId: String) -> String? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.first { $0.id == taskId }?.status
        }
    }

    public func taskCompletedAtForTesting(taskId: String) -> Date? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.first { $0.id == taskId }?.completedAt
        }
    }

    public func taskClosedAtForTesting(taskId: String) -> Date? {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskRecords.first { $0.id == taskId }?.closedAt
        }
    }

    public func setTaskAssigneeForTesting(taskId: String, type: String, id: String) {
        tasksAndRemindersStore.mutex.withLock { owned in
            if let index = owned.taskRecords.firstIndex(where: { $0.id == taskId }) {
                owned.taskRecords[index].assigneeType = type
                owned.taskRecords[index].assigneeId = id
                owned.taskRecords[index].claimedAt = Date()
            }
        }
    }

    public func reopenTaskForTesting(taskId: String, status: String) {
        tasksAndRemindersStore.mutex.withLock { owned in
            if let index = owned.taskRecords.firstIndex(where: { $0.id == taskId }) {
                owned.taskRecords[index].status = status
                owned.taskRecords[index].completedAt = nil
                owned.taskRecords[index].closedAt = nil
            }
        }
    }

    public func taskEventTypesForTesting(taskId: String) -> [(eventType: String, actorType: String)] {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.taskEvents.filter { $0.taskId == taskId }.map { ($0.eventType, $0.actorType) }
        }
    }

    public func appReminderEventsForTesting(reminderId: String) -> [(type: String, version: Int)] {
        return tasksAndRemindersStore.mutex.withLock { owned in
            return owned.reminderEvents.filter { $0.reminderId == reminderId }.map { ($0.type, $0.version) }
        }
    }

    public func fireAppReminderForTesting(reminderId: String) {
        let store = tasksAndRemindersStore
        _ = store.mutateReminder(
            reminderId: reminderId, ownerAgentId: store.ownerAgentId(reminderId: reminderId) ?? "",
            expectedVersion: store.reminderRow(id: reminderId)?.version ?? 0, type: "fired"
        ) { reminder in
            reminder.status = "fired"
        }
    }

    public func addReminderForTesting(serverId: String, ownerAgentId: String, title: String, fireAt: Date) {
        tasksAndRemindersStore.addReminder(serverId: serverId, ownerAgentId: ownerAgentId, title: title, fireAt: fireAt)
    }

    @discardableResult
    public func createAppReminderForTesting(
        serverId: String, ownerAgentId: String, title: String, fireAt: Date
    ) -> String {
        tasksAndRemindersStore.createReminder(
            serverId: serverId, ownerAgentId: ownerAgentId, title: title, fireAt: fireAt
        )
    }

    public func appReminderRowForTesting(id: String) -> (status: String, version: Int)? {
        tasksAndRemindersStore.reminderRow(id: id).map { ($0.status, $0.version) }
    }
}
