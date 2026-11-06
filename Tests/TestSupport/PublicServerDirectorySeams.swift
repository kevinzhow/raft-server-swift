// Test seam for the public server directory: public id poke.
@testable import RaftHTTP
import Foundation

extension PublicServerDirectory {
    public func setServerPublicIdForTesting(serverId: String, publicId: String) {
        state.withLock { state in
            if let index = state.servers.firstIndex(where: { $0.id == serverId }) {
                state.servers[index].publicId = publicId
            }
        }
    }
}
