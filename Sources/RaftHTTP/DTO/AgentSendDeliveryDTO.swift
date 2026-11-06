import Foundation
import RaftShared

// MARK: - Requests

/// `POST /internal/agent/:agentId/send` request body.
///
/// The legacy handler accepted any JSON object with a string `target` and a
/// string `content`; a missing or non-string key is the published
/// `Invalid target` 400. The route decodes this shape when it can and passes
/// `nil` when it cannot, so the same 400 stays reachable for a malformed body.
public struct AgentSendRequest: Codable, Sendable, Equatable {
    public var target: String?
    public var content: String?

    public init(target: String? = nil, content: String? = nil) {
        self.target = target
        self.content = content
    }
}

/// `POST /internal/agent/:agentId/receive-ack` request body.
///
/// The legacy parser reads raw JSON numbers and strings, not typed arrays:
/// non-numeric `seqs` entries are skipped, repeated or non-positive values are
/// dropped, and non-string `messageIds` entries are ignored. The custom decode
/// keeps that per-element tolerance.
public struct AgentReceiveAckRequest: Decodable, Sendable, Equatable {
    public var seqs: [Int]
    public var messageIds: [String]

    public init(seqs: [Int] = [], messageIds: [String] = []) {
        self.seqs = seqs
        self.messageIds = messageIds
    }

    private enum CodingKeys: String, CodingKey {
        case seqs
        case messageIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSeqs = (try? container.decodeIfPresent([JSONValue].self, forKey: .seqs)) ?? nil
        var seqs: [Int] = []
        var seen = Set<Int>()
        for item in rawSeqs ?? [] {
            guard let number = item.receiveAckNumber else { continue }
            let value = Int(number.rounded(.down))
            guard value > 0, seen.insert(value).inserted else { continue }
            seqs.append(value)
        }
        let rawIds = (try? container.decodeIfPresent([JSONValue].self, forKey: .messageIds)) ?? nil
        let messageIds = (rawIds ?? []).compactMap { item -> String? in
            guard case .string(let raw) = item else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.seqs = seqs
        self.messageIds = messageIds
    }
}

/// `POST /internal/agent/:agentId/threads/unfollow` and
/// `POST /internal/agent-api/threads/unfollow` request body.
public struct AgentThreadUnfollowRequest: Codable, Sendable, Equatable {
    public var thread: String?

    public init(thread: String? = nil) {
        self.thread = thread
    }
}

/// `POST /internal/agent-api/activity` request body.
///
/// `events` is required and must be an array of objects; the legacy untyped
/// events cast rejected every other shape.
/// The per-event keys stay a `JSONValue` map because the two accepted schemas
/// read different fields and the v1 schema reports unknown keys.
public struct AgentActivityIngestRequest: Decodable, Sendable, Equatable {
    public var schema: String?
    public var events: [AgentActivityEvent]
    public var dropped: Int

    public init(
        schema: String? = nil,
        events: [AgentActivityEvent] = [],
        dropped: Int = 0
    ) {
        self.schema = schema
        self.events = events
        self.dropped = dropped
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case events
        case dropped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = (try? container.decodeIfPresent(String.self, forKey: .schema)) ?? nil
        self.events = try container.decode([AgentActivityEvent].self, forKey: .events)
        let dropped = (try? container.decodeIfPresent(JSONValue.self, forKey: .dropped)) ?? nil
        if case .integer(let value)? = dropped {
            self.dropped = Int(clamping: value)
        } else if case .number(let value)? = dropped {
            self.dropped = Self.intValue(value)
        } else if case .bool(let value)? = dropped {
            self.dropped = value ? 1 : 0
        } else {
            self.dropped = 0
        }
    }

    private static func intValue(_ value: Double) -> Int {
        guard value.isFinite, value >= Double(Int.min), value <= Double(Int.max) else { return 0 }
        return Int(value)
    }
}

/// One activity-ingest event. Unknown keys survive because the v1 schema
/// reports them and rejects `transcript_path` wherever it appears.
public struct AgentActivityEvent: Decodable, Sendable, Equatable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue] = [:]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.fields = try container.decode([String: JSONValue].self)
    }

    /// `eventId` is only read when it is a non-empty string.
    public var eventId: String? {
        guard case .string(let value)? = fields["eventId"], !value.isEmpty else { return nil }
        return value
    }

    /// `occurredAt` is only read when it is a string the ISO parser accepts.
    public var occurredAt: Date? {
        guard case .string(let value)? = fields["occurredAt"] else { return nil }
        return EmailLoginDirectory.isoDate(value)
    }

    /// A non-string status is ignored, exactly like the legacy `as? String`.
    public var status: String? {
        guard case .string(let value)? = fields["status"] else { return nil }
        return value
    }

    public var hookEventName: String? {
        guard case .string(let value)? = fields["hookEventName"] else { return nil }
        return value
    }

    /// `nil` means the key is absent; a present non-string value is
    /// `.null`/`.object`/… and must be rejected as `Invalid status detail`.
    public var detail: JSONValue? {
        fields["detail"]
    }
}

