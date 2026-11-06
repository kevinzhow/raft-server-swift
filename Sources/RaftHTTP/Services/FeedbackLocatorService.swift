import Foundation
import RaftShared

/// Domain failure for the feedback-locator operations.
///
/// Every case names the published error object the route answers with. The
/// bodies are `OrderedJSON` trees because the legacy replies publish a fixed
/// non-alphabetical key order; `Respond.swift` prints `errorBody` verbatim.
public enum FeedbackLocatorError: DomainError, Equatable {
    case missingAuthorization
    case invalidAccessToken
    case capabilityNotAuthorized(capability: String)
    case invalidAgentCredential
    case missingScope(scope: String)
    case invalidPayload
    case unknownArtifactKind
    case unknownEventKind
    case forbiddenField
    case invalidRouteRef
    case unknownSchemaVersion
    case reportIdentityConflict

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidAccessToken, .invalidAgentCredential:
            401
        case .capabilityNotAuthorized, .missingScope:
            403
        case .reportIdentityConflict:
            409
        case .invalidPayload, .unknownArtifactKind, .unknownEventKind,
             .forbiddenField, .invalidRouteRef, .unknownSchemaVersion:
            400
        }
    }

    /// Only the plain `DomainError` requirement; the locator routes always
    /// publish the structured body below.
    public var errorMessage: String {
        switch self {
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidAccessToken:
            "Invalid or expired token"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .invalidAgentCredential:
            "Invalid agent credential"
        case .missingScope:
            "missing required scope"
        case .invalidPayload, .unknownArtifactKind, .unknownEventKind, .forbiddenField,
             .invalidRouteRef, .unknownSchemaVersion, .reportIdentityConflict:
            "Feedback locator rejected"
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .missingAuthorization:
            return Self.authErrorBody(
                error: "Missing or invalid Authorization header",
                code: "auth_required"
            )
        case .invalidAccessToken:
            return Self.authErrorBody(error: "Invalid or expired token", code: "auth_required")
        case .capabilityNotAuthorized(let capability):
            return Self.authErrorBody(
                error: "Agent credential is not authorized for this capability",
                code: "capability_not_authorized",
                requiredCapability: capability
            )
        case .invalidAgentCredential:
            return Self.authErrorBody(error: "Invalid agent credential", code: "auth_required")
        case .missingScope(let scope):
            var body = OrderedJSONObject()
            body.append("error", "missing required scope")
            body.append("requiredScope", scope)
            body.append("reason", "missing_scope")
            return body.json
        case .invalidPayload:
            return Self.failureBody(reason: "invalid_payload")
        case .unknownArtifactKind:
            return Self.failureBody(reason: "unknown_artifact_kind")
        case .unknownEventKind:
            return Self.failureBody(reason: "unknown_event_kind")
        case .forbiddenField:
            return Self.failureBody(reason: "forbidden_field")
        case .invalidRouteRef:
            return Self.failureBody(reason: "invalid_route_ref")
        case .unknownSchemaVersion:
            return Self.failureBody(reason: "unknown_schema_version")
        case .reportIdentityConflict:
            return Self.failureBody(reason: "report_identity_conflict")
        }
    }

    /// The published credential refusal: `error`, then `code`, then the
    /// optional `requiredCapability`.
    public static func authErrorBody(
        error: String,
        code: String,
        requiredCapability: String? = nil
    ) -> OrderedJSON {
        var body = OrderedJSONObject()
        body.append("error", error)
        body.append("code", code)
        body.append("requiredCapability", ifPresent: requiredCapability)
        return body.json
    }

    /// The published validation refusal: `status`, then `reason_code`.
    public static func failureBody(reason: String) -> OrderedJSON {
        .object([
            OrderedJSONField("status", "failed"),
            OrderedJSONField("reason_code", reason),
        ])
    }
}

/// Product feedback locators (`POST/GET /internal/agent-api/feedback-locators`)
/// plus the agent credential/grant policy the rest of the agent API shares.
///
/// The service owns the validations, the credential and grant decisions, and
/// the locator rows. It returns the published `Codable` DTOs or throws
/// `FeedbackLocatorError`; it never builds an HTTP reply, header set or
/// JSON tree. The insert decision and the append run in one `FeedbackStore`
/// critical section.
public struct FeedbackLocatorService: Sendable {
    /// The credential/capability outcome without an HTTP reply, for callers
    /// that own their own error projection (the managed-MCP service).
    enum IdentityResolution: Sendable, Equatable {
        case success(agentId: String, serverId: String)
        case missingAuthorization
        case invalidAccessToken
        case capabilityNotAuthorized(capability: String)
        case invalidAgentCredential
    }

