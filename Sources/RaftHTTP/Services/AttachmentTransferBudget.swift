import Synchronization

/// A bounded FIFO budget for attachment object-transfer preparation.
///
/// Moving attachment get/put/multipart buffer preparation out of the business
/// writer FIFO lets independent transfers overlap. Each prepared operation can
/// hold up to 200 MiB plus crypto buffers, so that overlap needs an explicit
/// bound. This budget runs at most `limit` operations at once and grants
/// additional callers permits in FIFO order.
///
/// The budget is independent of the business writer FIFO and of every other
/// instance. It bounds transfer preparation only: it does not bound overall
/// process heap, and it does not bound buffers a slow client retains while a
/// response drains. Those remain the concern of the response/connection layer.
///
/// Cancellation is checked before a caller takes a permit and while it waits in
/// the queue. A canceled waiter is removed without running its operation and
/// without consuming a permit. A permit granted at the same instant as
/// cancellation is released before the operation starts. An operation that has
/// already started is not detached: its permit is released when it returns or
/// throws, including when it observes task cancellation and unwinds. A
/// non-cooperative operation therefore keeps its permit; forcibly reclaiming it
/// would exceed `limit`.
public final class AttachmentTransferBudget: Sendable {
    /// The conservative process-wide budget for transfer preparation.
    ///
    /// Call sites that need one shared bound use this instance; tests and
    /// independent transfer paths create explicit instances so their permits
    /// cannot interact. No call site consults this value until it adopts it.
    public static let shared = AttachmentTransferBudget(limit: 4)

    private enum Registration: Sendable {
        case registering
        case queued
        case cancelled
    }

    private struct Waiter: Sendable {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Storage: Sendable {
        var active = 0
        var nextID: UInt64 = 0
        var queue: [Waiter] = []
        var registrations: [UInt64: Registration] = [:]
    }

    private let limit: Int
    private let storage = Mutex(Storage())

    public init(limit: Int) {
        precondition(limit > 0, "AttachmentTransferBudget limit must be positive")
        self.limit = limit
    }

    /// Runs `operation` while holding one permit.
    ///
    /// The permit covers the whole operation, so preparation work runs before
    /// the permit becomes available to the next waiter. The permit is returned
    /// on success, on a thrown operation error, and when the caller is canceled.
    public func withPermit<Output: Sendable>(
        _ operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        try Task.checkCancellation()
        try await acquire()
        // No suspension between acquiring and installing this release.
        defer { release() }
        // Grant can race cancellation. The permit still belongs to this scope
        // until it unwinds, so check before entering the operation.
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        if takeImmediatePermit() { return }

        let id: UInt64 = storage.withLock { stored in
            let id = stored.nextID
            stored.nextID &+= 1
            stored.registrations[id] = .registering
            return id
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                enqueue(id, continuation: continuation)
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// Takes a permit without suspending. The queue is non-empty only while
    /// every permit is active, so a free permit means no older waiter exists.
    private func takeImmediatePermit() -> Bool {
        storage.withLock { stored in
            guard stored.active < limit else { return false }
            precondition(stored.queue.isEmpty, "Transfer budget granted ahead of a queued waiter")
            stored.active += 1
            return true
        }
    }

    private func enqueue(
        _ id: UInt64,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        enum Resolution: Sendable {
            case granted
            case queued
            case cancelled
        }

        let resolution: Resolution = storage.withLock { stored in
            guard let registration = stored.registrations[id] else {
                preconditionFailure("Missing transfer-budget ticket registration")
            }
            switch registration {
            case .cancelled:
                stored.registrations.removeValue(forKey: id)
                return .cancelled
            case .queued:
                preconditionFailure("Transfer-budget ticket queued more than once")
            case .registering:
                if stored.active < limit {
                    precondition(stored.queue.isEmpty, "Transfer budget granted ahead of a queued waiter")
                    stored.active += 1
                    stored.registrations.removeValue(forKey: id)
                    return .granted
                }
                stored.queue.append(Waiter(id: id, continuation: continuation))
                stored.registrations[id] = .queued
                return .queued
            }
        }

        switch resolution {
        case .granted:
            continuation.resume()
        case .queued:
            break
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(_ id: UInt64) {
        let continuation: CheckedContinuation<Void, any Error>? = storage.withLock { stored in
            switch stored.registrations[id] {
            case .registering:
                // `enqueue` has not installed the continuation yet. Record the
                // cancellation so that enqueue resumes it without queueing.
                stored.registrations[id] = .cancelled
                return nil
            case .queued:
                guard let index = stored.queue.firstIndex(where: { $0.id == id }) else {
                    preconditionFailure("Queued transfer-budget ticket is missing")
                }
                let waiter = stored.queue.remove(at: index)
                stored.registrations.removeValue(forKey: id)
                return waiter.continuation
            case .cancelled, .none:
                // Already cancelled, granted or running. A granted permit is
                // released by its own scope, never transferred by cancellation.
                return nil
            }
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func release() {
        let next: CheckedContinuation<Void, any Error>? = storage.withLock { stored in
            precondition(stored.active > 0, "Transfer budget released without an active permit")
            stored.active -= 1
            guard !stored.queue.isEmpty else { return nil }
            let waiter = stored.queue.removeFirst()
            stored.active += 1
            stored.registrations.removeValue(forKey: waiter.id)
            return waiter.continuation
        }
        next?.resume()
    }
}
