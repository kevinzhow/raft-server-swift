import Foundation
import RaftShared

// Request and response shapes for the integrations and app-access surface:
// setup declarations, marketplace installs, agent grants and app events,
// attachment comments, and the agent integration-app routes.
//
// Every response whose legacy body was concatenated by hand owns its published
// member order as an `OrderedJSON` tree (`JSONBodyConvertible`), so the strings
// keep the legacy `jsonString` escaping. The two agent app projections that the
// legacy route serialized with sorted keys are plain `Encodable` values: their
// escaping and member order are those of the sorted `JSONEncoder` in
// `Respond.swift`.

// MARK: - Request body

/// A top-level JSON object whose members are read leniently, one by one.
///
/// The retired handlers parsed the body with an object cast and read each
/// member with `as?`, so a member of the wrong type read as absent while a
/// present key stayed distinguishable from a missing one. The reads below keep
/// those rules (`Bool` accepts `0`/`1`, `Int` accepts whole numbers and booleans,
/// array reads skip non-string elements). A body that is not a JSON object does
/// not decode; the service answers its own published refusal.
public struct IntegrationRequestBody: Decodable, Sendable, Equatable {
    public let members: [String: JSONValue]

    public init(members: [String: JSONValue] = [:]) {
        self.members = members
    }

    public init(from decoder: any Decoder) throws {
        guard case .object(let members) = try JSONValue(from: decoder) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a JSON object"
            ))
        }
        self.members = members
    }

    public func has(_ key: String) -> Bool {
        members[key] != nil
    }

    /// The legacy `object[key] as? String`.
    public func string(_ key: String) -> String? {
        if case .string(let value)? = members[key] { return value }
        return nil
    }

    /// The legacy `object[key] as? Bool` (`NSNumber` bridging: `0`/`1` too).
    public func bool(_ key: String) -> Bool? {
        switch members[key] {
        case .bool(let value)?:
            return value
        case .integer(let value)?:
            return value == 0 ? false : (value == 1 ? true : nil)
        case .number(let value)?:
            return value == 0 ? false : (value == 1 ? true : nil)
        default:
            return nil
        }
    }

    /// The legacy `object[key] as? Int` (`NSNumber` bridging).
    public func int(_ key: String) -> Int? {
        switch members[key] {
        case .integer(let value)?:
            return Int(exactly: value)
        case .number(let value)?:
            return Int(exactly: value)
        case .bool(let value)?:
            return value ? 1 : 0
        default:
            return nil
        }
    }

    /// The legacy `(object[key] as? [Any])?.compactMap { $0 as? String }`.
    public func stringElements(_ key: String) -> [String]? {
        guard case .array(let elements)? = members[key] else { return nil }
        return elements.compactMap { element in
            if case .string(let value) = element { return value }
            return nil
        }
    }

    /// The raw member, `.null` for an explicit JSON null, nil when absent.
    public func value(_ key: String) -> JSONValue? {
        members[key]
    }
}

// MARK: - Integration service rows

/// One integration service row of the OAuth ledger, typed.
///
/// The ledger used to hand these over as untyped dictionaries. `name` and
/// `whenToUse` are the stored text; `snapshot` renders them through the
/// third-party inert-text rule exactly as the agent integration listing does.
public struct IntegrationServiceRow: Sendable, Equatable {
    public var id: String
    public var clientId: String
    public var name: String
    public var description: String?
    public var homepageUrl: String?
    public var agentManifestUrl: String?
    public var agentManifestUrlSource: String?
    public var allowedScopes: [String]?
    public var whenToUse: String?
    public var appType: String

    public init(
        id: String,
        clientId: String,
        name: String,
        description: String?,
        homepageUrl: String?,
        agentManifestUrl: String?,
        agentManifestUrlSource: String?,
        allowedScopes: [String]?,
        whenToUse: String?,
        appType: String
    ) {
        self.id = id
        self.clientId = clientId
        self.name = name
        self.description = description
        self.homepageUrl = homepageUrl
        self.agentManifestUrl = agentManifestUrl
        self.agentManifestUrlSource = agentManifestUrlSource
        self.allowedScopes = allowedScopes
        self.whenToUse = whenToUse
        self.appType = appType
    }

