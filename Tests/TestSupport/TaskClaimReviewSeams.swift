// Review seams for the agent task claim/conversion follow-up: the private
// reminder surface (durable feedback identity), task ledger reads and the
// per-task canonical event types. These are fixture read/write pokes only; the
// production services keep their own locked accessors.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    /// Records the durable agent-private reminder surface. Production creates
    /// it through the app-installation reminder write; tests need the same row
    /// without minting an installation credential.
    public func setAgentReminderSurfaceForTesting(agentId: String, channelId: String) {
        feedbackStore.setAgentReminderSurface(agentId: agentId, channelId: channelId)
    }

    /// Links an assistant to its owner through the same store fact the HTTP
    /// `PUT /api/agents/:id/assistant-owner` writes. The test still enables the
    /// live feature flag when it needs `assistantMayPostTo`.
    public func linkAssistantOwnerForTesting(agentId: String, userId: String) {
        _ = agentsRuntimeStore.claimAssistantOwner(agentId: agentId, userId: userId, isLive: { _ in true })
    }

    /// The immutable host text of one stored message. Used after a runtime
    /// durable read to prove the conversion did not rewrite the chat row.
    public func messageContentForTesting(messageId: String) -> String? {
        messagesAndThreadsStore.withState { state in
            state.humanMessageRows.first { $0.id == messageId }?.content
        }
    }

    /// The canonical tasks currently linked to one channel, in ledger order.
    public func taskSnapshotsForTesting(
        channelId: String
    ) -> [(id: String, taskNumber: Int, title: String, status: String, messageId: String, creatorId: String?)] {
        tasksAndRemindersStore.mutex.withLock { storage in
            storage.taskRecords
                .filter { $0.channelId == channelId }
                .map { ($0.id, $0.taskNumber, $0.title, $0.status, $0.messageId, $0.creatorId) }
        }
    }

    /// The canonical event types recorded for one task, oldest first.
    public func taskPublishedEventTypesForTesting(taskId: String) -> [String] {
        tasksAndRemindersStore.publishedTaskEvents(taskId: taskId).map(\.eventType)
    }

    /// One task row with the exact claim facts a repeated/foreign/closed claim
    /// must observe. The host message id is a real string so the row is
    /// addressable by both claim modes.
    @discardableResult
    public func addTaskForClaimTesting(
        channelId: String,
        title: String,
        messageId: String = UUID().uuidString.lowercased(),
        status: String = "in_progress",
        assigneeType: String? = nil,
        assigneeId: String? = nil,
        claimedAt: Date? = nil,
        creatorId: String? = nil
    ) -> String {
        tasksAndRemindersStore.mutex.withLock { storage in
            let taskNumber = storage.taskRecords.filter { $0.channelId == channelId }
                .map(\.taskNumber).max() ?? 0
            let id = UUID().uuidString.lowercased()
            storage.taskRecords.append(TaskRecord(
                id: id, channelId: channelId, title: title, description: nil,
                status: status, taskNumber: taskNumber + 1, messageId: messageId,
                createdAt: Date(), creatorId: creatorId, assigneeId: assigneeId,
                assigneeType: assigneeType, claimedAt: claimedAt
            ))
            return id
        }
    }

    public func taskClaimFactsForTesting(
        taskId: String
    ) -> (status: String, assigneeType: String?, assigneeId: String?, claimedAt: Date?)? {
        tasksAndRemindersStore.mutex.withLock { storage in
            guard let task = storage.taskRecords.first(where: { $0.id == taskId }) else { return nil }
            return (task.status, task.assigneeType, task.assigneeId, task.claimedAt)
        }
    }
}
