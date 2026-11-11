import Foundation
import RaftShared

/// One request part of an agent-api contract route.
public enum AgentApiContractPart: String, Sendable, CaseIterable {
    case params
    case query
    case body
}

/// The published 400 for one request part that the route's shared schema
/// rejects.
///
/// Pinned `packages/server/src/routes/internalAgentApi.ts:402-431` validates
/// params, query and body with the `agentApiContract` zod schema of the route
/// and answers:
///
/// ```json
/// {"error":"Invalid agent-api <routeKey> <part>",
///  "code":"agent_api_contract_invalid",
///  "issues":[{"path":"…","message":"…"}]}
/// ```
///
/// Every route builds its body here instead of spelling the shape per route;
/// `DomainError` carries it to `Respond.swift` like any other domain failure.
public struct AgentApiContractFailure: Error, Sendable, Equatable, DomainError {
    public let routeKey: String
    public let part: AgentApiContractPart
    public let issues: [AuthRequestIssue]

    public init(routeKey: String, part: AgentApiContractPart, issues: [AuthRequestIssue]) {
        self.routeKey = routeKey
        self.part = part
        self.issues = issues
    }

    public var status: UInt { 400 }

    public var errorMessage: String {
        "Invalid agent-api \(routeKey) \(part.rawValue)"
    }

    public var errorBody: OrderedJSON? {
        .object([
            OrderedJSONField("error", errorMessage),
            OrderedJSONField("code", "agent_api_contract_invalid"),
            OrderedJSONField("issues", .array(issues.map(\.json))),
        ])
    }
}

/// One field of a contract object schema, in published shape order.
struct AgentApiContractField: Sendable {
    let name: String
    let schema: AgentApiContractSchema
    let required: Bool

    static func field(
        _ name: String,
        _ schema: AgentApiContractSchema,
        required: Bool = false
    ) -> AgentApiContractField {
        AgentApiContractField(name: name, schema: schema, required: required)
    }
}

/// A `.passthrough()` / `.strict()` object from an `agentApiContract` schema.
struct AgentApiContractObject: Sendable {
    var fields: [AgentApiContractField]
    var strict: Bool
    var refinements: [AgentApiContractRefinement]

    init(
        _ fields: [AgentApiContractField],
        strict: Bool = false,
        refinements: [AgentApiContractRefinement] = []
    ) {
        self.fields = fields
        self.strict = strict
        self.refinements = refinements
    }
}

/// A custom whole-object check (`.refine` / `.superRefine`) that runs only
/// after every member parses, exactly like zod.
enum AgentApiContractRefinement: Sendable {
    /// Counts members that are present and not `undefined`; any other count is
    /// the published custom message.
    case exactlyOneOf([String], String)
    /// At least one of the members is present and not `undefined`.
    case atLeastOneOf([String], String)

    func message(fields: [String: JSONValue]) -> String? {
        switch self {
        case .exactlyOneOf(let names, let message):
            let count = names.count { fields[$0] != nil }
            return count == 1 ? nil : message
        case .atLeastOneOf(let names, let message):
            return names.contains { fields[$0] != nil } ? nil : message
        }
    }
}

/// A member-level `.refine` on a trimmed string.
enum AgentApiStringRefinement: Sendable {
    /// `startsWith("@") && slice(1).trim().length > 0`.
    case atHandle(String)
    /// `!/\s/.test(value)`.
    case noWhitespace(String)

    func message(for text: String) -> String? {
        switch self {
        case .atHandle(let message):
            return text.hasPrefix("@")
                && !text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : message
        case .noWhitespace(let message):
            return text.contains(where: \.isWhitespace) ? message : nil
        }
    }
}