    /// The row the agent sees: inert name and `whenToUse`, nothing else changed.
    var snapshot: AgentIntegrationServiceSnapshot {
        AgentIntegrationServiceSnapshot(
            id: id,
            clientId: clientId,
            name: ThirdPartyText.inertThirdPartyText(name),
            description: description,
            homepageUrl: homepageUrl,
            agentManifestUrl: agentManifestUrl,
            agentManifestUrlSource: agentManifestUrlSource,
            allowedScopes: allowedScopes,
            whenToUse: whenToUse.map(ThirdPartyText.inertThirdPartyText),
            appType: appType
        )
    }
}

/// One Marketplace listing row an agent may install.
public struct MarketplaceClientRow: Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var clientId: String
    public var name: String
    public var description: String?
    public var homepageUrl: String?
    public var allowedScopes: [String]
    public var installedOnServer: Bool

    public init(
        id: String,
        clientId: String,
        name: String,
        description: String?,
        homepageUrl: String?,
        allowedScopes: [String],
        installedOnServer: Bool
    ) {
        self.id = id
        self.clientId = clientId
        self.name = name
        self.description = description
        self.homepageUrl = homepageUrl
        self.allowedScopes = allowedScopes
        self.installedOnServer = installedOnServer
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("name", name),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("homepageUrl", optional: homepageUrl),
            OrderedJSONField("allowedScopes", .array(allowedScopes.map(OrderedJSON.string))),
            OrderedJSONField("installedOnServer", installedOnServer),
        ])
    }
}

// MARK: - Agent app projection (sorted keys)

/// The setup block of an agent app projection. Every member is published, a
/// nil one as JSON `null`.
public struct IntegrationAppSetupProjection: Encodable, Sendable, Equatable {
    public var status: String
    public var url: String?
    public var description: String?
    public var revision: Int
    public var completedAt: String?

    public init(status: String, url: String?, description: String?, revision: Int, completedAt: String?) {
        self.status = status
        self.url = url
        self.description = description
        self.revision = revision
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case status, url, description, revision, completedAt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeOrNull(url, forKey: .url)
        try container.encodeOrNull(description, forKey: .description)
        try container.encode(revision, forKey: .revision)
        try container.encodeOrNull(completedAt, forKey: .completedAt)
    }
}

/// `GET /internal/agent-api/integrations/app` row: the agent-facing view of an
/// App the agent may manage. The legacy route serialized it with sorted keys and
/// `null` for every absent member, which `encode(to:)` reproduces.
public struct IntegrationAppProjection: Encodable, Sendable, Equatable {
    public var installationId: String?
    public var name: String
    public var clientKey: String
    public var createdAt: String
    public var updatedAt: String
    public var description: String?
    public var homepageUrl: String?
    public var callbackUrl: String?
    public var agentManifestUrl: String?
    public var setupUrl: String?
    public var setupDescription: String?
    public var setupRevision: Int
    public var setup: IntegrationAppSetupProjection?
    public var scopes: [String]
    public var appType: String
    public var publishStatus: String
    public var enabled: Bool
    public var authority: String
    public var recoveryCommand: String

    public init(
        installationId: String?,
        name: String,
        clientKey: String,
        createdAt: String,
        updatedAt: String,
        description: String?,
        homepageUrl: String?,
        callbackUrl: String?,
        agentManifestUrl: String?,
        setupUrl: String?,
        setupDescription: String?,
        setupRevision: Int,
        setup: IntegrationAppSetupProjection?,
        scopes: [String],
        appType: String,
        publishStatus: String,
        enabled: Bool,
        authority: String,
        recoveryCommand: String
    ) {
        self.installationId = installationId
        self.name = name
        self.clientKey = clientKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.description = description
        self.homepageUrl = homepageUrl
        self.callbackUrl = callbackUrl
        self.agentManifestUrl = agentManifestUrl
        self.setupUrl = setupUrl
        self.setupDescription = setupDescription
        self.setupRevision = setupRevision
        self.setup = setup
        self.scopes = scopes
        self.appType = appType
        self.publishStatus = publishStatus
        self.enabled = enabled
        self.authority = authority
        self.recoveryCommand = recoveryCommand
    }

