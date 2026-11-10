import Foundation

// MARK: - Request bodies
//
// The retired handlers read these bodies with the raw object cast plus
// per-field `as? String` / `NSNumber` checks. The decoders
// below keep that tolerance: a value of the wrong JSON type reads as absent,
// so a request the old routes accepted cannot become a 400. A body that is not
// a JSON object fails to decode and the route falls back to the empty request,
// which is the `?? [:]` the old parser used.

/// The `maxUses` tri-state of `POST /api/servers/:id/join-links`.
///
/// Upstream reads the raw value with `as? NSNumber`: an absent key or JSON
/// `null` means no cap, an empty string also means no cap, and an integral
/// number of at least one is the cap. Anything else is the published
/// `maxUses must be a positive integer` 400. A JSON boolean bridges to
/// `NSNumber` there, so `true`/`false` keep the legacy `1`/invalid reading.
public enum JoinLinkMaxUses: Sendable, Equatable {
    case unspecified
    case unlimited
    case limited(Int)
    case invalid
}

extension JoinLinkMaxUses: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self = integer >= 1 ? .limited(Int(integer)) : .invalid
        } else if (try? container.decode(Double.self)) != nil {
            self = .invalid
        } else if let string = try? container.decode(String.self) {
            self = string.isEmpty ? .unlimited : .invalid
        } else if let boolean = try? container.decode(Bool.self) {
            self = boolean ? .limited(1) : .invalid
        } else {
            self = .invalid
        }
    }
}

extension JoinLinkMaxUses: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unspecified, .invalid:
            try container.encodeNil()
        case .unlimited:
            try container.encode("")
        case .limited(let value):
            try container.encode(value)
        }
    }
}

/// `POST /api/servers/:id/join-links` request body.
public struct CreateJoinLinkRequest: Codable, Sendable, Equatable {
    public var expiresAt: String?
    public var maxUses: JoinLinkMaxUses

    public init(expiresAt: String? = nil, maxUses: JoinLinkMaxUses = .unspecified) {
        self.expiresAt = expiresAt
        self.maxUses = maxUses
    }

    private enum CodingKeys: String, CodingKey {
        case expiresAt
        case maxUses
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.expiresAt), !((try? container.decodeNil(forKey: .expiresAt)) ?? true) {
            expiresAt = try? container.decode(String.self, forKey: .expiresAt)
        } else {
            expiresAt = nil
        }
        if container.contains(.maxUses), !((try? container.decodeNil(forKey: .maxUses)) ?? true) {
            maxUses = (try? container.decode(JoinLinkMaxUses.self, forKey: .maxUses)) ?? .invalid
        } else {
            maxUses = .unspecified
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        switch maxUses {
        case .unspecified, .invalid:
            try container.encodeNil(forKey: .maxUses)
        case .unlimited:
            try container.encode("", forKey: .maxUses)
        case .limited(let value):
            try container.encode(value, forKey: .maxUses)
        }
    }
}

/// `POST /api/auth/accept-invite` request body. `token` is required by the
/// handler; `agreementId` is the optional pre-join agreement acknowledgement.
public struct JoinLinkAcceptRequest: Codable, Sendable, Equatable {
    public var token: String?
    public var agreementId: String?

    public init(token: String? = nil, agreementId: String? = nil) {
        self.token = token
        self.agreementId = agreementId
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case agreementId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = (try? container.decodeIfPresent(String.self, forKey: .token)) ?? nil
        agreementId = (try? container.decodeIfPresent(String.self, forKey: .agreementId)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encodeIfPresent(agreementId, forKey: .agreementId)
    }
}

/// `POST /api/servers/:id/invites` request body.
public struct CreateServerInviteRequest: Codable, Sendable, Equatable {
    public var email: String?
    public var role: String?

    public init(email: String? = nil, role: String? = nil) {
        self.email = email
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case email
        case role
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = (try? container.decodeIfPresent(String.self, forKey: .email)) ?? nil
        role = (try? container.decodeIfPresent(String.self, forKey: .role)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(role, forKey: .role)
    }
}

/// `POST /api/servers/:id/setup-transition` request body.
public struct ServerSetupTransitionRequest: Codable, Sendable, Equatable {
    public var action: String?

