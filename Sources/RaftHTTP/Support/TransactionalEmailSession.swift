import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// swift-corelibs-foundation 6.4 tears down a `URLSession`'s libcurl multi handle
/// synchronously inside `_MultiHandle.deinit`. That cleanup unregisters sockets by
/// enqueueing `_SocketSources` blocks which call back into the same multi handle.
/// For an established (keep-alive) TLS connection libcurl additionally runs its
/// close-notify path during cleanup, so those callbacks can fire after deinit has
/// begun. The Swift runtime then aborts the process with
/// "`_MultiHandle` deallocated with non-zero retain count 2"
/// (swift-corelibs-foundation issues 5203 and 5491).
///
/// A session that has ever started a task can therefore not be released safely
/// while the process keeps running. Retaining it until process exit is
/// deliberate: Swift globals are never deinitialized, so the multi-handle
/// teardown never runs. Production builds one email sender (and therefore one
/// session); tests create a bounded number.
enum TransactionalEmailSessionRetirement {
    private static let sessions = Mutex<[URLSession]>([])

    static func retire(_ session: URLSession) {
        sessions.withLock { retained in
            guard !retained.contains(where: { $0 === session }) else { return }
            retained.append(session)
        }
    }
}

/// Signals the URLSession delegate's `didBecomeInvalid` callback. The bounded
/// wait only drains invalidation; it does not make session deallocation safe.
final class TransactionalEmailInvalidationSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let fired = Mutex(false)

    init() {
        let pair = AsyncStream.makeStream(of: Void.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        let first = fired.withLock { alreadyFired -> Bool in
            guard !alreadyFired else { return false }
            alreadyFired = true
            return true
        }
        guard first else { return }
        continuation.yield(())
        continuation.finish()
    }

    /// `AsyncStream` iteration is cancellation-aware, so the timeout arm cannot
    /// leave this wait suspended after the task group has been cancelled.
    func wait(upTo duration: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [stream] in
                for await _ in stream { break }
            }
            group.addTask {
                try? await Task.sleep(for: duration)
            }
            await group.next()
            group.cancelAll()
        }
    }
}

/// One process-owned transport for both email providers.
///
/// `shutdown()` and `perform(_:)` share a lifecycle lock so the session can
/// never be invalidated between creating and resuming a task. Creating a task
/// on an invalidated `URLSession` traps in swift-corelibs-foundation, so that
/// window must not exist while the worker is winding down.
final class TransactionalEmailTransport: Sendable {
    private let session: URLSession
    private let invalidation: TransactionalEmailInvalidationSignal
    private let closed = Mutex(false)

    init() {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 40
        settings.httpShouldSetCookies = false
        settings.urlCache = nil
        let invalidation = TransactionalEmailInvalidationSignal()
        self.invalidation = invalidation
        session = URLSession(
            configuration: settings,
            delegate: TransactionalEmailNoRedirects(onInvalidated: { invalidation.signal() }),
            delegateQueue: nil
        )
    }

    deinit {
        // Never release a used session here: Foundation's multi-handle teardown
        // can abort the process. See `TransactionalEmailSessionRetirement`.
        TransactionalEmailSessionRetirement.retire(session)
        session.invalidateAndCancel()
    }

    /// Runs one request. `shutdown` may cancel it at any point after the task is
    /// created; the completion then reports the URL loading error to the caller.
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let created = closed.withLock { isClosed -> Bool in
                guard !isClosed else { return false }
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: TransactionalEmailError.invalidProviderResponse)
                    }
                }
                task.resume()
                return true
            }
            if !created {
                continuation.resume(throwing: TransactionalEmailError.transportFailure)
            }
        }
    }

    /// Stops new tasks, cancels outstanding ones, waits a bounded time for the
    /// session invalidation callback, then retires the session so its
    /// multi-handle teardown cannot run during process shutdown. Idempotent.
    func shutdown() async {
        let first = closed.withLock { isClosed -> Bool in
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        if first { session.invalidateAndCancel() }
        await invalidation.wait(upTo: .seconds(2))
        TransactionalEmailSessionRetirement.retire(session)
    }
}