    /// `agentCapabilityDenial` without an HTTP reply.
    enum CapabilityDecision: Sendable, Equatable {
        case allowed
        case denied(capability: String)
    }

    /// `agentGrantDenial` without an HTTP reply.
    enum GrantDecision: Sendable, Equatable {
        case allowed
        case missingScope(scope: String)
    }

    private let feedback: FeedbackStore
    private let agents: AgentsRuntimeStore
    private let channels: ServersAndChannelsStore
    private let cards: ManagedMCPAndCardsStore
    private let oauth: OAuthLedger
    private let now: @Sendable () -> Date
    private let makeReceiptId: @Sendable () -> String
    private let hashPayload: @Sendable (String) -> String

    init(directory source: EmailLoginDirectory) {
        self.feedback = source.feedbackStore
        self.agents = source.agentsRuntimeStore
        self.channels = source.serversAndChannelsStore
        self.cards = source.managedMCPAndCardsStore
        self.oauth = source.oauth
        self.now = { Date() }
        self.makeReceiptId = { UUID().uuidString.lowercased() }
        self.hashPayload = { EmailLoginDirectory.sha256($0) }
    }

    init(
        feedback: FeedbackStore,
        agents: AgentsRuntimeStore,
        channels: ServersAndChannelsStore,
        cards: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        now: @escaping @Sendable () -> Date = { Date() },
        makeReceiptId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        hashPayload: @escaping @Sendable (String) -> String = { EmailLoginDirectory.sha256($0) }
    ) {
        self.feedback = feedback
        self.agents = agents
        self.channels = channels
        self.cards = cards
        self.oauth = oauth
        self.now = now
        self.makeReceiptId = makeReceiptId
        self.hashPayload = hashPayload
    }

    // MARK: - Credential and grant policy

