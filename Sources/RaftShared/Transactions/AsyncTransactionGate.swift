import Synchronization

/// Actor reentrancy is not the permit. Ownership stays with one ticket over
/// awaits; cancellations remove queued tickets and never release a running one.
final class AsyncTransactionGate: Sendable {
    private final class Ticket: Sendable {}
    private enum Registration: Sendable { case registering, queued, cancelled }
    private struct Waiter: Sendable {
        let ticket: Ticket
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct Storage: Sendable {
        var owner: Ticket?
        var queue: [Waiter] = []
        var registrations: [ObjectIdentifier: Registration] = [:]
    }
    private let storage = Mutex(Storage())

    func withPermit<Output: Sendable>(
        _ operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        let ticket = Ticket()
        let key = ObjectIdentifier(ticket)
        storage.withLock { $0.registrations[key] = .registering }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enqueue(ticket, continuation: continuation)
            }
        } onCancel: {
            self.cancel(ticket)
        }
        // Grant can race cancellation. A granted ticket still owns the permit
        // until this scope releases it, including while its body unwinds.
        defer { release(ticket) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func enqueue(_ ticket: Ticket, continuation: CheckedContinuation<Void, any Error>) {
        enum Resolution: Sendable { case granted, queued, cancelled }
        let resolution: Resolution = storage.withLock { stored in
            let key = ObjectIdentifier(ticket)
            guard let registration = stored.registrations[key] else {
                preconditionFailure("Missing FIFO ticket registration")
            }
            if registration == .cancelled {
                stored.registrations.removeValue(forKey: key)
                return .cancelled
            }
            precondition(registration == .registering)
            if stored.owner == nil {
                precondition(stored.queue.isEmpty)
                stored.owner = ticket
                stored.registrations.removeValue(forKey: key)
                return .granted
            }
            stored.queue.append(Waiter(ticket: ticket, continuation: continuation))
            stored.registrations[key] = .queued
            return .queued
        }
        switch resolution {
        case .granted: continuation.resume()
        case .cancelled: continuation.resume(throwing: CancellationError())
        case .queued: break
        }
    }

    private func cancel(_ ticket: Ticket) {
        let continuation: CheckedContinuation<Void, any Error>? = storage.withLock { stored in
            let key = ObjectIdentifier(ticket)
            switch stored.registrations[key] {
            case .registering:
                stored.registrations[key] = .cancelled
                return nil
            case .queued:
                guard let index = stored.queue.firstIndex(where: { $0.ticket === ticket }) else {
                    preconditionFailure("Queued FIFO ticket is missing")
                }
                let waiter = stored.queue.remove(at: index)
                stored.registrations.removeValue(forKey: key)
                return waiter.continuation
            case .cancelled, .none:
                // Already cancelled, granted or running. Never transfer a
                // running permit from this cancellation callback.
                return nil
            }
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func release(_ ticket: Ticket) {
        let next: CheckedContinuation<Void, any Error>? = storage.withLock { stored in
            precondition(stored.owner === ticket, "FIFO permit released by another ticket")
            if stored.queue.isEmpty {
                stored.owner = nil
                return nil
            }
            let waiter = stored.queue.removeFirst()
            stored.owner = waiter.ticket
            stored.registrations.removeValue(forKey: ObjectIdentifier(waiter.ticket))
            return waiter.continuation
        }
        next?.resume()
    }
}
