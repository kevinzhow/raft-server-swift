import Synchronization

public enum TransactionError: Error, Sendable, Equatable {
    case nestedTransaction
    case contextAlreadyUsed
    case domainAlreadyActive
    case unscopedWriterInProgress
    case operationInProgress
    case contextNotActive
    case contextNotPrepared
    case contextNotPublished
    case transactionNotFinalized
    case cellNotInSnapshot
    case wrongDomain
    case rollbackOnly
}

/// One use only. The coordinator must prepare BEFORE encoding/SQL COMMIT,
/// publish only AFTER SQL COMMIT, and flush effects only after publication.
public final class TransactionContext: Sendable {
    private enum Phase: Sendable { case idle, active, prepared, publishing, published, discarded }
    private struct Storage: Sendable {
        var phase = Phase.idle
        var borrows = 0
        var rollbackOnly = false
        var base: [ObjectIdentifier: any FrozenTransactionEntry] = [:]
        var pending: [ObjectIdentifier: any PendingTransactionEntry] = [:]
        var prepared: [ObjectIdentifier: any FrozenTransactionEntry] = [:]
    }

    public let domain: TransactionDomain
    private let storage = Mutex(Storage())
    let effects = TransactionEffectBuffer()

    public init(domain: TransactionDomain = .shared) { self.domain = domain }

    /// An effect producer can reject this request even when a Feature converts
    /// its error to an HTTP response. A later prepare must still refuse commit.
    public func markRollbackOnly() {
        storage.withLock { stored in
            if stored.phase == .active { stored.rollbackOnly = true }
        }
    }

    var admitsDurableEffects: Bool {
        storage.withLock { $0.phase == .active }
    }

    var isClosed: Bool {
        storage.withLock { $0.phase == .published || $0.phase == .discarded }
    }

    func activate() throws {
        guard storage.withLock({ $0.phase == .idle }) else { throw TransactionError.contextAlreadyUsed }
        let base = try domain.begin(self)
        do {
            try storage.withLock { stored in
                guard stored.phase == .idle else { throw TransactionError.contextAlreadyUsed }
                stored.base = base
                stored.phase = .active
            }
        } catch {
            domain.end(self)
            throw error
        }
    }

    func withValue<State: Sendable, Output, Failure: Error>(
        _ cell: TransactionalState<State>,
        _ body: (inout sending State) throws(Failure) -> sending Output
    ) throws(Failure) -> sending Output {
        precondition(cell.domain === domain, "Cell belongs to another transaction domain")
        let entry: PendingState<State> = storage.withLock { stored in
            precondition(stored.phase == .active, "Transaction context is closed for mutation")
            let pending: any PendingTransactionEntry
            if let existing = stored.pending[cell.transactionKey] {
                pending = existing
            } else {
                guard let initial = stored.base[cell.transactionKey] else {
                    preconditionFailure("Allocate all transactional cells before beginning the UoW")
                }
                pending = initial.makePending()
                stored.pending[cell.transactionKey] = pending
            }
            guard let typed = pending as? PendingState<State> else {
                preconditionFailure("Transaction cell identity/type mismatch")
            }
            stored.borrows += 1
            return typed
        }
        defer { storage.withLock { $0.borrows -= 1 } }
        return try entry.withLock(body)
    }

    /// Freeze all pending values and the effect queue. New work inherited by
    /// stream tasks is rejected from this point. An admitted borrow prevents
    /// preparation; the coordinator must join its child tasks before calling.
    public func prepareCommit() throws {
        try storage.withLock { stored in
            guard stored.phase == .active else { throw TransactionError.contextNotActive }
            guard !stored.rollbackOnly else { throw TransactionError.rollbackOnly }
            guard stored.borrows == 0 else { throw TransactionError.operationInProgress }
            effects.seal()
            stored.prepared = stored.pending.mapValues { $0.freeze() }
            stored.phase = .prepared
        }
    }

    /// Read immutable outbox envelopes after preparation and before SQL commit.
    public func preparedDurableEffects() throws -> [DurableEffectIntent] {
        try storage.withLock { stored in
            guard stored.phase == .prepared else { throw TransactionError.contextNotPrepared }
            return effects.preparedIntents()
        }
    }

    /// Typed codec access after preparation. Untouched cells use the same base
    /// revision; there is no public key lookup, owner getter or untyped JSON.
    public func snapshot<State: Sendable>(of cell: TransactionalState<State>) throws -> State {
        guard cell.domain === domain else { throw TransactionError.wrongDomain }
        return try storage.withLock { stored in
            guard stored.phase == .prepared else { throw TransactionError.contextNotPrepared }
            guard let value = (stored.prepared[cell.transactionKey] ?? stored.base[cell.transactionKey])
                as? FrozenState<State> else { throw TransactionError.cellNotInSnapshot }
            return value.value
        }
    }

    /// Existing sync snapshot codecs can use normal Store getters in this
    /// scoped view. Any incidental inout cleanup is discarded, never encoded as
    /// a later mutation. The captured view cannot be reused by escaped tasks.
    public func withPendingReadView<Output>(_ body: () throws -> Output) throws -> Output {
        let values = try storage.withLock { stored in
            guard stored.phase == .prepared else { throw TransactionError.contextNotPrepared }
            return stored.base.merging(stored.prepared) { _, pending in pending }
        }
        return try withTransactionReadView(TransactionReadView(domain: domain, values: values), body)
    }

    /// Encode the last committed value of every cell. This is read-only and is
    /// used to decide whether a prepared transaction actually changed a durable
    /// fact; it never exposes a pending value.
    public func withBaseReadView<Output>(_ body: () throws -> Output) throws -> Output {
        let values = try storage.withLock { stored -> [ObjectIdentifier: any FrozenTransactionEntry] in
            guard stored.phase == .prepared else { throw TransactionError.contextNotPrepared }
            return stored.base
        }
        return try withTransactionReadView(TransactionReadView(domain: domain, values: values), body)
    }

    /// Infallible once prepared and the matching external database COMMIT has
    /// succeeded. All touched committed cells switch under one short barrier.
    /// The API cannot verify that a database commit actually occurred.
    public func publishCommitted() {
        let entries: [any FrozenTransactionEntry] = storage.withLock { stored in
            precondition(stored.phase == .prepared, "Prepare before database COMMIT; publish exactly once")
            stored.phase = .publishing
            return Array(stored.prepared.values)
        }
        domain.publish(entries, context: self)
        let retired = storage.withLock { stored in
            let old = stored
            stored.base = [:]
            stored.pending = [:]
            stored.prepared = [:]
            stored.phase = .published
            return old
        }
        effects.markCommitted()
        withExtendedLifetime(retired) {}
    }

    /// DB failure/cancellation before confirmed commit must take this path.
    /// A late discard can never undo a published commit.
    public func discard() {
        let retired: Storage? = storage.withLock { stored in
            switch stored.phase {
            case .published, .publishing: return nil
            case .discarded: return nil
            case .idle, .active, .prepared:
                let old = stored
                stored.base = [:]
                stored.pending = [:]
                stored.prepared = [:]
                stored.phase = .discarded
                return old
            }
        }
        if retired != nil {
            effects.discard()
            domain.end(self)
        }
        withExtendedLifetime(retired) {}
    }

    public func flushDeferredEffects() {
        precondition(storage.withLock { $0.phase == .published }, "Effects require a published commit")
        effects.flush()
    }

    func requireFinalized() throws {
        try storage.withLock { stored in
            guard stored.phase == .published || stored.phase == .discarded else {
                throw TransactionError.transactionNotFinalized
            }
        }
    }
}
