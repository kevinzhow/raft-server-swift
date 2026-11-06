@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func setManagedMCPServerEndpointForTesting(id: String, endpointUrl: String) {
        managedMCPAndCardsStore.storage.withLock { state in
            if let index = state.managedMCPServers.firstIndex(where: { $0.id == id }) {
                state.managedMCPServers[index].endpointUrl = endpointUrl
            }
        }
    }

    public func setReadPositionSettleForTesting(_ milliseconds: Int) {
        messagesAndThreadsStore.withState { state in
            state.readPositionSettleMs = milliseconds
        }
    }
}