    public init(action: String? = nil) {
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case action
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = (try? container.decodeIfPresent(String.self, forKey: .action)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(action, forKey: .action)
    }
}

/// `POST /internal/agent-api/profile` request body.
public struct AgentProfileUpdateRequest: Codable, Sendable, Equatable {
    public var description: String?
    public var displayName: String?

    public init(description: String? = nil, displayName: String? = nil) {
        self.description = description
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case description
        case displayName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(displayName, forKey: .displayName)
    }
}

// MARK: - Shared response shapes

/// One pre-join agreement record. The published member order is the upstream
/// `agreementJSON` order, not alphabetical.
public struct ServerAgreementDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var version: Int
    public var title: String
    public var bodyMarkdown: String
    public var enabled: Bool

    public init(id: String, version: Int, title: String, bodyMarkdown: String, enabled: Bool) {
        self.id = id
        self.version = version
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.enabled = enabled
    }

    init(_ info: OAuthLedger.ServerAgreementInfo) {
        self.init(
            id: info.id,
            version: info.version,
            title: info.title,
            bodyMarkdown: info.bodyMarkdown,
            enabled: info.enabled
        )
    }

    /// Exact upstream `agreementJSON` order: id, version, title, bodyMarkdown,
    /// enabled.
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("version", version)
        body.append("title", title)
        body.append("bodyMarkdown", bodyMarkdown)
        body.append("enabled", enabled)
        return body.json
    }
}

/// The `{"ok":true}` body for the revoke/leave operations.
public struct JoinLinksOkResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public init() {}

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("ok", true)])
    }
}

// MARK: - Join links

/// One stored join link as the list/create responses publish it.
public struct JoinLinkPayloadDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var token: String
    public var createdAt: String
    public var expiresAt: String?
    public var maxUses: Int?
    public var useCount: Int
    public var revokedAt: String?

    public init(
        id: String,
        token: String,
        createdAt: String,
        expiresAt: String?,
        maxUses: Int?,
        useCount: Int,
        revokedAt: String?
    ) {
        self.id = id
        self.token = token
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.useCount = useCount
        self.revokedAt = revokedAt
    }

    init(_ record: JoinLinkRecord) {
        self.init(
            id: record.id,
            token: record.token,
            createdAt: DateText.isoString(record.createdAt),
            expiresAt: record.expiresAt.map(DateText.isoString),
            maxUses: record.maxUses,
            useCount: record.useCount,
            revokedAt: record.revokedAt.map(DateText.isoString)
        )
    }

    /// Exact upstream `joinLinkJSON` order.
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("token", token)
        body.append("createdAt", createdAt)
        body.append("expiresAt", optional: expiresAt)
        body.append("maxUses", optional: maxUses)
        body.append("useCount", useCount)
        body.append("revokedAt", optional: revokedAt)
        return body.json
    }
}

/// `POST /api/servers/:id/join-links` response.
public struct JoinLinkCreateResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var token: String
    public var link: JoinLinkPayloadDTO
    public var maxUses: Int?
    public var expiresAt: String?

    public init(token: String, link: JoinLinkPayloadDTO, maxUses: Int?, expiresAt: String?) {
        self.token = token
        self.link = link
        self.maxUses = maxUses
        self.expiresAt = expiresAt
    }

    /// Exact upstream create order: token, link, maxUses, expiresAt.
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("token", token)
        body.append("link", link)
        body.append("maxUses", optional: maxUses)
        body.append("expiresAt", optional: expiresAt)
        return body.json
    }
}

/// `GET /api/servers/:id/join-links` response: a bare array.
public struct JoinLinkListResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var links: [JoinLinkPayloadDTO]

    public init(links: [JoinLinkPayloadDTO]) {
        self.links = links
    }

    public var jsonBody: OrderedJSON {
        .array(links.map(\.jsonBody))
    }
}

