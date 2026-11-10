import Foundation
import PostgresNIO

extension PostgresPersistence {
    /// Inspection only. This does not grant permission to dispatch an effect.
    /// Returns due, unclaimed/expired entries; at most 100 MiB of payload per call.
    public func pendingOutbox(limit: Int = 32) async throws -> [DurableOutboxEntry] {
        try DurableOutbox.validateLimit(limit)
        return try await withConnection(operation: "outbox pending") { connection, logger in
            var result: [DurableOutboxEntry] = []
            for try await row in try await connection.query("""
                SELECT effect_id, kind, payload, created_at, sequence, writer_epoch,
                    attempts::bigint, next_attempt_at, delivered_at, exhausted_at, last_failure,
                    claim_token, claimed_writer_epoch, claim_expires_at
                FROM raft_persistence.durable_outbox
                WHERE delivered_at IS NULL AND exhausted_at IS NULL AND attempts < 10
                    AND next_attempt_at <= clock_timestamp()
                    AND (claim_token IS NULL OR claim_expires_at <= clock_timestamp())
                ORDER BY sequence LIMIT \(limit)
                """, logger: logger) { result.append(try DurableOutbox.decode(row).entry) }
            return result
        }
    }

    /// Reconciliation for an unknown CAS/dispatch acknowledgement outcome.
    /// Absence alone is not permission to replay a command: reconcile its read
    /// set/revisions too. This retains delivered and exhausted entries.
    public func outboxEffect(effectID: UUID) async throws -> DurableOutboxEntry? {
        try await withConnection(operation: "outbox reconciliation") { connection, logger in
            var result: DurableOutboxEntry?
            for try await row in try await connection.query("""
                SELECT effect_id, kind, payload, created_at, sequence, writer_epoch,
                    attempts::bigint, next_attempt_at, delivered_at, exhausted_at, last_failure,
                    claim_token, claimed_writer_epoch, claim_expires_at
                FROM raft_persistence.durable_outbox WHERE effect_id = \(effectID)
                """, logger: logger) { result = try DurableOutbox.decode(row).entry }
            return result
        }
    }

    /// Claims are transactionally fenced and expire after 1...300 seconds.
    /// Attempts count claims, including an executor crash after sending. A new
    /// writer must wait for any old claim's expiry; receivers deduplicate effectID.
    public func claimOutbox(
        expectedWriterEpoch: Int64, kinds: Set<DurableEffectKind>? = nil,
        limit: Int = 32, visibilityTimeoutSeconds: Int = 30
    ) async throws -> [DurableOutboxClaim] {
        try DurableOutbox.validateLimit(limit)
        guard (1...300).contains(visibilityTimeoutSeconds) else { throw PersistenceError.invalidOutboxRequest }
        if let kinds, kinds.isEmpty || kinds.count > 64 { throw PersistenceError.invalidOutboxRequest }
        let claimAll = kinds == nil
        let acceptedKinds = kinds?.map(\.rawValue).sorted() ?? []
        let token = UUID()
        return try await withOutboxTransaction(expectedWriterEpoch: expectedWriterEpoch, operation: "outbox claim") {
            connection, logger in
            // Persist an observable terminal state when the last executor died
            // without recording failure. Entries are never silently deleted.
            try await PersistenceSchema.drain("""
                UPDATE raft_persistence.durable_outbox
                SET exhausted_at = clock_timestamp(), last_failure = 'unknownOutcome',
                    claim_token = NULL, claimed_writer_epoch = NULL, claim_expires_at = NULL
                WHERE delivered_at IS NULL AND exhausted_at IS NULL AND attempts >= 10
                    AND (\(claimAll) OR kind = ANY(\(acceptedKinds)::text[]))
                    AND (claim_token IS NULL OR claim_expires_at <= clock_timestamp())
                """, on: connection, logger: logger)
            var claims: [DurableOutboxClaim] = []
            for try await row in try await connection.query("""
                WITH candidates AS (
                    SELECT effect_id FROM raft_persistence.durable_outbox
                    WHERE delivered_at IS NULL AND exhausted_at IS NULL AND attempts < 10
                        AND (\(claimAll) OR kind = ANY(\(acceptedKinds)::text[]))
                        AND next_attempt_at <= clock_timestamp()
                        AND (claim_token IS NULL OR claim_expires_at <= clock_timestamp())
                    ORDER BY sequence LIMIT \(limit) FOR UPDATE SKIP LOCKED
                )
                UPDATE raft_persistence.durable_outbox AS outbox
                SET claim_token = \(token), claimed_writer_epoch = \(expectedWriterEpoch),
                    claim_expires_at = clock_timestamp() + make_interval(secs => \(visibilityTimeoutSeconds)::double precision),
                    attempts = outbox.attempts + 1
                FROM candidates WHERE outbox.effect_id = candidates.effect_id
                RETURNING outbox.effect_id, outbox.kind, outbox.payload, outbox.created_at,
                    outbox.sequence, outbox.writer_epoch, outbox.attempts::bigint,
                    outbox.next_attempt_at, outbox.delivered_at, outbox.exhausted_at,
                    outbox.last_failure, outbox.claim_token, outbox.claimed_writer_epoch, outbox.claim_expires_at
                """, logger: logger) {
                let stored = try DurableOutbox.decode(row)
                guard let claimToken = stored.token, let claimedEpoch = stored.claimedEpoch,
                      let expiresAt = stored.expiresAt else { throw PersistenceError.invalidEffect }
                claims.append(DurableOutboxClaim(
                    entry: stored.entry, claimToken: claimToken, claimedWriterEpoch: claimedEpoch, expiresAt: expiresAt
                ))
            }
            return claims.sorted { $0.entry.sequence < $1.entry.sequence }
        }
    }

