import Foundation
import PostgresNIO

/// PostgreSQL, rather than Redis or a process-local counter, owns this epoch.
/// The bigint lock namespace is distinct from domain two-int transaction locks.
enum WriterFence {
    static let sessionLock: Int64 = 5_927_113_626_123_820_102

    static func holdsSessionLock(on connection: PostgresConnection, logger: Logger) async throws -> Bool {
        let high = sessionLock >> 32
        let low = sessionLock & 0xffff_ffff
        var held = false
        for try await row in try await connection.query("""
            SELECT EXISTS (
                SELECT 1 FROM pg_locks
                WHERE locktype = 'advisory' AND pid = pg_backend_pid()
                    AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
                    AND classid = \(high)::oid AND objid = \(low)::oid AND objsubid = 1
                    AND mode = 'ExclusiveLock' AND granted
            )
            """, logger: logger) { held = try row.decode(Bool.self) }
        return held
    }

    /// Invoke inside the business SERIALIZABLE transaction, before any writes.
    /// FOR SHARE prevents a replacement epoch from being claimed until the old
    /// transaction ends. A snapshot predating a claim receives serialization
    /// failure, never a successful stale-epoch commit after that claim returns.
    static func validate(
        expectedEpoch: Int64?, on connection: PostgresConnection, logger: Logger
    ) async throws {
        var current: (Int64, Int64?)?
        for try await row in try await connection.query("""
            SELECT writer_epoch, backend_pid::bigint
            FROM raft_persistence.writer_control WHERE singleton FOR SHARE
            """, logger: logger) {
            guard current == nil else { throw PersistenceError.schemaNotCurrent }
            current = try row.decode((Int64, Int64?).self)
        }
        guard let (epoch, pid) = current else { throw PersistenceError.schemaNotCurrent }
        if let expectedEpoch {
            guard expectedEpoch > 0, epoch == expectedEpoch else {
                throw PersistenceError.writerEpochMismatch
            }
            var sameBackend = false
            for try await backend in try await connection.query(
                "SELECT pg_backend_pid()::bigint", logger: logger
            ) { sameBackend = try backend.decode(Int64.self) == pid }
            guard sameBackend, try await holdsSessionLock(on: connection, logger: logger) else {
                throw PersistenceError.writerLeaseLost
            }
        } else {
            // Backwards compatibility is only available before the database
            // has ever enabled single-writer mode. It cannot bypass fencing.
            guard epoch == 0 else { throw PersistenceError.writerLeaseRequired }
        }
    }
}