/// The zod construct the contract schema uses for one request member.
indirect enum AgentApiContractSchema: Sendable {
    case string(
        min: Int?,
        max: Int?,
        trim: Bool,
        pattern: String?,
        patternMessage: String?,
        refinement: AgentApiStringRefinement?
    )
    case number(int: Bool, positive: Bool, nonnegative: Bool, max: Double?)
    case coerceNumber(int: Bool, positive: Bool)
    case boolean
    case literal(String)
    case enumeration([String])
    case array(AgentApiContractSchema, min: Int?, max: Int?)
    case object(AgentApiContractObject)
    case record(AgentApiContractSchema)
    case union([AgentApiContractSchema])
    case discriminatedUnion(discriminator: String, members: [AgentApiContractSchema])
    /// `z.<schema>.nullable()`: JSON `null` is a valid value; absence still
    /// reports the inner schema's `undefined` issue.
    case nullable(AgentApiContractSchema)
    case any

    static func text(
        trim: Bool = false,
        min: Int? = nil,
        max: Int? = nil,
        pattern: String? = nil,
        patternMessage: String? = nil,
        refinement: AgentApiStringRefinement? = nil
    ) -> AgentApiContractSchema {
        .string(
            min: min,
            max: max,
            trim: trim,
            pattern: pattern,
            patternMessage: patternMessage,
            refinement: refinement
        )
    }

    static func list(
        _ element: AgentApiContractSchema,
        min: Int? = nil,
        max: Int? = nil
    ) -> AgentApiContractSchema {
        .array(element, min: min, max: max)
    }

    static func integer(
        positive: Bool = false,
        nonnegative: Bool = false,
        max: Double? = nil
    ) -> AgentApiContractSchema {
        .number(int: true, positive: positive, nonnegative: nonnegative, max: max)
    }

    static func decimal() -> AgentApiContractSchema {
        .number(int: false, positive: false, nonnegative: false, max: nil)
    }

    static func uuid() -> AgentApiContractSchema {
        .text(pattern: AgentApiContractPatterns.uuid, patternMessage: "Invalid UUID")
    }

    static func datetime() -> AgentApiContractSchema {
        .text(pattern: AgentApiContractPatterns.datetime, patternMessage: "Invalid ISO datetime")
    }

    static func positiveIntegerString() -> AgentApiContractSchema {
        .text(
            trim: true,
            pattern: "^[1-9][0-9]*$",
            patternMessage: "must be a positive integer"
        )
    }

    static func nonNegativeIntegerString(
        message: String = "must be a non-negative integer"
    ) -> AgentApiContractSchema {
        .text(trim: true, pattern: "^(0|[1-9][0-9]*)$", patternMessage: message)
    }
}

enum AgentApiContractPatterns {
    /// `regexes.cjs` `uuid()` without a version argument.
    static let uuid = "^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$"

    /// `regexes.cjs` `datetime()` with the default options: calendar-valid
    /// date, `T`, `HH:MM` with optional `:SS[.fraction]`, and a literal `Z`.
    static let datetime = "^(?:(?:\\d\\d[2468][048]|\\d\\d[13579][26]|\\d\\d0[48]|[02468][048]00|[13579][26]00)-02-29|\\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\\d|30)|(?:02)-(?:0[1-9]|1\\d|2[0-8])))T(?:[01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d(?:\\.\\d+)?)?Z$"

    /// JavaScript's largest exactly-representable integer.
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
}

enum AgentApiContractSchemaValidator {
    /// One schema parse: the published issues plus zod's abort state.
    ///
    /// zod 4.3.6 (`core/schemas.js`, `$ZodType`'s `runChecks`) starts
    /// `isAborted = util.aborted(payload)` and skips every check while that is
    /// true. `util.aborted` (`core/util.js`) treats an issue as continuable
    /// only when `continue === true`; the checks these contract schemas use
    /// (`min`/`max`, `regex`, `positive`, and `int`'s safe-range guard) set
    /// that, while parse failures (`invalid_type` for a wrong or missing
    /// member, `invalid_value` for enum/literal, `invalid_union`) leave it
    /// unset. An object `.refine`/`.superRefine` is such a check, so it runs
    /// after continuable member issues but is skipped after an aborting one.
    private struct ParseResult {
        var issues: [AuthRequestIssue] = []
        var aborted = false
    }

    /// The issues of one value against one schema, with `nil` meaning the JS
    /// `undefined` an absent member has.
    static func issues(
        _ schema: AgentApiContractSchema,
        _ value: JSONValue?,
        path: String
    ) -> [AuthRequestIssue] {
        result(schema, value, path: path).issues
    }