    /// Return a claim that has not begun external dispatch to the due queue.
    /// This refunds exactly this reservation, never an earlier send attempt.
    /// A repeated, expired or foreign-writer deferral cannot change the budget.
    public func deferOutbox(
        _ claim: DurableOutboxClaim, expectedWriterEpoch: Int64, retryAfterSeconds: Int = 5
    ) async throws {
        guard (1...300).contains(retryAfterSeconds) else { throw PersistenceError.invalidOutboxRequest }
        guard claim.claimedWriterEpoch == expectedWriterEpoch,
              (1...PersistenceLimits.maximumOutboxAttempts).contains(claim.entry.attempts) else {
            throw PersistenceError.outboxClaimLost
        }
        let id = claim.entry.effect.effectID
        let token = claim.claimToken
        let attempts = claim.entry.attempts
        try await withOutboxTransaction(expectedWriterEpoch: expectedWriterEpoch, operation: "outbox defer") {
            connection, logger in
            var updated = false
            for try await row in try await connection.query("""
                UPDATE raft_persistence.durable_outbox
                SET attempts = attempts - 1,
                    next_attempt_at = clock_timestamp() + make_interval(secs => \(retryAfterSeconds)::double precision),
                    claim_token = NULL, claimed_writer_epoch = NULL, claim_expires_at = NULL
                WHERE effect_id = \(id) AND claim_token = \(token)
                    AND claimed_writer_epoch = \(expectedWriterEpoch) AND attempts = \(attempts)
                    AND claim_expires_at > clock_timestamp()
                    AND delivered_at IS NULL AND exhausted_at IS NULL
                RETURNING effect_id
                """, logger: logger) { _ = try row.decode(UUID.self); updated = true }
            guard updated else { throw PersistenceError.outboxClaimLost }
        }
    }

    /// An acknowledgement is fenced by the active epoch and the exact unexpired
    /// claim. Sending succeeded but acknowledgement failed can cause a later resend.
    public func markDelivered(_ claim: DurableOutboxClaim, expectedWriterEpoch: Int64) async throws {
        guard claim.claimedWriterEpoch == expectedWriterEpoch else { throw PersistenceError.outboxClaimLost }
        let id = claim.entry.effect.effectID
        let token = claim.claimToken
        try await withOutboxTransaction(expectedWriterEpoch: expectedWriterEpoch, operation: "outbox delivered") {
            connection, logger in
            var updated = false
            for try await row in try await connection.query("""
                UPDATE raft_persistence.durable_outbox
                SET delivered_at = clock_timestamp(), claim_token = NULL,
                    claimed_writer_epoch = NULL, claim_expires_at = NULL
                WHERE effect_id = \(id) AND claim_token = \(token)
                    AND claimed_writer_epoch = \(expectedWriterEpoch)
                    AND claim_expires_at > clock_timestamp()
                    AND delivered_at IS NULL AND exhausted_at IS NULL
                RETURNING effect_id
                """, logger: logger) { _ = try row.decode(UUID.self); updated = true }
            guard updated else { throw PersistenceError.outboxClaimLost }
        }
    }

