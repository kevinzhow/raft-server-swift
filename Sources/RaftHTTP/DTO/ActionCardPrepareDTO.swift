import Foundation
import RaftShared

// MARK: - Integration marketplace (`GET /api/integrations/marketplace`)

/// `GET /api/integrations/marketplace` success body.
///
/// The legacy handler built a JSON array in row order, with each row's members
/// in the order below. The array is kept as an explicit ordered body so the
/// bytes (and `Content-Length`) do not depend on Linux `JSONEncoder` key order.
public struct IntegrationMarketplaceListing: ExactJSONBody, Sendable, Equatable {
    public var rows: [IntegrationMarketplaceRow]

    public init(rows: [IntegrationMarketplaceRow]) {
        self.rows = rows
    }

    public var jsonBody: JSONBody {
        .array(rows.map(\.jsonBody))
    }
}

/// One marketplace row. `appNotificationPendingRevisionId` is `null` when the
/// app has no pending revision.
public struct IntegrationMarketplaceRow: ExactJSONBody, Sendable, Equatable {
    public var id: String
    public var clientId: String
    public var name: String
    public var pendingGroups: [String]
    public var pendingRevisionId: String?
    public var canReviewAppNotifications: Bool

    public init(
        id: String,
        clientId: String,
        name: String,
        pendingGroups: [String],
        pendingRevisionId: String?,
        canReviewAppNotifications: Bool
    ) {
        self.id = id
        self.clientId = clientId
        self.name = name
        self.pendingGroups = pendingGroups
        self.pendingRevisionId = pendingRevisionId
        self.canReviewAppNotifications = canReviewAppNotifications
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("id", .string(id)),
            JSONMember("clientId", .string(clientId)),
            JSONMember("name", .string(name)),
            JSONMember("appNotificationPendingGroups", .array(pendingGroups.map { .string($0) })),
            JSONMember(
                "appNotificationPendingRevisionId",
                pendingRevisionId.map(JSONBody.string) ?? .null
            ),
            JSONMember("canReviewAppNotifications", .boolean(canReviewAppNotifications)),
        ])
    }
}

// MARK: - App-notification permission review

/// `POST /api/integrations/clients/:clientId/app-notifications/permissions/review`
/// request body.
///
/// The legacy parser read `expected_revision_id` with `as? String`, so a
/// missing key, `null`, a number or an empty string all fall through to the
/// same `invalid_expected_revision_id` 400. This decoder keeps that tolerance:
/// a wrong-typed member becomes `nil` instead of failing the whole body.
public struct ReviewAppNotificationPermissionsRequest: Codable, Sendable, Equatable {
    public var expectedRevisionId: String?

    public init(expectedRevisionId: String? = nil) {
        self.expectedRevisionId = expectedRevisionId
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevisionId = "expected_revision_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectedRevisionId = (try? container.decodeIfPresent(
            String.self,
            forKey: .expectedRevisionId
        )) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(expectedRevisionId, forKey: .expectedRevisionId)
    }
}

/// `POST …/permissions/review` success body: `{"ok":true,"groups":[…]}`.
public struct ReviewAppNotificationPermissionsResponse: ExactJSONBody, Sendable, Equatable {
    public var groups: [String]

    public init(groups: [String]) {
        self.groups = groups
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("ok", .boolean(true)),
            JSONMember("groups", .array(groups.map { .string($0) })),
        ])
    }
}

// MARK: - Legacy Agent-JWT settings

/// `GET /api/integrations/clients/:clientId/agent-jwt` success body.
///
/// The route answers `Cache-Control: private, no-store`; the feature supplies
/// that extra header to `respond`, so the DTO only owns the body bytes.
public struct LegacyAppAgentJWTResponse: ExactJSONBody, Sendable, Equatable {
    public var scope: String
    public var effectiveEnabled: Bool
    public var audience: String

    public init(scope: String, effectiveEnabled: Bool, audience: String) {
        self.scope = scope
        self.effectiveEnabled = effectiveEnabled
        self.audience = audience
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("scope", .string(scope)),
            JSONMember("enabled", .boolean(true)),
            JSONMember("appEnabled", .boolean(true)),
            JSONMember("effectiveEnabled", .boolean(effectiveEnabled)),
            JSONMember("canEnable", .boolean(false)),
            JSONMember("audience", .string(audience)),
            JSONMember("expiresIn", .integer(300)),
        ])
    }
}

// MARK: - Agent context (`GET /internal/agent-api/context`)

