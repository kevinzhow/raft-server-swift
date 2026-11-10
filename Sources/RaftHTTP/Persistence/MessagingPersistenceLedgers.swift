import Foundation

extension InboxFactStore {
    func exportPersistenceData() throws -> Data {
        let captured = persistenceFactsSnapshot
        return try MessagingPersistenceFormat.encode(
            MessagingPersistenceInboxSnapshot(facts: captured.map(MessagingPersistenceStoredInboxFactDTO.init)),
            owner: MessagingPersistenceInboxSnapshot.owner
        )
    }

    /// Replaces the complete ordered ledger, including empty snapshots and
    /// duplicate facts; append would leave rows from the previous process.
    func restorePersistenceData(from data: Data) throws {
        let payload = try MessagingPersistenceFormat.decode(
            MessagingPersistenceInboxSnapshot.self, from: data, owner: MessagingPersistenceInboxSnapshot.owner
        )
        let replacement = payload.facts.map(\.value)
        persistenceFactsSnapshot = replacement
    }
}

extension ThreadFollowStore {
    func exportPersistenceData() throws -> Data {
        let captured = persistenceRowsSnapshot
        return try MessagingPersistenceFormat.encode(
            MessagingPersistenceThreadFollowSnapshot(rows: captured.mapValues(MessagingPersistenceAgentThreadFollowRecordDTO.init)),
            owner: MessagingPersistenceThreadFollowSnapshot.owner
        )
    }

    /// Preserve actual keys, followed/done/unfollowed timestamps and all rows.
    /// Upsert or key reconstruction would not restore the original dictionary.
    func restorePersistenceData(from data: Data) throws {
        let payload = try MessagingPersistenceFormat.decode(
            MessagingPersistenceThreadFollowSnapshot.self, from: data, owner: MessagingPersistenceThreadFollowSnapshot.owner
        )
        let replacement = payload.rows.mapValues(\.value)
        persistenceRowsSnapshot = replacement
    }
}

private struct MessagingPersistenceInboxSnapshot: Codable, Sendable {
    static let owner = "inbox-facts"
    let facts: [MessagingPersistenceStoredInboxFactDTO]
}

private struct MessagingPersistenceThreadFollowSnapshot: Codable, Sendable {
    static let owner = "thread-follows"
    let rows: [String: MessagingPersistenceAgentThreadFollowRecordDTO]
}
