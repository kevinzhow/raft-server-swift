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

/// The single builder for the `issues` entries the request body schemas publish.
///
/// Pinned `routes/auth.ts:102-126` validates four bodies with zod 4.3.6 and
/// `formatBodyIssues` maps every issue to `{path, message}` (a dotted path).
/// zod 4 changed both the type wording and the length wording from zod 3
/// (`Invalid input: expected string, received undefined`,
/// `Too small: expected string to have >=1 characters`,
/// `Unrecognized key: "k"`, `Invalid input: expected object, received array`),
/// so every request route builds its list here instead of spelling the text per
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
///
/// The legacy agent send body (`packages/shared/src/agentApiMessageContract.ts`
/// `legacyAgentSendBodySchema`, used by `routes/internal.ts:680`) is the other
/// `formatBodyIssues`-style publisher. Its optional members and arrays use the
/// helpers below; the numeric and enum wording is zod 4.3.6's.
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

    /// One `z.number().finite().optional()` member: an absent key is valid.
    ///
    /// A JSON boolean, string, object, array or null receives zod's type
    /// issue; a non-finite number receives the same wording zod prints for a
    /// received non-finite number. JSON text cannot spell NaN, but the shared
    /// `JSONValue` can, and zod names it explicitly.
    static func optionalNumber(
        _ value: JSONValue?,
        path: String
    ) -> (value: Double?, issues: [AuthRequestIssue]) {
        guard let value else { return (nil, []) }
        let number: Double
        switch value {
        case .integer(let integer):
            number = Double(integer)
        case .number(let double):
            number = double
        case .object, .array, .string, .bool, .null:
            return (nil, [AuthRequestIssue(
                path: path,
                message: "Invalid input: expected number, received \(value.zodKind)"
            )])
        }
        guard number.isFinite else {
            return (nil, [AuthRequestIssue(
                path: path,
                message: "Invalid input: expected number, received \(number.isNaN ? "NaN" : "number")"
            )])
        }
        return (number, [])
    }

    /// One `z.boolean().optional()` member: an absent key is valid.
    static func optionalBoolean(
        _ value: JSONValue?,
        path: String
    ) -> (value: Bool?, issues: [AuthRequestIssue]) {
        guard let value else { return (nil, []) }
        guard case .bool(let flag) = value else {
            return (nil, [AuthRequestIssue(
                path: path,
                message: "Invalid input: expected boolean, received \(value.zodKind)"
            )])
        }
        return (flag, [])
    }

    /// The largest integer JavaScript (and therefore zod) considers safe.
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    /// One `z.number().int().positive()` array element.
    ///
    /// zod runs the integer check before the positive check but still reports
    /// both when an integer outside the safe range is also non-positive; a
    /// fractional number reports only the integer failure.
    static func integer(
        _ value: JSONValue,
        path: String,
        positive: Bool
    ) -> (value: Int?, issues: [AuthRequestIssue]) {
        func typeIssue(_ received: String) -> (Int?, [AuthRequestIssue]) {
            (nil, [AuthRequestIssue(
                path: path,
                message: "Invalid input: expected number, received \(received)"
            )])
        }
        switch value {
        case .integer(let integer):
            var issues: [AuthRequestIssue] = []
            if integer > maximumSafeInteger {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too big: expected int to be <=\(maximumSafeInteger)"
                ))
            } else if integer < -maximumSafeInteger {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too small: expected int to be >=\(-maximumSafeInteger)"
                ))
            }
            if positive, integer <= 0 {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too small: expected number to be >0"
                ))
            }
            guard issues.isEmpty, let exact = Int(exactly: integer) else {
                return (nil, issues)
            }
            return (exact, [])
        case .number(let number):
            guard number.isFinite else {
                return typeIssue(number.isNaN ? "NaN" : "number")
            }
            guard number.rounded() == number else {
                return (nil, [AuthRequestIssue(
                    path: path,
                    message: "Invalid input: expected int, received number"
                )])
            }
            var issues: [AuthRequestIssue] = []
            if number > Double(maximumSafeInteger) {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too big: expected int to be <=\(maximumSafeInteger)"
                ))
            } else if number < -Double(maximumSafeInteger) {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too small: expected int to be >=\(-maximumSafeInteger)"
                ))
            }
            if positive, number <= 0 {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too small: expected number to be >0"
                ))
            }
            guard issues.isEmpty, let exact = Int(exactly: number) else {
                return (nil, issues)
            }
            return (exact, [])
        case .object, .array, .string, .bool, .null:
            return typeIssue(value.zodKind)
        }
    }

    /// One `z.array(…)` member: an absent key is valid; any non-array is one
    /// type issue. Element issues and an array-level maximum stay with the
    /// caller so their published order matches zod's.
    static func array(
        _ value: JSONValue?,
        path: String
    ) -> (items: [JSONValue]?, issues: [AuthRequestIssue]) {
        guard let value else { return (nil, []) }
        guard case .array(let items) = value else {
            return (nil, [AuthRequestIssue(
                path: path,
                message: "Invalid input: expected array, received \(value.zodKind)"
            )])
        }
        return (items, [])
    }

    /// One `z.string().min(1).nullable().optional()` member: an absent key or
    /// JSON null is valid; a string is checked for the minimum length.
    static func nullableString(
        _ value: JSONValue?,
        path: String,
        min: Int? = nil
    ) -> (value: String?, issues: [AuthRequestIssue]) {
        guard let value, !value.isNull else { return (nil, []) }
        return string(value, path: path, min: min)
    }

    /// One `z.enum([…]).optional()` member.
    ///
    /// zod 4 reports the same `Invalid option` sentence for an invalid string
    /// and for every non-string type.
    static func enumValue(
        _ value: JSONValue?,
        path: String,
        options: [String]
    ) -> (value: String?, issues: [AuthRequestIssue]) {
        guard let value else { return (nil, []) }
        if case .string(let text) = value, options.contains(text) {
            return (text, [])
        }
        let listed = options.map { "\"\($0)\"" }.joined(separator: "|")
        return (nil, [AuthRequestIssue(
            path: path,
            message: "Invalid option: expected one of \(listed)"
        )])
    }

    /// One `z.string()….optional()` member: an absent key is valid.
    static func optionalString(
        _ value: JSONValue?,
        path: String,
        min: Int? = nil,
        max: Int? = nil,
        trim: Bool = false
    ) -> (value: String?, issues: [AuthRequestIssue]) {
        guard let value else { return (nil, []) }
        return string(value, path: path, min: min, max: max, trim: trim)
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
