import Foundation
import RaftShared

/// A top-level JSON object body read member by member with the retired
/// handlers' cast rules.
///
/// The retired routes parsed the body with a raw object cast and read each
/// member with `as?`, so a member of the wrong type read as absent while a
/// present member (explicit `null` included) stayed distinguishable from a
/// missing one. `fields` keeps that: a key is present exactly when the request
/// carried it. A body that is not a JSON object does not decode, and the route
/// falls back to the empty request, which is the `?? [:]` the old parser used.
public struct LegacyJSONObjectBody: Decodable, Sendable, Equatable {
    public let fields: [String: JSONValue]

    public init(fields: [String: JSONValue] = [:]) {
        self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        fields = try container.decode([String: JSONValue].self)
    }

    public subscript(key: String) -> JSONValue? {
        fields[key]
    }

    public func string(_ key: String) -> String? {
        fields[key]?.legacyString
    }
}

extension JSONValue {
    /// Foundation `as? Bool` over the `NSNumber` bridge: a JSON boolean, and
    /// the numbers `0` and `1` (any other number is not a boolean).
    var bridgedBool: Bool? {
        switch self {
        case .bool(let value):
            value
        case .integer(let value):
            value == 0 ? false : (value == 1 ? true : nil)
        case .number(let value):
            value == 0 ? false : (value == 1 ? true : nil)
        default:
            nil
        }
    }

    /// Foundation `as? Int` over the `NSNumber` bridge: an integral number or a
    /// JSON boolean (`true` is `1`).
    var bridgedInt: Int? {
        switch self {
        case .bool(let value):
            value ? 1 : 0
        case .integer(let value):
            Int(exactly: value)
        case .number(let value):
            Int(exactly: value)
        default:
            nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
