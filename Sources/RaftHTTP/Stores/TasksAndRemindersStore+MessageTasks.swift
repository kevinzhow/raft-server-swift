import Foundation

/// Canonical task links created from an already-persisted host message.
///
/// Both writers converge here: `POST /api/tasks/convert-message` (where a
/// duplicate is a published refusal) and an `asTask` send (where a retry
/// returns the existing row). The task-number scan and the append run in one
/// task-owner critical section.
extension TasksAndRemindersStore {
    enum ConvertedMessageTaskOutcome: Sendable {
        case alreadyConverted
        case created(TaskRecord)
    }

    enum MessageTaskLinkOutcome: Sendable {
        case created(TaskRecord)
        case existing(TaskRecord)
    }

    /// Idempotently link one canonical task to an existing host message.
    ///
    /// This is the `asTask` send link: the plain host message has already been
    /// persisted, so the task is created against its real id. The duplicate
    /// scan, the max-number scan (frozen message-task numbers plus canonical
    /// rows) and the append run in one task-owner critical section, so a replay
    /// or a concurrent convert converges on one row and one number.
    func ensureMessageTask(
        channelId: String,
        messageId: String,
        title: String,
        convertedByType: String = "user",
        creatorId: String,
        legacyMessageMaxNumber: Int,
        now: Date
    ) -> MessageTaskLinkOutcome {
        mutex.withLock { storage in
            if let existing = storage.taskRecords.first(where: { $0.messageId == messageId }) {
                return .existing(existing)
            }
            let next = max(legacyMessageMaxNumber,
                storage.taskRecords.filter { $0.channelId == channelId }.map(\.taskNumber).max() ?? 0) + 1
            let task = TaskRecord(id: UUID().uuidString.lowercased(), channelId: channelId,
                title: title, description: nil, status: "todo", taskNumber: next, messageId: messageId,
                createdAt: now, updatedAt: now, creatorId: creatorId)
            storage.taskRecords.append(task)
            TasksAndRemindersStore.appendTaskEventLocked(state: &storage, taskId: task.id,
                eventType: "created", actorType: convertedByType, actorId: creatorId,
                payloadJSON: OrderedJSON.object([
                    .init("taskNumber", task.taskNumber),
                    .init("status", task.status),
                    .init("convertedFromMessage", true),
                ]).render(),
                now: now)
            return .created(task)
        }
    }

    /// Preserve the actual immutable host text. Link uniqueness and max-number
    /// allocation are one task-owner critical section; duplicate conversion is a
    /// refusal, not a second task or a successful replay.
    func appendConvertedMessageTask(channelId: String, messageId: String, title: String, creatorId: String,
        legacyMessageMaxNumber: Int, now: Date) -> ConvertedMessageTaskOutcome {
        switch ensureMessageTask(channelId: channelId, messageId: messageId, title: title,
                                 creatorId: creatorId, legacyMessageMaxNumber: legacyMessageMaxNumber, now: now) {
        case .existing:
            return .alreadyConverted
        case .created(let task):
            return .created(task)
        }
    }
}