    private enum CodingKeys: String, CodingKey {
        case state, card, installationId, name, clientKey, createdAt, updatedAt, description
        case homepageUrl, callbackUrl, agentManifestUrl, setupUrl, setupDescription, setupRevision
        case setup, scopes, category, dataAccessSummary, logoUrl, appType, publishStatus, enabled
        case authority, recoveryCommand
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("committed", forKey: .state)
        try container.encodeNil(forKey: .card)
        try container.encodeOrNull(installationId, forKey: .installationId)
        try container.encode(name, forKey: .name)
        try container.encode(clientKey, forKey: .clientKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeOrNull(description, forKey: .description)
        try container.encodeOrNull(homepageUrl, forKey: .homepageUrl)
        try container.encodeOrNull(callbackUrl, forKey: .callbackUrl)
        try container.encodeOrNull(agentManifestUrl, forKey: .agentManifestUrl)
        try container.encodeOrNull(setupUrl, forKey: .setupUrl)
        try container.encodeOrNull(setupDescription, forKey: .setupDescription)
        try container.encode(setupRevision, forKey: .setupRevision)
        if let setup {
            try container.encode(setup, forKey: .setup)
        } else {
            try container.encodeNil(forKey: .setup)
        }
        try container.encode(scopes, forKey: .scopes)
        try container.encode("Other", forKey: .category)
        try container.encodeNil(forKey: .dataAccessSummary)
        try container.encodeNil(forKey: .logoUrl)
        try container.encode(appType, forKey: .appType)
        try container.encode(publishStatus, forKey: .publishStatus)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(authority, forKey: .authority)
        try container.encode(recoveryCommand, forKey: .recoveryCommand)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOrNull(_ value: String?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

public struct AgentIntegrationAppListResponse: Encodable, Sendable, Equatable {
    public var apps: [IntegrationAppProjection]

    public init(apps: [IntegrationAppProjection]) {
        self.apps = apps
    }
}

public struct AgentIntegrationAppStatusResponse: Encodable, Sendable, Equatable {
    public var app: IntegrationAppProjection

    public init(app: IntegrationAppProjection) {
        self.app = app
    }
}

// MARK: - Setup and install responses

/// `GET /api/integrations/clients/:clientId/setup` and the App backend's
/// `PUT /api/oauth/installations/:installationId/setup` reply. `canConfigure`
/// is published only by the human read.
public struct IntegrationSetupStateResponse: Sendable, Equatable, JSONBodyConvertible {
    public var status: String
    public var url: String?
    public var description: String?
    public var revision: Int
    public var completedAt: String?
    public var canConfigure: Bool?

    public init(
        status: String,
        url: String?,
        description: String?,
        revision: Int,
        completedAt: String?,
        canConfigure: Bool?
    ) {
        self.status = status
        self.url = url
        self.description = description
        self.revision = revision
        self.completedAt = completedAt
        self.canConfigure = canConfigure
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("status", status)
        body.append("url", optional: url)
        body.append("description", optional: description)
        body.append("revision", revision)
        body.append("completedAt", optional: completedAt)
        body.append("canConfigure", ifPresent: canConfigure)
        return body.json
    }
}

/// `PATCH /api/integrations/clients/:clientId` reply.
public struct IntegrationClientSetupUpdate: Sendable, Equatable, JSONBodyConvertible {
    public var clientId: String
    public var setupUrl: String?
    public var setupDescription: String?
    public var setupRevision: Int

    public init(clientId: String, setupUrl: String?, setupDescription: String?, setupRevision: Int) {
        self.clientId = clientId
        self.setupUrl = setupUrl
        self.setupDescription = setupDescription
        self.setupRevision = setupRevision
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("setupUrl", optional: setupUrl),
            OrderedJSONField("setupDescription", optional: setupDescription),
            OrderedJSONField("setupRevision", setupRevision),
        ])
    }
}

/// `POST /api/integrations/marketplace/:clientId/install` reply.
public struct MarketplaceInstallResponse: Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var setupStatus: String
    public var setupRevision: Int

