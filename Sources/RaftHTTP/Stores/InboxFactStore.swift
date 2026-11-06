import Foundation
import Synchronization

struct StoredInboxFact: Sendable {
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
final class InboxFactStore: Sendable {
    private let facts = Mutex<[StoredInboxFact]>([])

    func append(_ fact: StoredInboxFact) {
        facts.withLock { $0.append(fact) }
    }

    func all() -> [StoredInboxFact] {
        facts.withLock { $0 }
    }
}
