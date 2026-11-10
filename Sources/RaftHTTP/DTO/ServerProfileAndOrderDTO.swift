import Foundation

// MARK: - Request bodies
//
// The retired handlers read their bodies with the raw Foundation parser plus a
// per-member `as?` cast. The decoders below keep that tolerance: a member of the
// wrong JSON type reads as the legacy `nil` (so the domain's published 400 is
// unchanged), a JSON `0`/`1` still reads as a boolean exactly as the bridged
// `NSNumber` did, and a member whose legacy reader told "absent" from "present
// but wrong" keeps both states.

/// One request member whose legacy reader distinguished an absent key from a
/// present value of the wrong JSON type (`null` counts as present).
public enum ServerRequestField<Value: Sendable & Equatable>: Sendable, Equatable {
    case absent
    case value(Value)
    case invalid
}

/// Reads one boolean member the way the retired `as? Bool` cast did: JSON
/// `true`/`false`, plus the numbers `0` and `1` (including `0.0`/`1.0`), which
/// the raw parser bridged to `NSNumber`. Everything else, `null` included,
/// reads as nil.
func legacyBool<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    _ key: Key
) -> Bool? {
    if let boolean = try? container.decode(Bool.self, forKey: key) { return boolean }
    if let number = try? container.decode(Double.self, forKey: key) {
        if number == 1 { return true }
        if number == 0 { return false }
    }
    return nil
}

/// Reads one member with the legacy absent / wrong-type / value distinction.
func legacyField<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    _ key: Key,
    string: String.Type
) -> ServerRequestField<String> {
    guard container.contains(key) else { return .absent }
    if let value = try? container.decode(String.self, forKey: key) { return .value(value) }
    return .invalid
}

func legacyField<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    _ key: Key,
    bool: Bool.Type
) -> ServerRequestField<Bool> {
    guard container.contains(key) else { return .absent }
    if let value = legacyBool(container, key) { return .value(value) }
    return .invalid
}

/// A string element that never fails to decode: a non-string element reads as
/// nil, the way `compactMap { $0 as? String }` skipped it.
struct LenientStringElement: Decodable, Sendable {
    let value: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(String.self)
    }
}

/// `PUT /api/servers/:id/agreement` request body. All three members must read
/// as their legacy type; a body that does not carry them keeps the published
/// `Invalid agreement request` 400.
public struct ServerAgreementPutRequest: Sendable, Equatable, Decodable {
    public var enabled: Bool?
    public var title: String?
    public var bodyMarkdown: String?

    public init(enabled: Bool? = nil, title: String? = nil, bodyMarkdown: String? = nil) {
        self.enabled = enabled
        self.title = title
        self.bodyMarkdown = bodyMarkdown
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case title
        case bodyMarkdown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = legacyBool(container, .enabled)
        title = try? container.decode(String.self, forKey: .title)
        bodyMarkdown = try? container.decode(String.self, forKey: .bodyMarkdown)
    }
}

/// `PATCH /api/servers/:id/translation-settings` request body.
public struct ServerTranslationSettingsPatchRequest: Sendable, Equatable, Decodable {
    public var translationEnabled: Bool?

    public init(translationEnabled: Bool? = nil) {
        self.translationEnabled = translationEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case translationEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translationEnabled = legacyBool(container, .translationEnabled)
    }
}

/// `PATCH /api/servers/:id` request body. `name` and `hideHumansFromMembers`
/// are each optional, but a present value of the wrong type is its own 400.
public struct ServerProfilePatchRequest: Sendable, Equatable, Decodable {
    public var name: ServerRequestField<String>
    public var hideHumansFromMembers: ServerRequestField<Bool>

    public init(
        name: ServerRequestField<String> = .absent,
        hideHumansFromMembers: ServerRequestField<Bool> = .absent
    ) {
        self.name = name
        self.hideHumansFromMembers = hideHumansFromMembers
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case hideHumansFromMembers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = legacyField(container, .name, string: String.self)
        hideHumansFromMembers = legacyField(container, .hideHumansFromMembers, bool: Bool.self)
    }
}

/// `POST /api/message-translations:batch` request body. A member of the wrong
/// type reads as nil; `messageIds` keeps only its string elements, exactly as
/// the legacy `compactMap { $0 as? String }` did, and is nil when the member is
/// not an array.
public struct MessageTranslationBatchRequest: Sendable, Equatable, Decodable {
    public var targetLanguage: String?
    public var mode: String?
    public var messageIds: [String]?