    public init(id: String, setupStatus: String, setupRevision: Int) {
        self.id = id
        self.setupStatus = setupStatus
        self.setupRevision = setupRevision
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("setup", .object([
                OrderedJSONField("status", setupStatus),
                OrderedJSONField("revision", setupRevision),
            ])),
        ])
    }
}

/// `{"status": …}`: an approved access request or a revoked grant.
public struct AgentAccessDecisionResponse: Sendable, Equatable, JSONBodyConvertible {
    public var status: String

    public init(status: String) {
        self.status = status
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("status", status)])
    }
}

// MARK: - Agent grants and app events

/// `POST /api/integrations/agents/:agentId/grants` reply: `201` for a new grant,
/// `200` for the existing one.
public struct AgentGrantCreatedResponse: Sendable, Equatable, JSONBodyConvertible {
    public var status: UInt
    public var grantId: String
    public var created: Bool

    public init(status: UInt, grantId: String, created: Bool) {
        self.status = status
        self.grantId = grantId
        self.created = created
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("grantId", grantId),
            OrderedJSONField("created", created),
        ])
    }
}

/// `GET /api/integrations/agents/:agentId/grants`: a bare array.
public struct AgentGrantListResponse: Sendable, Equatable, JSONBodyConvertible {
    public var rows: [OAuthLedger.AgentGrantRow]

    public init(rows: [OAuthLedger.AgentGrantRow]) {
        self.rows = rows
    }

    public var jsonBody: OrderedJSON {
        .array(rows.map { row in
            .object([
                OrderedJSONField("id", row.id),
                OrderedJSONField("clientId", row.clientRecordId),
                OrderedJSONField("scopes", .array(row.scopes.map(OrderedJSON.string))),
                OrderedJSONField("grantSource", row.grantSource),
            ])
        })
    }
}

/// `GET /api/integrations/agents/:agentId/grantable-apps` reply.
public struct AgentGrantableAppsResponse: Sendable, JSONBodyConvertible {
    public var apps: [OAuthLedger.GrantableApp]

    public init(apps: [OAuthLedger.GrantableApp]) {
        self.apps = apps
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("apps", .array(apps.map { app in
                .object([
                    OrderedJSONField("clientId", app.recordId),
                    OrderedJSONField("clientKey", app.clientKey),
                    OrderedJSONField("name", app.name),
                    OrderedJSONField("scopes", .array(app.scopes.map(OrderedJSON.string))),
                ])
            })),
        ])
    }
}

extension OAuthLedger.AgentAppEventSummary {
    /// The event summary the list and the detail share. Timestamps use the
    /// default (whole-second) ISO formatter, as the legacy projection did.
    fileprivate var summaryFields: [OrderedJSONField] {
        let formatter = ISO8601DateFormatter()
        return [
            OrderedJSONField("id", id),
            OrderedJSONField("kind", kind),
            OrderedJSONField("summary", summary),
            OrderedJSONField("status", status),
            OrderedJSONField("createdAt", formatter.string(from: createdAt)),
            OrderedJSONField("expiresAt", formatter.string(from: expiresAt)),
            OrderedJSONField("deliveredAt", optional: deliveredAt.map { formatter.string(from: $0) }),
            OrderedJSONField("externalEventId", optional: externalEventId),
            OrderedJSONField("app", .object([
                OrderedJSONField("clientKey", clientKey),
                OrderedJSONField("clientName", clientName),
                OrderedJSONField("logoUrl", .null),
            ])),
        ]
    }
}

