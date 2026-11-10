import Foundation

protocol TransactionalEmailSending: Sendable {
    func send(_ intent: TransactionalEmailIntent, outboxID: String, now: Date) async throws -> TransactionalEmailReceipt
    /// Cancels outstanding tasks and retires the transport session. Idempotent.
    func shutdown() async
}

/// Selects a real transport without changing the persisted intent codec. Provider
/// credentials and configuration are never serialized into the durable outbox.
public struct TransactionalEmailSender: Sendable {
    private let sender: any TransactionalEmailSending

    public init(configuration: TransactionalEmailConfiguration) {
        switch configuration.provider {
        case .resend: sender = ResendTransactionalEmailSender(configuration: configuration)
        case .cloudflare: sender = CloudflareTransactionalEmailSender(configuration: configuration)
        }
    }

    public func deliver(
        kind: String, codec: String, payload: Data, outboxID: String, now: Date = Date()
    ) async throws -> TransactionalEmailReceipt {
        let intent = try TransactionalEmailIntent.decodeOutboxPayload(kind: kind, codec: codec, payload: payload)
        return try await send(intent, outboxID: outboxID, now: now)
    }

    public func send(
        _ intent: TransactionalEmailIntent, outboxID: String, now: Date = Date()
    ) async throws -> TransactionalEmailReceipt {
        try await sender.send(intent, outboxID: outboxID, now: now)
    }

    /// Stops new deliveries, cancels in-flight requests and prevents the
    /// transport session's process-unsafe deallocation. Idempotent.
    public func shutdown() async {
        await sender.shutdown()
    }
}
