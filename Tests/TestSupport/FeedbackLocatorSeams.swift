// Test seams for the feedback locator: agent grant sets.
@testable import RaftHTTP
import Foundation

extension EmailLoginDirectory {
    public func setAgentGrantsForTesting(agentId: String, scopes: [String]) {
        managedMCPAndCardsStore.storage.withLock { owned in
            owned.agentGrantSets[agentId] = Set(scopes)
        }
    }

    public func resetAgentGrantsForTesting(agentId: String) {
        managedMCPAndCardsStore.storage.withLock { owned in
            _ = owned.agentGrantSets.removeValue(forKey: agentId)
        }
    }
}
