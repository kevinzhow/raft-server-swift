import Foundation
import RaftShared

// MARK: - Requests

/// `POST /internal/agent/:agentId/send` request body.
///
/// The pinned route validates the whole body with `legacyAgentSendBodySchema`
/// before the handler runs: every member is optional, unknown members pass
/// through, and a wrong member type is one `issues` entry rather than a
/// decode failure. `issues` is empty exactly when the body matches that
/// schema; the route turns a non-empty list into the published
/// `legacy_agent_send_contract_invalid` 400 before any side effect.
public struct AgentSendRequest: Sendable, Equatable {
    /// One zod issue: a dotted path and a human-readable reason.
    ///
    /// The shared `AuthRequestIssue` is the only issue shape this repo
    /// publishes for zod request bodies; the nested name stays for callers.
    public typealias Issue = AuthRequestIssue

    public var target: String?
    public var channel: String?
    public var dmTo: String?
    public var content: String?
    public var attachmentIds: [String]
    public var idempotencyKey: String?
    public var reconcileOnly: Bool
    /// The deprecated `continue` request member.
    public var continueFlag: Bool
    public var sendDraft: Bool
    public var continueAnyway: Bool
    public var draftReholdCount: Double?
    public var draftReplacedExisting: Bool
    /// Kept as the JSON number the schema accepts; the handler floors it.
    public var seenUpToSeq: Double?
    public var seenExactSeqs: [Int]
    public var freshnessContextMode: String?
    public var issues: [Issue]

    public init(
        target: String? = nil,
        channel: String? = nil,
        dmTo: String? = nil,
        content: String? = nil,
        attachmentIds: [String] = [],
        idempotencyKey: String? = nil,
        reconcileOnly: Bool = false,
        continueFlag: Bool = false,
        sendDraft: Bool = false,
        continueAnyway: Bool = false,
        draftReholdCount: Double? = nil,
        draftReplacedExisting: Bool = false,
        seenUpToSeq: Double? = nil,
        seenExactSeqs: [Int] = [],
        freshnessContextMode: String? = nil,
        issues: [Issue] = []
    ) {
        self.target = target
        self.channel = channel
        self.dmTo = dmTo
        self.content = content
        self.attachmentIds = attachmentIds
        self.idempotencyKey = idempotencyKey
        self.reconcileOnly = reconcileOnly
        self.continueFlag = continueFlag
        self.sendDraft = sendDraft
        self.continueAnyway = continueAnyway
        self.draftReholdCount = draftReholdCount
        self.draftReplacedExisting = draftReplacedExisting
        self.seenUpToSeq = seenUpToSeq
        self.seenExactSeqs = seenExactSeqs
        self.freshnessContextMode = freshnessContextMode
        self.issues = issues
    }

    /// The effective target: `target || channel || dm:@<dm_to>` (`||` skips an
    /// empty string, exactly like the pinned route).
    public var effectiveTarget: String? {
        if let target, !target.isEmpty { return target }
        if let channel, !channel.isEmpty { return channel }
        if let dmTo, !dmTo.isEmpty {
            var peer = dmTo
            if peer.hasPrefix("@") { peer = String(peer.dropFirst()) }
            return "dm:@\(peer)"
        }
        return nil
    }
}

