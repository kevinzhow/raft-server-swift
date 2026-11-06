import Foundation

/// One ordered JSON value whose rendered bytes are stable across processes.
///
/// Linux Foundation's `JSONEncoder` serializes a keyed container from a
/// `Dictionary`, so the same `Codable` value can emit a different key order on
/// two runs. The action-card prepare bodies were hand-built with a fixed member
/// order before the migration, and a client may read either the bytes or the
/// `Content-Length`. This tree keeps that order explicit: members are encoded
/// in the order they are declared, strings use the same `jsonString` escaping
/// the legacy bodies used, and integers/bools/null render canonically.
///
/// It is still `Encodable`; a value can round-trip through the canonical
/// `JSONEncoder` in tests or diagnostics. The `respond` overload for
/// `ExactJSONBody` uses `exactJSON` instead, which is the byte-identical path.
public indirect enum JSONBody: Sendable, Equatable, Encodable {
    case object([JSONMember])
    case array([JSONBody])
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case null

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .object(let members):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for member in members {
                guard let key = DynamicCodingKey(stringValue: member.key) else { continue }
                try container.encode(member.value, forKey: key)
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    /// The published JSON text. The escaping and separators match the legacy
    /// `Self.json` bodies: no whitespace, `jsonString` string escaping.
    public var jsonText: String {
        switch self {
        case .object(let members):
            let body = members.map { member in
                jsonString(member.key) + ":" + member.value.jsonText
            }.joined(separator: ",")
            return "{" + body + "}"
        case .array(let values):
            return "[" + values.map(\.jsonText).joined(separator: ",") + "]"
        case .string(let value):
            return jsonString(value)
        case .integer(let value):
            return String(value)
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// One ordered member of a `JSONBody.object`.
public struct JSONMember: Sendable, Equatable {
    public let key: String
    public let value: JSONBody

    public init(_ key: String, _ value: JSONBody) {
        self.key = key
        self.value = value
    }
}

/// A published body whose member order and bytes are part of the contract.
///
/// `Sources/RaftHTTPServer/Features/Respond.swift` has an overload for this
/// protocol that writes `exactJSON` with the same header set and `Content-Length`
/// as the legacy `Self.json` reply, so a migrated route keeps the bytes the
/// pre-migration handler produced.
public protocol ExactJSONBody: Encodable {
    var jsonBody: JSONBody { get }
}

public extension ExactJSONBody {
    var exactJSON: String { jsonBody.jsonText }

    func encode(to encoder: any Encoder) throws {
        try jsonBody.encode(to: encoder)
    }
}

/// A `DomainErrorWithBody` whose failure object also has a fixed member order.
public protocol DomainErrorWithExactBody: DomainErrorWithBody {
    var exactBody: any ExactJSONBody { get }
}

public extension DomainErrorWithExactBody {
    var body: any Encodable { exactBody }
}
