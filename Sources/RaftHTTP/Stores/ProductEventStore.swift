import Foundation

/// Owns product/client event facts behind its own lock.
///
/// R3 store extraction: `EmailLoginDirectory` keeps the HTTP/auth/analytics
/// decisions; this store only owns the ledger rows and the client-event
/// idempotency set, so event traffic no longer shares the directory lock.
final class ProductEventStore: @unchecked Sendable {
    private let lock = NSLock()
    private var productEvents: [RecordedProductEvent] = []
    private var clientEvents: [ClientEventRecord] = []
    private var seenClientEventIDs: Set<String> = []

    func append(_ event: RecordedProductEvent) {
        lock.lock()
        productEvents.append(event)
        lock.unlock()
    }

    func productEvents(subjectId: String) -> [RecordedProductEvent] {
        lock.lock()
        defer { lock.unlock() }
        return productEvents.filter { $0.subjectId == subjectId }
    }

    func clientEvents(serverId: String) -> [ClientEventRecord] {
        lock.lock()
        defer { lock.unlock() }
        return clientEvents.filter { $0.serverId == serverId }
    }

    func containsSeenClientEvent(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seenClientEventIDs.contains(id)
    }

    /// Appends accepted rows and records every syntactically valid batch id as
    /// seen in one critical section, matching the original batch semantics.
    func appendClientEvents(_ rows: [ClientEventRecord], seenIDs: [String]) {
        lock.lock()
        clientEvents.append(contentsOf: rows)
        seenClientEventIDs.formUnion(seenIDs)
        lock.unlock()
    }
}

extension ProductEventStore {
    /// One event of a client batch that already passed validation, with the
    /// batch id the idempotency set tracks and the row to store when it is new.
    struct ClientEventCandidate: Sendable {
        let eventId: String
        let record: ClientEventRecord
    }

    /// Admits a validated batch: a candidate whose id was already seen (in an
    /// earlier batch or earlier in this one) is dropped, the rest append, and
    /// every syntactically valid batch id (`seenIDs`) joins the seen set, all in
    /// one critical section. Two concurrent deliveries of the same batch
    /// therefore store its events once. Returns the number of rows appended.
    func admitClientEvents(_ candidates: [ClientEventCandidate], seenIDs: [String]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var admitted: [ClientEventRecord] = []
        var batchSeen: Set<String> = []
        for candidate in candidates {
            if seenClientEventIDs.contains(candidate.eventId) || !batchSeen.insert(candidate.eventId).inserted {
                continue
            }
            admitted.append(candidate.record)
        }
        clientEvents.append(contentsOf: admitted)
        seenClientEventIDs.formUnion(seenIDs)
        return admitted.count
    }
}
