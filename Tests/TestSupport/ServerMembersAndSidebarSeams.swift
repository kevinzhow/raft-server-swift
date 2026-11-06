// Test seams for the server-member/task-aggregate fixtures.
//
// The task row appends used to live on `EmailLoginDirectory` beside the
// production metrics; they now belong to `TasksAndRemindersStore`. These
// helpers keep the old fixture signatures for the tests that seed rows.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    /// Appends one `todo` task row and returns its id.
    public func addTask(channelId: String, title: String, description: String?) -> String {
        tasksAndRemindersStore.addTask(channelId: channelId, title: title, description: description)
    }

    /// Appends one task row with caller-supplied timestamps and status.
    public func addTaskSnapshot(
        channelId: String,
        title: String,
        status: String,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        tasksAndRemindersStore.addTaskSnapshot(
            channelId: channelId,
            title: title,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt
        )
    }

    /// Appends one completed task row with caller-supplied timestamps.
    public func addCompletedTask(
        channelId: String,
        title: String,
        createdAt: Date,
        completedAt: Date
    ) {
        tasksAndRemindersStore.addCompletedTask(
            channelId: channelId,
            title: title,
            createdAt: createdAt,
            completedAt: completedAt
        )
    }
}
