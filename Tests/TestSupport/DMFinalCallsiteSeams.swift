import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    /// Number of live-or-tombstoned postable rows, for the "a refused target
    /// created nothing" checks. Tests compare it before and after a refusal.
    public var postableChannelCountForTesting: Int {
        serversAndChannelsStore.state.postableChannels.count
    }
}
