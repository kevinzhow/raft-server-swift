import Foundation

/// A durable delivery request. The transaction coordinator must append this
/// envelope to PostgreSQL in the same commit as the corresponding business data.
public struct DurableEffectIntent: Sendable {
    public let effectID: UUID
    public let kind: String
    public let payload: Data
    public let createdAt: Date

    public init(effectID: UUID = UUID(), kind: String, payload: Data, createdAt: Date = Date()) throws {
        guard !kind.isEmpty, kind.utf8.count <= 64,
              kind.utf8.allSatisfy({ (33...126).contains($0) }),
              payload.count <= 1024 * 1024 else {
            throw DurableEffectIntentError.invalidEnvelope
        }
        self.effectID = effectID
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}

public enum DurableEffectIntentError: Error, Sendable {
    case invalidEnvelope
    case transactionRequired
}

extension DeferredEffects {
    public static func markRollbackOnly() {
        TransactionLocals.context?.markRollbackOnly()
    }

    public static func requireDurableTransaction(in domain: TransactionDomain) throws {
        guard TransactionLocals.readView == nil,
              let context = TransactionLocals.context,
              context.domain === domain,
              context.admitsDurableEffects,
              TransactionLocals.effects != nil else {
            throw DurableEffectIntentError.transactionRequired
        }
    }

    /// This records data for a durable outbox. It does not send a message or
    /// substitute an in-memory after-commit callback for delivery persistence.
    public static func persist(
        kind: String, payload: Data, effectID: UUID = UUID()
    ) throws {
        guard TransactionLocals.readView == nil,
              let context = TransactionLocals.context,
              let buffer = TransactionLocals.effects,
              !context.isClosed else {
            throw DurableEffectIntentError.transactionRequired
        }
        buffer.appendIntent(try DurableEffectIntent(effectID: effectID, kind: kind, payload: payload))
    }
}
