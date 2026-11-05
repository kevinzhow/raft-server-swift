import Foundation

/// Agent thread-follow ledger behind its own lock.
final class ThreadFollowStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: AgentThreadFollowRecord] = [:]

    private func key(serverId: String, agentId: String, threadChannelId: String) -> String {
        "\(serverId)\n\(agentId)\n\(threadChannelId)"
    }

    func upsert(_ record: AgentThreadFollowRecord) {
        lock.lock()
        rows[key(serverId: record.serverId, agentId: record.agentId, threadChannelId: record.threadChannelId)] = record
        lock.unlock()
    }

    func record(serverId: String, agentId: String, threadChannelId: String) -> AgentThreadFollowRecord? {
        lock.lock()
        defer { lock.unlock() }
        return rows[key(serverId: serverId, agentId: agentId, threadChannelId: threadChannelId)]
    }

    func all() -> [AgentThreadFollowRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(rows.values)
    }

    func markUnfollowed(serverId: String, agentId: String, threadChannelId: String, at date: Date) {
        lock.lock()
        if var record = rows[key(serverId: serverId, agentId: agentId, threadChannelId: threadChannelId)] {
            record.unfollowedAt = date
            rows[key(serverId: serverId, agentId: agentId, threadChannelId: threadChannelId)] = record
        }
        lock.unlock()
    }
}
