import Synchronization

/// A value-semantic, Sendable State behind the existing synchronous Store API.
/// Sendable alone does not make mutable reference-valued fields copy-on-write.
/// Keep those fields out of State; domain codecs decide what data is durable.
public final class TransactionalState<State: Sendable>: Sendable, AnyTransactionCell {
    public let domain: TransactionDomain
    private let committed: Mutex<State>
    private let unscopedWriter = Mutex(())

    public init(_ initialValue: State, domain: TransactionDomain = .shared) {
        self.domain = domain
        committed = Mutex(initialValue)
        domain.register(self)
    }

    deinit { domain.unregister(transactionKey) }

    /// Matches Synchronization.Mutex's sending/typed-throws contract. When E is
    /// Never callers need no `try`, just as with the former rethrows interface.
    /// A throwing callback retains its inout edits in the selected view.
    public func withLock<Result, E: Error>(
        _ body: (inout sending State) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        if let view = TransactionLocals.readView {
            return try view.withValue(self, body)
        }
        if let context = TransactionLocals.context {
            return try context.withValue(self, body)
        }
        if domain.isReadOnlyUnscoped {
            let view = domain.committedView()
            defer { view.close() }
            return try view.withValue(self, body)
        }
        return try unscopedWriter.withLock { (_) throws(E) -> sending Result in
            var value = domain.beginUnscoped(self)
            defer { domain.finishUnscoped(self, value: value) }
            return try body(&value)
        }
    }

    var transactionKey: ObjectIdentifier { ObjectIdentifier(self) }

    func committedValue() -> State { committed.withLock { $0 } }

    func replaceCommitted(_ value: State) -> RetiredState<State> {
        committed.withLock { stored in
            let old = stored
            stored = value
            return RetiredState(value: old)
        }
    }

    func freezeCommitted() -> any FrozenTransactionEntry {
        FrozenState(cell: self, value: committedValue())
    }
}

protocol FrozenTransactionEntry: Sendable {
    func makePending() -> any PendingTransactionEntry
    func publish() -> any RetiredTransactionValue
}

protocol PendingTransactionEntry: Sendable {
    func freeze() -> any FrozenTransactionEntry
}

protocol RetiredTransactionValue: Sendable {}
struct RetiredState<State: Sendable>: RetiredTransactionValue { let value: State }

final class FrozenState<State: Sendable>: FrozenTransactionEntry {
    let cell: TransactionalState<State>
    let value: State

    init(cell: TransactionalState<State>, value: State) {
        self.cell = cell
        self.value = value
    }

    func makePending() -> any PendingTransactionEntry { PendingState(cell: cell, value: value) }
    func publish() -> any RetiredTransactionValue { cell.replaceCommitted(value) }
}

final class PendingState<State: Sendable>: PendingTransactionEntry {
    private let cell: TransactionalState<State>
    private let value: Mutex<State>

    init(cell: TransactionalState<State>, value: State) {
        self.cell = cell
        self.value = Mutex(value)
    }

    func withLock<Result, E: Error>(
        _ body: (inout sending State) throws(E) -> sending Result
    ) throws(E) -> sending Result { try value.withLock(body) }

    func freeze() -> any FrozenTransactionEntry {
        FrozenState(cell: cell, value: value.withLock { $0 })
    }
}