    private static func result(
        _ schema: AgentApiContractSchema,
        _ value: JSONValue?,
        path: String
    ) -> ParseResult {
        guard let value else { return missingResult(schema, path: path) }
        switch schema {
        case .any:
            return ParseResult()
        case .string(_, _, _, _, _, _):
            return stringResult(schema, value, path: path)
        case .number(let int, let positive, let nonnegative, let max):
            return numberResult(
                for: value,
                path: path,
                int: int,
                positive: positive,
                nonnegative: nonnegative,
                max: max
            )
        case .coerceNumber(let int, let positive):
            return coerceNumberResult(value, path: path, int: int, positive: positive)
        case .boolean:
            guard case .bool = value else {
                return ParseResult(
                    issues: [typeIssue("boolean", received: value.zodKind, path: path)],
                    aborted: true
                )
            }
            return ParseResult()
        case .literal(let expected):
            if case .string(let text) = value, text == expected { return ParseResult() }
            return ParseResult(
                issues: [AuthRequestIssue(
                    path: path,
                    message: "Invalid input: expected \"\(expected)\""
                )],
                aborted: true
            )
        case .enumeration(let options):
            if case .string(let text) = value, options.contains(text) { return ParseResult() }
            return ParseResult(
                issues: [AuthRequestIssue(path: path, message: enumMessage(options))],
                aborted: true
            )
        case .array(let element, let min, let max):
            return arrayResult(element, value, path: path, min: min, max: max)
        case .object(let object):
            return objectResult(object, value, path: path)
        case .record(let element):
            return recordResult(element, value, path: path)
        case .union(let options):
            for option in options where self.result(option, value, path: path).issues.isEmpty {
                return ParseResult()
            }
            return ParseResult(
                issues: [AuthRequestIssue(path: path, message: "Invalid input")],
                aborted: true
            )
        case .discriminatedUnion(let discriminator, let members):
            return discriminatedUnionResult(
                discriminator: discriminator,
                members: members,
                value: value,
                path: path
            )
        case .nullable(let inner):
            if case .null = value { return ParseResult() }
            return self.result(inner, value, path: path)
        }
    }

    // MARK: - Objects

    private static func objectResult(
        _ object: AgentApiContractObject,
        _ value: JSONValue,
        path: String
    ) -> ParseResult {
        guard case .object(let members) = value else {
            return ParseResult(
                issues: [typeIssue("object", received: value.zodKind, path: path)],
                aborted: true
            )
        }
        var result = ParseResult()
        for field in object.fields {
            let child = members[field.name]
            let childPath = join(path, field.name)
            if child == nil {
                if field.required {
                    let missing = missingResult(field.schema, path: childPath)
                    result.issues += missing.issues
                    result.aborted = result.aborted || missing.aborted
                }
                continue
            }
            let parsed = self.result(field.schema, child, path: childPath)
            result.issues += parsed.issues
            result.aborted = result.aborted || parsed.aborted
        }
        if object.strict {
            let known = Set(object.fields.map(\.name))
            let unknown = members.keys.filter { !known.contains($0) }
            if let issue = AuthRequestSchema.unrecognizedKeys(unknown) {
                result.issues.append(AuthRequestIssue(path: path, message: issue.message))
                // `unrecognized_keys` has no `continue: true`; zod skips the
                // object's own checks after it.
                result.aborted = true
            }
        }
        guard !result.aborted else { return result }
        for refinement in object.refinements {
            if let message = refinement.message(fields: members) {
                result.issues.append(AuthRequestIssue(path: path, message: message))
            }
        }
        return result
    }

    private static func arrayResult(
        _ element: AgentApiContractSchema,
        _ value: JSONValue,
        path: String,
        min: Int?,
        max: Int?
    ) -> ParseResult {
        guard case .array(let items) = value else {
            return ParseResult(
                issues: [typeIssue("array", received: value.zodKind, path: path)],
                aborted: true
            )
        }
        var result = ParseResult()
        for (index, item) in items.enumerated() {
            let parsed = self.result(element, item, path: join(path, String(index)))
            result.issues += parsed.issues
            result.aborted = result.aborted || parsed.aborted
        }
        // Length checks use zod's `when` predicate, so they still run after an
        // aborting element issue and contribute only continuable issues.
        if let min, items.count < min {
            result.issues.append(AuthRequestIssue(
                path: path,
                message: "Too small: expected array to have >=\(min) items"
            ))
        }
        if let max, items.count > max {
            result.issues.append(AuthRequestIssue(
                path: path,
                message: "Too big: expected array to have <=\(max) items"
            ))
        }
        return result
    }

    private static func recordResult(
        _ element: AgentApiContractSchema,
        _ value: JSONValue,
        path: String
    ) -> ParseResult {
        guard case .object(let members) = value else {
            return ParseResult(
                issues: [typeIssue("record", received: value.zodKind, path: path)],
                aborted: true
            )
        }
        var result = ParseResult()
        for key in members.keys.sorted() {
            let parsed = self.result(element, members[key], path: join(path, key))
            result.issues += parsed.issues
            result.aborted = result.aborted || parsed.aborted
        }
        return result
    }

