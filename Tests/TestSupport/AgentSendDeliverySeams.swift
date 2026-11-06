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

extension EmailLoginDirectory {
    /// Seeds one agent thread-follow row. The production service only reads
    /// these rows after the mention/follow flows write them; tests need the
    /// seed without going through a route.
    public func followThreadForAgentTesting(
        serverId: String,
        agentId: String,
        threadChannelId: String,
        parentMessageId: String,
        reason: String = "manual",
        followedAt: Date = Date(),
        unfollowedAt: Date? = nil
    ) {
        threadFollowStore.upsert(AgentThreadFollowRecord(
            serverId: serverId,
            agentId: agentId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId,
            followedAt: followedAt,
            reason: reason,
            doneAt: nil,
            unfollowedAt: unfollowedAt
        ))
    }
}