// MARK: - Responses

public struct AgentSendResponse: Codable, Sendable, Equatable, OrderedJSONBody {
    public let id: String
    public let channelId: String

    public init(id: String, channelId: String) {
        self.id = id
        self.channelId = channelId
    }

    /// Legacy order: `id`, then `channelId`.
    public func jsonBody() -> String {
        "{\"id\":\(jsonString(id)),\"channelId\":\(jsonString(channelId))}"
    }
}

/// `POST /internal/agent/:agentId/runtime-profile/migration-done` body.
///
/// The route is a deprecated acknowledgement: `noop` is present only when the
/// request carried no `migrationKey`. Legacy order is `ok`, `deprecated`,
/// optional `noop`, then `message`.
public struct AgentRuntimeProfileMigrationResponse: Codable, Sendable, Equatable, OrderedJSONBody {
    public static let message = "Runtime Profile migration acknowledgments are deprecated; runtime changes reset the session automatically."

    public let noop: Bool

    public init(noop: Bool) {
        self.noop = noop
    }

    public func jsonBody() -> String {
        let noopField = noop ? ",\"noop\":\"no pending migration\"" : ""
        return "{\"ok\":true,\"deprecated\":true\(noopField),\"message\":\(jsonString(Self.message))}"
    }
}

/// `POST /internal/agent-api/activity` body.
///
/// `ignoredFields` appears only for the v1 schema and only when it is non-empty,
/// always after `droppedCount` and sorted by name.
public struct AgentActivityIngestResponse: Codable, Sendable, Equatable, OrderedJSONBody {
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let droppedCount: Int
    public let ignoredFields: [String]?

    public init(
        acceptedCount: Int,
        rejectedCount: Int,
        droppedCount: Int,
        ignoredFields: [String]? = nil
    ) {
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.droppedCount = droppedCount
        self.ignoredFields = ignoredFields
    }

    public func jsonBody() -> String {
        var body = "{\"ok\":true,\"acceptedCount\":\(acceptedCount),\"rejectedCount\":\(rejectedCount),\"droppedCount\":\(droppedCount)"
        if let ignoredFields, !ignoredFields.isEmpty {
            body += ",\"ignoredFields\":[\(ignoredFields.map(jsonString).joined(separator: ","))]"
        }
        return body + "}"
    }
}

/// `GET /internal/agent-api/threads` body.
public struct AgentThreadListResponse: Codable, Sendable, Equatable, OrderedJSONBody {
    public let threads: [AgentThreadListEntry]

    public init(threads: [AgentThreadListEntry]) {
        self.threads = threads
    }

    public func jsonBody() -> String {
        "{\"threads\":[\(threads.map { $0.jsonBody() }.joined(separator: ","))]}"
    }
}

public struct AgentThreadListEntry: Codable, Sendable, Equatable, OrderedJSONBody {
    public let target: String
    public let threadChannelId: String
    public let parentChannelRef: String
    public let parentMessageId: String
    public let parentMessageShortId: String
    public let followedAt: String
    public let reason: String
    public let doneAt: String?

    public init(
        target: String,
        threadChannelId: String,
        parentChannelRef: String,
        parentMessageId: String,
        parentMessageShortId: String,
        followedAt: String,
        reason: String,
        doneAt: String?
    ) {
        self.target = target
        self.threadChannelId = threadChannelId
        self.parentChannelRef = parentChannelRef
        self.parentMessageId = parentMessageId
        self.parentMessageShortId = parentMessageShortId
        self.followedAt = followedAt
        self.reason = reason
        self.doneAt = doneAt
    }

    /// Legacy order: target, threadChannelId, parentChannelRef,
    /// parentMessageId, parentMessageShortId, followedAt, reason, doneAt.
    public func jsonBody() -> String {
        "{\"target\":\(jsonString(target)),\"threadChannelId\":\(jsonString(threadChannelId)),\"parentChannelRef\":\(jsonString(parentChannelRef)),\"parentMessageId\":\(jsonString(parentMessageId)),\"parentMessageShortId\":\(jsonString(parentMessageShortId)),\"followedAt\":\(jsonString(followedAt)),\"reason\":\(jsonString(reason)),\"doneAt\":\(doneAt.map(jsonString) ?? "null")}"
    }
}

/// `GET /internal/agent-api/integrations` body.
public struct AgentIntegrationListResponse: Codable, Sendable, Equatable, OrderedJSONBody {
    public let services: [AgentIntegrationServiceSnapshot]
    public let activeLogins: [AgentIntegrationActiveLogin]

    public init(
        services: [AgentIntegrationServiceSnapshot],
        activeLogins: [AgentIntegrationActiveLogin]
    ) {
        self.services = services
        self.activeLogins = activeLogins
    }