    private static func discriminatedUnionResult(
        discriminator: String,
        members: [AgentApiContractSchema],
        value: JSONValue,
        path: String
    ) -> ParseResult {
        guard case .object(let fields) = value else {
            return ParseResult(
                issues: [typeIssue("object", received: value.zodKind, path: path)],
                aborted: true
            )
        }
        let discriminatorPath = join(path, discriminator)
        guard case .string(let tag)? = fields[discriminator] else {
            return ParseResult(
                issues: [AuthRequestIssue(path: discriminatorPath, message: "Invalid input")],
                aborted: true
            )
        }
        guard let member = members.first(where: { memberTag($0, discriminator: discriminator) == tag }) else {
            return ParseResult(
                issues: [AuthRequestIssue(path: discriminatorPath, message: "Invalid input")],
                aborted: true
            )
        }
        return self.result(member, value, path: path)
    }

    private static func memberTag(
        _ schema: AgentApiContractSchema,
        discriminator: String
    ) -> String? {
        guard case .object(let object) = schema,
              let field = object.fields.first(where: { $0.name == discriminator }),
              case .literal(let tag) = field.schema
        else { return nil }
        return tag
    }

    // MARK: - Strings

    private static func stringResult(
        _ schema: AgentApiContractSchema,
        _ value: JSONValue,
        path: String
    ) -> ParseResult {
        guard case .string(
            let min,
            let max,
            let trim,
            let pattern,
            let patternMessage,
            let refinement
        ) = schema else { return ParseResult() }
        guard case .string(var text) = value else {
            var issues = [typeIssue("string", received: value.zodKind, path: path)]
            // zod's length checks run whenever the received value has a
            // `length`; a JSON array is the only other such value here.
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
            return ParseResult(issues: issues, aborted: true)
        }
        if trim { text = MessageMentionRules.trimmingJavaScriptWhitespace(text) }
        var issues: [AuthRequestIssue] = []
        let length = text.utf16.count
        if let min, length < min {
            issues.append(AuthRequestIssue(
                path: path,
                message: "Too small: expected string to have >=\(min) characters"
            ))
        }
        if let max, length > max {
            issues.append(AuthRequestIssue(
                path: path,
                message: "Too big: expected string to have <=\(max) characters"
            ))
        }
        if let pattern, text.range(of: pattern, options: .regularExpression) == nil {
            issues.append(AuthRequestIssue(
                path: path,
                message: patternMessage ?? "Invalid string: must match pattern /\(pattern)/"
            ))
        }
        if let refinement, let message = refinement.message(for: text) {
            issues.append(AuthRequestIssue(path: path, message: message))
        }
        return ParseResult(issues: issues)
    }

    // MARK: - Numbers

    private static func numberResult(
        for value: JSONValue,
        path: String,
        int: Bool,
        positive: Bool,
        nonnegative: Bool,
        max: Double?
    ) -> ParseResult {
        let number: Double
        switch value {
        case .integer(let integer):
            number = Double(integer)
        case .number(let double):
            number = double
        case .object, .array, .string, .bool, .null:
            return ParseResult(
                issues: [typeIssue("number", received: value.zodKind, path: path)],
                aborted: true
            )
        }
        return numberResult(
            number,
            path: path,
            int: int,
            positive: positive,
            nonnegative: nonnegative,
            max: max
        )
    }

