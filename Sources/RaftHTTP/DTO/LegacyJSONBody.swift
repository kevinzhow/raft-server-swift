import Foundation
import RaftShared

// Lenient request bodies for the managed-MCP, reminder and history routes.
//
// The retired handlers parsed the raw body into an untyped object and read each
// member with a Foundation `as?` cast, so a member of the wrong type read as
// absent while a body that was not a JSON object failed as a whole. These types
// keep that: the root is read as a `JSONValue` tree and each member is
// projected with the cast rules measured on the Linux Foundation bridge.

/// A top-level JSON object whose members are read one by one. A body that is
/// not a JSON object does not decode.
public struct LegacyJSONObjectBody: Decodable, Sendable, Equatable {
    public let members: [String: JSONValue]

    public init(members: [String: JSONValue] = [:]) {
        self.members = members
    }

    public init(from decoder: any Decoder) throws {
        guard case .object(let members) = try JSONValue(from: decoder) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a JSON object"
            ))
        }
        self.members = members
    }

    /// A member by key; present exactly when the request carried it, an
    /// explicit `null` included.
    public subscript(key: String) -> JSONValue? {
        members[key]
    }

    public func string(_ key: String) -> String? {
        members[key]?.legacyString
    }
}

extension JSONValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// `value as? String`: JSON strings only.
    var castString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// `value as? Bool` over the Foundation number bridge: a JSON boolean, or
    /// a number equal to `0` or `1`.
    var castBool: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .integer(let value):
            return value == 0 ? false : (value == 1 ? true : nil)
        case .number(let value):
            return value == 0 ? false : (value == 1 ? true : nil)
        default:
            return nil
        }
    }

    /// `value as? Int`: an integer, a number with an exact integer value, or a
    /// boolean (`0`/`1`).
    var castInt: Int? {
        switch self {
        case .bool(let value):
            return value ? 1 : 0
        case .integer(let value):
            return Int(exactly: value)
        case .number(let value):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    /// A JSON object member map.
    var castObject: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    /// A JSON array.
    var castArray: [JSONValue]? {
        if case .array(let elements) = self { return elements }
        return nil
    }
}
