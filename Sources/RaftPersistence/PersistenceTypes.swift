import Foundation

/// The thirteen owner boundaries. A codec must define the aggregate keys and
/// schema of its own domain; this enumeration does not persist an in-memory store.
public enum DurableDomain: String, Codable, CaseIterable, Sendable {
    case authProfiles = "auth_profiles"
    case notifications = "notifications"
    case productEvents = "product_events"
    case inboxFacts = "inbox_facts"
    case threadFollows = "thread_follows"
    case messagesAndThreads = "messages_and_threads"
    case agentsRuntime = "agents_runtime"
    case tasksAndReminders = "tasks_and_reminders"
    case machinesAndComputers = "machines_and_computers"
    case serversAndChannels = "servers_and_channels"
    case managedMCPAndCards = "managed_mcp_and_cards"
    case feedback = "feedback"
    case oauthLedger = "oauth_ledger"
}

public struct DurableKey: Hashable, Sendable {
    public let domain: DurableDomain
    public let aggregateID: String

    public init(domain: DurableDomain, aggregateID: String) throws {
        guard !aggregateID.isEmpty, aggregateID.utf8.count <= 512,
              !aggregateID.utf8.contains(0) else { throw PersistenceError.invalidAggregateKey }
        self.domain = domain
        self.aggregateID = aggregateID
    }

    var orderingKey: String { domain.rawValue + "\u{0}" + aggregateID }
}

/// An immutable database result. JSON decoding is explicit and version checked.
public struct DurableDocument: Sendable {
    public let key: DurableKey
    public let revision: Int64
    public let codecVersion: Int
    public let updatedAt: Date
    public let json: Data

    public func decode<Value: Decodable & Sendable>(
        _ type: Value.Type, codecVersion expected: Int
    ) throws -> Value {
        guard codecVersion == expected else {
            throw PersistenceError.codecVersionMismatch(expected: expected, actual: codecVersion)
        }
        do { return try JSONDecoder().decode(type, from: json) }
        catch { throw PersistenceError.invalidDocument }
    }
}

/// Include every aggregate read by a command, including rows that the command
/// will not write. An absent expectation also protects an absence-based decision.
public struct DurableCondition: Sendable {
    public let key: DurableKey
    public let expectedRevision: Int64?

    public init(key: DurableKey, expectedRevision: Int64?) throws {
        if let expectedRevision, expectedRevision <= 0 { throw PersistenceError.invalidRevision }
        self.key = key
        self.expectedRevision = expectedRevision
    }
}

public struct DurableRevision: Sendable, Equatable {
    public let key: DurableKey
    public let revision: Int64
    public let deleted: Bool
}

/// A prepared write contains data, never an owner callback. Nil expectedRevision
/// means create only when no live row exists. A revision means replace that exact
/// live revision. Deleted rows retain their revision to prevent delete/recreate ABA.
public struct DurableWrite: Sendable {
    let key: DurableKey
    let expectedRevision: Int64?
    let operation: Operation

    enum Operation: Sendable {
        case put(codecVersion: Int32, json: String)
        case delete
    }

    public static func put<Value: Encodable & Sendable>(
        _ value: Value, key: DurableKey, codecVersion: Int,
        expectedRevision: Int64?
    ) throws -> Self {
        try validateRevision(expectedRevision)
        guard codecVersion > 0, codecVersion <= Int(Int32.max) else {
            throw PersistenceError.invalidCodecVersion
        }
        let bytes: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bytes = try encoder.encode(value)
        } catch { throw PersistenceError.invalidDocument }
        guard bytes.count <= 16 * 1024 * 1024,
              let json = String(data: bytes, encoding: .utf8) else {
            throw PersistenceError.documentTooLarge
        }
        return Self(key: key, expectedRevision: expectedRevision,
                    operation: .put(codecVersion: Int32(codecVersion), json: json))
    }

    public static func delete(key: DurableKey, expectedRevision: Int64) throws -> Self {
        try validateRevision(expectedRevision)
        return Self(key: key, expectedRevision: expectedRevision, operation: .delete)
    }

    private static func validateRevision(_ revision: Int64?) throws {
        if let revision, revision <= 0 || revision == Int64.max {
            throw PersistenceError.invalidRevision
        }
    }
}

/// Descriptions deliberately omit URLs, passwords, SQL, bindings and documents.
/// SQLSTATE 40001/40P01 permits retry only after re-reading and re-running the
/// domain transaction. A commit outcome error requires reconciliation, not replay.
public enum PersistenceError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidConfiguration(String)
    case closed
    case notReady
    case timedOut
    case invalidAggregateKey
    case invalidRevision
    case invalidCodecVersion
    case invalidDocument
    case documentTooLarge
    case invalidBatch
    case conflict(expected: Int64?, actual: Int64?)
    case codecVersionMismatch(expected: Int, actual: Int)
    case schemaMismatch(version: Int64)
    case schemaNotCurrent
    case database(operation: String, sqlState: String?, driverCode: String)
    case commitOutcomeUnknown(sqlState: String?)
    case rollbackFailed
    case writerLeaseRequired
    case writerLeaseLost
    case writerBusy
    case writerEpochMismatch
    case writerEpochExhausted
    case invalidWriterLeaseConfiguration
    case invalidEffect
    case transactionTooLarge
    case invalidOutboxRequest
    case outboxClaimLost

    public var description: String {
        switch self {
        case .invalidConfiguration(let field): "Invalid PostgreSQL configuration: \(field)"
        case .closed: "PostgreSQL persistence is closed"
        case .notReady: "PostgreSQL persistence is not ready"
        case .timedOut: "PostgreSQL operation exceeded its deadline"
        case .invalidAggregateKey: "Invalid durable aggregate key"
        case .invalidRevision: "Invalid durable revision"
        case .invalidCodecVersion: "Invalid durable codec version"
        case .invalidDocument: "Durable document encoding or decoding failed"
        case .documentTooLarge: "Durable document exceeds the size limit"
        case .invalidBatch: "Durable transaction requires 1...256 distinct keys"
        case .conflict: "Durable aggregate revision conflict"
        case .codecVersionMismatch: "Durable document codec version mismatch"
        case .schemaMismatch(let version): "PostgreSQL migration mismatch at version \(version)"
        case .schemaNotCurrent: "PostgreSQL schema is not current"
        case .database(let operation, let state, let code):
            "PostgreSQL \(operation) failed (\(state ?? code))"
        case .commitOutcomeUnknown(let state):
            "PostgreSQL commit outcome requires reconciliation (\(state ?? "unavailable"))"
        case .rollbackFailed: "PostgreSQL transaction rollback failed"
        case .writerLeaseRequired: "An active PostgreSQL writer lease and epoch are required"
        case .writerLeaseLost: "PostgreSQL writer lease was lost; claim again and reload before admitting work"
        case .writerBusy: "PostgreSQL writer connection is already processing a command"
        case .writerEpochMismatch: "PostgreSQL writer epoch is no longer current"
        case .writerEpochExhausted: "PostgreSQL writer epoch cannot advance"
        case .invalidWriterLeaseConfiguration: "Invalid PostgreSQL writer heartbeat configuration"
        case .invalidEffect: "Invalid durable effect envelope"
        case .transactionTooLarge: "Durable transaction exceeds the total payload size limit"
        case .invalidOutboxRequest: "Invalid durable outbox request"
        case .outboxClaimLost: "Durable outbox claim expired or is no longer current"
        }
    }
}