    private static func numberResult(
        _ number: Double,
        path: String,
        int: Bool,
        positive: Bool,
        nonnegative: Bool,
        max: Double?
    ) -> ParseResult {
        guard number.isFinite else {
            return ParseResult(
                issues: [typeIssue(
                    "number",
                    received: number.isNaN ? "NaN" : "number",
                    path: path
                )],
                aborted: true
            )
        }
        if int {
            guard number.rounded() == number else {
                return ParseResult(
                    issues: [AuthRequestIssue(
                        path: path,
                        message: "Invalid input: expected int, received number"
                    )],
                    aborted: true
                )
            }
            var issues: [AuthRequestIssue] = []
            if number > Double(AgentApiContractPatterns.maximumSafeInteger) {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too big: expected int to be <=\(AgentApiContractPatterns.maximumSafeInteger)"
                ))
            } else if number < -Double(AgentApiContractPatterns.maximumSafeInteger) {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too small: expected int to be >=\(-AgentApiContractPatterns.maximumSafeInteger)"
                ))
            }
            if positive, number <= 0 {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too small: expected number to be >0"
                ))
            } else if nonnegative, number < 0 {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too small: expected number to be >=0"
                ))
            }
            if let max, number > max {
                issues.append(AuthRequestIssue(
                    path: path,
                    message: "Too big: expected number to be <=\(format(max))"
                ))
            }
            return ParseResult(issues: issues)
        }
        if let max, number > max {
            return ParseResult(issues: [AuthRequestIssue(
                path: path,
                message: "Too big: expected number to be <=\(format(max))"
            )])
        }
        return ParseResult()
    }

    private static func coerceNumberResult(
        _ value: JSONValue,
        path: String,
        int: Bool,
        positive: Bool
    ) -> ParseResult {
        switch JavaScriptNumber.coerce(value) {
        case .finite(let number):
            return numberResult(
                number,
                path: path,
                int: int,
                positive: positive,
                nonnegative: false,
                max: nil
            )
        case .notANumber:
            return ParseResult(
                issues: [typeIssue("number", received: "NaN", path: path)],
                aborted: true
            )
        case .infinite:
            // `Number("Infinity")` and `Number("1e999")` stay numbers; zod
            // names the received type `number`, never `NaN`.
            return ParseResult(
                issues: [typeIssue("number", received: "number", path: path)],
                aborted: true
            )
        }
    }

    /// The finite value `z.coerce.number()` parses, or `nil` for `NaN` and
    /// non-finite results. Typed consumers use this to read the same parsed
    /// data the pinned middleware writes back onto the request.
    static func finiteCoercedNumber(_ value: JSONValue) -> Double? {
        guard case .finite(let number) = JavaScriptNumber.coerce(value) else { return nil }
        return number
    }

    /// JavaScript `Number(value)` for `z.coerce.number()`, keeping `NaN` and
    /// non-finite results distinct because zod prints them differently.
    private enum JavaScriptNumber {
        case finite(Double)
        case notANumber
        case infinite

        static func coerce(_ value: JSONValue) -> JavaScriptNumber {
            switch value {
            case .integer(let integer):
                return .finite(Double(integer))
            case .number(let number):
                if number.isNaN { return .notANumber }
                return number.isFinite ? .finite(number) : .infinite
            case .bool(let flag):
                return .finite(flag ? 1 : 0)
            case .null:
                return .finite(0)
            case .string(let text):
                return parse(text)
            case .array:
                // `Number(array)` is always `Number(String(array))`, i.e. the
                // array joined with "," after JavaScript `String` conversion.
                // In particular `Number([true])` is `Number("true")` = NaN,
                // not `Number(true)` = 1.
                return parse(javaScriptString(value))
            case .object:
                return .notANumber
            }
        }

        /// JavaScript `String(value)` as `Array.prototype.join` applies it:
        /// `null`/`undefined` become the empty string, arrays join recursively,
        /// and a plain object is `"[object Object]"`.
        static func javaScriptString(_ value: JSONValue) -> String {
            switch value {
            case .string(let text):
                return text
            case .integer(let integer):
                return String(integer)
            case .number(let number):
                return javaScriptNumberString(number)
            case .bool(let flag):
                return flag ? "true" : "false"
            case .null:
                return ""
            case .array(let items):
                return items.map(javaScriptString).joined(separator: ",")
            case .object:
                return "[object Object]"
            }
        }

        private static func javaScriptNumberString(_ number: Double) -> String {
            if number.isNaN { return "NaN" }
            if number.isInfinite { return number > 0 ? "Infinity" : "-Infinity" }
            if number == 0 { return "0" }
            return String(number)
        }

        /// JavaScript `Number(string)`: ECMAScript whitespace trim, optional
        /// sign on decimal/Infinity forms, unsigned `0x`/`0b`/`0o` integer
        /// literals, and `Infinity` for a decimal overflow such as `1e999`.
        static func parse(_ text: String) -> JavaScriptNumber {
            let trimmed = MessageMentionRules.trimmingJavaScriptWhitespace(text)
            if trimmed.isEmpty { return .finite(0) }
            switch trimmed {
            case "Infinity", "+Infinity", "-Infinity":
                return .infinite
            default:
                break
            }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("0x") || lower.hasPrefix("0b") || lower.hasPrefix("0o") {
                let radix: Int
                switch lower.prefix(2) {
                case "0x": radix = 16
                case "0b": radix = 2
                default: radix = 8
                }
                let digits = trimmed.utf8.dropFirst(2)
                guard !digits.isEmpty else { return .notANumber }
                var value = 0.0
                for byte in digits {
                    let digit: Int
                    switch byte {
                    case 48...57: digit = Int(byte - 48)
                    case 65...70: digit = Int(byte - 55)
                    case 97...102: digit = Int(byte - 87)
                    default: return .notANumber
                    }
                    guard digit < radix else { return .notANumber }
                    value = value * Double(radix) + Double(digit)
                }
                return .finite(value)
            }
            guard trimmed.range(
                of: #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#,
                options: .regularExpression
            ) != nil else { return .notANumber }
            guard let number = Double(trimmed) else { return .notANumber }
            return number.isFinite ? .finite(number) : .infinite
        }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - Missing and type issues

    private static func missingResult(
        _ schema: AgentApiContractSchema,
        path: String
    ) -> ParseResult {
        switch schema {
        case .any:
            return ParseResult()
        case .string:
            return ParseResult(
                issues: [typeIssue("string", received: "undefined", path: path)],
                aborted: true
            )
        case .number:
            return ParseResult(
                issues: [typeIssue("number", received: "undefined", path: path)],
                aborted: true
            )
        case .coerceNumber:
            return ParseResult(
                issues: [typeIssue("number", received: "NaN", path: path)],
                aborted: true
            )
        case .boolean:
            return ParseResult(
                issues: [typeIssue("boolean", received: "undefined", path: path)],
                aborted: true
            )
        case .literal(let expected):
            return ParseResult(
                issues: [AuthRequestIssue(
                    path: path,
                    message: "Invalid input: expected \"\(expected)\""
                )],
                aborted: true
            )
        case .enumeration(let options):
            return ParseResult(
                issues: [AuthRequestIssue(path: path, message: enumMessage(options))],
                aborted: true
            )
        case .array:
            return ParseResult(
                issues: [typeIssue("array", received: "undefined", path: path)],
                aborted: true
            )
        case .object, .discriminatedUnion:
            return ParseResult(
                issues: [typeIssue("object", received: "undefined", path: path)],
                aborted: true
            )
        case .record:
            return ParseResult(
                issues: [typeIssue("record", received: "undefined", path: path)],
                aborted: true
            )
        case .union:
            return ParseResult(
                issues: [AuthRequestIssue(path: path, message: "Invalid input")],
                aborted: true
            )
        case .nullable(let inner):
            return missingResult(inner, path: path)
        }
    }

    private static func typeIssue(
        _ expected: String,
        received: String,
        path: String
    ) -> AuthRequestIssue {
        AuthRequestIssue(
            path: path,
            message: "Invalid input: expected \(expected), received \(received)"
        )
    }

    private static func enumMessage(_ options: [String]) -> String {
        let listed = options.map { "\"\($0)\"" }.joined(separator: "|")
        return "Invalid option: expected one of \(listed)"
    }

    private static func join(_ path: String, _ member: String) -> String {
        path.isEmpty ? member : "\(path).\(member)"
    }
}