/// `GET /internal/agent-api/context` success body.
///
/// `prompt` is `null` for a managed agent; an external agent gets the
/// self-hosted-runner operating guide under `{"audience","text"}`.
public struct AgentContextResponse: ExactJSONBody, Sendable, Equatable {
    public var agent: AgentContextAgent
    public var server: AgentContextServer
    public var capabilities: [String]
    public var prompt: AgentContextPrompt?
    public var features: AgentContextFeatures

    public init(
        agent: AgentContextAgent,
        server: AgentContextServer,
        capabilities: [String],
        prompt: AgentContextPrompt?,
        features: AgentContextFeatures
    ) {
        self.agent = agent
        self.server = server
        self.capabilities = capabilities
        self.prompt = prompt
        self.features = features
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("agent", agent.jsonBody),
            JSONMember("server", server.jsonBody),
            JSONMember(
                "credential",
                .object([JSONMember("capabilities", .array(capabilities.map { .string($0) }))])
            ),
            JSONMember("prompt", prompt?.jsonBody ?? .null),
            JSONMember("features", features.jsonBody),
        ])
    }
}

/// The agent identity block. `description` and `assistantOf` are `null` when
/// absent; `external` is `runtime == "external"`.
public struct AgentContextAgent: ExactJSONBody, Sendable, Equatable {
    public var id: String
    public var name: String
    public var displayName: String
    public var description: String?
    public var runtime: String
    public var external: Bool
    public var assistantOf: String?
    public var serverRole: String

    public init(
        id: String,
        name: String,
        displayName: String,
        description: String?,
        runtime: String,
        external: Bool,
        assistantOf: String?,
        serverRole: String
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.runtime = runtime
        self.external = external
        self.assistantOf = assistantOf
        self.serverRole = serverRole
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("id", .string(id)),
            JSONMember("name", .string(name)),
            JSONMember("displayName", .string(displayName)),
            JSONMember("description", description.map(JSONBody.string) ?? .null),
            JSONMember("runtime", .string(runtime)),
            JSONMember("external", .boolean(external)),
            JSONMember(
                "assistantOf",
                assistantOf.map { .object([JSONMember("userId", .string($0))]) } ?? .null
            ),
            JSONMember("serverRole", .string(serverRole)),
        ])
    }
}

/// The server identity block.
public struct AgentContextServer: ExactJSONBody, Sendable, Equatable {
    public var id: String
    public var slug: String
    public var name: String

    public init(id: String, slug: String, name: String) {
        self.id = id
        self.slug = slug
        self.name = name
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("id", .string(id)),
            JSONMember("slug", .string(slug)),
            JSONMember("name", .string(name)),
        ])
    }
}

/// The external-agent operating guide envelope.
public struct AgentContextPrompt: ExactJSONBody, Sendable, Equatable {
    public var audience: String
    public var text: String

    public init(audience: String = "self-hosted-runner", text: String) {
        self.audience = audience
        self.text = text
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("audience", .string(audience)),
            JSONMember("text", .string(text)),
        ])
    }
}

/// The two server-scoped feature flags the context reply advertises.
public struct AgentContextFeatures: ExactJSONBody, Sendable, Equatable {
    public var reminderApp: Bool
    public var vaultApp: Bool

    public init(reminderApp: Bool, vaultApp: Bool) {
        self.reminderApp = reminderApp
        self.vaultApp = vaultApp
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("reminderApp", .boolean(reminderApp)),
            JSONMember("vaultApp", .boolean(vaultApp)),
        ])
    }
}

// MARK: - Agent app config (`/internal/agent-api/apps/:appId/config`)

/// `PATCH /internal/agent-api/apps/:appId/config` request body.
///
/// The legacy handler accepted a JSON object only and read `expectedRevision`
/// with the Foundation `as? NSNumber` cast, so JSON booleans (`0`/`1`) and
/// fractional numbers were accepted through `intValue`. This decoder keeps
/// that shape; every other shape throws, which the route maps to the published
/// `Invalid config request` 400 after authorization (the legacy order).
public struct AgentAppConfigPatchRequest: Codable, Sendable, Equatable {
    public var expectedRevision: Int
    public var set: [String: JSONValue]
    public var unset: [String]

