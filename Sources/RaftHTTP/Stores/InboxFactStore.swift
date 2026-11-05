import Foundation

struct StoredInboxFact {
    var messageId: String
    var receiverType: String
    var receiverId: String
    var channelId: String?
    var serverId: String?
    var personalMention: Bool
    var unreadEligible: Bool = true
}

/// Agent inbox-fact ledger behind its own lock.
///
/// Handlers query it while holding the directory lock today; the snapshot API
/// keeps the migration mechanical. Domain-specific queries can move into this
/// store without touching the directory's session/channel state.
final class InboxFactStore: @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [StoredInboxFact] = []

    func append(_ fact: StoredInboxFact) {
        lock.lock()
        facts.append(fact)
        lock.unlock()
    }

    func all() -> [StoredInboxFact] {
        lock.lock()
        defer { lock.unlock() }
        return facts
    }
}
