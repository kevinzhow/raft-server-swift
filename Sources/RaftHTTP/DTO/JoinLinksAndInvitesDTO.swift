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
public struct ServerAgreementDTO: Codable, Sendable, Equatable {
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

    /// Exact upstream `agreementJSON` bytes: id, version, title, bodyMarkdown,
    /// enabled.
    public func jsonBody() -> String {
        "{\"id\":\(jsonString(id)),\"version\":\(version),\"title\":\(jsonString(title)),\"bodyMarkdown\":\(jsonString(bodyMarkdown)),\"enabled\":\(enabled)}"
    }
}

extension ServerAgreementDTO: ExactJSONResponse {}

/// The `{"ok":true}` body for the revoke/leave operations.
public struct JoinLinksOkResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
    public init() {}

    public func jsonBody() -> String { "{\"ok\":true}" }
}

// MARK: - Join links

/// One stored join link as the list/create responses publish it.
public struct JoinLinkPayloadDTO: Codable, Sendable, Equatable {
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
            createdAt: EmailLoginDirectory.isoString(record.createdAt),
            expiresAt: record.expiresAt.map(EmailLoginDirectory.isoString),
            maxUses: record.maxUses,
            useCount: record.useCount,
            revokedAt: record.revokedAt.map(EmailLoginDirectory.isoString)
        )
    }

    /// Exact upstream `joinLinkJSON` bytes.
    public func jsonBody() -> String {
        let expires = expiresAt.map(jsonString) ?? "null"
        let revoked = revokedAt.map(jsonString) ?? "null"
        let max = maxUses.map(String.init) ?? "null"
        return "{\"id\":\(jsonString(id)),\"token\":\(jsonString(token)),\"createdAt\":\(jsonString(createdAt)),\"expiresAt\":\(expires),\"maxUses\":\(max),\"useCount\":\(useCount),\"revokedAt\":\(revoked)}"
    }
}

extension JoinLinkPayloadDTO: ExactJSONResponse {}

/// `POST /api/servers/:id/join-links` response.
public struct JoinLinkCreateResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
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

    /// Exact upstream create bytes: token, link, maxUses, expiresAt.
    public func jsonBody() -> String {
        let max = maxUses.map(String.init) ?? "null"
        let expires = expiresAt.map(jsonString) ?? "null"
        return "{\"token\":\(jsonString(token)),\"link\":\(link.jsonBody()),\"maxUses\":\(max),\"expiresAt\":\(expires)}"
    }
}

/// `GET /api/servers/:id/join-links` response: a bare array.
public struct JoinLinkListResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
    public var links: [JoinLinkPayloadDTO]

    public init(links: [JoinLinkPayloadDTO]) {
        self.links = links
    }

    public func jsonBody() -> String {
        "[\(links.map { $0.jsonBody() }.joined(separator: ","))]"
    }
}

/// `GET /api/auth/invite-info` response.
public struct InviteInfoResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
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

    /// Exact upstream invite-info bytes.
    public func jsonBody() -> String {
        let message = humanSeatLimitMessage.map(jsonString) ?? "null"
        let agreementJSON = agreement?.jsonBody() ?? "null"
        return "{\"serverId\":\(jsonString(serverId)),\"serverName\":\(jsonString(serverName)),\"serverSlug\":\(jsonString(serverSlug)),\"humanSeatLimitReached\":\(humanSeatLimitReached),\"humanSeatLimitMessage\":\(message),\"memberCount\":\(memberCount),\"agentCount\":\(agentCount),\"insideCountsHidden\":\(insideCountsHidden),\"agreement\":\(agreementJSON)}"
    }
}

/// `POST /api/auth/accept-invite` success body.
public struct JoinLinkAcceptResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
    public var serverId: String

    public init(serverId: String) {
        self.serverId = serverId
    }

    public func jsonBody() -> String {
        "{\"ok\":true,\"serverId\":\(jsonString(serverId))}"
    }
}

// MARK: - Email invites

/// One pending email invite row.
public struct ServerInviteRowDTO: Codable, Sendable, Equatable {
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

    /// Exact upstream invite-row bytes (the id/email/role/status projection).
    public func jsonBody() -> String {
        "{\"id\":\(jsonString(id)),\"invitedEmail\":\(jsonString(invitedEmail)),\"email\":\(jsonString(email)),\"role\":\(jsonString(role)),\"status\":\(jsonString(status))}"
    }
}

extension ServerInviteRowDTO: ExactJSONResponse {}

/// `GET /api/servers/:id/invites` response: a bare array.
public struct ServerInviteListResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
    public var invites: [ServerInviteRowDTO]

    public init(invites: [ServerInviteRowDTO]) {
        self.invites = invites
    }

    public func jsonBody() -> String {
        "[\(invites.map { $0.jsonBody() }.joined(separator: ","))]"
    }
}