/// The schemas of the `/internal/agent-api` contract routes the Server
/// implements, keyed by the pinned `agentApiContract` route key.
///
/// Only routes whose upstream registration actually runs
/// `agentApiRequestValidators` or an inline `validateAgentApiQuery/Body` are
/// present: a route with a contract schema but no validator (for example
/// `mentionsList` or `serverUpdate`) does not publish
/// `agent_api_contract_invalid` upstream either.
public enum AgentApiContractRouteKey: String, Sendable, CaseIterable {
    case userChannels
    case historyRead
    case mentionActionsPending
    case mentionActionsExecute
    case messageReactionAdd
    case messageReactionRemove
    case channelJoin
    case channelLeave
    case channelCreate
    case channelUpdate
    case channelArchive
    case channelUnarchive
    case channelMemberAdd
    case channelMemberRemove
    case channelMute
    case channelUnmute
    case events
    case attachmentDownload
    case attachmentDownloadUrl
    case attachmentCommentsList
    case messageSend
    case messageSendV2
    case resolveChannel
    case messageSearch
    case messageResolve
    case channelMembers
    case threadUnfollow
    case inboxList
    case assistantOwnerInbox
    case assistantOwnerMessages
    case profileShow
    case profileUpdate
    case integrationMarketplaceSearch
    case integrationToken
    case integrationLogin
    case integrationAppPrepare
    case integrationAppUpdate
    case integrationAppStatus
    case taskList
    case taskCreate
    case taskClaim
    case taskAssign
    case taskUpdateStatus
    case taskResourceReceipt
    case taskDelete
    case taskConvert
    case taskAmend
    case taskHistory
    case taskUnclaim
    case attachmentUploadSessionCreate
    case attachmentUploadSessionComplete
    case attachmentUploadSessionCancel
    case attachmentUploadSessionStatus
    case integrationAppRotateSecret
    case integrationAppTransferOwner
    case integrationAppManage
    case reminderList
    case reminderCreate
    case reminderCancel
    case reminderSnooze
    case reminderUpdate
    case reminderLog
    case appConfigGet
    case appConfigPatch
    case actionPrepare
    case managedMcpCall
    case feedbackLocatorIngest
    case feedbackLocatorList

