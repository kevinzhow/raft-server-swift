import Foundation
import RaftPersistence
import RaftShared

/// Coordinates the same retained owners with one fenced PostgreSQL writer.
/// A failed commit closes admission permanently; restart and reload to recover.
public actor BusinessPersistenceRuntime {
    let persistence: PostgresPersistence
    let lease: WriterLease
    nonisolated let domain: TransactionDomain
    nonisolated let readyState = BusinessPersistenceReadinessState()
    let bindings: [DurableSnapshotBinding]
    var revisions: [DurableKey: Int64] = [:]
    var activated = false
    var stopping = false
    var resourcesClosed = false
    var healthMonitor: Task<Void, Never>?

    private init(
        persistence: PostgresPersistence, lease: WriterLease,
        bindings: [DurableSnapshotBinding], domain: TransactionDomain
    ) {
        self.persistence = persistence
        self.lease = lease
        self.bindings = bindings
        self.domain = domain
    }

    /// All transactional cells, including OAuth's secret, must already exist.
    /// Startup restores business data but deliberately leaves admission closed.
    /// Configure live relays/providers next, then activate before listeners start.
    public static func start(
        configuration: PostgresPersistenceConfiguration,
        bindings: [DurableSnapshotBinding], domain: TransactionDomain = .shared
    ) async throws -> BusinessPersistenceRuntime {
        try validateBusinessBindings(bindings)
        guard !domain.isReadOnlyUnscoped else { throw BusinessPersistenceError.unavailable }
        let persistence = try await PostgresPersistence.start(configuration: configuration)
        do {
            guard let lease = try await persistence.tryAcquireWriterLease() else {
                throw BusinessPersistenceError.writerUnavailable
            }
            let runtime = BusinessPersistenceRuntime(
                persistence: persistence, lease: lease, bindings: bindings, domain: domain
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
            let writes = try preparedWrites(context: context, creating: false)
            let conditions = try bindings.map { binding in
                guard let revision = revisions[binding.key] else {
                    throw BusinessPersistenceError.invalidRevisionSet
                }
                return try DurableCondition(key: binding.key, expectedRevision: revision)
            }
            let effects = try context.preparedDurableEffects().map { intent in
                try DurableEffect(
                    effectID: intent.effectID, kind: DurableEffectKind(intent.kind),
                    payload: intent.payload, createdAt: intent.createdAt
                )
            }
            let committed = try await persistence.compareAndSwap(
                writes, checking: conditions, expectedWriterEpoch: lease.epoch, effects: effects
            )
            // A confirmed COMMIT must publish even if close starts concurrently.
            // Never substitute a blind in-memory rollback for an unknown COMMIT.
            revisions = try checkedRevisions(committed)
            context.publishCommitted()
            context.flushDeferredEffects()
        } catch {
            context.discard()
            if (error as? TransactionError) != .rollbackOnly {
                await failClosed()
            }
            throw error
        }
        return try result.get()
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
            let writes = try preparedWrites(context: context, creating: true)
            let conditions = try bindings.map { try DurableCondition(key: $0.key, expectedRevision: nil) }
            let created = try await persistence.compareAndSwap(
                writes, checking: conditions, expectedWriterEpoch: lease.epoch
            )
            revisions = try checkedRevisions(created)
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

    private func preparedWrites(context: TransactionContext, creating: Bool) throws -> [DurableWrite] {
        try context.withPendingReadView {
            try bindings.map { binding in
                let revision = creating ? nil : revisions[binding.key]
                if !creating && revision == nil { throw BusinessPersistenceError.invalidRevisionSet }
                return try DurableWrite.put(
                    binding.encode(), key: binding.key, codecVersion: 1, expectedRevision: revision
                )
            }
        }
        // PG validates each outer base64 envelope and the total snapshot/effect
        // budget against 16 MiB. This root-snapshot design has a hard scale bound.
    }

    private func checkedRevisions(_ committed: [DurableRevision]) throws -> [DurableKey: Int64] {
        guard committed.count == bindings.count,
              Set(committed.map(\.key)) == Set(bindings.map(\.key)),
              committed.allSatisfy({ !$0.deleted && $0.revision > 0 }) else {
            throw BusinessPersistenceError.invalidRevisionSetAfterCommit
        }
        return Dictionary(uniqueKeysWithValues: committed.map { ($0.key, $0.revision) })
    }

    func requireAdmission() async throws {
        guard activated else { throw BusinessPersistenceError.notActivated }
        guard !stopping, !resourcesClosed, readinessSnapshot.isReady else {
            throw BusinessPersistenceError.unavailable
        }
        let health = await lease.healthSnapshot()
        guard health.isHealthy, !stopping else {
            await failClosed()
            throw BusinessPersistenceError.writerUnavailable
        }
        readyState.observedHealthy(epoch: health.epoch)
    }

    func failClosed() async {
        stopping = true
        readyState.stop(.failed)
        healthMonitor?.cancel()
        // Caller already owns the Shared FIFO permit. Do not acquire it again.
        await closeResources()
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
        if healthy { readyState.observedHealthy(epoch: epoch) }
        else {
            stopping = true
            readyState.stop(.failed)
            Task.detached { await self.close() }
        }
    }

    /// Stop admission first, drain the FIFO, close the lease, then close PG.
    /// A close requested from inside a business UoW schedules the drain instead
    /// of awaiting its own permit; the outer command still has to finalize.
    public func close() async {
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
        healthMonitor = nil
    }
}