    /// Records only a bounded enum; never pass executor errors or token-bearing
    /// URLs. Retry delay is 1,2,4,...256,300 seconds, at most ten dispatch claims.
    public func recordFailure(
        _ claim: DurableOutboxClaim, expectedWriterEpoch: Int64, code: OutboxFailureCode
    ) async throws {
        guard claim.claimedWriterEpoch == expectedWriterEpoch,
              (1...PersistenceLimits.maximumOutboxAttempts).contains(claim.entry.attempts) else {
            throw PersistenceError.outboxClaimLost
        }
        let id = claim.entry.effect.effectID
        let token = claim.claimToken
        let failure = code.rawValue
        let delay = min(300, 1 << (claim.entry.attempts - 1))
        try await withOutboxTransaction(expectedWriterEpoch: expectedWriterEpoch, operation: "outbox failure") {
            connection, logger in
            var updated = false
            for try await row in try await connection.query("""
                UPDATE raft_persistence.durable_outbox
                SET last_failure = \(failure),
                    next_attempt_at = clock_timestamp() + make_interval(secs => \(delay)::double precision),
                    exhausted_at = CASE WHEN attempts >= 10 THEN clock_timestamp() ELSE NULL END,
                    claim_token = NULL, claimed_writer_epoch = NULL, claim_expires_at = NULL
                WHERE effect_id = \(id) AND claim_token = \(token)
                    AND claimed_writer_epoch = \(expectedWriterEpoch)
                    AND claim_expires_at > clock_timestamp()
                    AND delivered_at IS NULL AND exhausted_at IS NULL
                RETURNING effect_id
                """, logger: logger) { _ = try row.decode(UUID.self); updated = true }
            guard updated else { throw PersistenceError.outboxClaimLost }
        }
    }

    private func withOutboxTransaction<Value: Sendable>(
        expectedWriterEpoch: Int64, operation name: String,
        _ operation: @escaping @Sendable (PostgresConnection, Logger) async throws -> Value
    ) async throws -> Value {
        try await withWriteConnection(expectedWriterEpoch: expectedWriterEpoch, operation: name) { connection, logger in
            try await connection.withTransaction(logger: logger) { connection in
                try await PersistenceSchema.drain(
                    "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", on: connection, logger: logger
                )
                try await WriterFence.validate(expectedEpoch: expectedWriterEpoch, on: connection, logger: logger)
                return try await operation(connection, logger)
            }
        }
    }
}

/// Internal SQL/row projection only. No dispatcher or process-local queue.
enum DurableOutbox {
    static func validateLimit(_ limit: Int) throws {
        guard (1...PersistenceLimits.maximumOutboxBatch).contains(limit) else {
            throw PersistenceError.invalidOutboxRequest
        }
    }

    static func insert(
        _ effect: DurableEffect, writerEpoch: Int64, on connection: PostgresConnection, logger: Logger
    ) async throws {
        let id = effect.effectID
        let kind = effect.kind.rawValue
        let payload = effect.payload
        let created = effect.createdAt
        // A duplicate ID aborts the entire business transaction. Do not swallow
        // ON CONFLICT: that could commit a second mutation without its effect.
        try await PersistenceSchema.drain("""
            INSERT INTO raft_persistence.durable_outbox
                (effect_id, kind, payload, created_at, writer_epoch)
            VALUES (\(id), \(kind), \(payload), \(created), \(writerEpoch))
            """, on: connection, logger: logger)
    }

    struct Stored: Sendable {
        let entry: DurableOutboxEntry
        let token: UUID?
        let claimedEpoch: Int64?
        let expiresAt: Date?
    }

    static func decode(_ row: PostgresRow) throws -> Stored {
        let (id, kind, payload, created, sequence, epoch, attempts, next, delivered, exhausted, failure, token, claimed, expires) =
            try row.decode((UUID, String, Data, Date, Int64, Int64, Int64, Date, Date?, Date?, String?, UUID?, Int64?, Date?).self)
        guard sequence > 0, epoch > 0, (0...10).contains(attempts) else {
            throw PersistenceError.invalidEffect
        }
        let failureCode: OutboxFailureCode?
        if let failure {
            guard let decoded = OutboxFailureCode(rawValue: failure) else { throw PersistenceError.invalidEffect }
            failureCode = decoded
        } else { failureCode = nil }
        let effect = try DurableEffect(effectID: id, kind: DurableEffectKind(kind), payload: payload, createdAt: created)
        return Stored(entry: DurableOutboxEntry(
            effect: effect, sequence: sequence, writerEpoch: epoch, attempts: Int(attempts), nextAttemptAt: next,
            deliveredAt: delivered, exhaustedAt: exhausted, lastFailure: failureCode
        ), token: token, claimedEpoch: claimed, expiresAt: expires)
    }
}