    public var routeKey: String { rawValue }

    /// The contract capability the pinned route requires before a request
    /// schema is validated (`agentApiContract[key].capability`).
    public var capability: String {
        switch self {
        case .historyRead, .events, .attachmentDownload, .attachmentDownloadUrl,
             .attachmentCommentsList, .messageResolve, .messageSearch, .inboxList,
             .assistantOwnerInbox, .assistantOwnerMessages, .profileShow,
             .integrationMarketplaceSearch, .integrationToken, .integrationLogin,
             .integrationAppPrepare, .integrationAppUpdate, .integrationAppStatus,
             .integrationAppRotateSecret, .integrationAppTransferOwner,
             .integrationAppManage,
             .reminderList, .reminderLog, .appConfigGet, .feedbackLocatorList:
            return "read"
        case .messageSend, .messageSendV2, .resolveChannel, .profileUpdate,
             .feedbackLocatorIngest, .attachmentUploadSessionCreate,
             .attachmentUploadSessionComplete, .attachmentUploadSessionCancel,
             .attachmentUploadSessionStatus:
            return "send"
        case .messageReactionAdd, .messageReactionRemove:
            return "reactions"
        case .mentionActionsPending, .mentionActionsExecute:
            return "mentions"
        case .channelJoin, .channelLeave, .channelCreate, .channelUpdate,
             .channelArchive, .channelUnarchive, .channelMemberAdd,
             .channelMemberRemove, .channelMute, .channelUnmute, .channelMembers,
             .threadUnfollow, .userChannels:
            return "channels"
        case .taskList, .taskCreate, .taskClaim, .taskAssign, .taskUpdateStatus,
             .taskResourceReceipt, .taskDelete, .taskConvert, .taskAmend,
             .taskHistory, .taskUnclaim,
             .reminderCreate, .reminderCancel, .reminderSnooze, .reminderUpdate,
             .appConfigPatch, .actionPrepare:
            return "tasks"
        case .managedMcpCall:
            return "mcp"
        }
    }

    /// The ordered credential/agent checks the pinned registration runs before
    /// the request validators:
    /// `requireAgentCapability(route.capability)`, then
    /// `requireAgentGrant(AGENT_API_ROUTE_GRANTS[key])`, then any inline pair
    /// the route spells out (`userChannels` adds `read` + `server:read`).
    /// `requireAgentGrant` reads the human-managed agent grant set, not the
    /// credential scopes.
    public var preconditions: [AgentApiContractPrecondition] {
        switch self {
        case .userChannels:
            // `routes/internalAgentApi.ts:2546-2548`: the registered
            // `channels` + `channel:read` pair, then the inline
            // `read` + `server:read` pair, then the query schema.
            return [
                .capability("channels"),
                .grant("channel:read"),
                .capability("read"),
                .grant("server:read"),
            ]
        default:
            return [.capability(capability)] + grants.map(AgentApiContractPrecondition.grant)
        }
    }

    /// `AGENT_API_ROUTE_GRANTS`: the per-agent grants the pinned
    /// `registerAgentApiRoute` inserts before the request validators. Routes
    /// absent from that table have no grant check (their services still apply
    /// ownership and membership authority).
    public var grants: [String] {
        switch self {
        case .historyRead, .events, .messageResolve, .messageSearch:
            return ["message:read"]
        case .channelMembers:
            return ["channel:read"]
        case .messageSend, .messageSendV2, .messageReactionAdd, .messageReactionRemove:
            return ["message:send"]
        case .channelJoin:
            return ["channel:join"]
        case .channelLeave:
            return ["channel:leave"]
        case .threadUnfollow:
            return ["thread:unfollow"]
        case .channelCreate:
            return ["channel:create"]
        case .channelUpdate:
            return ["channel:update"]
        case .channelMemberAdd:
            return ["channel:add_member"]
        case .channelMemberRemove:
            return ["channel:remove_member"]
        case .taskList:
            return ["task:read"]
        case .taskCreate, .taskClaim, .taskUnclaim, .taskUpdateStatus:
            return ["task:write"]
        case .actionPrepare:
            return ["action:prepare"]
        case .attachmentUploadSessionCreate, .attachmentUploadSessionComplete:
            return ["attachment:upload"]
        case .userChannels:
            return ["channel:read", "server:read"]
        default:
            return []
        }
    }
}

