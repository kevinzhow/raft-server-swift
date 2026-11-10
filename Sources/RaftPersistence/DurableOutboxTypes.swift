import Foundation

/// Bounds apply before opening a transaction. The transaction bound includes all
/// prepared document bytes and effect payload bytes, across all thirteen owners.
public enum PersistenceLimits {
    public static let maximumDocumentBytes = 16 * 1024 * 1024
    public static let maximumTransactionPayloadBytes = 16 * 1024 * 1024
    public static let maximumEffectPayloadBytes = 1024 * 1024
    public static let maximumEffectsPerTransaction = 256
    public static let maximumOutboxAttempts = 10
    public static let maximumOutboxBatch = 100
}

public struct DurableEffectKind: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first,
              (97...122).contains(first), bytes.allSatisfy({
                  (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
              }) else { throw PersistenceError.invalidEffect }
        self.rawValue = rawValue
    }
}

/// Payloads may contain credentials. Never log an envelope or its payload.
/// Reuse the effect ID for reconciliation; receivers must deduplicate that ID.
public struct DurableEffect: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let effectID: UUID
    public let kind: DurableEffectKind
    public let payload: Data
    public let createdAt: Date

    public init(effectID: UUID = UUID(), kind: DurableEffectKind, payload: Data, createdAt: Date = Date()) throws {
        guard payload.count <= PersistenceLimits.maximumEffectPayloadBytes,
              createdAt.timeIntervalSince1970.isFinite else { throw PersistenceError.invalidEffect }
        self.effectID = effectID
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }

    public var description: String { "DurableEffect(redacted)" }
    public var debugDescription: String { description }
}

public enum OutboxFailureCode: String, Sendable {
    case unavailable, rejected, timedOut, cancelled, unknownOutcome
}

public struct DurableOutboxEntry: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let effect: DurableEffect
    public let sequence: Int64
    public let writerEpoch: Int64
    public let attempts: Int
    public let nextAttemptAt: Date
    public let deliveredAt: Date?
    public let exhaustedAt: Date?
    public let lastFailure: OutboxFailureCode?

    public var description: String { "DurableOutboxEntry(redacted)" }
    public var debugDescription: String { description }
}

/// An expiring dispatch permit, not proof of delivery. An executor must use
/// effect.effectID as a receiver idempotency key and acknowledge only after send.
public struct DurableOutboxClaim: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let entry: DurableOutboxEntry
    public let claimToken: UUID
    public let claimedWriterEpoch: Int64
    public let expiresAt: Date

    public var description: String { "DurableOutboxClaim(redacted)" }
    public var debugDescription: String { description }
}