    public func jsonBody() -> String {
        "{\"services\":[\(services.map { $0.jsonBody() }.joined(separator: ","))],\"activeLogins\":[\(activeLogins.map { $0.jsonBody() }.joined(separator: ","))]}"
    }
}

/// One integration service row. The projection in
/// `Sources/RaftHTTP/Support/AgentIntegrationProjection.swift` maps the
/// OAuth ledger's untyped client row into this shape, so the service and this
/// DTO never touch an untyped JSON dictionary.
public struct AgentIntegrationServiceSnapshot: Codable, Sendable, Equatable, OrderedJSONBody {
    public let id: String?
    public let clientId: String?
    public let name: String?
    public let description: String?
    public let homepageUrl: String?
    public let agentManifestUrl: String?
    public let agentManifestUrlSource: String?
    public let allowedScopes: [String]?
    public let whenToUse: String?
    public let appType: String?
    public let setup: AgentIntegrationSetup?

    public init(
        id: String?,
        clientId: String?,
        name: String?,
        description: String?,
        homepageUrl: String?,
        agentManifestUrl: String?,
        agentManifestUrlSource: String?,
        allowedScopes: [String]?,
        whenToUse: String?,
        appType: String?,
        setup: AgentIntegrationSetup? = nil
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
        self.setup = setup
    }

    /// Same row with the app-setup block attached; used when the listing asks
    /// the OAuth ledger for the server's active installation state.
    public func withSetup(_ setup: AgentIntegrationSetup?) -> AgentIntegrationServiceSnapshot {
        AgentIntegrationServiceSnapshot(
            id: id,
            clientId: clientId,
            name: name,
            description: description,
            homepageUrl: homepageUrl,
            agentManifestUrl: agentManifestUrl,
            agentManifestUrlSource: agentManifestUrlSource,
            allowedScopes: allowedScopes,
            whenToUse: whenToUse,
            appType: appType,
            setup: setup
        )
    }

    /// Legacy order: id, clientId, name, description, homepageUrl,
    /// agentManifestUrl, agentManifestUrlSource, allowedScopes, whenToUse,
    /// appType, then the optional setup object.
    public func jsonBody() -> String {
        var body = "{\"id\":\(id.map(jsonString) ?? "null")"
        body += ",\"clientId\":\(clientId.map(jsonString) ?? "null")"
        body += ",\"name\":\(name.map(jsonString) ?? "null")"
        body += ",\"description\":\(description.map(jsonString) ?? "null")"
        body += ",\"homepageUrl\":\(homepageUrl.map(jsonString) ?? "null")"
        body += ",\"agentManifestUrl\":\(agentManifestUrl.map(jsonString) ?? "null")"
        body += ",\"agentManifestUrlSource\":\(agentManifestUrlSource.map(jsonString) ?? "null")"
        body += ",\"allowedScopes\":\(allowedScopes.map { "[\($0.map(jsonString).joined(separator: ","))]" } ?? "null")"
        body += ",\"whenToUse\":\(whenToUse.map(jsonString) ?? "null")"
        body += ",\"appType\":\(appType.map(jsonString) ?? "null")"
        if let setup {
            body += ",\"setup\":\(setup.jsonBody())"
        }
        return body + "}"
    }
}

public struct AgentIntegrationSetup: Codable, Sendable, Equatable, OrderedJSONBody {
    public let status: String
    public let url: String?
    public let description: String?
    public let revision: Int

    public init(status: String, url: String?, description: String?, revision: Int) {
        self.status = status
        self.url = url
        self.description = description
        self.revision = revision
    }

    public func jsonBody() -> String {
        "{\"status\":\(jsonString(status)),\"url\":\(url.map(jsonString) ?? "null"),\"description\":\(description.map(jsonString) ?? "null"),\"revision\":\(revision)}"
    }
}

public struct AgentIntegrationActiveLogin: Codable, Sendable, Equatable, OrderedJSONBody {
    public let clientId: String
    public let agentManifestUrl: String?
    public let agentManifestUrlSource: String?

    public init(clientId: String, agentManifestUrl: String?, agentManifestUrlSource: String?) {
        self.clientId = clientId
        self.agentManifestUrl = agentManifestUrl
        self.agentManifestUrlSource = agentManifestUrlSource
    }

    public func jsonBody() -> String {
        "{\"clientId\":\(jsonString(clientId)),\"agentManifestUrl\":\(agentManifestUrl.map(jsonString) ?? "null"),\"agentManifestUrlSource\":\(agentManifestUrlSource.map(jsonString) ?? "null")}"
    }
}

// MARK: - JSON helpers

private extension JSONValue {
    /// The number view the legacy receive-ack parser got from `NSNumber`.
    var receiveAckNumber: Double? {
        switch self {
        case .integer(let value):
            Double(value)
        case .number(let value):
            value
        case .bool(let value):
            value ? 1 : 0
        case .string, .array, .object, .null:
            nil
        }
    }
}
