import Foundation
import RaftHTTP
import RaftPersistence
import Synchronization

/// One serial consumer. PG claim/ack/failure use the runtime's business FIFO;
/// HTTP delivery happens between them, never under a PG transaction. Delivery is
/// at least once. Resend retries keep its provider idempotency key; Cloudflare
/// documents no equivalent guarantee, so ambiguous outcomes can duplicate mail.
/// An acceptance is not mailbox delivery.
struct ProductionEmailWorker: Sendable {
    private let task: Task<Void, Never>
    private let sender: TransactionalEmailSender
    private let state: ProductionEmailWorkerState

    init(runtime: BusinessPersistenceRuntime, configuration: TransactionalEmailConfiguration) {
        let sender = TransactionalEmailSender(configuration: configuration)
        let state = ProductionEmailWorkerState()
        self.sender = sender
        self.state = state
        task = Task.detached { [sender, state] in
            while !state.isStopped && !Task.isCancelled {
                do {
                    // Sender's resource timeout is40s. One claim prevents queued
                    // messages from expiring behind another network operation.
                    let kinds = try Set([
                        TransactionalEmailIntent.Kind.verifyEmail, .resetPassword,
                    ].map { try DurableEffectKind($0.rawValue) })
                    let claims = try await runtime.claimOutbox(kinds: kinds, limit: 1, visibilityTimeoutSeconds: 90)
                    guard let claim = claims.first else {
                        try await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    // No new delivery may begin after stop. The claim is left to
                    // its visibility timeout, exactly as on executor loss.
                    if state.isStopped || Task.isCancelled { return }
                    let row = claim.entry.effect
                    guard TransactionalEmailIntent.Kind(rawValue: row.kind.rawValue) != nil else {
                        try await runtime.recordFailure(claim, code: .rejected)
                        continue
                    }
                    do {
                        _ = try await sender.deliver(
                            kind: row.kind.rawValue, codec: TransactionalEmailIntent.payloadCodec,
                            payload: row.payload, outboxID: row.effectID.uuidString, now: Date()
                        )
                    } catch {
                        // Bounded codes only; errors and payloads contain secrets.
                        let code: OutboxFailureCode
                        if state.isStopped || Task.isCancelled { code = .cancelled }
                        else if let emailError = error as? TransactionalEmailError {
                            code = emailError.retryable ? .unavailable : .rejected
                        } else { code = .unknownOutcome }
                        try await runtime.recordFailure(claim, code: code)
                        if state.isStopped || Task.isCancelled { return }
                        continue
                    }
                    // A failed mark is not a failed send: do not issue a second
                    // network request or overwrite an unknown acknowledgement.
                    try await runtime.markDelivered(claim)
                } catch {
                    if state.isStopped || Task.isCancelled { return }
                    guard runtime.readinessSnapshot.isReady else { return }
                    // The database retains claims/failures, including unknown
                    // kinds and nonretryable mail, with its bounded attempt limit.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Stops admission first, then cancels the in-flight URL request, then joins
    /// the worker. The worker task itself is never cancelled here: cancelling it
    /// in the middle of `recordFailure` closes the PostgreSQL writer connection
    /// mid-transaction and can stall `runtime.close()` for the whole statement
    /// deadline. The remaining waits are the sender's bounded invalidation wait
    /// and one already-admitted PostgreSQL operation.
    func stop() async {
        state.stop()
        await sender.shutdown()
        await task.value
    }
}

/// Shared by the worker task and `stop()`; `ProductionEmailWorker` is a value.
private final class ProductionEmailWorkerState: Sendable {
    private let stopped = Mutex(false)

    var isStopped: Bool { stopped.withLock { $0 } }

    func stop() { stopped.withLock { $0 = true } }
}