extension AgentSendRequest: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.parse(try container.decode(JSONValue.self))
    }

    /// Pinned `legacyAgentSendBodySchema` over `req.body ?? {}`.
    ///
    /// The schema is `agentApiSendBodySchema.extend({channel, dm_to})` with
    /// `.passthrough()`. zod reports issues in shape order, not input order,
    /// and an array-level `.max` issue follows every element issue. This
    /// builder walks the shape in that same order; a JSON `null` root is the
    /// empty object, exactly like `req.body ?? {}`.
    static func parse(_ raw: JSONValue?) -> AgentSendRequest {
        let (fields, rootIssue) = AuthRequestSchema.objectFields(raw)
        if let rootIssue {
            return AgentSendRequest(issues: [rootIssue])
        }
        return validate(fields)
    }

    private static func validate(_ fields: [String: JSONValue]) -> AgentSendRequest {
        var issues: [AuthRequestIssue] = []
        var request = AgentSendRequest()

        let target = AuthRequestSchema.optionalString(fields["target"], path: "target")
        issues += target.issues
        request.target = target.value

        let content = AuthRequestSchema.optionalString(fields["content"], path: "content")
        issues += content.issues
        request.content = content.value

        let attachmentIds = AuthRequestSchema.array(fields["attachmentIds"], path: "attachmentIds")
        issues += attachmentIds.issues
        if let entries = attachmentIds.items {
            var ids: [String] = []
            for (index, entry) in entries.enumerated() {
                let element = AuthRequestSchema.string(
                    entry,
                    path: "attachmentIds.\(index)",
                    min: 1,
                    trim: true
                )
                issues += element.issues
                if let id = element.value { ids.append(id) }
            }
            request.attachmentIds = ids
        }

        let idempotencyKey = AuthRequestSchema.optionalString(
            fields["idempotencyKey"], path: "idempotencyKey", trim: true
        )
        issues += idempotencyKey.issues
        request.idempotencyKey = idempotencyKey.value

        let reconcileOnly = AuthRequestSchema.optionalBoolean(fields["reconcileOnly"], path: "reconcileOnly")
        issues += reconcileOnly.issues
        request.reconcileOnly = reconcileOnly.value ?? false

        let continueFlag = AuthRequestSchema.optionalBoolean(fields["continue"], path: "continue")
        issues += continueFlag.issues
        request.continueFlag = continueFlag.value ?? false

        let sendDraft = AuthRequestSchema.optionalBoolean(fields["sendDraft"], path: "sendDraft")
        issues += sendDraft.issues
        request.sendDraft = sendDraft.value ?? false

        let continueAnyway = AuthRequestSchema.optionalBoolean(fields["continueAnyway"], path: "continueAnyway")
        issues += continueAnyway.issues
        request.continueAnyway = continueAnyway.value ?? false

        let draftReholdCount = AuthRequestSchema.optionalNumber(
            fields["draftReholdCount"], path: "draftReholdCount"
        )
        issues += draftReholdCount.issues
        request.draftReholdCount = draftReholdCount.value

        let draftReplacedExisting = AuthRequestSchema.optionalBoolean(
            fields["draftReplacedExisting"], path: "draftReplacedExisting"
        )
        issues += draftReplacedExisting.issues
        request.draftReplacedExisting = draftReplacedExisting.value ?? false

        let seenUpToSeq = AuthRequestSchema.optionalNumber(fields["seenUpToSeq"], path: "seenUpToSeq")
        issues += seenUpToSeq.issues
        request.seenUpToSeq = seenUpToSeq.value

        let seenExactSeqs = AuthRequestSchema.array(fields["seenExactSeqs"], path: "seenExactSeqs")
        issues += seenExactSeqs.issues
        if let entries = seenExactSeqs.items {
            var seqs: [Int] = []
            for (index, entry) in entries.enumerated() {
                let element = AuthRequestSchema.integer(
                    entry,
                    path: "seenExactSeqs.\(index)",
                    positive: true
                )
                issues += element.issues
                if let seq = element.value { seqs.append(seq) }
            }
            if entries.count > 2500 {
                issues.append(AuthRequestIssue(
                    path: "seenExactSeqs",
                    message: "Too big: expected array to have <=2500 items"
                ))
            }
            request.seenExactSeqs = seqs
        }

        if let value = fields["seenCards"] {
            if case .object(let cards) = value {
                for key in ["channel", "peer"] {
                    let card = AuthRequestSchema.nullableString(
                        cards[key],
                        path: "seenCards.\(key)",
                        min: 1
                    )
                    issues += card.issues
                }
            } else {
                issues.append(AuthRequestIssue(
                    path: "seenCards",
                    message: "Invalid input: expected object, received \(value.zodKind)"
                ))
            }
        }

        let freshnessContextMode = AuthRequestSchema.enumValue(
            fields["freshnessContextMode"],
            path: "freshnessContextMode",
            options: ["inline", "withheld"]
        )
        issues += freshnessContextMode.issues
        request.freshnessContextMode = freshnessContextMode.value

        let channel = AuthRequestSchema.optionalString(fields["channel"], path: "channel")
        issues += channel.issues
        request.channel = channel.value

        let dmTo = AuthRequestSchema.optionalString(fields["dm_to"], path: "dm_to")
        issues += dmTo.issues
        request.dmTo = dmTo.value

        request.issues = issues
        return request
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
        return DateText.isoDate(value)
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

/// `POST /internal/agent/:agentId/send` committed body.
///
/// Legacy order: `ok`, `state`, `messageId`, `messageSeq`, then the optional
/// sender-side mention fields. A held response never carries them.
public struct AgentSendResponse: JSONBodyConvertible, Sendable, Equatable {
    public let messageId: String
    public let messageSeq: Int

    public init(messageId: String, messageSeq: Int) {
        self.messageId = messageId
        self.messageSeq = messageSeq
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("state", "sent")
        body.append("messageId", messageId)
        body.append("messageSeq", messageSeq)
        return body.json
    }
}

/// `POST /internal/agent/:agentId/send` freshness hold.
///
/// The `apmHeldFreshness` inline envelope plus the legacy-only extras. Member
/// order is the pinned spread order; `continueAnywaySuggested` and
/// `seenUpToMessageId` are always present (false / JSON null), while
/// `firstShownSeq` is only present when a context window was shown.
public struct LegacyAgentSendHeldResponse: JSONBodyConvertible, Sendable, Equatable {
    public var producerFactId: String
    /// Envelopes already rendered by the action-card prepare service.
    public var heldMessages: [String]
    public var newMessageCount: Int
    public var shownMessageCount: Int
    public var omittedMessageCount: Int
    public var seenUpToSeq: Int
    public var seenUpToMessageId: String?
    public var formalMentionCount: Int
    public var continueAnywaySuggested: Bool

    public init(
        producerFactId: String,
        heldMessages: [String],
        newMessageCount: Int,
        shownMessageCount: Int,
        omittedMessageCount: Int,
        seenUpToSeq: Int,
        seenUpToMessageId: String?,
        formalMentionCount: Int,
        continueAnywaySuggested: Bool
    ) {
        self.producerFactId = producerFactId
        self.heldMessages = heldMessages
        self.newMessageCount = newMessageCount
        self.shownMessageCount = shownMessageCount
        self.omittedMessageCount = omittedMessageCount
        self.seenUpToSeq = seenUpToSeq
        self.seenUpToMessageId = seenUpToMessageId
        self.formalMentionCount = formalMentionCount
        self.continueAnywaySuggested = continueAnywaySuggested
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("state", "held")
        body.append("outcome", "held")
        body.append("subtype", "freshness")
        body.append("reason", "newer_messages_available")
        body.append("decision", "syncing_hold")
        body.append("producerFactId", producerFactId)
        body.append("available_actions", .array([
            .string("check_messages"),
            .string("send_draft"),
            .string("send_anyway"),
        ]))
        body.append("heldMessages", .array(heldMessages.map(OrderedJSON.raw)))
        body.append("newMessageCount", newMessageCount)
        body.append("shownMessageCount", shownMessageCount)
        body.append("omittedMessageCount", omittedMessageCount)
        body.append("seenUpToSeq", seenUpToSeq)
        body.append("mentionAnnotation", .object([
            OrderedJSONField("formalMentionCount", formalMentionCount),
        ]))
        body.append("continueAnywaySuggested", continueAnywaySuggested)
        body.append("seenUpToMessageId", optional: seenUpToMessageId)
        return body.json
    }
}

/// `POST /internal/agent/:agentId/runtime-profile/migration-done` body.
///
/// The route is a deprecated acknowledgement: `noop` is present only when the
/// request carried no `migrationKey`. Legacy order is `ok`, `deprecated`,
/// optional `noop`, then `message`.
public struct AgentRuntimeProfileMigrationResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public static let message = "Runtime Profile migration acknowledgments are deprecated; runtime changes reset the session automatically."

    public let noop: Bool

    public init(noop: Bool) {
        self.noop = noop
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("deprecated", true)
        if noop { body.append("noop", "no pending migration") }
        body.append("message", Self.message)
        return body.json
    }
}

