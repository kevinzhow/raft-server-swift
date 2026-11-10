import Foundation

extension TasksAndRemindersStore {
    enum HumanStatusOutcome: Sendable {
        case notFound
        case channelDeletedTerminalOnly
        case onlyAssigneeCanReturnToTodo
        case resourceReceiptRequired
        case updated(TaskRecord)
    }

    /// `PATCH /api/tasks/:taskId/status`: the refusals and the status write
    /// (with its completion, close and claim stamps) are one critical section.
    func applyHumanStatus(
        taskId: String,
        status: String,
        userId: String,
        channelDeletion: TaskChannelDeletionQuery,
        now: Date
    ) -> HumanStatusOutcome {
        mutex.withLock { storage in
            guard let index = storage.taskRecords.firstIndex(where: { $0.id == taskId }) else { return .notFound }
            let current = storage.taskRecords[index]
            if channelDeletion.isDeleted(channelId: current.channelId), !["done", "closed", "cancelled"].contains(status) {
                return .channelDeletedTerminalOnly
            }
            if status == "todo", current.status == "in_progress", current.assigneeId != userId {
                return .onlyAssigneeCanReturnToTodo
            }
            if status == "done", current.requiresResourceReceipt,
               current.resourceReceiptJSON.flatMap({ try? JSONDecoder().decode(AgentTaskResourceReceipt.self, from: Data($0.utf8)) }) == nil {
                return .resourceReceiptRequired
            }
            let previousStatus = storage.taskRecords[index].status
            storage.taskRecords[index].updatedAt = now
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
            TasksAndRemindersStore.appendTaskEventLocked(state: &storage,
                taskId: storage.taskRecords[index].id,
                eventType: TasksAndRemindersStore.statusEventType(from: previousStatus, to: status),
                actorType: "user", actorId: userId,
                payloadJSON: TasksAndRemindersStore.statusEventPayload(from: previousStatus, to: status, forced: false),
                now: now)
            return .updated(storage.taskRecords[index])
        }
    }

}