/// One middleware check the pinned registration runs before the request
/// validators.
public enum AgentApiContractPrecondition: Sendable, Equatable {
    case capability(String)
    case grant(String)
}

/// The parsed data of the `taskHistory` query.
///
/// Pinned `routes/internalAgentApi.ts:475-486` replaces `req.query` with the
/// schema's `parsed.data` before the handler runs, so the task lookup consumes
/// this trimmed `channel` and coerced `task_number` instead of the raw query
/// text. `taskHistory` is the only route whose contract schema uses
/// `z.coerce.number()`; the parser stays the validator's single
/// `JavaScriptNumber` implementation.
public struct AgentApiTaskHistoryQuery: Sendable, Equatable {
    public let channel: String
    public let taskNumber: Int

    public init(channel: String, taskNumber: Int) {
        self.channel = channel
        self.taskNumber = taskNumber
    }
}

/// The single validation entry point: one route key plus one request part.
public enum AgentApiContractValidator {
    static func schema(
        for key: AgentApiContractRouteKey,
        part: AgentApiContractPart
    ) -> AgentApiContractSchema? {
        if part == .body {
            return AgentApiContractSchemas.bodySchema(for: key)
        }
        return AgentApiContractSchemas.object(for: key, part: part).map(AgentApiContractSchema.object)
    }

    /// Whether the pinned route has a request schema for this part.
    public static func hasSchema(
        for key: AgentApiContractRouteKey,
        part: AgentApiContractPart
    ) -> Bool {
        schema(for: key, part: part) != nil
    }

    /// The route's path parameter names in the pinned schema, for a params
    /// part. The transport maps them onto its own route bindings.
    public static func parameterNames(for key: AgentApiContractRouteKey) -> [String] {
        AgentApiContractSchemas.object(for: key, part: .params)?.fields.map(\.name) ?? []
    }

    /// The parsed form of the `taskHistory` query after the pinned middleware
    /// writes the schema output back onto the request.
    ///
    /// The route must look the task up with the trimmed channel and the
    /// `z.coerce.number()` result (`0b101` → 5, `0o17` → 15, `1e1` → 10), not
    /// with `Int(raw)`, which rejects every non-decimal form and resolves
    /// task 0. Returns `nil` when the raw value does not satisfy the taskHistory
    /// schema, so the route keeps its own auth/404 path.
    public static func taskHistoryQuery(_ value: JSONValue?) -> AgentApiTaskHistoryQuery? {
        guard case .object(let fields)? = value,
              case .string(let rawChannel)? = fields["channel"],
              let rawTaskNumber = fields["task_number"],
              failure(for: .taskHistory, part: .query, value: value) == nil,
              let number = AgentApiContractSchemaValidator.finiteCoercedNumber(rawTaskNumber),
              let taskNumber = Int(exactly: number)
        else { return nil }
        return AgentApiTaskHistoryQuery(
            channel: MessageMentionRules.trimmingJavaScriptWhitespace(rawChannel),
            taskNumber: taskNumber
        )
    }

    /// The published failure for one part, or `nil` when the value matches the
    /// pinned schema. `nil` for the value means the JS `undefined`; route
    /// bodies pass `req.body ?? {}` and query/params always pass an object.
    public static func failure(
        for key: AgentApiContractRouteKey,
        part: AgentApiContractPart,
        value: JSONValue?
    ) -> AgentApiContractFailure? {
        guard let schema = schema(for: key, part: part) else { return nil }
        let raw: JSONValue
        if let value, value != .null {
            raw = value
        } else {
            raw = .object([:])
        }
        let issues = AgentApiContractSchemaValidator.issues(schema, raw, path: "")
        guard !issues.isEmpty else { return nil }
        return AgentApiContractFailure(
            routeKey: key.routeKey,
            part: part,
            issues: issues
        )
    }
}
