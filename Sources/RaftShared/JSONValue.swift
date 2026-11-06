import CoreFoundation
import Foundation


/// Canonical JSON tree used by new feature controllers and services.
///
/// Existing handlers still build JSON strings; new code should construct a
/// `JSONValue` and go through `HTTPReply.jsonValue(_:_:)` so keys, escaping and
/// number formatting are centralized.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case integer(Int64)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

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