    public init(targetLanguage: String? = nil, mode: String? = nil, messageIds: [String]? = nil) {
        self.targetLanguage = targetLanguage
        self.mode = mode
        self.messageIds = messageIds
    }

    private enum CodingKeys: String, CodingKey {
        case targetLanguage
        case mode
        case messageIds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetLanguage = try? container.decode(String.self, forKey: .targetLanguage)
        mode = try? container.decode(String.self, forKey: .mode)
        messageIds = (try? container.decode([LenientStringElement].self, forKey: .messageIds))?
            .compactMap(\.value)
    }
}

/// `POST /machine/scope-attestation` request body.
///
/// `audience` and `resource` are refused whatever their value, so only their
/// presence is kept. `metadata` is the raw member map (an object whose values
/// keep the legacy casts); a non-object `metadata` reads as empty.
public struct MachineScopeAttestationRequest: Sendable, Equatable, Decodable {
    public var scope: String?
    public var hasAudience: Bool
    public var hasResource: Bool
    public var metadata: [String: JSONScalarValue]

    public init(
        scope: String? = nil,
        hasAudience: Bool = false,
        hasResource: Bool = false,
        metadata: [String: JSONScalarValue] = [:]
    ) {
        self.scope = scope
        self.hasAudience = hasAudience
        self.hasResource = hasResource
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case audience
        case resource
        case metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try? container.decode(String.self, forKey: .scope)
        hasAudience = container.contains(.audience)
        hasResource = container.contains(.resource)
        metadata = (try? container.decode([String: JSONScalarValue].self, forKey: .metadata)) ?? [:]
    }
}

/// `POST /api/servers/:id/scope-attestation` request body. Only `scope` is read.
public struct ServerScopeAttestationRequest: Sendable, Equatable, Decodable {
    public var scope: String?

    public init(scope: String? = nil) {
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case scope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try? container.decode(String.self, forKey: .scope)
    }
}

// MARK: - Responses

/// One `GET /api/servers/unread-summary` row. The published order is
/// `serverId`, `unreadCount`, `serverPushMuted`, `activityUnreadCount`.
public struct ServerUnreadSummaryEntry: Sendable, Equatable, JSONBodyConvertible {
    public var serverId: String
    public var unreadCount: Int
    public var serverPushMuted: Bool

    public init(serverId: String, unreadCount: Int, serverPushMuted: Bool) {
        self.serverId = serverId
        self.unreadCount = unreadCount
        self.serverPushMuted = serverPushMuted
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("unreadCount", unreadCount),
            OrderedJSONField("serverPushMuted", serverPushMuted),
            OrderedJSONField("activityUnreadCount", unreadCount),
        ])
    }
}

/// `GET /api/servers/unread-summary` body: a bare array.
public struct ServerUnreadSummaryResponse: Sendable, Equatable, JSONBodyConvertible {
    public var entries: [ServerUnreadSummaryEntry]

    public init(entries: [ServerUnreadSummaryEntry]) {
        self.entries = entries
    }

    public var jsonBody: OrderedJSON {
        .array(entries.map(\.jsonBody))
    }
}

/// `GET`/`PATCH /api/servers/order` body.
public struct ServerOrderResponse: Sendable, Equatable, JSONBodyConvertible {
    public var serverOrder: [String]
    public var serverOrderVersion: Int

    public init(serverOrder: [String], serverOrderVersion: Int) {
        self.serverOrder = serverOrder
        self.serverOrderVersion = serverOrderVersion
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("serverOrder", .array(serverOrder.map(OrderedJSON.string))),
            OrderedJSONField("serverOrderVersion", serverOrderVersion),
        ])
    }
}

/// Member-visible `GET /api/servers` facts, in pinned Node field order.
/// Creation/downgrade timestamps remain omitted until their owner stores facts.
public struct OrderedServerListEntry: Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var name: String
    public var avatarUrl: String?
    public var slug: String
    public var ownerId: String
    public var onboardingAgentId: String?
    public var hideHumansFromMembers: Bool
    public var plan: String
    public var role: String
    public var serverPushMuted: Bool
    public var serverOrderVersion: Int

    public init(id: String, name: String, avatarUrl: String?, slug: String, ownerId: String,
                onboardingAgentId: String?, hideHumansFromMembers: Bool, plan: String,
                role: String, serverPushMuted: Bool, serverOrderVersion: Int) {
        self.id = id
        self.name = name
        self.avatarUrl = avatarUrl
        self.slug = slug
        self.ownerId = ownerId
        self.onboardingAgentId = onboardingAgentId
        self.hideHumansFromMembers = hideHumansFromMembers
        self.plan = plan
        self.role = role
        self.serverPushMuted = serverPushMuted
        self.serverOrderVersion = serverOrderVersion
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("avatarUrl", optional: avatarUrl),
            OrderedJSONField("slug", slug),
            OrderedJSONField("ownerId", ownerId),
            OrderedJSONField("onboardingAgentId", optional: onboardingAgentId),
            OrderedJSONField("hideHumansFromMembers", hideHumansFromMembers),
            OrderedJSONField("plan", plan),
            OrderedJSONField("role", role),
            OrderedJSONField("serverPushMuted", serverPushMuted),
            OrderedJSONField("serverOrderVersion", serverOrderVersion),
            OrderedJSONField("publicPageLive", false),
        ])
    }
}

