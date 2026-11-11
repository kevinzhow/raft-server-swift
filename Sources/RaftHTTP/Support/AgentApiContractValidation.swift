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
    /// The issues of one value against one schema, with `nil` meaning the JS
    /// `undefined` an absent member has.
    static func issues(
        _ schema: AgentApiContractSchema,
        _ value: JSONValue?,
        path: String
    ) -> [AuthRequestIssue] {
        guard let value else { return missingIssues(schema, path: path) }
        switch schema {
        case .any:
            return []
        case .string(_, _, _, _, _, _):
            return stringIssues(schema, value, path: path)
        case .number(let int, let positive, let nonnegative, let max):
            return numberIssues(
                value,
                path: path,
                int: int,
                positive: positive,
                nonnegative: nonnegative,
                max: max
            )
        case .coerceNumber(let int, let positive):
            return coerceNumberIssues(value, path: path, int: int, positive: positive)
        case .boolean:
            guard case .bool = value else {
                return [typeIssue("boolean", received: value.zodKind, path: path)]
            }
            return []
        case .literal(let expected):
            if case .string(let text) = value, text == expected { return [] }
            return [AuthRequestIssue(path: path, message: "Invalid input: expected \"\(expected)\"")]
        case .enumeration(let options):
            if case .string(let text) = value, options.contains(text) { return [] }
            return [AuthRequestIssue(path: path, message: enumMessage(options))]
        case .array(let element, let min, let max):
            guard case .array(let items) = value else {
                return [typeIssue("array", received: value.zodKind, path: path)]
            }
            var issues: [AuthRequestIssue] = []
            for (index, item) in items.enumerated() {
                issues += self.issues(element, item, path: join(path, String(index)))
            }
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
            return issues
        case .object(let object):
            return objectIssues(object, value, path: path)
        case .record(let element):
            guard case .object(let members) = value else {
                return [typeIssue("record", received: value.zodKind, path: path)]
            }
            var issues: [AuthRequestIssue] = []
            for key in members.keys.sorted() {
                issues += self.issues(element, members[key], path: join(path, key))
            }
            return issues
        case .union(let options):
            for option in options where self.issues(option, value, path: path).isEmpty {
                return []
            }
            return [AuthRequestIssue(path: path, message: "Invalid input")]
        case .discriminatedUnion(let discriminator, let members):
            return discriminatedUnionIssues(
                discriminator: discriminator,
                members: members,
                value: value,
                path: path
            )
        case .nullable(let inner):
            if case .null = value { return [] }
            return self.issues(inner, value, path: path)
        }
    }

    // MARK: - Objects

    private static func objectIssues(
        _ object: AgentApiContractObject,
        _ value: JSONValue,
        path: String
    ) -> [AuthRequestIssue] {
        guard case .object(let members) = value else {
            return [typeIssue("object", received: value.zodKind, path: path)]
        }
        var issues: [AuthRequestIssue] = []
        for field in object.fields {
            let child = members[field.name]
            let childPath = join(path, field.name)
            if child == nil {
                if field.required {
                    issues += missingIssues(field.schema, path: childPath)
                }
                continue
            }
            issues += self.issues(field.schema, child, path: childPath)
        }
        if object.strict {
            let known = Set(object.fields.map(\.name))
            let unknown = members.keys.filter { !known.contains($0) }
            if let issue = AuthRequestSchema.unrecognizedKeys(unknown) {
                issues.append(AuthRequestIssue(path: path, message: issue.message))
            }
        }
        guard issues.isEmpty else { return issues }
        for refinement in object.refinements {
            if let message = refinement.message(fields: members) {
                issues.append(AuthRequestIssue(path: path, message: message))
            }
        }
        return issues
    }

    private static func discriminatedUnionIssues(
        discriminator: String,
        members: [AgentApiContractSchema],
        value: JSONValue,
        path: String
    ) -> [AuthRequestIssue] {
        guard case .object(let fields) = value else {
            return [typeIssue("object", received: value.zodKind, path: path)]
        }
        let discriminatorPath = join(path, discriminator)
        guard case .string(let tag)? = fields[discriminator] else {
            return [AuthRequestIssue(path: discriminatorPath, message: "Invalid input")]
        }
        guard let member = members.first(where: { memberTag($0, discriminator: discriminator) == tag }) else {
            return [AuthRequestIssue(path: discriminatorPath, message: "Invalid input")]
        }
        return self.issues(member, value, path: path)
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

    private static func stringIssues(
        _ schema: AgentApiContractSchema,
        _ value: JSONValue,
        path: String
    ) -> [AuthRequestIssue] {
        guard case .string(
            let min,
            let max,
            let trim,
            let pattern,
            let patternMessage,
            let refinement
        ) = schema else { return [] }
        let checked = AuthRequestSchema.string(
            value,
            path: path,
            min: min,
            max: max,
            trim: trim,
            pattern: pattern,
            patternMessage: patternMessage
        )
        var issues = checked.issues
        guard case .string(let raw) = value else { return issues }
        if let refinement {
            let text = trim
                ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
                : raw
            if let message = refinement.message(for: text) {
                issues.append(AuthRequestIssue(path: path, message: message))
            }
        }
        return issues
    }

    // MARK: - Numbers

    private static func numberIssues(
        _ value: JSONValue,
        path: String,
        int: Bool,
        positive: Bool,
        nonnegative: Bool,
        max: Double?
    ) -> [AuthRequestIssue] {
        let number: Double
        switch value {
        case .integer(let integer):
            number = Double(integer)
        case .number(let double):
            number = double
        case .object, .array, .string, .bool, .null:
            return [typeIssue("number", received: value.zodKind, path: path)]
        }
        guard number.isFinite else {
            return [typeIssue("number", received: number.isNaN ? "NaN" : "number", path: path)]
        }
        if int {
            guard number.rounded() == number else {
                return [AuthRequestIssue(
                    path: path,
                    message: "Invalid input: expected int, received number"
                )]
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
            return issues
        }
        if let max, number > max {
            return [AuthRequestIssue(
                path: path,
                message: "Too big: expected number to be <=\(format(max))"
            )]
        }
        return []
    }

    private static func coerceNumberIssues(
        _ value: JSONValue,
        path: String,
        int: Bool,
        positive: Bool
    ) -> [AuthRequestIssue] {
        let text: String
        switch value {
        case .string(let string): text = string
        case .integer, .number, .bool, .object, .array, .null: text = ""
        }
        let number = javascriptNumber(text)
        guard number.isFinite else {
            return [typeIssue("number", received: "NaN", path: path)]
        }
        return numberIssues(
            .number(number),
            path: path,
            int: int,
            positive: positive,
            nonnegative: false,
            max: nil
        )
    }

    /// JavaScript `Number(text)` for the query strings `z.coerce.number()`
    /// receives.
    private static func javascriptNumber(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
        if trimmed == "-Infinity" { return -.infinity }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            guard let parsed = Int64(trimmed.dropFirst(2), radix: 16) else { return .nan }
            return Double(parsed)
        }
        return Double(trimmed) ?? .nan
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - Missing and type issues

    private static func missingIssues(
        _ schema: AgentApiContractSchema,
        path: String
    ) -> [AuthRequestIssue] {
        switch schema {
        case .any:
            return []
        case .string:
            return [typeIssue("string", received: "undefined", path: path)]
        case .number:
            return [typeIssue("number", received: "undefined", path: path)]
        case .coerceNumber:
            return [typeIssue("number", received: "NaN", path: path)]
        case .boolean:
            return [typeIssue("boolean", received: "undefined", path: path)]
        case .literal(let expected):
            return [AuthRequestIssue(
                path: path,
                message: "Invalid input: expected \"\(expected)\""
            )]
        case .enumeration(let options):
            return [AuthRequestIssue(path: path, message: enumMessage(options))]
        case .array:
            return [typeIssue("array", received: "undefined", path: path)]
        case .object, .discriminatedUnion:
            return [typeIssue("object", received: "undefined", path: path)]
        case .record:
            return [typeIssue("record", received: "undefined", path: path)]
        case .union:
            return [AuthRequestIssue(path: path, message: "Invalid input")]
        case .nullable(let inner):
            return missingIssues(inner, path: path)
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
