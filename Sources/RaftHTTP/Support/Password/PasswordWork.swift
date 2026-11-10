import Dispatch
import Foundation
import Synchronization

/// Two serial CPU workers cap live Argon2 memory at 128 MiB. The admitted
/// backlog is bounded too; dispatch never blocks a cooperative executor.
/// Only pure KDF closures run here. Store reads/commits stay on the caller Task.
enum PasswordWork {
    private static let workers = [
        DispatchQueue(label: "raft.password.0", qos: .userInitiated),
        DispatchQueue(label: "raft.password.1", qos: .userInitiated)
    ]
    private struct Admission: Sendable {
        var outstanding = [0, 0]
    }
    private static let admission = Mutex(Admission())

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let index = admission.withLock { state -> Int? in
            guard state.outstanding.reduce(0, +) < 34 else { return nil }
            let selected = state.outstanding[0] <= state.outstanding[1] ? 0 : 1
            state.outstanding[selected] += 1
            return selected
        }
        guard let index else { throw PasswordCredentialError.busy }
        let cancelled = Mutex(false)
        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workers[index].async {
                    let result: Result<Value, any Error>
                    if cancelled.withLock({ $0 }) {
                        result = .failure(CancellationError())
                    } else {
                        result = Result { try operation() }
                    }
                    admission.withLock { $0.outstanding[index] -= 1 }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return value
    }

    static func hash(_ password: String) async throws -> String {
        try await run { try PasswordCredential.hash(password) }
    }

    static func verify(_ password: String, encoded: String) async throws -> Bool {
        try await run { PasswordCredential.verify(password, encoded: encoded) }
    }
}
