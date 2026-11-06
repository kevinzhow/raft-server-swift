// Test seam for the public server directory: public id poke.
@testable import RaftHTTP
import Foundation

extension PublicServerDirectory {
    public func setServerPublicIdForTesting(serverId: String, publicId: String) {
        lock.lock()
        if let index = servers.firstIndex(where: { $0.id == serverId }) {
            servers[index].publicId = publicId
        }
        lock.unlock()
    }
}
