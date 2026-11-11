import Foundation

/// The retained owner onboarding-briefing ledger. One row per
/// `(serverId, ownerId)`, the same facts upstream keeps on `serverMembers`.
///
/// `openerV2SentAt` is the one-shot sent fact for the visible opener and its
/// ledger wake. It is written only after the delivery admission accepted the
/// ledger notice, never from the handoff acknowledgment (a human click).
struct OwnerOpenerLedger: Sendable, Equatable {
    /// Legacy/generic briefing stamp. A row that already carries it is not
    /// re-briefed by the opener-v2 path (upstream returns false).
    var dmSentAt: Date?
    var dmSentByAgentId: String?
    var openerV2SentAt: Date?
    var openerV2SentByAgentId: String?
    var openerV2MessageIds: [String] = []
    var openerV2Version: String?
    var openerV2Topics: [String] = []
    /// Five-minute one-sender-at-a-time lease (`claimOwnerOpener`).
    var openerClaimedAt: Date?
}

extension ServersAndChannelsStore {
    /// Upstream `OWNER_OPENER_CLAIM_LEASE_MS`.
    static let ownerOpenerClaimLease: TimeInterval = 5 * 60

    static func ownerOpenerLedgerKey(serverId: String, ownerId: String) -> String {
        "\(serverId)\n\(ownerId)"
    }

    /// One locked read; a missing row reads as "never briefed, never claimed".
    func ownerOpenerLedger(serverId: String, ownerId: String) -> OwnerOpenerLedger {
        mutex.withLock { storage in
            storage.ownerOpenerLedgers[Self.ownerOpenerLedgerKey(serverId: serverId, ownerId: ownerId)]
                ?? OwnerOpenerLedger()
        }
    }

    /// Conditional claim over the complete upstream predicate: the opener is
    /// unsent and the lease is absent or expired. Returns this sender's token
    /// (the claim time) only to the caller that set it.
    func claimOwnerOpener(serverId: String, ownerId: String, now: Date) -> Date? {
        mutex.withLock { storage in
            let key = Self.ownerOpenerLedgerKey(serverId: serverId, ownerId: ownerId)
            var ledger = storage.ownerOpenerLedgers[key] ?? OwnerOpenerLedger()
            guard ledger.openerV2SentAt == nil else { return nil }
            if let claimedAt = ledger.openerClaimedAt,
               claimedAt >= now.addingTimeInterval(-Self.ownerOpenerClaimLease) {
                return nil
            }
            ledger.openerClaimedAt = now
            storage.ownerOpenerLedgers[key] = ledger
            return now
        }
    }

    /// Clear a claim this sender still holds. A slow sender whose lease ran out
    /// and was taken over must not clear the new holder's claim.
    func releaseOwnerOpenerClaim(serverId: String, ownerId: String, token: Date) {
        mutex.withLock { storage in
            let key = Self.ownerOpenerLedgerKey(serverId: serverId, ownerId: ownerId)
            guard var ledger = storage.ownerOpenerLedgers[key], ledger.openerClaimedAt == token else { return }
            ledger.openerClaimedAt = nil
            storage.ownerOpenerLedgers[key] = ledger
        }
    }

    /// The one-shot sent ledger, written only after an accepted notice receipt.
    /// Both stamps keep the caller's single `sentAt`, like upstream's one
    /// `sentAt` for the four preference fields.
    func stampOwnerOpener(serverId: String, ownerId: String, agentId: String, at sentAt: Date,
                          messageIds: [String], version: String, topics: [String]) {
        mutex.withLock { storage in
            let key = Self.ownerOpenerLedgerKey(serverId: serverId, ownerId: ownerId)
            var ledger = storage.ownerOpenerLedgers[key] ?? OwnerOpenerLedger()
            ledger.dmSentAt = sentAt
            ledger.dmSentByAgentId = agentId
            ledger.openerV2SentAt = sentAt
            ledger.openerV2SentByAgentId = agentId
            ledger.openerV2MessageIds = messageIds
            ledger.openerV2Version = version
            ledger.openerV2Topics = topics
            storage.ownerOpenerLedgers[key] = ledger
        }
    }

    /// Upstream `pickOnboardingAgent` self-heal for a stale/deleted reference.
    /// Never invents a replacement; only clears the unusable pointer.
    func clearOnboardingAgent(serverId: String) {
        mutex.withLock { storage in
            guard var server = storage.serverOnboardingSettings[serverId] else { return }
            server.agentId = nil
            storage.serverOnboardingSettings[serverId] = server
        }
    }
}
