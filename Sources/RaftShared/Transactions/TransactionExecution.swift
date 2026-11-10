import Synchronization

// These task locals remain internal so callers cannot bypass the async gate by
// installing a context themselves. Child tasks inherit a lifecycle-checked view.
enum TransactionLocals {
    @TaskLocal static var context: TransactionContext?
    @TaskLocal static var readView: TransactionReadView?
    @TaskLocal static var effects: TransactionEffectBuffer?
    @TaskLocal static var effectFlush: TransactionEffectFlushScope?
}

final class TransactionReadView: Sendable {
    let domain: TransactionDomain
    private let values: [ObjectIdentifier: any FrozenTransactionEntry]
    private let open = Mutex(true)

    init(domain: TransactionDomain, values: [ObjectIdentifier: any FrozenTransactionEntry]) {
        self.domain = domain
        self.values = values
    }

    func close() { open.withLock { $0 = false } }
    var isClosed: Bool { open.withLock { !$0 } }

    func withValue<State: Sendable, Output, Failure: Error>(
        _ cell: TransactionalState<State>,
        _ body: (inout sending State) throws(Failure) -> sending Output
    ) throws(Failure) -> sending Output {
        precondition(open.withLock { $0 }, "Read view escaped its synchronous scope")
        precondition(cell.domain === domain, "Read view crosses transaction domains")
        guard let frozen = values[cell.transactionKey] as? FrozenState<State> else {
            preconditionFailure("Cell was not present when the read view was captured")
        }
        var copy = frozen.value
        return try body(&copy)
    }
}

/// One coherent committed revision for an entire synchronous auth/read decision.
/// No pending values are visible, even when called from an active transaction.
/// Inout cleanup is local to each callback and never changes durable state.
public func withCommittedReadView<Output>(
    in domain: TransactionDomain = .shared,
    _ operation: () throws -> Output
) rethrows -> Output {
    try withTransactionReadView(domain.committedView(), operation)
}

func withTransactionReadView<Output>(
    _ view: TransactionReadView,
    _ operation: () throws -> Output
) rethrows -> Output {
    defer { view.close() }
    return try TransactionLocals.$context.withValue(nil) {
        try TransactionLocals.$effects.withValue(nil) {
            try TransactionLocals.$readView.withValue(view, operation: operation)
        }
    }
}

/// Holds an async FIFO permit over the whole DB unit of work. No Mutex is held
/// across an await. Success without explicit publish/discard is an error.
/// Nested UoWs are rejected instead of deadlocking on the same permit.
public func withTransactionContext<Output: Sendable>(
    _ context: TransactionContext,
    operation: @Sendable () async throws -> Output
) async throws -> Output {
    guard TransactionLocals.context?.isClosed != false && TransactionLocals.readView?.isClosed != false else {
        throw TransactionError.nestedTransaction
    }
    return try await context.domain.gate.withPermit {
        try context.activate()
        do {
            let output = try await TransactionLocals.$effectFlush.withValue(nil) {
                try await TransactionLocals.$readView.withValue(nil) {
                    try await TransactionLocals.$context.withValue(context) {
                        try await TransactionLocals.$effects.withValue(context.effects) {
                            try await operation()
                        }
                    }
                }
            }
            try context.requireFinalized()
            return output
        } catch {
            context.discard()
            throw error
        }
    }
}
