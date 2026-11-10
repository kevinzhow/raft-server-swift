import Foundation
import RaftHTTP
import RaftPersistence

/// One serial consumer. PG claim/ack/failure use the runtime's business FIFO;
/// HTTP delivery happens between them, never under a PG transaction. Delivery is
/// at least once. Resend retries keep its provider idempotency key; Cloudflare
/// documents no equivalent guarantee, so ambiguous outcomes can duplicate mail.
/// An acceptance is not mailbox delivery.
struct ProductionEmailWorker: Sendable {
    private let task: Task<Void, Never>

    init(runtime: BusinessPersistenceRuntime, configuration: TransactionalEmailConfiguration) {
        let sender = TransactionalEmailSender(configuration: configuration)
        task = Task.detached {
            while !Task.isCancelled {
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
                    try Task.checkCancellation()
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
                        if Task.isCancelled { code = .cancelled }
                        else if let emailError = error as? TransactionalEmailError {
                            code = emailError.retryable ? .unavailable : .rejected
                        } else { code = .unknownOutcome }
                        try await runtime.recordFailure(claim, code: code)
                        if Task.isCancelled { return }
                        continue
                    }
                    // A failed mark is not a failed send: do not issue a second
                    // network request or overwrite an unknown acknowledgement.
                    try await runtime.markDelivered(claim)
                } catch {
                    if Task.isCancelled { return }
                    guard runtime.readinessSnapshot.isReady else { return }
                    // The database retains claims/failures, including unknown
                    // kinds and nonretryable mail, with its bounded attempt limit.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    func stop() async {
        task.cancel()
        await task.value
    }
}