/// `GET /api/integrations/agents/:agentId/events` reply.
public struct AgentAppEventPageResponse: Sendable, Equatable, JSONBodyConvertible {
    public var events: [OAuthLedger.AgentAppEventSummary]
    public var nextCursor: String?

    public init(events: [OAuthLedger.AgentAppEventSummary], nextCursor: String?) {
        self.events = events
        self.nextCursor = nextCursor
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("events", .array(events.map { .object($0.summaryFields) })),
            OrderedJSONField("nextCursor", optional: nextCursor),
        ])
    }
}

/// `GET /api/integrations/agents/:agentId/events/:eventId` reply: the summary
/// plus the stored payload text, published as the JSON it already is.
public struct AgentAppEventDetailResponse: Sendable, Equatable, JSONBodyConvertible {
    public var event: OAuthLedger.AgentAppEventSummary

    public init(event: OAuthLedger.AgentAppEventSummary) {
        self.event = event
    }

    public var jsonBody: OrderedJSON {
        var fields = event.summaryFields
        fields.append(OrderedJSONField("payload", .raw(event.payloadJSON.isEmpty ? "null" : event.payloadJSON)))
        return .object(fields)
    }
}

// MARK: - Attachment comments

/// `GET /api/attachments/comments/counts` reply: one member per requested id
/// the caller can read, in request order (a repeated id repeats the member).
public struct AttachmentCommentCountsResponse: Sendable, Equatable, JSONBodyConvertible {
    public var counts: [(id: String, count: Int)]

    public init(counts: [(id: String, count: Int)]) {
        self.counts = counts
    }

    public static func == (lhs: AttachmentCommentCountsResponse, rhs: AttachmentCommentCountsResponse) -> Bool {
        lhs.counts.count == rhs.counts.count
            && zip(lhs.counts, rhs.counts).allSatisfy { $0.id == $1.id && $0.count == $1.count }
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("counts", .object(counts.map { OrderedJSONField($0.id, $0.count) })),
        ])
    }
}

/// `GET /api/attachments/:id/comments` reply.
public struct AttachmentCommentListResponse: Sendable, Equatable, JSONBodyConvertible {
    public struct Comment: Sendable, Equatable {
        public var id: String
        public var attachmentId: String
        public var content: String
        /// The stored, already canonical anchor JSON.
        public var anchorJSON: String?
        public var senderType: String
        public var senderId: String
        public var senderName: String
        public var createdAt: String

        public init(
            id: String,
            attachmentId: String,
            content: String,
            anchorJSON: String?,
            senderType: String,
            senderId: String,
            senderName: String,
            createdAt: String
        ) {
            self.id = id
            self.attachmentId = attachmentId
            self.content = content
            self.anchorJSON = anchorJSON
            self.senderType = senderType
            self.senderId = senderId
            self.senderName = senderName
            self.createdAt = createdAt
        }
    }

    public var comments: [Comment]
    public var canComment: Bool
    public var reason: String

    public init(comments: [Comment], canComment: Bool, reason: String) {
        self.comments = comments
        self.canComment = canComment
        self.reason = reason
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("comments", .array(comments.map { comment in
                .object([
                    OrderedJSONField("id", comment.id),
                    OrderedJSONField("attachmentId", comment.attachmentId),
                    OrderedJSONField("content", comment.content),
                    OrderedJSONField("anchor", comment.anchorJSON.map(OrderedJSON.raw) ?? .null),
                    OrderedJSONField("sender", .object([
                        OrderedJSONField("type", comment.senderType),
                        OrderedJSONField("id", comment.senderId),
                        OrderedJSONField("name", comment.senderName),
                    ])),
                    OrderedJSONField("createdAt", comment.createdAt),
                    OrderedJSONField("reactions", .array([])),
                ])
            })),
            OrderedJSONField("viewer", .object([
                OrderedJSONField("canComment", canComment),
                OrderedJSONField("reason", reason),
            ])),
        ])
    }
}

