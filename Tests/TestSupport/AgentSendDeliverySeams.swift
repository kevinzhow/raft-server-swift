// Test seams for agent send delivery: activity read-backs.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func agentActivityForTesting(agentId: String) -> (activity: String, detail: String)? {
        lock.lock()
        defer { lock.unlock() }
        return agentActivities[agentId]
    }

    public func agentStatusAdoptedForTesting(agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return agentStatusAdopted.contains(agentId)
    }
}
