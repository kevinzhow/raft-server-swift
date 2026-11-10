import Synchronization

/// A coordination domain, not an owner registry. Cells never expose their owner.
/// All durable cells in one database unit of work must use the same domain.
public final class TransactionDomain: Sendable {
    public static let shared = TransactionDomain()

    private struct Storage: Sendable {
        var cells: [ObjectIdentifier: WeakTransactionCell] = [:]
        var activeContext: ObjectIdentifier?
        var unscopedWriters = 0
        var readOnlyUnscoped = false
    }

    private let barrier = Mutex(Storage())
    let gate = AsyncTransactionGate()

    public init() {}

    /// Outside a context, execute legacy inout callbacks on a copy and discard
    /// their changes. This cannot identify writes or turn their return values
    /// into durable acknowledgements. Mutating entrypoints still require a UoW.
    public func enableReadOnlyUnscoped() {
        barrier.withLock { storage in
            precondition(storage.activeContext == nil && storage.unscopedWriters == 0,
                         "Enable production policy before admitting work")
            storage.readOnlyUnscoped = true
        }
    }

    public var isReadOnlyUnscoped: Bool {
        barrier.withLock { $0.readOnlyUnscoped }
    }

    func register(_ cell: any AnyTransactionCell) {
        let reference = WeakTransactionCell(cell)
        barrier.withLock { storage in
            precondition(storage.activeContext == nil && !storage.readOnlyUnscoped,
                         "Allocate all cells before enabling production policy or beginning a UoW")
            storage.cells[cell.transactionKey] = reference
        }
    }

    func unregister(_ key: ObjectIdentifier) {
        let retired = barrier.withLock { $0.cells.removeValue(forKey: key) }
        withExtendedLifetime(retired) {}
    }

    func committedView() -> TransactionReadView {
        let values = barrier.withLock { storage in
            Self.capture(storage.cells)
        }
        return TransactionReadView(domain: self, values: values)
    }

    func begin(_ context: TransactionContext) throws -> [ObjectIdentifier: any FrozenTransactionEntry] {
        try barrier.withLock { storage in
            guard storage.activeContext == nil else { throw TransactionError.domainAlreadyActive }
            guard storage.unscopedWriters == 0 else { throw TransactionError.unscopedWriterInProgress }
            storage.activeContext = ObjectIdentifier(context)
            return Self.capture(storage.cells)
        }
    }

    func end(_ context: TransactionContext) {
        barrier.withLock { storage in
            if storage.activeContext == ObjectIdentifier(context) { storage.activeContext = nil }
        }
    }

    /// Only internal immutable entries run under this barrier. No user callbacks,
    /// encoding, I/O, continuation resumption or awaits are allowed here.
    func publish(_ entries: [any FrozenTransactionEntry], context: TransactionContext) {
        let retired: [any RetiredTransactionValue] = barrier.withLock { storage in
            precondition(storage.activeContext == ObjectIdentifier(context), "Wrong transaction domain owner")
            let old = entries.map { $0.publish() }
            storage.activeContext = nil
            return old
        }
        // A removed State can own reference lifetimes. Release after the barrier.
        withExtendedLifetime(retired) {}
    }

    func beginUnscoped<State: Sendable>(_ cell: TransactionalState<State>) -> State {
        barrier.withLock { storage in
            precondition(!storage.readOnlyUnscoped, "Production access requires a read view or transaction")
            precondition(storage.activeContext == nil, "Unscoped writer overlaps a transaction")
            storage.unscopedWriters += 1
            return cell.committedValue()
        }
    }

    func finishUnscoped<State: Sendable>(_ cell: TransactionalState<State>, value: State) {
        let retired = barrier.withLock { storage in
            precondition(storage.unscopedWriters > 0 && storage.activeContext == nil)
            let old = cell.replaceCommitted(value)
            storage.unscopedWriters -= 1
            return old
        }
        withExtendedLifetime(retired) {}
    }

    private static func capture(
        _ cells: [ObjectIdentifier: WeakTransactionCell]
    ) -> [ObjectIdentifier: any FrozenTransactionEntry] {
        var values: [ObjectIdentifier: any FrozenTransactionEntry] = [:]
        for (key, reference) in cells {
            if let cell = reference.load() { values[key] = cell.freezeCommitted() }
        }
        return values
    }
}

protocol AnyTransactionCell: AnyObject, Sendable {
    var transactionKey: ObjectIdentifier { get }
    func freezeCommitted() -> any FrozenTransactionEntry
}

private final class WeakTransactionCell: Sendable {
    private struct Reference: Sendable {
        weak var cell: (any AnyTransactionCell)?
    }
    private let reference: Mutex<Reference>

    init(_ cell: any AnyTransactionCell) { reference = Mutex(Reference(cell: cell)) }
    func load() -> (any AnyTransactionCell)? { reference.withLock { $0.cell } }
}