/// `GET /api/servers` body for a caller with at least one membership.
public struct OrderedServerListResponse: Sendable, Equatable, JSONBodyConvertible {
    public var servers: [OrderedServerListEntry]

    public init(servers: [OrderedServerListEntry]) {
        self.servers = servers
    }

    public var jsonBody: OrderedJSON {
        .array(servers.map(\.jsonBody))
    }
}

/// `GET /api/servers/:id/apps` body.
public struct ServerAppsResponse: Sendable, Equatable, JSONBodyConvertible {
    public struct App: Sendable, Equatable {
        public var appId: String
        public var displayName: String

        public init(appId: String, displayName: String) {
            self.appId = appId
            self.displayName = displayName
        }
    }

    public var apps: [App]

    public init(apps: [App]) {
        self.apps = apps
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("apps", .array(apps.map { app in
                .object([
                    OrderedJSONField("appId", app.appId),
                    OrderedJSONField("displayName", app.displayName),
                ])
            })),
        ])
    }
}

/// `GET`/`PUT /api/servers/:id/agreement` body: the agreement, or JSON `null`.
public struct ServerAgreementResponse: Sendable, Equatable, JSONBodyConvertible {
    public var agreement: ServerAgreementDTO?

    public init(agreement: ServerAgreementDTO?) {
        self.agreement = agreement
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("agreement", .bodyOrNull(agreement))])
    }
}

/// One entry of the `POST /api/message-translations:batch` result list.
public enum MessageTranslationResultDTO: Sendable, Equatable, JSONBodyConvertible {
    case notFound(messageId: String, targetLanguage: String)
    case skipped(messageId: String, skipReason: String, sourceLanguage: String, targetLanguage: String)
    case translated(
        messageId: String,
        contentHash: String,
        sourceLanguage: String,
        sourceConfidence: Int,
        targetLanguage: String,
        translatedContent: String,
        provider: String,
        providerVersion: String
    )

    public var jsonBody: OrderedJSON {
        switch self {
        case .notFound(let messageId, let targetLanguage):
            return .object([
                OrderedJSONField("messageId", messageId),
                OrderedJSONField("status", "not_found"),
                OrderedJSONField("targetLanguage", targetLanguage),
            ])
        case .skipped(let messageId, let skipReason, let sourceLanguage, let targetLanguage):
            return .object([
                OrderedJSONField("messageId", messageId),
                OrderedJSONField("status", "skipped"),
                OrderedJSONField("skipReason", skipReason),
                OrderedJSONField("sourceLanguage", sourceLanguage),
                OrderedJSONField("targetLanguage", targetLanguage),
            ])
        case .translated(
            let messageId, let contentHash, let sourceLanguage, let sourceConfidence,
            let targetLanguage, let translatedContent, let provider, let providerVersion
        ):
            return .object([
                OrderedJSONField("messageId", messageId),
                OrderedJSONField("status", "translated"),
                OrderedJSONField("contentHash", contentHash),
                OrderedJSONField("sourceLanguage", sourceLanguage),
                OrderedJSONField("sourceConfidence", sourceConfidence),
                OrderedJSONField("targetLanguage", targetLanguage),
                OrderedJSONField("translatedContent", translatedContent),
                OrderedJSONField("provider", provider),
                OrderedJSONField("providerVersion", providerVersion),
                OrderedJSONField("placeholderPolicyVersion", "placeholder-v0"),
            ])
        }
    }
}

/// `POST /api/message-translations:batch` body.
public struct MessageTranslationBatchResponse: Sendable, Equatable, JSONBodyConvertible {
    public var results: [MessageTranslationResultDTO]

    public init(results: [MessageTranslationResultDTO]) {
        self.results = results
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("results", .array(results.map(\.jsonBody)))])
    }
}

