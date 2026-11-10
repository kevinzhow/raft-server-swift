import Foundation
import PostgresNIO

public enum WriterLeaseStatus: String, Sendable {
    case active, lost, closed
}

public struct WriterLeaseHealth: Sendable {
    public let epoch: Int64
    public let status: WriterLeaseStatus
    public let lastSuccessfulHeartbeat: Date
    public var isHealthy: Bool { status == .active }
}

/// One dedicated PostgreSQL session owns both the advisory lock and all fenced
/// write transactions. No pool replacement can silently renew its permission.
/// Claim before loading owners/opening the HTTP gate. On loss, stop admission,
/// close the lease, acquire a new one, reload, and only then reopen the gate.
public actor WriterLease {
    public nonisolated let epoch: Int64
    private let connection: PostgresConnection
    private let logger: Logger
    private let timeout: Duration
    private let heartbeatInterval: Duration
    private var status: WriterLeaseStatus = .active
    private var lastHeartbeat = Date()
    private var lastHeartbeatInstant = ContinuousClock.now
    private var busy = false
    private var heartbeatInFlight = false
    private var heartbeatWaiters: [CheckedContinuation<Void, Never>] = []
    private var heartbeatTask: Task<Void, Never>?
    private var closeMonitor: Task<Void, Never>?

    private init(
        epoch: Int64, connection: PostgresConnection, logger: Logger,
        timeout: Duration, heartbeatInterval: Duration
    ) {
        self.epoch = epoch
        self.connection = connection
        self.logger = logger
        self.timeout = timeout
        self.heartbeatInterval = heartbeatInterval
    }

    /// Equivalent to persistence.tryAcquireWriterLease. A competing instance
    /// returns nil, so the host must fail closed before opening its work gate.
    public static func tryAcquire(
        on persistence: PostgresPersistence, heartbeatInterval: Duration = .seconds(2)
    ) async throws -> WriterLease? {
        try await persistence.tryAcquireWriterLease(heartbeatInterval: heartbeatInterval)
    }

    static func acquire(
        configuration: PostgresPersistenceConfiguration, heartbeatInterval: Duration
    ) async throws -> WriterLease? {
        guard heartbeatInterval >= .milliseconds(100), heartbeatInterval <= .seconds(30) else {
            throw PersistenceError.invalidWriterLeaseConfiguration
        }
        let logger = Logger(label: "raft.persistence.writer")
        do {
            let config = try configuration.connectionConfiguration()
            return try await withPersistenceDeadline(configuration.operationTimeout) { () async throws -> WriterLease? in
                let connection = try await PostgresConnection.connect(configuration: config, id: 1, logger: logger)
                do {
                    return try await withTaskCancellationHandler {
                        try await PersistenceSchema.verify(on: connection, logger: logger)
                        var acquired = false
                        for try await row in try await connection.query(
                            "SELECT pg_try_advisory_lock(\(WriterFence.sessionLock))", logger: logger
                        ) { acquired = try row.decode(Bool.self) }
                        guard acquired else {
                            try await connection.close()
                            return nil
                        }
                        let writerID = UUID()
                        let epoch = try await connection.withTransaction(logger: logger) { connection in
                            try await PersistenceSchema.drain(
                                "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", on: connection, logger: logger
                            )
                            var epoch: Int64?
                            for try await row in try await connection.query("""
                                UPDATE raft_persistence.writer_control
                                SET writer_epoch = writer_epoch + 1, writer_id = \(writerID),
                                    backend_pid = pg_backend_pid(), claimed_at = clock_timestamp()
                                WHERE singleton AND writer_epoch < 9223372036854775807
                                RETURNING writer_epoch
                                """, logger: logger) { epoch = try row.decode(Int64.self) }
                            guard let epoch, epoch > 0 else { throw PersistenceError.writerEpochExhausted }
                            return epoch
                        }
                        let lease = WriterLease(
                            epoch: epoch, connection: connection, logger: logger,
                            timeout: configuration.operationTimeout, heartbeatInterval: heartbeatInterval
                        )
                        await lease.startMonitoring()
                        return lease
                    } onCancel: { connection.close().whenComplete { _ in } }
                } catch {
                    try? await connection.close()
                    throw error
                }
            }
        } catch { throw persistenceFailure(error, operation: "writer claim") }
    }

    /// This reads local admission state and the real channel's closed state.
    /// Heartbeat and close monitoring permanently revoke permission on failure.
    public func healthSnapshot() -> WriterLeaseHealth {
        if status == .active,
           connection.isClosed || lastHeartbeatInstant.duration(to: ContinuousClock.now) > timeout + heartbeatInterval {
            status = .lost
            heartbeatTask?.cancel()
            connection.close().whenComplete { _ in }
        }
        return WriterLeaseHealth(epoch: epoch, status: status, lastSuccessfulHeartbeat: lastHeartbeat)
    }

    /// Waits for socket closure; a session lock is never returned to the pool.
    public func close() async {
        guard status != .closed else { return }
        status = .closed
        heartbeatTask?.cancel()
        closeMonitor?.cancel()
        try? await connection.close()
        if let heartbeatTask { await heartbeatTask.value }
        if let closeMonitor { await closeMonitor.value }
        heartbeatTask = nil
        closeMonitor = nil
    }

    /// Reject concurrent commands rather than interleave transactions on the
    /// dedicated session. The host must serialize prepared business commits.
    func withConnection<Value: Sendable>(
        operation name: String,
        _ operation: @escaping @Sendable (PostgresConnection, Logger) async throws -> Value
    ) async throws -> Value {
        // The monitoring query owns the session only briefly. Wait for that
        // query to finish before admitting a command, without replaying SQL.
        if heartbeatInFlight {
            await withCheckedContinuation { continuation in
                heartbeatWaiters.append(continuation)
            }
        }
        try Task.checkCancellation()
        guard healthSnapshot().isHealthy else { throw PersistenceError.writerLeaseLost }
        guard !busy else { throw PersistenceError.writerBusy }
        busy = true
        defer { busy = false }
        let connection = connection
        let logger = logger
        do {
            let value = try await withPersistenceDeadline(timeout) {
                try await withTaskCancellationHandler {
                    try await operation(connection, logger)
                } onCancel: { connection.close().whenComplete { _ in } }
            }
            // A completed COMMIT is not changed to an error merely because close
            // races its response. The next admission observes terminal lease loss.
            lastHeartbeat = Date()
            lastHeartbeatInstant = ContinuousClock.now
            return value
        } catch {
            let failure = persistenceFailure(error, operation: name)
            if failure is CancellationError || (failure as? PersistenceError) == .timedOut {
                await losePermission()
                // A deadline/cancellation can race COMMIT's acknowledgement.
                // Reconcile durable state and effect IDs; never blindly replay.
                throw PersistenceError.commitOutcomeUnknown(sqlState: nil)
            }
            if let known = failure as? PersistenceError {
                switch known {
                case .conflict, .outboxClaimLost, .invalidEffect, .invalidBatch,
                     .invalidDocument, .invalidRevision, .invalidCodecVersion, .documentTooLarge,
                     .transactionTooLarge:
                    break // The driver completed rollback; no connection replacement.
                case .database(_, let sqlState, _) where sqlState != nil && !connection.isClosed:
                    break // Known server rejection after a completed rollback.
                default:
                    await losePermission()
                }
            } else { await losePermission() }
            throw failure
        }
    }

    private func startMonitoring() {
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard await self?.heartbeat() == true else { return }
            }
        }
        let connection = connection
        closeMonitor = Task { [weak self] in
            try? await connection.closeFuture.get()
            await self?.connectionDidClose()
        }
    }

    private func heartbeat() async -> Bool {
        guard healthSnapshot().isHealthy else { return false }
        // The active command has its own deadline and uses this same session.
        // Do not insert a heartbeat SELECT into its transaction or result stream.
        if busy { return true }
        busy = true
        heartbeatInFlight = true
        defer {
            busy = false
            heartbeatInFlight = false
            let waiting = heartbeatWaiters
            heartbeatWaiters = []
            for continuation in waiting { continuation.resume() }
        }
        let connection = connection
        let logger = logger
        do {
            let held = try await withPersistenceDeadline(timeout) {
                try await withTaskCancellationHandler {
                    try await WriterFence.holdsSessionLock(on: connection, logger: logger)
                } onCancel: { connection.close().whenComplete { _ in } }
            }
            guard held, status == .active else {
                await losePermission()
                return false
            }
            lastHeartbeat = Date()
            lastHeartbeatInstant = ContinuousClock.now
            return true
        } catch {
            await losePermission()
            return false
        }
    }

    private func connectionDidClose() {
        if status == .active { status = .lost }
        heartbeatTask?.cancel()
    }

    private func losePermission() async {
        if status == .active { status = .lost }
        heartbeatTask?.cancel()
        try? await connection.close()
    }
}