    public init(
        expectedRevision: Int,
        set: [String: JSONValue] = [:],
        unset: [String] = []
    ) {
        self.expectedRevision = expectedRevision
        self.set = set
        self.unset = unset
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision
        case set
        case unset
    }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let members) = value,
              let rawRevision = members["expectedRevision"],
              let expectedRevision = Self.legacyInteger(rawRevision)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "expectedRevision is required")
            )
        }
        self.expectedRevision = expectedRevision
        if case .object(let members) = members["set"] {
            set = members
        } else {
            set = [:]
        }
        if case .array(let elements) = members["unset"] {
            unset = elements.compactMap { element in
                guard case .string(let value) = element else { return nil }
                return value
            }
        } else {
            unset = []
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedRevision, forKey: .expectedRevision)
        try container.encode(set, forKey: .set)
        try container.encode(unset, forKey: .unset)
    }

    /// Foundation's `NSNumber.intValue`: booleans become `0`/`1`, an integer is
    /// itself, and a fractional number truncates toward zero (clamped rather
    /// than trapping on a value outside `Int`).
    static func legacyInteger(_ value: JSONValue) -> Int? {
        switch value {
        case .bool(let flag):
            return flag ? 1 : 0
        case .integer(let integer):
            return Int(integer)
        case .number(let number):
            if number >= Double(Int.max) { return Int.max }
            if number <= Double(Int.min) { return Int.min }
            return Int(number)
        default:
            return nil
        }
    }
}

/// `GET/PATCH /internal/agent-api/apps/:appId/config` success body.
///
/// `schema`, `defaults`, `overrides` and `effective` are ordered objects: the
/// legacy handler emitted them in `enabled`, `threshold_bytes`,
/// `interval_seconds` order.
public struct AgentAppConfigResponse: ExactJSONBody, Sendable, Equatable {
    public var appId: String
    public var revision: Int
    public var overrides: [JSONMember]
    public var effective: [JSONMember]

    public init(appId: String, revision: Int, overrides: [JSONMember], effective: [JSONMember]) {
        self.appId = appId
        self.revision = revision
        self.overrides = overrides
        self.effective = effective
    }

    public var jsonBody: JSONBody {
        .object([
            JSONMember("appId", .string(appId)),
            JSONMember("revision", .integer(revision)),
            JSONMember("schema", Self.schema),
            JSONMember("defaults", Self.defaults),
            JSONMember("overrides", .object(overrides)),
            JSONMember("effective", .object(effective)),
        ])
    }

    /// The fixed schema string the legacy handler inlined.
    public static let schema: JSONBody = .object([
        JSONMember("enabled", .object([JSONMember("type", .string("boolean"))])),
        JSONMember("threshold_bytes", .object([
            JSONMember("type", .string("integer")),
            JSONMember("minimum", .integer(4096)),
            JSONMember("maximum", .integer(1_073_741_824)),
        ])),
        JSONMember("interval_seconds", .object([
            JSONMember("type", .string("integer")),
            JSONMember("minimum", .integer(900)),
            JSONMember("maximum", .integer(604_800)),
        ])),
    ])

    /// The fixed defaults object the legacy handler inlined.
    public static let defaults: JSONBody = .object([
        JSONMember("enabled", .boolean(true)),
        JSONMember("threshold_bytes", .integer(65_536)),
        JSONMember("interval_seconds", .integer(3600)),
    ])
}

/// The published error object for every prepare-route failure.
///
/// One ordered shape covers all cases: `error`, then `code` or `errorCode`,
/// then `requiredCapability` or `currentRevision`. That matches the legacy
/// member order for each branch (`error`/`code`, `error`/`errorCode`,
/// `error`/`code`/`requiredCapability`, `error`/`errorCode`/`currentRevision`).
public struct ActionCardPrepareErrorBody: ExactJSONBody, Sendable, Equatable {
    public var error: String
    public var code: String?
    public var errorCode: String?
    public var requiredCapability: String?
    public var currentRevision: Int?

    public init(
        error: String,
        code: String? = nil,
        errorCode: String? = nil,
        requiredCapability: String? = nil,
        currentRevision: Int? = nil
    ) {
        self.error = error
        self.code = code
        self.errorCode = errorCode
        self.requiredCapability = requiredCapability
        self.currentRevision = currentRevision
    }

    public var jsonBody: JSONBody {
        var members: [JSONMember] = [JSONMember("error", .string(error))]
        if let code { members.append(JSONMember("code", .string(code))) }
        if let errorCode { members.append(JSONMember("errorCode", .string(errorCode))) }
        if let requiredCapability {
            members.append(JSONMember("requiredCapability", .string(requiredCapability)))
        }
        if let currentRevision {
            members.append(JSONMember("currentRevision", .integer(currentRevision)))
        }
        return .object(members)
    }
}
