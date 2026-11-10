import Foundation
import Synchronization

/// A test-only deadline. It exists so a fixture that loses a continuation
/// wakeup, or a blocking fixture call that never returns, fails the test with a
/// diagnostic instead of parking the whole test process forever.
///
/// This is not a synchronization mechanism: it cannot resume a continuation
/// that was never resumed, and it must never replace a real signal. Use it
/// only around fixture waits whose real interleaving is already established by
/// a gate or an application call.
public struct TestDeadlineExceeded: Error, CustomStringConvertible, Sendable {
    public let label: String
    public let seconds: Double

    public init(label: String, seconds: Double) {
        self.label = label
        self.seconds = seconds
    }

    public var description: String {
        let formatted = String(format: "%.1f", seconds)
        return """
        Test did not reach '\(label)' within \(formatted)s. The operation was abandoned; \
        the usual causes are a fixture gate that resumed a continuation before the waiter \
        installed it (a lost wakeup), a blocking fixture call that never returned, or the \
        test runner being unable to write its output. The abandoned operation is not \
        evidence of a product deadlock.
        """
    }
}

/// Runs `operation` and throws ``TestDeadlineExceeded`` when it has not
/// finished in `seconds`. On expiry the operation is cancelled (a task
/// suspended on a checked continuation cannot be cancelled, so it may remain
/// suspended) and the test continues. The thrown error names the wait.
public func withTestDeadline<T: Sendable>(
    _ label: String,
    seconds: Double = 30,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let slot = Mutex<CheckedContinuation<T, any Error>?>(nil)
    let takeContinuation: @Sendable () -> CheckedContinuation<T, any Error>? = {
        slot.withLock { value in
            defer { value = nil }
            return value
        }
    }

    return try await withCheckedThrowingContinuation { continuation in
        slot.withLock { $0 = continuation }
        let body = Task { try await operation() }
        Task {
            do {
                let value = try await body.value
                takeContinuation()?.resume(returning: value)
            } catch {
                takeContinuation()?.resume(throwing: error)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            body.cancel()
            takeContinuation()?.resume(throwing: TestDeadlineExceeded(label: label, seconds: seconds))
        }
    }
}
