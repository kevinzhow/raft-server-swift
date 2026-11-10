import PostgresNIO

/// Owns the pool's run task. start does not return until a real connection has
/// verified the schema and a pooled connection is ready. close cancels and awaits
/// the driver task. Stop admitting HTTP work before closing this object.
public actor PostgresPersistence {
    public static let currentSchemaVersion = PersistenceSchema.currentVersion
    private let client: PostgresClient
    private let logger: Logger
    private let timeout: Duration
    private let runner: Task<Void, Never>
    private var ready = false
    private var closed = false
    private let configuration: PostgresPersistenceConfiguration
    private var writerLease: WriterLease?
    private var claimingWriter = false

    private init(
        client: PostgresClient, runner: Task<Void, Never>, timeout: Duration, logger: Logger,
        configuration: PostgresPersistenceConfiguration
    ) {
        self.client = client
        self.runner = runner
        self.timeout = timeout
        self.logger = logger
        self.configuration = configuration
    }

    public static func start(
        configuration: PostgresPersistenceConfiguration, migrate: Bool = true
    ) async throws -> PostgresPersistence {
        try await prepareDatabase(configuration: configuration, migrate: migrate)
        let logger = Logger(label: "raft.persistence")
        let client = PostgresClient(configuration: configuration.clientConfiguration(), backgroundLogger: logger)
        let runner = Task { await client.run() }
        let persistence = PostgresPersistence(
            client: client, runner: runner, timeout: configuration.operationTimeout, logger: logger,
            configuration: configuration
        )
        do {
            try await persistence.completeStartup()
            return persistence
        } catch {
            await persistence.close()
            throw persistenceFailure(error, operation: "startup")
        }
    }

    /// --migrate-only: establish a real connection, atomically apply and verify
    /// migrations, close that connection, then return. No HTTP listener is started.
    public static func migrate(configuration: PostgresPersistenceConfiguration) async throws {
        try await prepareDatabase(configuration: configuration, migrate: true)
    }

    /// Requires the current schema as well as a working database connection.
    public func ping() async throws {
        try await withConnection(operation: "readiness") { connection, logger in
            try await PersistenceSchema.verify(on: connection, logger: logger)
        }
    }

    /// Returns nil if another session owns the single-writer lock. Do not start
    /// listeners or load mutable owners until claim succeeds. Every successful
    /// replacement claim has a new epoch and requires a fresh durable reload.
    public func tryAcquireWriterLease(heartbeatInterval: Duration = .seconds(2)) async throws -> WriterLease? {
        guard !closed else { throw PersistenceError.closed }
        guard ready else { throw PersistenceError.notReady }
        guard !claimingWriter else { throw PersistenceError.writerBusy }
        claimingWriter = true
        defer { claimingWriter = false }
        if let prior = writerLease {
            if await prior.healthSnapshot().isHealthy { return nil }
            await prior.close()
            writerLease = nil
        }
        let lease = try await WriterLease.acquire(configuration: configuration, heartbeatInterval: heartbeatInterval)
        guard !closed else {
            await lease?.close()
            throw PersistenceError.closed
        }
        writerLease = lease
        return lease
    }

    public func close() async {
        closed = true
        ready = false
        let lease = writerLease
        writerLease = nil
        await lease?.close()
        runner.cancel()
        await runner.value
    }

    /// Only internal operations receive a connection. No client, owner or state
    /// handle escapes through the public API.
    func withWriteConnection<Value: Sendable>(
        expectedWriterEpoch: Int64?, operation name: String,
        _ operation: @escaping @Sendable (PostgresConnection, Logger) async throws -> Value
    ) async throws -> Value {
        guard !closed else { throw PersistenceError.closed }
        guard ready else { throw PersistenceError.notReady }
        if let expectedWriterEpoch {
            guard let lease = writerLease, lease.epoch == expectedWriterEpoch else {
                throw PersistenceError.writerLeaseRequired
            }
            return try await lease.withConnection(operation: name, operation)
        }
        guard writerLease == nil, !claimingWriter else { throw PersistenceError.writerLeaseRequired }
        do { return try await withConnection(operation: name, operation) }
        catch {
            if error is CancellationError || (error as? PersistenceError) == .timedOut {
                throw PersistenceError.commitOutcomeUnknown(sqlState: nil)
            }
            throw error
        }
    }

    private func completeStartup() async throws {
        let client = client
        let logger = logger
        try await withPersistenceDeadline(timeout) {
            try await client.withConnection { connection in
                try await withTaskCancellationHandler {
                    try await PersistenceSchema.verify(on: connection, logger: logger)
                } onCancel: {
                    connection.close().whenComplete { _ in }
                }
            }
        }
        guard !closed else { throw PersistenceError.closed }
        ready = true
    }

    func withConnection<Value: Sendable>(
        operation name: String,
        _ operation: @escaping @Sendable (PostgresConnection, Logger) async throws -> Value
    ) async throws -> Value {
        guard !closed else { throw PersistenceError.closed }
        guard ready else { throw PersistenceError.notReady }
        let client = client
        let logger = logger
        do {
            return try await withPersistenceDeadline(timeout) {
                try await client.withConnection { connection in
                    try await withTaskCancellationHandler {
                        try await operation(connection, logger)
                    } onCancel: {
                        // Do not return a connection with an interrupted transaction
                        // to the pool. The driver observes the close and replaces it.
                        connection.close().whenComplete { _ in }
                    }
                }
            }
        } catch { throw persistenceFailure(error, operation: name) }
    }

    private static func prepareDatabase(
        configuration: PostgresPersistenceConfiguration, migrate: Bool
    ) async throws {
        let logger = Logger(label: "raft.persistence.migration")
        do {
            let connectionConfiguration = try configuration.connectionConfiguration()
            try await withPersistenceDeadline(configuration.operationTimeout) {
                let connection = try await PostgresConnection.connect(
                    configuration: connectionConfiguration, id: 0, logger: logger
                )
                do {
                    try await withTaskCancellationHandler {
                        if migrate { try await PersistenceSchema.migrate(on: connection, logger: logger) }
                        try await PersistenceSchema.verify(on: connection, logger: logger)
                    } onCancel: {
                        connection.close().whenComplete { _ in }
                    }
                    try await connection.close()
                } catch {
                    try? await connection.close()
                    throw error
                }
            }
        } catch { throw persistenceFailure(error, operation: "migration or schema verification") }
    }
}

func withPersistenceDeadline<Value: Sendable>(
    _ timeout: Duration, operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw PersistenceError.timedOut
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw PersistenceError.closed }
        return value
    }
}
