@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func setManagedMCPServerEndpointForTesting(id: String, endpointUrl: String) {
        lock.lock()
        if let index = managedMCPServers.firstIndex(where: { $0.id == id }) {
            managedMCPServers[index].endpointUrl = endpointUrl
        }
        lock.unlock()
    }

    public func setReadPositionSettleForTesting(_ milliseconds: Int) {
        lock.lock(); readPositionSettleMs = milliseconds; lock.unlock()
    }
}
