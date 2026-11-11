import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    /// Number of live-or-tombstoned postable rows, for the "a refused target
    /// created nothing" checks. Tests compare it before and after a refusal.
    public var postableChannelCountForTesting: Int {
        serversAndChannelsStore.state.postableChannels.count
    }

    /// Number of task rows across the store, for the DM-refusal zero-write
    /// checks that must not depend on a particular channel.
    public var taskRecordCountForTesting: Int {
        tasksAndRemindersStore.taskRecords.count
    }
}