    /// The credential/capability outcome: a missing or revoked credential is the
    /// published 401, a live credential without the capability is the 403.
    func identityResolution(authorization: String?, capability: String) -> IdentityResolution {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .missingAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredentials[token], credential.revokedAt == nil else {
            return .invalidAccessToken
        }
        guard credential.scopes.contains(capability) else {
            return .capabilityNotAuthorized(capability: capability)
        }
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return .invalidAgentCredential
        }
        return .success(agentId: credential.agentId, serverId: agent.serverId)
    }

    /// A missing, malformed or revoked credential passes here; only a live
    /// credential that lacks the capability is a denial, matching the legacy
    /// `agentCapabilityDenial`.
    func capabilityDecision(authorization: String?, capability: String) -> CapabilityDecision {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .allowed }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredentials[token], credential.revokedAt == nil else {
            return .allowed
        }
        return credential.scopes.contains(capability) ? .allowed : .denied(capability: capability)
    }

    /// An agent with no stored grant row carries every grantable scope, so only
    /// an explicit set without the scope is a denial.
    func grantDecision(agentId: String, scope: String) -> GrantDecision {
        guard let grants = cards.agentGrantSets[agentId], !grants.contains(scope) else {
            return .allowed
        }
        return .missingScope(scope: scope)
    }

    /// The raw scope list for a valid credential, revoked or not (callers use
    /// it to distinguish `read` from the long-form scopes).
    func credentialScopes(authorization: String?) -> [String]? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredentials[token] else { return nil }
        return Array(credential.scopes)
    }

    // MARK: - Locator ingest and listing

    /// `POST /internal/agent-api/feedback-locators`.
    ///
    /// The validation order is the legacy order: artifact kind, event kind,
    /// payload shape, forbidden keys, route resolution, schema version, then the
    /// required producer/locator fields. A duplicate `(server, report)` keeps the
    /// first receipt; a different payload digest is the 409.
    public func ingest(
        authorization: String?,
        body: FeedbackLocatorIngestRequest?
    ) throws -> FeedbackLocatorAcceptedResponse {
        let identity = try requireIdentity(authorization: authorization, capability: "send")
        guard let body else { throw FeedbackLocatorError.invalidPayload }
        guard body.artifactKind == .string("raft-feedback-locator-v0") else {
            throw FeedbackLocatorError.unknownArtifactKind
        }
        guard body.eventKind == .string("feedback-locator:created") else {
            throw FeedbackLocatorError.unknownEventKind
        }
        guard case let .object(payload)? = body.payload else {
            throw FeedbackLocatorError.invalidPayload
        }
        if Self.containsForbiddenKey(.object(payload)) {
            throw FeedbackLocatorError.forbiddenField
        }
        let route = Self.objectValue(payload["route"])
        let resolution = Self.objectValue(route?["resolution"])
        if let resolution, resolution["status"] != .string("resolved"),
           resolution["target"] != nil || resolution["ref"] != nil {
            throw FeedbackLocatorError.invalidRouteRef
        }
        if let target = Self.objectValue(resolution?["target"]) {
            guard target["kind"] == .string("public_channel"),
                  case let .string(ref)? = target["ref"],
                  ref.range(
                      of: "^#[a-z0-9][a-z0-9_-]{0,126}$",
                      options: [.regularExpression, .caseInsensitive]
                  ) != nil
            else {
                throw FeedbackLocatorError.invalidRouteRef
            }
        }
        guard payload["schema_version"] == .string("raft.feedback.locator.v0") else {
            throw FeedbackLocatorError.unknownSchemaVersion
        }
        guard case let .string(reportId)? = payload["report_id"],
              ServerScope.isUUID(reportId),
              case let .string(capturedRaw)? = payload["captured_at"],
              let capturedAt = EmailLoginDirectory.isoDate(capturedRaw),
              let producer = Self.objectValue(payload["producer"]),
              producer["server_id"] == .string(identity.serverId),
              producer["agent_id"] == .string(identity.agentId),
              let locators = Self.objectValue(payload["locators"]),
              let l0 = Self.objectValue(locators["l0"]),
              case let .string(runtime)? = l0["runtime"],
              let native = Self.objectValue(l0["native"]),
              case let .string(nativeStatus)? = native["status"]
        else {
            throw FeedbackLocatorError.invalidPayload
        }
        let resolved = resolution?["status"] == .string("resolved")
        if resolved {
            if let delivery = Self.objectValue(route?["delivery"]),
               case let .string(status)? = delivery["status"],
               status == "accepted" || status == "failed" {
                throw FeedbackLocatorError.invalidPayload
            }
            guard case let .string(ref)? = Self.objectValue(resolution?["target"])?["ref"],
                  ref == "#proj-feedback"
            else {
                throw FeedbackLocatorError.invalidRouteRef
            }
            let name = String(ref.dropFirst())
            let exists = channels.postableChannels.values.contains {
                $0.serverId == identity.serverId
                    && $0.kind == "channel"
                    && $0.name == name
                    && $0.deletedAt == nil
            }
            guard exists else { throw FeedbackLocatorError.invalidRouteRef }
        }
        let nativeLookupMethod = Self.stringValue(native["lookup_method"]) ?? "not_attempted"
        let nativeLocatorKind = Self.stringValue(native["locator_kind"]) ?? "none"
        var servedExactSha256: [String] = []
        if case let .array(exacts)? = payload["exacts"] {
            for entry in exacts {
                guard case let .object(row) = entry,
                      row["status"] == .string("retained"),
                      case let .string(sha)? = row["sha256"]
                else { continue }
                servedExactSha256.append(sha)
            }
        }
        let routeBasis = resolved ? Self.stringValue(resolution?["basis"]) : nil
        let routeTarget = resolved ? Self.stringValue(Self.objectValue(resolution?["target"])?["ref"]) : nil
        let digest = hashPayload(Self.stableJSON(.object(payload)))
        let record = FeedbackLocatorRecord(
            serverId: identity.serverId,
            producerAgentId: identity.agentId,
            reportId: reportId,
            receiptId: makeReceiptId(),
            capturedAt: capturedAt,
            runtime: runtime,
            nativeStatus: nativeStatus,
            nativeLookupMethod: nativeLookupMethod,
            nativeLocatorKind: nativeLocatorKind,
            hasServedExact: !servedExactSha256.isEmpty,
            servedExactSha256: servedExactSha256,
            routeBasis: routeBasis,
            routeTarget: routeTarget,
            payloadSha256: digest,
            createdAt: now()
        )
        switch feedback.insertFeedbackLocator(record) {
        case .inserted:
            return FeedbackLocatorAcceptedResponse(
                receiptId: record.receiptId,
                reportId: reportId,
                duplicate: false
            )
        case .duplicate(let receiptId):
            return FeedbackLocatorAcceptedResponse(
                receiptId: receiptId,
                reportId: reportId,
                duplicate: true
            )
        case .conflict:
            throw FeedbackLocatorError.reportIdentityConflict
        }
    }

    /// `GET /internal/agent-api/feedback-locators`.
    ///
    /// Rows are newest first; every filter is an exact match on a non-empty
    /// query value, and `limit` clamps to 1…100 with 50 as the default.
    public func list(
        authorization: String?,
        reportId: String?,
        runtime: String?,
        nativeStatus: String?,
        nativeLookupMethod: String?,
        servedExactSha256: String?,
        routeBasis: String?,
        limit rawLimit: String?
    ) throws -> FeedbackLocatorListResponse {
        let identity = try requireIdentity(authorization: authorization, capability: "read")
        let limit = min(max(Int(rawLimit ?? "") ?? 50, 1), 100)
        var rows = feedback.feedbackLocatorSnapshot(serverId: identity.serverId)
            .sorted { $0.createdAt > $1.createdAt }
        if let reportId, !reportId.isEmpty { rows = rows.filter { $0.reportId == reportId } }
        if let runtime, !runtime.isEmpty { rows = rows.filter { $0.runtime == runtime } }
        if let nativeStatus, !nativeStatus.isEmpty {
            rows = rows.filter { $0.nativeStatus == nativeStatus }
        }
        if let nativeLookupMethod, !nativeLookupMethod.isEmpty {
            rows = rows.filter { $0.nativeLookupMethod == nativeLookupMethod }
        }
        if let servedExactSha256, !servedExactSha256.isEmpty {
            rows = rows.filter { $0.servedExactSha256.contains(servedExactSha256) }
        }
        if let routeBasis, !routeBasis.isEmpty { rows = rows.filter { $0.routeBasis == routeBasis } }
        rows = Array(rows.prefix(limit))
        return FeedbackLocatorListResponse(locators: rows.map { row in
            FeedbackLocatorRow(
                reportId: row.reportId,
                receiptId: row.receiptId,
                capturedAt: EmailLoginDirectory.isoString(row.capturedAt),
                runtime: row.runtime,
                nativeStatus: row.nativeStatus,
                nativeLookupMethod: row.nativeLookupMethod,
                nativeLocatorKind: row.nativeLocatorKind,
                hasServedExact: row.hasServedExact,
                servedExactSha256: row.servedExactSha256,
                routeBasis: row.routeBasis,
                routeTarget: row.routeTarget
            )
        })
    }

    // MARK: - Helpers

    private func requireIdentity(
        authorization: String?,
        capability: String
    ) throws -> (agentId: String, serverId: String) {
        switch identityResolution(authorization: authorization, capability: capability) {
        case .success(let agentId, let serverId):
            return (agentId, serverId)
        case .missingAuthorization:
            throw FeedbackLocatorError.missingAuthorization
        case .invalidAccessToken:
            throw FeedbackLocatorError.invalidAccessToken
        case .capabilityNotAuthorized(let capability):
            throw FeedbackLocatorError.capabilityNotAuthorized(capability: capability)
        case .invalidAgentCredential:
            throw FeedbackLocatorError.invalidAgentCredential
        }
    }

    private static func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case let .object(object)? = value else { return nil }
        return object
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case let .string(string)? = value else { return nil }
        return string
    }

    /// Payload keys that would smuggle conversation content into a locator.
    private static let forbiddenKeys: Set<String> = [
        "body", "content", "content_window", "context", "context_window", "feedback_body",
        "l3", "message_body", "path", "prompt", "raw", "raw_args", "raw_argv", "raw_error",
        "raw_value", "raw_values", "searched_paths", "searchedpaths", "session_content",
        "session_text", "stderr", "stdin", "stdout", "trajectory", "transcript", "value",
        "values", "wider_window", "window",
    ]

    private static func normalizedKey(_ key: String) -> String {
        var result = ""
        var previous: Character?
        for character in key {
            if character == "-" || character == " " {
                result.append("_")
            } else if character.isUppercase, let prior = previous, prior.isLowercase {
                result.append("_")
                result.append(Character(character.lowercased()))
            } else {
                result.append(Character(character.lowercased()))
            }
            previous = character
        }
        return result
    }

    static func containsForbiddenKey(_ value: JSONValue) -> Bool {
        switch value {
        case .array(let array):
            return array.contains(where: containsForbiddenKey)
        case .object(let object):
            for (key, nested) in object {
                if forbiddenKeys.contains(normalizedKey(key)) { return true }
                if containsForbiddenKey(nested) { return true }
            }
            return false
        default:
            return false
        }
    }

    /// The duplicate-detection digest input: object keys sorted, arrays in
    /// order, scalars in the number/boolean form the legacy `NSNumber` walker
    /// produced.
    static func stableJSON(_ value: JSONValue) -> String {
        switch value {
        case .array(let array):
            return "[" + array.map { stableJSON($0) }.joined(separator: ",") + "]"
        case .object(let object):
            let parts = object.keys.sorted().map { key in
                "\(jsonString(key)):\(stableJSON(object[key]!))"
            }
            return "{" + parts.joined(separator: ",") + "}"
        case .bool(let bool):
            return bool ? "true" : "false"
        case .integer(let integer):
            let double = Double(integer)
            if abs(double) < 1e15 { return String(integer) }
            return String(double)
        case .number(let double):
            if double == double.rounded(), abs(double) < 1e15 {
                return String(Int64(double))
            }
            return String(double)
        case .string(let string):
            return jsonString(string)
        case .null:
            return "null"
        }
    }
}
