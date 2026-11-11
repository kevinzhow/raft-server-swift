import Foundation
import RaftShared

/// One entry of the published `issues` list of a body-schema 400.
public struct AuthRequestIssue: Sendable, Equatable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// The single builder for the `issues` entries the auth body schemas publish.
///
/// Pinned `routes/auth.ts:102-126` validates four bodies with zod 4.3.6 and
/// `formatBodyIssues` maps every issue to `{path, message}` (a dotted path).
/// zod 4 changed both the type wording and the length wording from zod 3
/// (`Invalid input: expected string, received undefined`,
/// `Too small: expected string to have >=1 characters`,
/// `Unrecognized key: "k"`, `Invalid input: expected object, received array`),
/// so every auth route builds its list here instead of spelling the text per
/// route. The pinned schemas are:
///
/// - `emailRegisterRequestSchema` (`routes/auth.ts:102`) — passthrough object,
///   `email`/`password` `z.string().min(1)`, optional `name` `.min(1)`, optional
///   `stagingSelfAccountCapability` `.min(32).max(256)`.
/// - `emailLoginRequestSchema` (`routes/auth.ts:114`) — passthrough object,
///   `email`/`password` `.min(1)`.
/// - `completeProfileRequestSchema` (`routes/auth.ts:109`) — strict object,
///   `name` `.min(1)`, `displayName` `.trim().min(1).max(80)`.
/// - `timezoneObservationRequestSchema` (`routes/auth.ts:119`) — strict object,
///   one `timezone` string.
///
/// Every pinned route parses `req.body ?? {}`, so an absent body or JSON `null`
/// is the empty object and reports the required members; any other non-object
/// root is one `expected object` issue naming the received type.
enum AuthRequestSchema {
    /// The members of `req.body ?? {}`, plus the root issue when the body is a
    /// non-object JSON value other than `null`.
    static func objectFields(_ raw: JSONValue?) -> (fields: [String: JSONValue], rootIssue: AuthRequestIssue?) {
        guard let raw else { return ([:], nil) }
        if case .null = raw { return ([:], nil) }
        if case .object(let fields) = raw { return (fields, nil) }
        return ([:], AuthRequestIssue(
            path: "",
            message: "Invalid input: expected object, received \(raw.zodKind)"
        ))
    }

    /// One required `z.string().min(_)` / `.max(_)` member.
    ///
    /// A missing member is `received undefined`. A non-string receives the
    /// type issue; when the value is a JSON array zod also runs the same
    /// length check against the array (`Too small: expected array to have
    /// >=N items`), which the pinned schema does too. Lengths are UTF-16 code
    /// units because the upstream checks JavaScript `String.length`.
    static func string(
        _ value: JSONValue?,
        path: String,
        min: Int? = nil,
        max: Int? = nil,
        trim: Bool = false
    ) -> (value: String?, issues: [AuthRequestIssue]) {
        guard let value else {
            return (nil, [AuthRequestIssue(
                path: path,
                message: "Invalid input: expected string, received undefined"
            )])
        }
        guard case .string(var text) = value else {
            var issues = [AuthRequestIssue(
                path: path,
                message: "Invalid input: expected string, received \(value.zodKind)"
            )]
            if case .array(let items) = value {
                if let min, items.count < min {
                    issues.append(AuthRequestIssue(
                        path: path,
                        message: "Too small: expected array to have >=\(min) items"
                    ))
                }
                if let max, items.count > max {
                    issues.append(AuthRequestIssue(
                        path: path,
                        message: "Too big: expected array to have <=\(max) items"
                    ))
                }
            }
            return (nil, issues)
        }
        if trim { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let length = text.utf16.count
        if let min, length < min {
            return (nil, [AuthRequestIssue(
                path: path,
                message: "Too small: expected string to have >=\(min) characters"
            )])
        }
        if let max, length > max {
            return (nil, [AuthRequestIssue(
                path: path,
                message: "Too big: expected string to have <=\(max) characters"
            )])
        }
        return (text, [])
    }

    /// One `z.string()….optional()` member: an absent key is valid.
    static func optionalString(
        _ value: JSONValue?,
        path: String,
        min: Int? = nil,
        max: Int? = nil
    ) -> (value: String?, issues: [AuthRequestIssue]) {
        guard let value else { return (nil, []) }
        return string(value, path: path, min: min, max: max)
    }

    /// The single issue `.strict()` reports for each member the shape does not
    /// know, emitted after the shape's own issues.
    ///
    /// Upstream prints the keys in the received member order (zod's `keys`
    /// order). The Swift JSON object is a dictionary without order, so the keys
    /// are sorted to keep the published bytes stable for multi-key bodies.
    static func unrecognizedKeys(_ unknown: [String]) -> AuthRequestIssue? {
        guard !unknown.isEmpty else { return nil }
        let keys = unknown.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        let label = unknown.count > 1 ? "Unrecognized keys" : "Unrecognized key"
        return AuthRequestIssue(path: "", message: "\(label): \(keys)")
    }
}

extension AuthRequestIssue {
    /// The published entry: `path`, then `message`.
    var json: OrderedJSON {
        .object([
            OrderedJSONField("path", path),
            OrderedJSONField("message", message),
        ])
    }
}

extension JSONValue {
    /// The JSON type name zod 4 prints for a received value.
    var zodKind: String {
        switch self {
        case .object: "object"
        case .array: "array"
        case .string: "string"
        case .number, .integer: "number"
        case .bool: "boolean"
        case .null: "null"
        }
    }
}
