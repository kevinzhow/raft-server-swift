// Test seams for the feedback locator: agent grant sets.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func setAgentGrantsForTesting(agentId: String, scopes: [String]) {
        lock.lock()
        agentGrantSets[agentId] = Set(scopes)
        lock.unlock()
    }

    public func resetAgentGrantsForTesting(agentId: String) {
        lock.lock()
        agentGrantSets.removeValue(forKey: agentId)
        lock.unlock()
    }
}
