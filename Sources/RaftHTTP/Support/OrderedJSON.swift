import Foundation

/// One `{"key":value}` member whose position in the printed object is the
/// position of the field in the array it belongs to.
public struct OrderedJSONField: Sendable, Equatable {
    public let key: String
    public let value: OrderedJSON

    public init(_ key: String, _ value: OrderedJSON) {
        self.key = key
        self.value = value
    }
}

/// A JSON tree that prints object members in declared order.
///
/// `JSONEncoder` on Linux stores keyed containers in a dictionary, so the same
/// value prints the same object members in different orders across encodes.
/// A domain whose published body has a fixed key order that is not
/// alphabetical builds this tree instead, and `Respond.swift` prints it exactly
/// once. String bytes go through the module's `jsonString` escaper, so escaping
/// stays identical to the legacy `Self.json` bodies.
public enum OrderedJSON: Sendable, Equatable {
    case object([OrderedJSONField])
    case array([OrderedJSON])
    case string(String)
    case bool(Bool)
    case int(Int)
    case null

    public func serialized() -> String {
        switch self {
        case .object(let fields):
            var out = "{"
            for (index, field) in fields.enumerated() {
                if index > 0 { out += "," }
                out += jsonString(field.key)
                out += ":"
                out += field.value.serialized()
            }
            return out + "}"
        case .array(let values):
            return "[" + values.map { $0.serialized() }.joined(separator: ",") + "]"
        case .string(let value):
            return jsonString(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .null:
            return "null"
        }
    }

    /// A string, or the JSON `null` an absent optional publishes.
    public static func stringOrNull(_ value: String?) -> OrderedJSON {
        value.map { .string($0) } ?? .null
    }

    /// A preformatted ISO-8601 string, or `null` for an absent date.
    public static func timestampOrNull(_ value: String?) -> OrderedJSON {
        value.map { .string($0) } ?? .null
    }
}

/// A response body that owns its published byte order.
///
/// A conforming DTO selects the ordered overload of
/// `Sources/RaftHTTPServer/Features/Respond.swift`, which prints
/// `orderedJSON` as-is instead of going through `JSONEncoder`. Every key the
/// body publishes — including a literal `null` — has to appear in
/// `orderedJSON`; the encoder never fills one in.
public protocol OrderedJSONBody: Encodable {
    var orderedJSON: OrderedJSON { get }
}
