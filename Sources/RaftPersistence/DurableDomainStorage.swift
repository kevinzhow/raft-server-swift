import Crypto
import Foundation
import PostgresNIO

extension PostgresPersistence {
    public func read(_ key: DurableKey) async throws -> DurableDocument? {
        try await withConnection(operation: "read") { connection, logger in
            try await Self.document(key, on: connection, logger: logger)
        }
    }

    /// Return existing live rows in canonical key order from one database
    /// snapshot. Missing rows are omitted. Supply all keys used by a command.
    /// The returned payloads together must fit the 16 MiB transaction budget.
    public func readSnapshot(_ keys: [DurableKey]) async throws -> [DurableDocument] {
        guard !keys.isEmpty, keys.count <= 256, Set(keys).count == keys.count else {
            throw PersistenceError.invalidBatch
        }
        let ordered = keys.sorted { $0.orderingKey < $1.orderingKey }
        return try await withConnection(operation: "snapshot") { connection, logger in
            try await connection.withTransaction(logger: logger) { connection in
                try await PersistenceSchema.drain(
                    "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
                    on: connection, logger: logger
                )
                var result: [DurableDocument] = []
                var payloadBytes = 0
                for key in ordered {
                    if let row = try await Self.document(key, on: connection, logger: logger) {
                        payloadBytes += row.json.count
                        guard payloadBytes <= PersistenceLimits.maximumTransactionPayloadBytes else {
                            throw PersistenceError.transactionTooLarge
                        }
                        result.append(row)
                    }
                }
                return result
            }
        }
    }

    /// Commit an entire command's write set atomically. Include every additional
    /// read dependency in checking. Publish socket/Redis effects only after this
    /// method returns. On conflict or serialization failure re-read and execute
    /// the business command again; never retry an already-mutated owner snapshot.
    /// An unknown commit result requires durable reconciliation/idempotency.
    /// Once a writer epoch has ever been claimed in this database, nil epoch is
    /// rejected. Fenced writes use that lease's dedicated session. Effects append
    /// before COMMIT in the same transaction; duplicate IDs abort all writes.
    public func compareAndSwap(
        _ writes: [DurableWrite], checking conditions: [DurableCondition] = [],
        expectedWriterEpoch: Int64? = nil, effects: [DurableEffect] = []
    ) async throws -> [DurableRevision] {
        guard !writes.isEmpty, writes.count <= 256, conditions.count <= 256,
              Set(writes.map(\.key)).count == writes.count,
              Set(conditions.map(\.key)).count == conditions.count else {
            throw PersistenceError.invalidBatch
        }
        guard effects.count <= PersistenceLimits.maximumEffectsPerTransaction,
              Set(effects.map(\.effectID)).count == effects.count else {
            throw PersistenceError.invalidEffect
        }
        if !effects.isEmpty, expectedWriterEpoch == nil { throw PersistenceError.writerLeaseRequired }
        var payloadBytes = 0
        for write in writes {
            if case .put(_, let json) = write.operation { payloadBytes += json.utf8.count }
        }
        for effect in effects { payloadBytes += effect.payload.count }
        guard payloadBytes <= PersistenceLimits.maximumTransactionPayloadBytes else {
            throw PersistenceError.transactionTooLarge
        }
        var expectations: [DurableKey: DurableCondition] = [:]
        for condition in conditions { expectations[condition.key] = condition }
        for write in writes {
            if let prior = expectations[write.key], prior.expectedRevision != write.expectedRevision {
                throw PersistenceError.invalidBatch
            }
            expectations[write.key] = try DurableCondition(key: write.key, expectedRevision: write.expectedRevision)
        }
        guard expectations.count <= 256 else { throw PersistenceError.invalidBatch }
        let checked = expectations.values.sorted { $0.key.orderingKey < $1.key.orderingKey }
        let orderedWrites = writes.sorted { $0.key.orderingKey < $1.key.orderingKey }
        // Sort actual lock identities, not keys: hash collisions only serialize
        // unrelated work and cannot reverse lock order across different batches.
        let locks = Set(checked.map { Self.lockID($0.key) }).sorted()
        return try await withWriteConnection(
            expectedWriterEpoch: expectedWriterEpoch, operation: "compare-and-swap"
        ) { connection, logger in
            try await connection.withTransaction(logger: logger) { connection in
                try await PersistenceSchema.drain(
                    "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", on: connection, logger: logger
                )
                try await WriterFence.validate(
                    expectedEpoch: expectedWriterEpoch, on: connection, logger: logger
                )
                for lock in locks {
                    // PostgreSQL's two-int key space is separate from the bigint
                    // key space used by schema migration locking.
                    let namespace: Int32 = 1_380_001_364
                    try await PersistenceSchema.drain(
                        "SELECT pg_advisory_xact_lock(\(namespace), \(lock))", on: connection, logger: logger
                    )
                }
                for condition in checked {
                    let actual = try await Self.liveRevision(condition.key, on: connection, logger: logger)
                    guard actual == condition.expectedRevision else {
                        throw PersistenceError.conflict(expected: condition.expectedRevision, actual: actual)
                    }
                }
                var result: [DurableRevision] = []
                for write in orderedWrites {
                    result.append(try await Self.apply(write, on: connection, logger: logger))
                }
                if let expectedWriterEpoch {
                    for effect in effects {
                        try await DurableOutbox.insert(
                            effect, writerEpoch: expectedWriterEpoch, on: connection, logger: logger
                        )
                    }
                }
                return result
            }
        }
    }