/// `POST /api/attachments/:id/comments` reply.
public struct AttachmentCommentCreatedResponse: Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var attachmentId: String
    public var content: String
    public var createdAt: String
    public var anchorJSON: String?
    public var hostMessageId: String
    public var hostChannelId: String
    public var threadChannelId: String

    public init(
        id: String,
        attachmentId: String,
        content: String,
        createdAt: String,
        anchorJSON: String?,
        hostMessageId: String,
        hostChannelId: String,
        threadChannelId: String
    ) {
        self.id = id
        self.attachmentId = attachmentId
        self.content = content
        self.createdAt = createdAt
        self.anchorJSON = anchorJSON
        self.hostMessageId = hostMessageId
        self.hostChannelId = hostChannelId
        self.threadChannelId = threadChannelId
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("message", .object([
                OrderedJSONField("id", id),
                OrderedJSONField("channelId", threadChannelId),
                OrderedJSONField("content", content),
                OrderedJSONField("senderType", "user"),
                OrderedJSONField("createdAt", createdAt),
                OrderedJSONField("anchor", anchorJSON.map(OrderedJSON.raw) ?? .null),
                OrderedJSONField("commentRef", .object([
                    OrderedJSONField("attachmentId", attachmentId),
                    OrderedJSONField("hostMessageId", hostMessageId),
                    OrderedJSONField("hostSource", .object([
                        OrderedJSONField("type", "channel"),
                        OrderedJSONField("routeKind", "channel"),
                        OrderedJSONField("channelId", hostChannelId),
                        OrderedJSONField("rootThreadChannelId", threadChannelId),
                    ])),
                ])),
            ])),
            OrderedJSONField("threadChannelId", threadChannelId),
        ])
    }
}

/// `GET /internal/agent-api/attachments/:attachmentId/comments` reply.
public struct AgentAttachmentCommentsResponse: Sendable, Equatable, JSONBodyConvertible {
    public struct Comment: Sendable, Equatable {
        public var id: String
        public var content: String
        public var senderType: String
        public var anchorJSON: String?
        public var resolved: Bool
        public var resolvedByReactorId: String?
        public var resolvedByReactorType: String?
        public var resolvedAt: String?

        public init(
            id: String,
            content: String,
            senderType: String,
            anchorJSON: String?,
            resolved: Bool,
            resolvedByReactorId: String?,
            resolvedByReactorType: String?,
            resolvedAt: String?
        ) {
            self.id = id
            self.content = content
            self.senderType = senderType
            self.anchorJSON = anchorJSON
            self.resolved = resolved
            self.resolvedByReactorId = resolvedByReactorId
            self.resolvedByReactorType = resolvedByReactorType
            self.resolvedAt = resolvedAt
        }
    }

    public var comments: [Comment]
    public var canResolve: Bool

    public init(comments: [Comment], canResolve: Bool) {
        self.comments = comments
        self.canResolve = canResolve
    }

    public var jsonBody: OrderedJSON {
        var viewer = OrderedJSONObject()
        viewer.append("canComment", false)
        viewer.append("reason", "agent_descoped")
        viewer.append("canResolve", canResolve)
        if canResolve {
            viewer.append("resolveAction", .object([
                OrderedJSONField("type", "reaction"),
                OrderedJSONField("emoji", "✅"),
            ]))
        }
        return .object([
            OrderedJSONField("comments", .array(comments.map { comment in
                let resolvedBy: OrderedJSON
                if let reactorId = comment.resolvedByReactorId, let reactorType = comment.resolvedByReactorType {
                    resolvedBy = .object([
                        OrderedJSONField("reactorId", reactorId),
                        OrderedJSONField("reactorType", reactorType),
                    ])
                } else {
                    resolvedBy = .null
                }
                return .object([
                    OrderedJSONField("id", comment.id),
                    OrderedJSONField("content", comment.content),
                    OrderedJSONField("senderType", comment.senderType),
                    OrderedJSONField("anchor", comment.anchorJSON.map(OrderedJSON.raw) ?? .null),
                    OrderedJSONField("resolved", comment.resolved),
                    OrderedJSONField("resolvedBy", resolvedBy),
                    OrderedJSONField("resolvedAt", optional: comment.resolvedAt),
                ])
            })),
            OrderedJSONField("viewer", viewer.json),
        ])
    }
}

