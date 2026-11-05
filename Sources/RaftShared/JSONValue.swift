import CoreFoundation
import Foundation


/// Canonical JSON tree used by new feature controllers and services.
///
/// Existing handlers still build JSON strings; new code should construct a
/// `JSONValue` and go through `HTTPReply.jsonValue(_:_:)` so keys, escaping and
/// number formatting are centralized.
public enum JSONValue: Encodable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case integer(Int64)
    case bool(Bool)
    case null

    public init(_ value: Any) throws {
        switch value {
        case let object as [String: Any]:
            var mapped: [String: JSONValue] = [:]
            for (key, element) in object { mapped[key] = try JSONValue(element) }
            self = .object(mapped)
        case let array as [Any]:
            self = .array(try array.map(JSONValue.init))
        case let string as String:
            self = .string(string)
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= Double(Int64.min), number.doubleValue <= Double(Int64.max) {
                self = .integer(number.int64Value)
            } else {
                self = .number(number.doubleValue)
            }
        case is NSNull:
            self = .null
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported JSON value"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for key in object.keys.sorted() {
                guard let codingKey = DynamicKey(stringValue: key) else { continue }
                try container.encode(object[key], forKey: codingKey)
            }
        case .array(let array):
            var container = encoder.unkeyedContainer()
            for element in array { try container.encode(element) }
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .number(let double):
            var container = encoder.singleValueContainer()
            try container.encode(double)
        case .integer(let integer):
            var container = encoder.singleValueContainer()
            try container.encode(integer)
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func string() throws -> String {
        String(decoding: try data(), as: UTF8.self)
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