    private static func document(
        _ key: DurableKey, on connection: PostgresConnection, logger: Logger
    ) async throws -> DurableDocument? {
        let domain = key.domain.rawValue
        let id = key.aggregateID
        let query: PostgresQuery = """
        SELECT revision, codec_version::bigint, payload::text, updated_at
        FROM raft_persistence.durable_domain_rows
        WHERE domain = \(domain) AND aggregate_key = \(id) AND NOT deleted
        """
        var result: DurableDocument?
        for try await row in try await connection.query(query, logger: logger) {
            let (revision, version, json, updatedAt) = try row.decode((Int64, Int64, String, Date).self)
            guard result == nil, revision > 0, version > 0, version <= Int64(Int32.max),
                  json.utf8.count <= 16 * 1024 * 1024 else { throw PersistenceError.invalidDocument }
            result = DurableDocument(
                key: key, revision: revision, codecVersion: Int(version), updatedAt: updatedAt,
                json: Data(json.utf8)
            )
        }
        return result
    }

    private static func liveRevision(
        _ key: DurableKey, on connection: PostgresConnection, logger: Logger
    ) async throws -> Int64? {
        let domain = key.domain.rawValue
        let id = key.aggregateID
        var result: Int64?
        for try await row in try await connection.query(
            "SELECT revision FROM raft_persistence.durable_domain_rows WHERE domain = \(domain) AND aggregate_key = \(id) AND NOT deleted",
            logger: logger
        ) { result = try row.decode(Int64.self) }
        return result
    }

    private static func apply(
        _ write: DurableWrite, on connection: PostgresConnection, logger: Logger
    ) async throws -> DurableRevision {
        let domain = write.key.domain.rawValue
        let id = write.key.aggregateID
        let query: PostgresQuery
        let deleted: Bool
        switch write.operation {
        case .put(let codecVersion, let json):
            deleted = false
            if let expected = write.expectedRevision {
                query = """
                UPDATE raft_persistence.durable_domain_rows
                SET revision = revision + 1, codec_version = \(codecVersion), payload = \(json)::jsonb,
                    deleted = FALSE, updated_at = clock_timestamp()
                WHERE domain = \(domain) AND aggregate_key = \(id) AND revision = \(expected) AND NOT deleted
                RETURNING revision
                """
            } else {
                query = """
                INSERT INTO raft_persistence.durable_domain_rows AS existing
                    (domain, aggregate_key, revision, codec_version, payload, deleted)
                VALUES (\(domain), \(id), 1, \(codecVersion), \(json)::jsonb, FALSE)
                ON CONFLICT (domain, aggregate_key) DO UPDATE
                SET revision = existing.revision + 1, codec_version = EXCLUDED.codec_version,
                    payload = EXCLUDED.payload, deleted = FALSE, updated_at = clock_timestamp()
                WHERE existing.deleted
                RETURNING revision
                """
            }
        case .delete:
            guard let expected = write.expectedRevision else { throw PersistenceError.invalidRevision }
            deleted = true
            query = """
            UPDATE raft_persistence.durable_domain_rows
            SET revision = revision + 1, payload = NULL, deleted = TRUE, updated_at = clock_timestamp()
            WHERE domain = \(domain) AND aggregate_key = \(id) AND revision = \(expected) AND NOT deleted
            RETURNING revision
            """
        }
        var revision: Int64?
        for try await row in try await connection.query(query, logger: logger) {
            revision = try row.decode(Int64.self)
        }
        guard let revision else {
            let actual = try await liveRevision(write.key, on: connection, logger: logger)
            throw PersistenceError.conflict(expected: write.expectedRevision, actual: actual)
        }
        return DurableRevision(key: write.key, revision: revision, deleted: deleted)
    }

    private static func lockID(_ key: DurableKey) -> Int32 {
        let hash = SHA256.hash(data: Data(key.orderingKey.utf8))
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int32(bitPattern: value)
    }
}