/// `GET`/`PATCH /api/servers/:id/translation-settings` body.
public struct ServerTranslationSettingsResponse: Sendable, Equatable, JSONBodyConvertible {
    public var translationEnabled: Bool
    public var translationAvailable: Bool
    public var canManageTranslation: Bool

    public init(translationEnabled: Bool, translationAvailable: Bool, canManageTranslation: Bool) {
        self.translationEnabled = translationEnabled
        self.translationAvailable = translationAvailable
        self.canManageTranslation = canManageTranslation
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("translationEnabled", translationEnabled),
            OrderedJSONField("translationAvailable", translationAvailable),
            OrderedJSONField("canManageTranslation", canManageTranslation),
        ])
    }
}

/// `PATCH /api/servers/:id` body.
public struct ServerProfilePatchResponse: Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var name: String
    public var slug: String
    public var avatarUrl: String?
    public var hideHumansFromMembers: Bool

    public init(id: String, name: String, slug: String, avatarUrl: String?, hideHumansFromMembers: Bool) {
        self.id = id
        self.name = name
        self.slug = slug
        self.avatarUrl = avatarUrl
        self.hideHumansFromMembers = hideHumansFromMembers
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("slug", slug),
            OrderedJSONField("avatarUrl", optional: avatarUrl),
            OrderedJSONField("hideHumansFromMembers", hideHumansFromMembers),
        ])
    }
}

/// `GET /api/servers/:id/members/:memberId/profile` body. A removed member and
/// a current member publish different shapes.
public enum ServerMemberProfileResponse: Sendable, Equatable, JSONBodyConvertible {
    public struct CreatedAgent: Sendable, Equatable {
        public var id: String
        public var name: String
        public var displayName: String

        public init(id: String, name: String, displayName: String) {
            self.id = id
            self.name = name
            self.displayName = displayName
        }
    }

    case removed(userId: String, name: String, email: String, avatarUrl: String?)
    case current(
        userId: String,
        name: String,
        email: String?,
        avatarUrl: String?,
        createdAgents: [CreatedAgent]
    )

    public var jsonBody: OrderedJSON {
        switch self {
        case .removed(let userId, let name, let email, let avatarUrl):
            return .object([
                OrderedJSONField("userId", userId),
                OrderedJSONField("name", name),
                OrderedJSONField("displayName", name),
                OrderedJSONField("email", email),
                OrderedJSONField("avatarUrl", optional: avatarUrl),
                OrderedJSONField("membershipStatus", "removed"),
            ])
        case .current(let userId, let name, let email, let avatarUrl, let createdAgents):
            return .object([
                OrderedJSONField("userId", userId),
                OrderedJSONField("name", name),
                OrderedJSONField("displayName", name),
                OrderedJSONField("email", optional: email),
                OrderedJSONField("avatarUrl", optional: avatarUrl),
                OrderedJSONField("createdAgents", .array(createdAgents.map { agent in
                    .object([
                        OrderedJSONField("id", agent.id),
                        OrderedJSONField("name", agent.name),
                        OrderedJSONField("displayName", agent.displayName),
                    ])
                })),
            ])
        }
    }
}

/// One `GET /api/servers/:id/members` row.
public struct ServerMemberListEntry: Sendable, Equatable, JSONBodyConvertible {
    public var userId: String
    public var role: String
    public var name: String
    public var email: String?
    public var avatarUrl: String?

    public init(userId: String, role: String, name: String, email: String?, avatarUrl: String?) {
        self.userId = userId
        self.role = role
        self.name = name
        self.email = email
        self.avatarUrl = avatarUrl
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("userId", userId),
            OrderedJSONField("role", role),
            OrderedJSONField("name", name),
            OrderedJSONField("displayName", name),
            OrderedJSONField("email", optional: email),
            OrderedJSONField("avatarUrl", optional: avatarUrl),
        ])
    }
}

/// `GET /api/servers/:id/members` body: a bare array.
public struct ServerMembersListResponse: Sendable, Equatable, JSONBodyConvertible {
    public var members: [ServerMemberListEntry]

    public init(members: [ServerMemberListEntry]) {
        self.members = members
    }

    public var jsonBody: OrderedJSON {
        .array(members.map(\.jsonBody))
    }
}

/// `GET /api/servers/:id/member-graph` body.
public struct ServerMemberGraphResponse: Sendable, Equatable, JSONBodyConvertible {
    public struct Human: Sendable, Equatable {
        public var id: String
        public var channelIds: [String]
    }

