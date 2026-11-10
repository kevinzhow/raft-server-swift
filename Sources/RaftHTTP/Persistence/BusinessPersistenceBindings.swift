import Foundation
import RaftPersistence

/// An opaque codec over an existing owner. No owner or mutable State escapes.
/// Payloads contain credentials; never log either closure's input or output.
public struct DurableSnapshotBinding: Sendable {
    public let key: DurableKey
    let encode: @Sendable () throws -> Data
    let restore: @Sendable (Data) throws -> Void

    public init(
        key: DurableKey,
        encode: @escaping @Sendable () throws -> Data,
        restore: @escaping @Sendable (Data) throws -> Void
    ) {
        self.key = key
        self.encode = encode
        self.restore = restore
    }

    init(
        domain: DurableDomain, aggregateID: String = "root",
        encode: @escaping @Sendable () throws -> Data,
        restore: @escaping @Sendable (Data) throws -> Void
    ) throws {
        self.init(key: try DurableKey(domain: domain, aggregateID: aggregateID), encode: encode, restore: restore)
    }
}

public enum BusinessPersistenceError: Error, Sendable {
    case invalidBindings
    case incompleteSnapshot
    case invalidRevisionSet
    case invalidRevisionSetAfterCommit
    case writerUnavailable
    case notActivated
    case unavailable
}

func validateBusinessBindings(_ bindings: [DurableSnapshotBinding]) throws {
    let roots = try DurableDomain.allCases.map { try DurableKey(domain: $0, aggregateID: "root") }
    let native = try DurableKey(domain: .notifications, aggregateID: "native")
    let expected = Set(roots + [native])
    guard bindings.count == 14, Set(bindings.map(\.key)) == expected else {
        throw BusinessPersistenceError.invalidBindings
    }
}