// MARK: - Agent integration apps

/// `POST /internal/agent-api/integrations/app/update` reply.
public struct AgentIntegrationAppUpdatedResponse: Sendable, Equatable, JSONBodyConvertible {
    public var clientId: String
    public var clientKey: String
    public var clientName: String
    public var updatedFields: [String]

    public init(clientId: String, clientKey: String, clientName: String, updatedFields: [String]) {
        self.clientId = clientId
        self.clientKey = clientKey
        self.clientName = clientName
        self.updatedFields = updatedFields
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("clientKey", clientKey),
            OrderedJSONField("clientName", clientName),
            OrderedJSONField("updatedFields", .array(updatedFields.map(OrderedJSON.string))),
        ])
    }
}

/// `GET /internal/agent-api/integrations/marketplace` reply.
public struct AgentIntegrationMarketplaceResponse: Sendable, Equatable, JSONBodyConvertible {
    public var query: String?
    public var apps: [MarketplaceClientRow]

    public init(query: String?, apps: [MarketplaceClientRow]) {
        self.query = query
        self.apps = apps
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("surface", "public_marketplace"),
            OrderedJSONField("metadataTrust", "untrusted_app_supplied"),
            OrderedJSONField("query", optional: query),
            OrderedJSONField("apps", .array(apps.map { $0.jsonBody })),
        ])
    }
}

/// `POST /internal/agent-api/integrations/login` reply.
public enum AgentIntegrationLoginResponse: Sendable, Equatable, JSONBodyConvertible {
    /// The service is not installed on the agent's Server yet.
    case installRequired(
        service: AgentIntegrationServiceSnapshot,
        scopes: [String],
        serverSlug: String,
        serverName: String,
        marketplaceUrl: String,
        target: String?,
        actionCardMessageId: String?
    )
    /// `logged_in` for a new login, `already_logged_in` for a repeat.
    case loggedIn(
        status: String,
        requestId: String,
        service: AgentIntegrationServiceSnapshot,
        scopes: [String]
    )

    public var jsonBody: OrderedJSON {
        switch self {
        case .installRequired(
            let service, let scopes, let serverSlug, let serverName, let marketplaceUrl,
            let target, let actionCardMessageId
        ):
            return .object([
                OrderedJSONField("status", "install_required"),
                OrderedJSONField("nextAction", "install_from_marketplace"),
                OrderedJSONField("service", service.jsonBody),
                OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
                OrderedJSONField("installation", .object([
                    OrderedJSONField("serverSlug", serverSlug),
                    OrderedJSONField("serverName", serverName),
                    OrderedJSONField("marketplaceUrl", marketplaceUrl),
                    OrderedJSONField("target", optional: target),
                    OrderedJSONField("actionCardMessageId", optional: actionCardMessageId),
                ])),
            ])
        case .loggedIn(let status, let requestId, let service, let scopes):
            return .object([
                OrderedJSONField("status", status),
                OrderedJSONField("requestId", requestId),
                OrderedJSONField("service", service.jsonBody),
                OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
            ])
        }
    }
}

// MARK: - Agent message lookups