    public struct Agent: Sendable, Equatable {
        public var id: String
        public var name: String
        public var channelIds: [String]
    }

    public struct Channel: Sendable, Equatable {
        public var id: String
        public var name: String
        public var memberCount: Int
    }

    public struct Edge: Sendable, Equatable {
        public var channelId: String
        public var memberType: String
        public var memberId: String
    }

    public var humans: [Human]
    public var agents: [Agent]
    public var channels: [Channel]
    public var edges: [Edge]

    public init(humans: [Human], agents: [Agent], channels: [Channel], edges: [Edge]) {
        self.humans = humans
        self.agents = agents
        self.channels = channels
        self.edges = edges
    }

    public var jsonBody: OrderedJSON {
        func strings(_ values: [String]) -> OrderedJSON { .array(values.map(OrderedJSON.string)) }
        return .object([
            OrderedJSONField("humans", .array(humans.map { human in
                .object([
                    OrderedJSONField("id", human.id),
                    OrderedJSONField("channelIds", strings(human.channelIds)),
                ])
            })),
            OrderedJSONField("agents", .array(agents.map { agent in
                .object([
                    OrderedJSONField("id", agent.id),
                    OrderedJSONField("name", agent.name),
                    OrderedJSONField("channelIds", strings(agent.channelIds)),
                ])
            })),
            OrderedJSONField("channels", .array(channels.map { channel in
                .object([
                    OrderedJSONField("id", channel.id),
                    OrderedJSONField("name", channel.name),
                    OrderedJSONField("memberCount", channel.memberCount),
                ])
            })),
            OrderedJSONField("edges", .array(edges.map { edge in
                .object([
                    OrderedJSONField("channelId", edge.channelId),
                    OrderedJSONField("memberType", edge.memberType),
                    OrderedJSONField("memberId", edge.memberId),
                ])
            })),
        ])
    }
}

/// `POST /api/servers/:id/avatar` body.
public struct ServerAvatarUploadResponse: Sendable, Equatable, JSONBodyConvertible {
    public var avatarUrl: String

    public init(avatarUrl: String) {
        self.avatarUrl = avatarUrl
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("avatarUrl", avatarUrl)])
    }
}

/// `POST /machine/scope-attestation` and `POST /api/servers/:id/scope-attestation`
/// success body.
///
/// `metadata` is the claims metadata object the machine route embeds, already
/// rendered with the same sorted-key encoder the signed claims use (the JWT
/// payload and this member must carry identical bytes); the server route has no
/// metadata and omits the member.
public struct ScopeAttestationResponse: Sendable, Equatable, JSONBodyConvertible {
    public var attestation: String
    public var scope: String
    public var audience: String
    public var resource: String
    public var expiresAt: String
    /// `nil` omits the member (server route); `.some(nil)` publishes `null`.
    public var metadata: ScopeAttestationMetadataBody?

    public init(
        attestation: String,
        scope: String,
        audience: String,
        resource: String,
        expiresAt: String,
        metadata: ScopeAttestationMetadataBody?
    ) {
        self.attestation = attestation
        self.scope = scope
        self.audience = audience
        self.resource = resource
        self.expiresAt = expiresAt
        self.metadata = metadata
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("attestation", attestation)
        body.append("scope", scope)
        body.append("audience", audience)
        body.append("resource", resource)
        body.append("expiresAt", expiresAt)
        if let metadata {
            body.append("metadata", metadata.json)
        }
        return body.json
    }
}

/// The attestation `metadata` member: JSON `null` when empty, otherwise the
/// sorted-key object the claims carry.
public struct ScopeAttestationMetadataBody: Sendable, Equatable {
    public var renderedObject: String?

    public init(renderedObject: String?) {
        self.renderedObject = renderedObject
    }

    var json: OrderedJSON {
        renderedObject.map(OrderedJSON.raw) ?? .null
    }
}

// MARK: - Share artifact page

/// The HTML page `GET /share/:id` publishes. The route owns the content type and
/// cache headers; the service owns the document.
public struct ShareArtifactPageOutput: Sendable, Equatable {
    public var html: String

    public init(html: String) {
        self.html = html
    }
}

/// The PNG bytes `GET /share/:id.png` publishes.
public struct ShareArtifactImageOutput: Sendable, Equatable {
    public var bytes: Data
    public var width: Int
    public var height: Int

    public init(bytes: Data, width: Int, height: Int) {
        self.bytes = bytes
        self.width = width
        self.height = height
    }
}
