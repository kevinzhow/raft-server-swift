import Crypto
import Foundation
import PostgresNIO

struct PersistenceSchema: Sendable {
    static let currentVersion: Int64 = 2
    // Distinct from the domain-key lock namespace. Transaction-scoped and shared
    // by all processes that run this schema's migrations.
    static let migrationLock: Int64 = 5_927_113_626_123_820_101

    struct Migration: Sendable {
        let version: Int64
        let name: String
        let statements: [String]

        var checksum: String {
            let fields = [String(version), name] + PersistenceSchema.bootstrap + statements
            let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
            return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    static let bootstrap: [String] = [
        "CREATE SCHEMA IF NOT EXISTS raft_persistence",
        """
        CREATE TABLE IF NOT EXISTS raft_persistence.schema_versions (
            version BIGINT PRIMARY KEY CHECK (version > 0),
            name TEXT NOT NULL,
            checksum TEXT NOT NULL CHECK (length(checksum) = 64),
            applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
        )
        """
    ]

    static let migrations: [Migration] = [
        Migration(version: 1, name: "durable_domain_rows", statements: [
            """
            CREATE TABLE raft_persistence.durable_domain_rows (
                domain TEXT NOT NULL CHECK (domain IN (
                    'auth_profiles', 'notifications', 'product_events', 'inbox_facts',
                    'thread_follows', 'messages_and_threads', 'agents_runtime',
                    'tasks_and_reminders', 'machines_and_computers', 'servers_and_channels',
                    'managed_mcp_and_cards', 'feedback', 'oauth_ledger'
                )),
                aggregate_key TEXT NOT NULL CHECK (
                    octet_length(aggregate_key) BETWEEN 1 AND 512
                ),
                revision BIGINT NOT NULL CHECK (revision > 0),
                codec_version INTEGER NOT NULL CHECK (codec_version > 0),
                payload JSONB,
                deleted BOOLEAN NOT NULL DEFAULT FALSE,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
                PRIMARY KEY (domain, aggregate_key),
                CHECK ((deleted AND payload IS NULL) OR (NOT deleted AND payload IS NOT NULL)),
                CHECK (payload IS NULL OR octet_length(payload::text) <= 16777216)
            )
            """
        ]),
        Migration(version: 2, name: "writer_fencing_and_durable_outbox", statements: [
            """
            CREATE TABLE raft_persistence.writer_control (
                singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
                writer_epoch BIGINT NOT NULL DEFAULT 0 CHECK (writer_epoch >= 0),
                writer_id UUID,
                backend_pid INTEGER,
                claimed_at TIMESTAMPTZ,
                CHECK ((writer_epoch = 0 AND writer_id IS NULL AND backend_pid IS NULL)
                    OR (writer_epoch > 0 AND writer_id IS NOT NULL AND backend_pid IS NOT NULL))
            )
            """,
            "INSERT INTO raft_persistence.writer_control (singleton) VALUES (TRUE)",
            """
            CREATE TABLE raft_persistence.durable_outbox (
                effect_id UUID PRIMARY KEY,
                sequence BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
                kind TEXT NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_.-]{0,63}$'),
                payload BYTEA NOT NULL CHECK (octet_length(payload) <= 1048576),
                created_at TIMESTAMPTZ NOT NULL,
                writer_epoch BIGINT NOT NULL CHECK (writer_epoch > 0),
                attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 10),
                next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
                claim_token UUID,
                claimed_writer_epoch BIGINT,
                claim_expires_at TIMESTAMPTZ,
                delivered_at TIMESTAMPTZ,
                exhausted_at TIMESTAMPTZ,
                last_failure TEXT CHECK (last_failure IN (
                    'unavailable', 'rejected', 'timedOut', 'cancelled', 'unknownOutcome'
                )),
                CHECK ((claim_token IS NULL AND claimed_writer_epoch IS NULL AND claim_expires_at IS NULL)
                    OR (claim_token IS NOT NULL AND claimed_writer_epoch > 0 AND claim_expires_at IS NOT NULL)),
                CHECK (delivered_at IS NULL OR exhausted_at IS NULL)
            )
            """,
            """
            CREATE INDEX durable_outbox_pending ON raft_persistence.durable_outbox
                (next_attempt_at, sequence)
                WHERE delivered_at IS NULL AND exhausted_at IS NULL
            """
        ])
    ]

    static func migrate(on connection: PostgresConnection, logger: Logger) async throws {
        try await connection.withTransaction(logger: logger) { connection in
            // Each statement after waiting for the migration lock must observe the
            // previous migrator's committed schema, rather than an older snapshot.
            try await drain("SET TRANSACTION ISOLATION LEVEL READ COMMITTED", on: connection, logger: logger)
            try await drain("SELECT pg_advisory_xact_lock(\(migrationLock))", on: connection, logger: logger)
            for statement in bootstrap {
                try await drain(PostgresQuery(unsafeSQL: statement), on: connection, logger: logger)
            }
            let applied = try await records(on: connection, logger: logger)
            try validate(applied, requireCurrent: false)
            for migration in migrations.dropFirst(applied.count) {
                for statement in migration.statements {
                    try await drain(PostgresQuery(unsafeSQL: statement), on: connection, logger: logger)
                }
                let version = migration.version
                let name = migration.name
                let checksum = migration.checksum
                try await drain(
                    "INSERT INTO raft_persistence.schema_versions (version, name, checksum) VALUES (\(version), \(name), \(checksum))",
                    on: connection, logger: logger
                )
            }
        }
    }

    static func verify(on connection: PostgresConnection, logger: Logger) async throws {
        try validate(try await records(on: connection, logger: logger), requireCurrent: true)
        try await drain(
            "SELECT domain, aggregate_key, revision, codec_version, payload, deleted, updated_at FROM raft_persistence.durable_domain_rows LIMIT 0",
            on: connection, logger: logger
        )
        var writerRows = 0
        for try await _ in try await connection.query(
            "SELECT writer_epoch, writer_id, backend_pid, claimed_at FROM raft_persistence.writer_control WHERE singleton",
            logger: logger
        ) { writerRows += 1 }
        guard writerRows == 1 else { throw PersistenceError.schemaNotCurrent }
        try await drain(
            "SELECT effect_id, sequence, kind, payload, created_at, writer_epoch, attempts, next_attempt_at, claim_token, claimed_writer_epoch, claim_expires_at, delivered_at, exhausted_at, last_failure FROM raft_persistence.durable_outbox LIMIT 0",
            on: connection, logger: logger
        )
    }

    private static func records(
        on connection: PostgresConnection, logger: Logger
    ) async throws -> [(Int64, String, String)] {
        var result: [(Int64, String, String)] = []
        for try await row in try await connection.query(
            "SELECT version, name, checksum FROM raft_persistence.schema_versions ORDER BY version",
            logger: logger
        ) {
            result.append(try row.decode((Int64, String, String).self))
        }
        return result
    }

    private static func validate(_ records: [(Int64, String, String)], requireCurrent: Bool) throws {
        guard records.count <= migrations.count else {
            throw PersistenceError.schemaMismatch(version: records.last?.0 ?? 0)
        }
        for (index, row) in records.enumerated() {
            let expected = migrations[index]
            guard row.0 == expected.version, row.1 == expected.name, row.2 == expected.checksum else {
                throw PersistenceError.schemaMismatch(version: row.0)
            }
        }
        if requireCurrent, records.count != migrations.count { throw PersistenceError.schemaNotCurrent }
    }

    static func drain(_ query: PostgresQuery, on connection: PostgresConnection, logger: Logger) async throws {
        for try await _ in try await connection.query(query, logger: logger) {}
    }
}

/// Convert driver errors at the module boundary so callers cannot accidentally
/// print SQL bindings containing account secrets. Keep SQLSTATE for retry policy.
func persistenceFailure(_ error: any Error, operation: String) -> any Error {
    if let error = error as? PersistenceError { return error }
    if error is CancellationError { return CancellationError() }
    if let transaction = error as? PostgresTransactionError {
        if let commit = transaction.commitError {
            let state = (commit as? PSQLError)?.serverInfo?[.sqlState]
            if state == "40001" || state == "40P01" {
                if transaction.rollbackError != nil { return PersistenceError.rollbackFailed }
                return PersistenceError.database(operation: operation, sqlState: state, driverCode: "transaction")
            }
            return PersistenceError.commitOutcomeUnknown(sqlState: state)
        }
        if transaction.rollbackError != nil { return PersistenceError.rollbackFailed }
        if let cause = transaction.closureError ?? transaction.beginError {
            return persistenceFailure(cause, operation: operation)
        }
    }
    if let postgres = error as? PSQLError {
        return PersistenceError.database(
            operation: operation, sqlState: postgres.serverInfo?[.sqlState], driverCode: postgres.code.description
        )
    }
    return PersistenceError.database(operation: operation, sqlState: nil, driverCode: "transport or decoding")
}