/// `GET /internal/agent-api/messages/:messageId/mention-deliveries` reply.
///
/// Upstream lists the message's occurrence rows and publishes only the authored
/// handle plus the coarse outcome. `targetId` is deliberately absent: the agent
/// surface addresses targets by the handle the author typed, and the pinned CLI
/// schema (`agentApiSenderMentionDeliveryRowSchema`) is a strict object with
/// exactly these members.
public struct AgentMentionDeliveriesResponse: Sendable, Equatable, JSONBodyConvertible {
    public struct Delivery: Sendable, Equatable {
        public var targetHandle: String
        public var outcome: MentionDeliveryOutcome

        public init(targetHandle: String, outcome: MentionDeliveryOutcome) {
            self.targetHandle = targetHandle
            self.outcome = outcome
        }

        fileprivate var fields: [OrderedJSONField] {
            var fields = [OrderedJSONField("targetHandle", targetHandle)]
            switch outcome {
            case .delivered:
                fields.append(OrderedJSONField("outcome", "delivered"))
            case .pending:
                fields.append(OrderedJSONField("outcome", "pending"))
            case .lost(let category):
                fields.append(OrderedJSONField("outcome", "lost"))
                fields.append(OrderedJSONField("reasonCategory", category))
            case .unknown:
                fields.append(OrderedJSONField("outcome", "unknown"))
            }
            return fields
        }
    }

    public var messageId: String
    public var deliveries: [Delivery]

    public init(messageId: String, deliveries: [Delivery]) {
        self.messageId = messageId
        self.deliveries = deliveries
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("messageId", messageId),
            OrderedJSONField("deliveries", .array(deliveries.map { .object($0.fields) })),
        ])
    }
}

/// `GET /internal/agent-api/messages/:messageId/resolve` reply.
public struct AgentMessageResolveResponse: Sendable, Equatable, JSONBodyConvertible {
    public struct ExternalMessage: Sendable, Equatable {
        public var messageId: String?
        public var provider: String?
        public var actorName: String?

        public init(messageId: String?, provider: String?, actorName: String?) {
            self.messageId = messageId
            self.provider = provider
            self.actorName = actorName
        }
    }

    public var messageId: String
    public var channelId: String
    public var channelName: String
    public var channelType: String
    public var senderType: String
    public var senderName: String
    public var content: String
    public var createdAt: String
    public var senderTimezone: String?
    public var mentioned: Bool
    public var attachments: [AgentHistoryMessage.Attachment]
    public var externalMessage: ExternalMessage?

    public init(
        messageId: String,
        channelId: String,
        channelName: String,
        channelType: String,
        senderType: String,
        senderName: String,
        content: String,
        createdAt: String,
        senderTimezone: String?,
        mentioned: Bool,
        attachments: [AgentHistoryMessage.Attachment] = [],
        externalMessage: ExternalMessage?
    ) {
        self.messageId = messageId
        self.channelId = channelId
        self.channelName = channelName
        self.channelType = channelType
        self.senderType = senderType
        self.senderName = senderName
        self.content = content
        self.createdAt = createdAt
        self.senderTimezone = senderTimezone
        self.mentioned = mentioned
        self.attachments = attachments
        self.externalMessage = externalMessage
    }

    public var jsonBody: OrderedJSON {
        var message = OrderedJSONObject()
        message.append("message_id", messageId)
        message.append("id", messageId)
        message.append("channel_id", channelId)
        message.append("channel_name", channelName)
        message.append("channel_type", channelType)
        message.append("sender_type", senderType)
        message.append("sender_name", senderName)
        message.append("content", content)
        message.append("created_at", createdAt)
        message.append("sender_timezone", optional: senderTimezone)
        message.append("mentioned", mentioned)
        message.append("attachments", .array(attachments.map(\.jsonBody)))
        if let externalMessage {
            message.append("external_message", .object([
                OrderedJSONField("message_id", optional: externalMessage.messageId),
                OrderedJSONField("provider", optional: externalMessage.provider),
                OrderedJSONField("actor_name", optional: externalMessage.actorName),
            ]))
        }
        return .object([OrderedJSONField("message", message.json)])
    }
}