/// `GET /api/auth/invite-info` response.
public struct InviteInfoResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var serverId: String
    public var serverName: String
    public var serverSlug: String
    public var humanSeatLimitReached: Bool
    public var humanSeatLimitMessage: String?
    public var memberCount: Int
    public var agentCount: Int
    public var insideCountsHidden: Bool
    public var agreement: ServerAgreementDTO?

    public init(
        serverId: String,
        serverName: String,
        serverSlug: String,
        humanSeatLimitReached: Bool,
        humanSeatLimitMessage: String?,
        memberCount: Int,
        agentCount: Int,
        insideCountsHidden: Bool,
        agreement: ServerAgreementDTO?
    ) {
        self.serverId = serverId
        self.serverName = serverName
        self.serverSlug = serverSlug
        self.humanSeatLimitReached = humanSeatLimitReached
        self.humanSeatLimitMessage = humanSeatLimitMessage
        self.memberCount = memberCount
        self.agentCount = agentCount
        self.insideCountsHidden = insideCountsHidden
        self.agreement = agreement
    }

    /// Exact upstream invite-info order; a nil agreement publishes `null`.
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("serverId", serverId)
        body.append("serverName", serverName)
        body.append("serverSlug", serverSlug)
        body.append("humanSeatLimitReached", humanSeatLimitReached)
        body.append("humanSeatLimitMessage", optional: humanSeatLimitMessage)
        body.append("memberCount", memberCount)
        body.append("agentCount", agentCount)
        body.append("insideCountsHidden", insideCountsHidden)
        body.append("agreement", OrderedJSON.bodyOrNull(agreement))
        return body.json
    }
}

/// `POST /api/auth/accept-invite` success body.
public struct JoinLinkAcceptResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var serverId: String

    public init(serverId: String) {
        self.serverId = serverId
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("serverId", serverId)
        return body.json
    }
}

// MARK: - Email invites

/// One pending email invite row.
public struct ServerInviteRowDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var invitedEmail: String
    public var email: String
    public var role: String
    public var status: String

    public init(id: String, invitedEmail: String, email: String, role: String, status: String = "pending") {
        self.id = id
        self.invitedEmail = invitedEmail
        self.email = email
        self.role = role
        self.status = status
    }

    /// Exact upstream invite-row order (the id/email/role/status projection).
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("invitedEmail", invitedEmail)
        body.append("email", email)
        body.append("role", role)
        body.append("status", status)
        return body.json
    }
}

/// `GET /api/servers/:id/invites` response: a bare array.
public struct ServerInviteListResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var invites: [ServerInviteRowDTO]

    public init(invites: [ServerInviteRowDTO]) {
        self.invites = invites
    }

    public var jsonBody: OrderedJSON {
        .array(invites.map(\.jsonBody))
    }
}

/// `POST /api/servers/:id/invites` response. The outer row and the nested
/// `invite` carry the same four fields in the upstream order.
public struct ServerInviteCreateResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var invitedEmail: String
    public var email: String
    public var role: String

    public init(id: String, invitedEmail: String, email: String, role: String) {
        self.id = id
        self.invitedEmail = invitedEmail
        self.email = email
        self.role = role
    }

    public var jsonBody: OrderedJSON {
        var invite = OrderedJSONObject()
        invite.append("id", id)
        invite.append("email", email)
        invite.append("role", role)
        invite.append("status", "pending")

        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("invitedEmail", invitedEmail)
        body.append("email", email)
        body.append("role", role)
        body.append("invite", invite.json)
        return body.json
    }
}

// MARK: - Server setup projection

