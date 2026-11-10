import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    /// Turns on Computer and App references for one server. Installed apps stay
    /// empty until recorded separately.
    public func allowComposerResourceReferencesForTesting(serverId: String) {
        serversAndChannelsStore.mutex.withLock { _ = $0.composerResourceServers.insert(serverId) }
    }

}