/// `POST /internal/agent-api/activity` body.
///
/// `ignoredFields` appears only for the v1 schema and only when it is non-empty,
/// always after `droppedCount` and sorted by name.
public struct AgentActivityIngestResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
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

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("acceptedCount", acceptedCount)
        body.append("rejectedCount", rejectedCount)
        body.append("droppedCount", droppedCount)
        if let ignoredFields, !ignoredFields.isEmpty {
            body.append("ignoredFields", .array(ignoredFields.map(OrderedJSON.string)))
        }
        return body.json
    }
}

/// `GET /internal/agent-api/threads` body.
public struct AgentThreadListResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public let threads: [AgentThreadListEntry]

    public init(threads: [AgentThreadListEntry]) {
        self.threads = threads
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("threads", .array(threads.map(\.jsonBody)))])
    }
}

public struct AgentThreadListEntry: Codable, Sendable, Equatable, JSONBodyConvertible {
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
    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("target", target),
            OrderedJSONField("threadChannelId", threadChannelId),
            OrderedJSONField("parentChannelRef", parentChannelRef),
            OrderedJSONField("parentMessageId", parentMessageId),
            OrderedJSONField("parentMessageShortId", parentMessageShortId),
            OrderedJSONField("followedAt", followedAt),
            OrderedJSONField("reason", reason),
            OrderedJSONField("doneAt", optional: doneAt),
        ])
    }
}