/// Facts and decisions supplied by the setup service; serialization has no Store access.
/// `revokedComputers` is appended only by the reset reply.
public struct SetupProjectionResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public struct RuntimeOption: Codable, Sendable, Equatable {
        public var runtimeId: String
        public var capabilityStatus: String
        public var formDefinitionSchemaVersion: String?
        var jsonBody: OrderedJSON {
            MachineRuntimeOptionsResponse.Option(runtimeId: runtimeId, capabilityStatus: capabilityStatus,
                canSelectInThisContext: capabilityStatus == "available", runtimeFormV2: false,
                formDefinitionSchemaVersion: formDefinitionSchemaVersion).jsonBody
        }
    }
    public struct OfflineComputer: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var lastHeartbeat: String?
        var jsonBody: OrderedJSON {
            .object([OrderedJSONField("id", id), OrderedJSONField("name", name),
                OrderedJSONField("lastHeartbeat", optional: lastHeartbeat), OrderedJSONField("isComputer", true)])
        }
    }
    public var surface: String = "none"
    public var phase: String? = nil
    public var currentStep: String? = nil
    public var blocksChat: Bool = false
    public var allowedExits: [String] = ["return_to_server"]
    public var transitionsEnabled: Bool = false
    public var completionEnabled: Bool = false
    public var gateReason: String? = "insufficient_permission"
    public var computerStatus: String = "unknown"
    public var runtimeStatus: String = "unknown"
    public var runtimeOptions: [RuntimeOption] = []
    public var hasConnectedComputer: Bool = false
    public var offlineComputers: [OfflineComputer] = []
    public var revokedComputers: Int? = nil

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("surface", surface)
        body.append("phase", optional: phase)
        body.append("currentStep", optional: currentStep)
        body.append("blocksChat", blocksChat)
        body.append("allowedExits", .array(allowedExits.map(OrderedJSON.string)))
        body.append("sideEffectState", .object([
            OrderedJSONField("transitions", transitionsEnabled ? "enabled" : "disabled"),
            OrderedJSONField("completion", completionEnabled ? "enabled" : "disabled"),
        ]))
        body.append("gateReason", optional: gateReason)
        body.append("computerStatus", computerStatus)
        body.append("runtimeStatus", runtimeStatus)
        body.append("runtimeOptions", .array(runtimeOptions.map(\.jsonBody)))
        body.append("hasConnectedComputer", hasConnectedComputer)
        body.append("offlineComputers", .array(offlineComputers.map(\.jsonBody)))
        // The existing owner has no completionReason / survey history. Do not
        // manufacture an owed personal workflow from an absent persistence fact.
        body.append("postSetup", .object([
            OrderedJSONField("surveyPending", false), OrderedJSONField("handoffPending", false),
        ]))
        body.append("revokedComputers", ifPresent: revokedComputers)
        return body.json
    }
}

// MARK: - Agent profile

/// `GET /internal/agent-api/profile` agent projection.
public struct AgentProfileResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var agentId: String
    public var name: String
    public var displayName: String
    public var description: String
    public var avatarUrl: String?

    public init(agentId: String, name: String, displayName: String, description: String, avatarUrl: String?) {
        self.agentId = agentId
        self.name = name
        self.displayName = displayName
        self.description = description
        self.avatarUrl = avatarUrl
    }

    init(_ agent: OAuthLedger.AgentRuntimeInfo) {
        self.init(
            agentId: agent.id,
            name: agent.name,
            displayName: agent.displayName,
            description: agent.description ?? "",
            avatarUrl: agent.avatarUrl
        )
    }

    /// Exact upstream agent-profile order.
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("agentId", agentId)
        body.append("name", name)
        body.append("displayName", displayName)
        body.append("description", description)
        body.append("avatarUrl", optional: avatarUrl)
        return body.json
    }
}

/// `GET /internal/agent-api/profile?target=@handle` human projection.
public struct AgentHumanProfileResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var userId: String
    public var name: String
    public var displayName: String
    public var avatarUrl: String?

    public init(userId: String, name: String, displayName: String, avatarUrl: String?) {
        self.userId = userId
        self.name = name
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }

    init(_ account: Account) {
        self.init(
            userId: account.id,
            name: account.name,
            displayName: account.displayName ?? account.name,
            avatarUrl: account.avatarUrl
        )
    }

    /// Exact upstream human-profile order.
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("userId", userId)
        body.append("name", name)
        body.append("displayName", displayName)
        body.append("avatarUrl", optional: avatarUrl)
        return body.json
    }
}

/// The profile-show reply is one of two published shapes.
public enum AgentProfileShowResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    case agent(AgentProfileResponseDTO)
    case human(AgentHumanProfileResponseDTO)

    public var jsonBody: OrderedJSON {
        switch self {
        case .agent(let profile):
            profile.jsonBody
        case .human(let profile):
            profile.jsonBody
        }
    }
}

/// `POST /internal/agent-api/profile` success body.
public struct AgentProfileUpdateResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var agentId: String
    public var displayName: String?
    public var description: String?

    public init(agentId: String, displayName: String?, description: String?) {
        self.agentId = agentId
        self.displayName = displayName
        self.description = description
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("agentId", agentId)
        body.append("displayName", optional: displayName)
        body.append("description", optional: description)
        return body.json
    }
}

/// The Slack bridge is not part of this build; the four routes keep the
/// published 503 body.
public struct SlackBridgeUnavailableResponseDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public init() {}

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", false)
        body.append("code", "slack_bridge_provider_unavailable")
        return body.json
    }
}
