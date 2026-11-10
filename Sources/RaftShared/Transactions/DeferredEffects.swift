import Synchronization

/// Wrap the actual synchronous delivery call. In a UoW this queues the call;
/// after publication it runs on the flushing caller, with no fake I/O dispatch.
public enum DeferredEffects {
    public static func emit(
        in domain: TransactionDomain? = nil,
        _ effect: @escaping @Sendable () -> Void
    ) {
        precondition(TransactionLocals.readView == nil, "A read-only snapshot cannot emit effects")
        if let flush = TransactionLocals.effectFlush {
            flush.requireOpen()
            effect()
            return
        }
        if let buffer = TransactionLocals.effects {
            if let domain {
                precondition(TransactionLocals.context?.domain === domain, "Effect crosses transaction domains")
            }
            buffer.append(effect)
        } else {
            let resolved = domain ?? TransactionDomain.shared
            precondition(!resolved.isReadOnlyUnscoped,
                         "Production effects require a transaction and confirmed commit")
            effect()
        }
    }
}

final class TransactionEffectBuffer: Sendable {
    private enum Phase: Sendable { case open, sealed, committed, flushed, discarded }
    private struct Storage: Sendable {
        var phase = Phase.open
        var effects: [@Sendable () -> Void] = []
        var durableIntents: [DurableEffectIntent] = []
    }
    private let storage = Mutex(Storage())

    func append(_ effect: @escaping @Sendable () -> Void) {
        storage.withLock { stored in
            precondition(stored.phase == .open, "Transaction effect buffer is closed")
            stored.effects.append(effect)
        }
    }

    func appendIntent(_ intent: DurableEffectIntent) {
        storage.withLock { stored in
            precondition(stored.phase == .open, "Transaction effect buffer is closed")
            stored.durableIntents.append(intent)
        }
    }

    func preparedIntents() -> [DurableEffectIntent] {
        storage.withLock { stored in
            precondition(stored.phase == .sealed, "Prepare before reading durable effects")
            return stored.durableIntents
        }
    }

    func seal() {
        storage.withLock { stored in
            precondition(stored.phase == .open)
            stored.phase = .sealed
        }
    }

    func markCommitted() {
        storage.withLock { stored in
            precondition(stored.phase == .sealed)
            stored.phase = .committed
        }
    }

    func discard() {
        let retired: [@Sendable () -> Void] = storage.withLock { stored in
            switch stored.phase {
            case .committed, .flushed: return []
            case .open, .sealed, .discarded:
                let old = stored.effects
                stored.effects = []
                stored.durableIntents = []
                stored.phase = .discarded
                return old
            }
        }
        withExtendedLifetime(retired) {}
    }

    func flush() {
        let effects: [@Sendable () -> Void] = storage.withLock { stored in
            if stored.phase == .flushed { return [] }
            precondition(stored.phase == .committed, "Cannot flush uncommitted effects")
            let result = stored.effects
            stored.effects = []
            stored.phase = .flushed
            return result
        }
        let scope = TransactionEffectFlushScope()
        defer { scope.close() }
        TransactionLocals.$context.withValue(nil) {
            TransactionLocals.$effects.withValue(nil) {
                TransactionLocals.$readView.withValue(nil) {
                    TransactionLocals.$effectFlush.withValue(scope) {
                        for effect in effects { effect() }
                    }
                }
            }
        }
    }
}

final class TransactionEffectFlushScope: Sendable {
    private let open = Mutex(true)
    func close() { open.withLock { $0 = false } }
    func requireOpen() {
        precondition(open.withLock { $0 }, "Effect flush scope escaped its synchronous lifetime")
    }
}
