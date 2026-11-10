import Foundation
import Synchronization
import RaftShared

/// Agent thread-follow ledger behind its own lock.
final class ThreadFollowStore: Sendable {
    private let rows = TransactionalState<[String: AgentThreadFollowRecord]>([:])

    var persistenceRowsSnapshot: [String: AgentThreadFollowRecord] {
        get { rows.withLock { $0 } }
        set { rows.withLock { $0 = newValue } }
    }

    private func key(serverId: String, agentId: String, threadChannelId: String) -> String {
        "\(serverId)\n\(agentId)\n\(threadChannelId)"
    }

    func upsert(_ record: AgentThreadFollowRecord) {
        rows.withLock {
            $0[key(serverId: record.serverId, agentId: record.agentId, threadChannelId: record.threadChannelId)] = record
        }
    }

    func record(serverId: String, agentId: String, threadChannelId: String) -> AgentThreadFollowRecord? {
        rows.withLock { $0[key(serverId: serverId, agentId: agentId, threadChannelId: threadChannelId)] }
    }

    func all() -> [AgentThreadFollowRecord] {
        rows.withLock { Array($0.values) }
    }

    func markUnfollowed(serverId: String, agentId: String, threadChannelId: String, at date: Date) {
        rows.withLock { rows in
            if var record = rows[key(serverId: serverId, agentId: agentId, threadChannelId: threadChannelId)] {
                record.unfollowedAt = date
                rows[key(serverId: serverId, agentId: agentId, threadChannelId: threadChannelId)] = record
            }
        }
    }
}