/// `GET /internal/agent-api/integrations` body.
public struct AgentIntegrationListResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public let services: [AgentIntegrationServiceSnapshot]
    public let activeLogins: [AgentIntegrationActiveLogin]

    public init(
        services: [AgentIntegrationServiceSnapshot],
        activeLogins: [AgentIntegrationActiveLogin]
    ) {
        self.services = services
        self.activeLogins = activeLogins
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("services", .array(services.map(\.jsonBody))),
            OrderedJSONField("activeLogins", .array(activeLogins.map(\.jsonBody))),
        ])
    }
}

/// One integration service row. The projection in
/// `Sources/RaftHTTP/Support/AgentIntegrationProjection.swift` maps the
/// OAuth ledger's untyped client row into this shape, so the service and this
/// DTO never touch an untyped JSON dictionary.
public struct AgentIntegrationServiceSnapshot: Codable, Sendable, Equatable, JSONBodyConvertible {
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
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", optional: id)
        body.append("clientId", optional: clientId)
        body.append("name", optional: name)
        body.append("description", optional: description)
        body.append("homepageUrl", optional: homepageUrl)
        body.append("agentManifestUrl", optional: agentManifestUrl)
        body.append("agentManifestUrlSource", optional: agentManifestUrlSource)
        body.append("allowedScopes", allowedScopesBody)
        body.append("whenToUse", optional: whenToUse)
        body.append("appType", optional: appType)
        if let setup { body.append("setup", setup.jsonBody) }
        return body.json
    }

    /// A nullable scope array: `null` when absent, otherwise its strings in
    /// the ledger's order.
    private var allowedScopesBody: OrderedJSON {
        guard let allowedScopes else { return .null }
        return .array(allowedScopes.map(OrderedJSON.string))
    }
}

public struct AgentIntegrationSetup: Codable, Sendable, Equatable, JSONBodyConvertible {
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

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("status", status),
            OrderedJSONField("url", optional: url),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("revision", revision),
        ])
    }
}

public struct AgentIntegrationActiveLogin: Codable, Sendable, Equatable, JSONBodyConvertible {
    public let clientId: String
    public let agentManifestUrl: String?
    public let agentManifestUrlSource: String?

    public init(clientId: String, agentManifestUrl: String?, agentManifestUrlSource: String?) {
        self.clientId = clientId
        self.agentManifestUrl = agentManifestUrl
        self.agentManifestUrlSource = agentManifestUrlSource
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("agentManifestUrl", optional: agentManifestUrl),
            OrderedJSONField("agentManifestUrlSource", optional: agentManifestUrlSource),
        ])
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
