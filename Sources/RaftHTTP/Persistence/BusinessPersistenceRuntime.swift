import Foundation
import Logging
import RaftPersistence
import RaftShared

/// A business-persistence failure that permanently closes admission. The reason
/// is produced from redacted error descriptions only; never add a raw driver
/// error, SQL, URL, credential or payload to this value.
public struct BusinessPersistenceFatalFailure: Sendable, CustomStringConvertible {
    public let operation: String
    public let reason: String
    public let writerEpoch: Int64
    public let phase: BusinessPersistencePhase

    init(operation: String, reason: String, writerEpoch: Int64, phase: BusinessPersistencePhase) {
        self.operation = operation
        self.reason = reason
        self.writerEpoch = writerEpoch
        self.phase = phase
    }

    public var description: String {
        "\(operation): \(reason) (writer epoch \(writerEpoch), phase \(phase.rawValue))"
    }
}

/// The composition owner decides what happens after admission failed closed.
/// Production passes a supervisor restart (non-zero exit); tests observe it.
public typealias BusinessPersistenceFatalFailureHandler = @Sendable (BusinessPersistenceFatalFailure) -> Void

/// Coordinates the same retained owners with one fenced PostgreSQL writer.
/// A failed commit closes admission permanently; the supervisor must restart
/// and reload. Request cancellation is not a commit failure: the fenced
/// transaction is shielded from the HTTP request task and always resolves.
public actor BusinessPersistenceRuntime {
    let persistence: PostgresPersistence
    let lease: WriterLease
    nonisolated let domain: TransactionDomain
    nonisolated let readyState = BusinessPersistenceReadinessState()
    let bindings: [DurableSnapshotBinding]
    let fatalFailureHandler: BusinessPersistenceFatalFailureHandler
    let logger: Logger
    var revisions: [DurableKey: Int64] = [:]
    /// Canonical bytes of the last confirmed commit for every binding. This is
    /// the comparison base for "did this transaction change a durable fact?".
    /// It is seeded from the wired live owners at activation and advanced only
    /// after a confirmed SQL COMMIT; it is never read back from PostgreSQL.
    var committedSnapshots: [DurableKey: Data] = [:]
    var activated = false
    var stopping = false
    var resourcesClosed = false
    var healthMonitor: Task<Void, Never>?
    var fatalFailure: BusinessPersistenceFatalFailure?
    var terminationSignaled = false
    var shutdownRequested = false

    private init(
        persistence: PostgresPersistence, lease: WriterLease,
        bindings: [DurableSnapshotBinding], domain: TransactionDomain,
        fatalFailureHandler: @escaping BusinessPersistenceFatalFailureHandler, logger: Logger
    ) {
        self.persistence = persistence
        self.lease = lease
        self.bindings = bindings
        self.domain = domain
        self.fatalFailureHandler = fatalFailureHandler
        self.logger = logger
    }

    /// All transactional cells, including OAuth's secret, must already exist.
    /// Startup restores business data but deliberately leaves admission closed.
    /// Configure live relays/providers next, then activate before listeners start.
    public static func start(
        configuration: PostgresPersistenceConfiguration,
        bindings: [DurableSnapshotBinding], domain: TransactionDomain = .shared,
        fatalFailureHandler: @escaping BusinessPersistenceFatalFailureHandler = { _ in }
    ) async throws -> BusinessPersistenceRuntime {
        try validateBusinessBindings(bindings)
        guard !domain.isReadOnlyUnscoped else { throw BusinessPersistenceError.unavailable }
        let persistence = try await PostgresPersistence.start(configuration: configuration)
        do {
            guard let lease = try await persistence.tryAcquireWriterLease() else {
                throw BusinessPersistenceError.writerUnavailable
            }
            let runtime = BusinessPersistenceRuntime(
                persistence: persistence, lease: lease, bindings: bindings, domain: domain,
                fatalFailureHandler: fatalFailureHandler,
                logger: Logger(label: "raft.persistence.business")
            )
            do {
                try await runtime.bootstrap()
                await runtime.startMonitoring()
                return runtime
            } catch {
                await runtime.close()
                throw error
            }
        } catch {
            await persistence.close()
            throw error
        }
    }

    public nonisolated var readinessSnapshot: BusinessPersistenceReadiness { readyState.snapshot() }

    /// One committed multi-owner revision for synchronous socket authorization.
    /// A stale lease observation rejects admission, including after the read.
    public nonisolated func withCommittedReadView<Output>(
        _ operation: () throws -> Output
    ) throws -> Output {
        guard readinessSnapshot.isReady else { throw BusinessPersistenceError.unavailable }
        return try RaftShared.withCommittedReadView(in: domain) {
            guard readinessSnapshot.isReady else { throw BusinessPersistenceError.unavailable }
            let value = try operation()
            guard readinessSnapshot.isReady else { throw BusinessPersistenceError.unavailable }
            return value
        }
    }

    public func readiness() async -> BusinessPersistenceReadiness {
        await observeLease()
        return readinessSnapshot
    }

    public func activate() async throws {
        let context = TransactionContext(domain: domain)
        try await withTransactionContext(context) {
            try await self.activateAdmitted(context: context)
        }
    }

    private func activateAdmitted(context: TransactionContext) async throws {
        guard !stopping, !activated, !resourcesClosed else { throw BusinessPersistenceError.unavailable }
        let health = await lease.healthSnapshot()
        guard health.isHealthy, !stopping, !activated else {
            readyState.stop(.failed)
            throw BusinessPersistenceError.writerUnavailable
        }
        // End this empty context while retaining its FIFO permit. Domain's
        // policy requires no active context and no concurrent unscoped writer.
        context.discard()
        domain.enableReadOnlyUnscoped()
        // Production wiring runs after start restored the owners and before
        // admission opens, so this committed view is the state the runtime is
        // about to serve, not the raw rows read at bootstrap. Encode it once;
        // without this seed every pure read would look like a durable change.
        try RaftShared.withCommittedReadView(in: domain) {
            var seeded: [DurableKey: Data] = [:]
            for binding in bindings {
                seeded[binding.key] = try binding.encode()
            }
            committedSnapshots = seeded
        }
        activated = true
        readyState.observedHealthy(epoch: health.epoch)
        readyState.activate()
    }

    /// The Shared FIFO permit spans operation, SQL commit, publication and flush.
    /// Actor isolation alone does not prevent another command entering at await.
    public func execute<Output: Sendable>(
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        let context = TransactionContext(domain: domain)
        return try await withTransactionContext(context) {
            try await self.executeAdmitted(context: context, operation: operation)
        }
    }

    private struct PreparedWrites {
        let writes: [DurableWrite]
        let changed: Set<DurableKey>
        /// Every pending snapshot encoded for this transaction. An effects-only
        /// commit needs all fourteen as its SQL payload and reuses these bytes
        /// instead of encoding the same frozen state a second time.
        let pending: [DurableKey: Data]
    }

    private func executeAdmitted<Output: Sendable>(
        context: TransactionContext,
        operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        try await requireAdmission()
        // Domain rejection can still mutate durable facts (expiry/use/counters).
        // Return its original Result only after those facts have committed.
        let result: Result<Output, any Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        do {
            try context.prepareCommit()
            let prepared = try preparedWrites(context: context, creating: false)
            let effects = try context.preparedDurableEffects().map { intent in
                try DurableEffect(
                    effectID: intent.effectID, kind: DurableEffectKind(intent.kind),
                    payload: intent.payload, createdAt: intent.createdAt
                )
            }
            if prepared.writes.isEmpty && effects.isEmpty {
                // A pure read leaves every durable fact unchanged. Upstream GET
                // handlers do not write either; publishing the identical snapshot
                // keeps the committed view coherent without consuming a revision.
                context.publishCommitted()
                context.flushDeferredEffects()
            } else {
                // A durable effect needs a real SQL transaction. Store writes are
                // then the transaction payload even when no snapshot byte moved;
                // reuse the pending snapshots this transaction already encoded.
                let payload = prepared.writes.isEmpty
                    ? try forcedWrites(from: prepared)
                    : prepared
                let conditions = try bindings.map { binding in
                    guard let revision = revisions[binding.key] else {
                        throw BusinessPersistenceError.invalidRevisionSet
                    }
                    return try DurableCondition(key: binding.key, expectedRevision: revision)
                }
                // The HTTP request task is cancelled when its client disconnects
                // (browser reload). Running the fenced transaction in a child task
                // keeps that transport cancellation from closing the writer
                // connection with an open transaction or failing admission closed.
                let committed = try await Self.runCommitShielded { [persistence, lease] in
                    try await persistence.compareAndSwap(
                        payload.writes, checking: conditions,
                        expectedWriterEpoch: lease.epoch, effects: effects
                    )
                }
                // A confirmed COMMIT must publish even if close starts concurrently.
                // Never substitute a blind in-memory rollback for an unknown COMMIT.
                try applyCommittedRevisions(committed, written: payload.changed)
                recordCommittedSnapshots(payload, written: payload.changed)
                context.publishCommitted()
                context.flushDeferredEffects()
            }
        } catch {
            context.discard()
            if (error as? TransactionError) != .rollbackOnly {
                await failClosed(operation: "business commit", error: error)
            }
            throw error
        }
        return try result.get()
    }

    /// The child task does not inherit the caller's cancellation. Awaiting its
    /// value parks the request until the real COMMIT resolves; the caller then
    /// publishes. Never make this path cancellable by an HTTP client.
    private static func runCommitShielded<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task { try await operation() }
        return try await task.value
    }

    private func bootstrap() async throws {
        let documents = try await persistence.readSnapshot(bindings.map(\.key))
        guard documents.isEmpty || documents.count == bindings.count else {
            throw BusinessPersistenceError.incompleteSnapshot
        }
        let context = TransactionContext(domain: domain)
        try await withTransactionContext(context) {
            try await self.restoreOrCreate(documents: documents, context: context)
        }
        let health = await lease.healthSnapshot()
        guard health.isHealthy else { throw BusinessPersistenceError.writerUnavailable }
        readyState.observedHealthy(epoch: health.epoch)
        readyState.loaded()
    }

    private func restoreOrCreate(documents: [DurableDocument], context: TransactionContext) async throws {
        if documents.isEmpty {
            try context.prepareCommit()
            let prepared = try preparedWrites(context: context, creating: true)
            let conditions = try bindings.map { try DurableCondition(key: $0.key, expectedRevision: nil) }
            let created = try await persistence.compareAndSwap(
                prepared.writes, checking: conditions, expectedWriterEpoch: lease.epoch
            )
            try applyCommittedRevisions(created, written: prepared.changed)
            recordCommittedSnapshots(prepared, written: prepared.changed)
        } else {
            let byKey = Dictionary(uniqueKeysWithValues: documents.map { ($0.key, $0) })
            for binding in bindings {
                guard let document = byKey[binding.key] else { throw BusinessPersistenceError.incompleteSnapshot }
                // Decode the outer Data envelope only. The codec owns every byte
                // and validates its own schema without generic JSON conversion.
                try binding.restore(document.decode(Data.self, codecVersion: 1))
            }
            try context.prepareCommit()
            let health = await lease.healthSnapshot()
            guard health.isHealthy else { throw BusinessPersistenceError.writerUnavailable }
            revisions = Dictionary(uniqueKeysWithValues: documents.map { ($0.key, $0.revision) })
        }
        context.publishCommitted()
        context.flushDeferredEffects()
    }

    /// Encode every pending snapshot exactly once in the same task, then compare
    /// it with the canonical bytes of the last confirmed commit. A binding whose
    /// bytes are identical did not change any durable fact and must not consume a
    /// revision or a row rewrite. The committed base is not re-encoded: activation
    /// seeded it from the wired live owners and only a confirmed commit advances
    /// it, so rollback and failed commits cannot move the comparison base.
    /// PG still checks every binding's revision and the total snapshot/effect
    /// budget against 16 MiB.
    private func preparedWrites(
        context: TransactionContext, creating: Bool
    ) throws -> PreparedWrites {
        if !creating {
            for binding in bindings
            where revisions[binding.key] == nil || committedSnapshots[binding.key] == nil {
                throw BusinessPersistenceError.invalidRevisionSet
            }
        }
        var pending: [DurableKey: Data] = [:]
        try context.withPendingReadView {
            for binding in bindings { pending[binding.key] = try binding.encode() }
        }
        if creating {
            let writes = try bindings.map { binding -> DurableWrite in
                guard let snapshot = pending[binding.key] else {
                    throw BusinessPersistenceError.invalidRevisionSet
                }
                return try DurableWrite.put(
                    snapshot, key: binding.key, codecVersion: 1, expectedRevision: nil
                )
            }
            return PreparedWrites(writes: writes, changed: Set(bindings.map(\.key)), pending: pending)
        }
        var writes: [DurableWrite] = []
        var changed: Set<DurableKey> = []
        for binding in bindings {
            guard let snapshot = pending[binding.key],
                  let revision = revisions[binding.key] else {
                throw BusinessPersistenceError.invalidRevisionSet
            }
            guard committedSnapshots[binding.key] != snapshot else { continue }
            writes.append(try DurableWrite.put(
                snapshot, key: binding.key, codecVersion: 1, expectedRevision: revision
            ))
            changed.insert(binding.key)
        }
        return PreparedWrites(writes: writes, changed: changed, pending: pending)
    }

    /// An effects-only commit needs a real SQL transaction, so every binding is
    /// the payload even though no snapshot byte moved. Reuse the snapshots the
    /// same frozen transaction already encoded; do not encode the owners again.
    private func forcedWrites(from prepared: PreparedWrites) throws -> PreparedWrites {
        let writes = try bindings.map { binding -> DurableWrite in
            guard let snapshot = prepared.pending[binding.key],
                  let revision = revisions[binding.key] else {
                throw BusinessPersistenceError.invalidRevisionSet
            }
            return try DurableWrite.put(
                snapshot, key: binding.key, codecVersion: 1, expectedRevision: revision
            )
        }
        return PreparedWrites(
            writes: writes, changed: Set(bindings.map(\.key)), pending: prepared.pending
        )
    }

    /// Advance the comparison base only after PostgreSQL confirmed the commit.
    /// A missing snapshot deliberately removes the key so the next command fails
    /// closed instead of treating an unknown base as unchanged.
    private func recordCommittedSnapshots(_ prepared: PreparedWrites, written: Set<DurableKey>) {
        for key in written { committedSnapshots[key] = prepared.pending[key] }
    }

    private func applyCommittedRevisions(_ committed: [DurableRevision], written: Set<DurableKey>) throws {
        guard committed.count == written.count,
              Set(committed.map(\.key)) == written,
              committed.allSatisfy({ !$0.deleted && $0.revision > 0 }) else {
            throw BusinessPersistenceError.invalidRevisionSetAfterCommit
        }
        var merged = revisions
        for revision in committed { merged[revision.key] = revision.revision }
        guard merged.count == bindings.count,
              bindings.allSatisfy({ merged[$0.key] != nil }) else {
            throw BusinessPersistenceError.invalidRevisionSetAfterCommit
        }
        revisions = merged
    }

    func requireAdmission() async throws {
        guard activated else { throw BusinessPersistenceError.notActivated }
        guard !stopping, !resourcesClosed, readinessSnapshot.isReady else {
            throw BusinessPersistenceError.unavailable
        }
        let health = await lease.healthSnapshot()
        guard health.isHealthy, !stopping else {
            await failClosed(operation: "admission lease check", reason: "writer lease is not healthy")
            throw BusinessPersistenceError.writerUnavailable
        }
        readyState.observedHealthy(epoch: health.epoch)
    }

    func failClosed(operation: String, error: any Error) async {
        await failClosed(operation: operation, reason: Self.redactedReason(error))
    }

    func failClosed(operation: String, reason: String) async {
        recordFatalFailure(operation: operation, reason: reason)
        // The journal line is written before anything can block. The supervisor
        // handler terminates here so a stuck drain cannot leave a 503-only
        // zombie; tests inject a recording handler and then drain below.
        signalFatalFailure()
        // Caller already owns the Shared FIFO permit. Do not acquire it again.
        await closeResources()
    }

    /// Log the redacted reason before closing anything so the journal always
    /// carries the underlying cause, even if draining the owners stalls.
    private func recordFatalFailure(operation: String, reason: String) {
        guard fatalFailure == nil else { return }
        stopping = true
        readyState.stop(.failed)
        healthMonitor?.cancel()
        let failure = BusinessPersistenceFatalFailure(
            operation: operation, reason: reason, writerEpoch: lease.epoch,
            phase: readinessSnapshot.phase
        )
        fatalFailure = failure
        logger.error("business persistence failed closed; refusing new work", metadata: [
            "operation": "\(failure.operation)",
            "reason": "\(failure.reason)",
            "writerEpoch": "\(failure.writerEpoch)",
        ])
    }

    private func signalFatalFailure() {
        guard let fatalFailure, !terminationSignaled, !shutdownRequested else { return }
        terminationSignaled = true
        fatalFailureHandler(fatalFailure)
    }

    /// Driver errors are mapped to `PersistenceError` by the persistence layer;
    /// that description omits URLs, credentials, SQL text, bindings and payloads.
    private static func redactedReason(_ error: any Error) -> String {
        if error is CancellationError { return "request cancelled before the fenced commit resolved" }
        if let error = error as? PersistenceError { return error.description }
        if let error = error as? BusinessPersistenceError { return String(describing: error) }
        if let error = error as? TransactionError { return String(describing: error) }
        return "unexpected \(String(reflecting: type(of: error)))"
    }

    private func startMonitoring() {
        let lease = lease
        healthMonitor = Task { [weak self] in
            while !Task.isCancelled {
                let health = await lease.healthSnapshot()
                await self?.observeHealth(healthy: health.isHealthy, epoch: health.epoch)
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func observeLease() async {
        let health = await lease.healthSnapshot()
        observeHealth(healthy: health.isHealthy, epoch: health.epoch)
    }

    private func observeHealth(healthy: Bool, epoch: Int64) {
        guard !stopping else { return }
        if healthy {
            readyState.observedHealthy(epoch: epoch)
            return
        }
        recordFatalFailure(operation: "writer lease health", reason: "writer lease heartbeat is stale")
        signalFatalFailure()
        // This observation is synchronous and may not own the FIFO permit.
        // A recording handler still drains; production has already exited.
        Task.detached { [weak self] in
            guard let self else { return }
            await self.close()
        }
    }

    /// Stop admission first, drain the FIFO, close the lease, then close PG.
    /// A close requested from inside a business UoW schedules the drain instead
    /// of awaiting its own permit; the outer command still has to finalize.
    public func close() async {
        // An explicit shutdown is not a crash: never ask the supervisor to
        // restart a process that is already draining after SIGTERM.
        if fatalFailure == nil { shutdownRequested = true }
        stopping = true
        readyState.stop(.closed)
        healthMonitor?.cancel()
        let context = TransactionContext(domain: domain)
        do {
            try await withTransactionContext(context) {
                context.discard()
                await self.closeResources()
            }
        } catch {
            let cleanup = Task.detached { await self.close() }
            if (error as? TransactionError) != .nestedTransaction { await cleanup.value }
        }
    }

    func closeResources() async {
        guard !resourcesClosed else { return }
        resourcesClosed = true
        await lease.close()
        await persistence.close()
        // Opaque snapshots can contain credentials; release them with the owners.
        committedSnapshots = [:]
        healthMonitor = nil
    }
}