/// `POST /api/servers/:id/invites` response. The outer row and the nested
/// `invite` carry the same four fields in the upstream order.
public struct ServerInviteCreateResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
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

    public func jsonBody() -> String {
        let idJSON = jsonString(id)
        let emailJSON = jsonString(email)
        let roleJSON = jsonString(role)
        let invite = "{\"id\":\(idJSON),\"email\":\(emailJSON),\"role\":\(roleJSON),\"status\":\"pending\"}"
        return "{\"id\":\(idJSON),\"invitedEmail\":\(emailJSON),\"email\":\(emailJSON),\"role\":\(roleJSON),\"invite\":\(invite)}"
    }
}

// MARK: - Server setup projection

/// The server setup projection. `revokedComputers` is present only on the
/// reset reply, which appends it after the shared projection.
public struct SetupProjectionResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
    public var phase: String
    public var isOwnerOrAdmin: Bool
    public var revokedComputers: Int?

    public init(phase: String, isOwnerOrAdmin: Bool, revokedComputers: Int? = nil) {
        self.phase = phase
        self.isOwnerOrAdmin = isOwnerOrAdmin
        self.revokedComputers = revokedComputers
    }

    public func jsonBody() -> String {
        let body: String
        if isOwnerOrAdmin {
            body = "{\"surface\":\"computer_runtime\",\"phase\":\(jsonString(phase)),\"currentStep\":\"computer_runtime\",\"blocksChat\":true,\"allowedExits\":[\"reset\",\"return_to_server\"],\"sideEffectState\":{\"transitions\":\"enabled\",\"completion\":\"disabled\"},\"gateReason\":\"computer_offline\",\"computerStatus\":\"offline\",\"runtimeStatus\":\"unknown\",\"runtimeOptions\":[],\"hasConnectedComputer\":false,\"offlineComputers\":[],\"postSetup\":{\"surveyPending\":false,\"handoffPending\":false}}"
        } else {
            body = "{\"surface\":\"none\",\"phase\":null,\"currentStep\":null,\"blocksChat\":false,\"allowedExits\":[\"return_to_server\"],\"sideEffectState\":{\"transitions\":\"disabled\",\"completion\":\"disabled\"},\"gateReason\":\"insufficient_permission\",\"computerStatus\":\"unknown\",\"runtimeStatus\":\"unknown\",\"runtimeOptions\":[],\"hasConnectedComputer\":false,\"offlineComputers\":[],\"postSetup\":{\"surveyPending\":false,\"handoffPending\":false}}"
        }
        guard let revokedComputers else { return body }
        return String(body.dropLast()) + ",\"revokedComputers\":\(revokedComputers)}"
    }
}

// MARK: - Agent profile

/// `GET /internal/agent-api/profile` agent projection.
public struct AgentProfileResponseDTO: Codable, Sendable, Equatable {
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

    /// Exact upstream agent-profile bytes.
    public func jsonBody() -> String {
        "{\"agentId\":\(jsonString(agentId)),\"name\":\(jsonString(name)),\"displayName\":\(jsonString(displayName)),\"description\":\(jsonString(description)),\"avatarUrl\":\(avatarUrl.map(jsonString) ?? "null")}"
    }
}

extension AgentProfileResponseDTO: ExactJSONResponse {}

/// `GET /internal/agent-api/profile?target=@handle` human projection.
public struct AgentHumanProfileResponseDTO: Codable, Sendable, Equatable {
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

    /// Exact upstream human-profile bytes.
    public func jsonBody() -> String {
        "{\"userId\":\(jsonString(userId)),\"name\":\(jsonString(name)),\"displayName\":\(jsonString(displayName)),\"avatarUrl\":\(avatarUrl.map(jsonString) ?? "null")}"
    }
}

extension AgentHumanProfileResponseDTO: ExactJSONResponse {}

/// The profile-show reply is one of two published shapes.
public enum AgentProfileShowResponse: Codable, Sendable, Equatable, ExactJSONResponse {
    case agent(AgentProfileResponseDTO)
    case human(AgentHumanProfileResponseDTO)

    public func jsonBody() -> String {
        switch self {
        case .agent(let profile):
            profile.jsonBody()
        case .human(let profile):
            profile.jsonBody()
        }
    }
}

/// `POST /internal/agent-api/profile` success body.
public struct AgentProfileUpdateResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
    public var agentId: String
    public var displayName: String?
    public var description: String?

    public init(agentId: String, displayName: String?, description: String?) {
        self.agentId = agentId
        self.displayName = displayName
        self.description = description
    }

    public func jsonBody() -> String {
        let display = displayName.map(jsonString) ?? "null"
        let description = description.map(jsonString) ?? "null"
        return "{\"ok\":true,\"agentId\":\(jsonString(agentId)),\"displayName\":\(display),\"description\":\(description)}"
    }
}

/// The Slack bridge is not part of this build; the four routes keep the
/// published 503 body.
public struct SlackBridgeUnavailableResponseDTO: Codable, Sendable, Equatable, ExactJSONResponse {
    public init() {}

    public func jsonBody() -> String {
        "{\"ok\":false,\"code\":\"slack_bridge_provider_unavailable\"}"
    }
}
