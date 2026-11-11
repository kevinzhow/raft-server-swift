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
    public func taskEventTypesForTesting(taskId: String) -> [String] {
        tasksAndRemindersStore.publishedTaskEvents(taskId: taskId).map(\.eventType)
    }
}
