import Foundation

// MARK: - Exact published bodies

/// A response body whose published bytes are already the contract.
///
/// `JSONEncoder` on Linux stores keyed containers in a hash container, so it
/// emits the same object with different member order on two calls (and it
/// escapes `/` differently from the archive's `jsonString`). A domain whose
/// legacy body has a fixed upstream member order therefore supplies the exact
/// JSON string; the type still conforms to `Encodable` so it stays a typed DTO
/// and `Sources/RaftHTTPServer/Features/Respond.swift` can project it.
public protocol CanonicalJSONBody: Encodable {
    /// The exact published body (no trailing newline).
    func jsonBody() -> String
}

/// A `DomainError` whose published error object also has a fixed member order.
/// `Respond.swift` maps it through the same exact-bytes reply as
/// `CanonicalJSONBody`, so a two-key or three-key error cannot be reordered.
public protocol CanonicalDomainErrorBody: DomainError {
    /// The exact published error body (no trailing newline).
    var bodyJSON: String { get }
}

/// ISO-8601 with fractional seconds: the archive's `isoString` formatter.
enum RuntimeUsageISO {
    static func string(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}

/// A JSON scalar decoded without assuming its type.
///
/// The legacy diagnostic parsers read `expectedVersion` with `as? NSNumber`
/// (so `true`, `false` and `1.0` are numbers) and `reportGeneratedAt` with
/// `as? String` / `NSNull`. The typed parser has to preserve that distinction
/// instead of turning a wrong type into a decode error with another message.
public enum JSONScalarValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case other
}

extension JSONScalarValue: Decodable {
    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else {
            self = .other
            return
        }
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .other
    }
}

/// Coding key for a closed request object: `allKeys` is how the legacy
/// `object.count == 1` check is expressed without an any-typed dictionary.
struct RuntimeUsageCodingKey: CodingKey {
    var stringValue: String

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int? { nil }

    init?(intValue: Int) { nil }
}

// MARK: - Request bodies

/// `POST /api/servers/:id/machines/:machineId/agents/:agentId/diagnostic/mention-delivery/:messageId/redrive`.
///
/// `expectedVersion` is the only key. A body with another key, a non-integer
/// value or no value does not decode, so the route keeps the legacy parser that
/// publishes `INVALID_REQUEST`. The archive accepts a JSON number with a zero
/// fraction, and also a boolean (it arrives as `NSNumber`); both spellings are
/// preserved by `MentionRedriveBody` below.
public struct MentionRedriveRequestDTO: Codable, Sendable, Equatable {
    public var expectedVersion: Int

    public init(expectedVersion: Int) {
        self.expectedVersion = expectedVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeUsageCodingKey.self)
        guard container.allKeys.count == 1,
              let key = container.allKeys.first,
              key.stringValue == "expectedVersion"
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "expectedVersion must be the only key"
            ))
        }
        expectedVersion = try container.decode(Int.self, forKey: key)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeUsageCodingKey.self)
        try container.encode(expectedVersion, forKey: RuntimeUsageCodingKey("expectedVersion"))
    }

    /// Canonical single-key JSON for the legacy parser.
    public func encodedBody() -> String {
        "{\"expectedVersion\":\(expectedVersion)}"
    }
}

/// The legacy redrive validation shape: exactly one `expectedVersion` key whose
/// value is a JSON number (a boolean counts, as it did for `NSNumber`).
public struct MentionRedriveBody: Decodable, Sendable, Equatable {
    public let expectedVersion: JSONScalarValue

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeUsageCodingKey.self)
        guard container.allKeys.count == 1,
              let key = container.allKeys.first,
              key.stringValue == "expectedVersion"
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "expectedVersion must be the only key"
            ))
        }
        expectedVersion = try container.decode(JSONScalarValue.self, forKey: key)
    }

    /// The archive's `NSNumber` rule: integral, and not negative.
    public var isAcceptedVersion: Bool {
        switch expectedVersion {
        case .bool:
            true
        case .integer(let value):
            value >= 0
        case .number(let value):
            value.rounded() == value && value >= 0
        case .null, .string, .other:
            false
        }
    }
}

/// `POST /api/servers/:id/machines/:machineId/agents/:agentId/feedback/:reportId/transcript`.
/// Only `reportGeneratedAt` is read; every other key is ignored, as before.
public struct TranscriptFeedbackRequestDTO: Codable, Sendable, Equatable {
    public var reportGeneratedAt: String?

    public init(reportGeneratedAt: String? = nil) {
        self.reportGeneratedAt = reportGeneratedAt
    }

    /// Canonical single-key JSON for the legacy parser.
    public func encodedBody() -> String {
        guard let reportGeneratedAt else { return "{}" }
        return "{\"reportGeneratedAt\":\(jsonString(reportGeneratedAt))}"
    }
}

/// The legacy transcript-feedback validation shape. An absent key and an
/// explicit `null` both pass; any other type publishes the timestamp error.
public struct TranscriptFeedbackBody: Decodable, Sendable, Equatable {
    public let reportGeneratedAt: JSONScalarValue?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeUsageCodingKey.self)
        if container.contains(RuntimeUsageCodingKey("reportGeneratedAt")) {
            reportGeneratedAt = try container.decode(
                JSONScalarValue.self,
                forKey: RuntimeUsageCodingKey("reportGeneratedAt")
            )
        } else {
            reportGeneratedAt = nil
        }
    }
}

/// The three outcomes the legacy transcript-feedback body check can publish.
public enum TranscriptFeedbackBodyCheck: Sendable, Equatable {
    case valid
    case malformed
    case invalidTimestamp
}

/// Typed re-implementation of the two raw diagnostic body parses. Both keep the
/// archive's messages and quirks (boolean `expectedVersion`, fractional
/// zero-second numbers, `null` `reportGeneratedAt`).
public enum RuntimeUsageDiagnosticBody {
    public static func mentionRedriveAccepted(_ body: String) -> Bool {
        guard let parsed = try? JSONDecoder().decode(MentionRedriveBody.self, from: Data(body.utf8)) else {
            return false
        }
        return parsed.isAcceptedVersion
    }

    public static func transcriptFeedback(_ body: String) -> TranscriptFeedbackBodyCheck {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .valid }
        guard let parsed = try? JSONDecoder().decode(TranscriptFeedbackBody.self, from: Data(body.utf8)) else {
            return .malformed
        }
        guard let raw = parsed.reportGeneratedAt else { return .valid }
        switch raw {
        case .null:
            return .valid
        case .string(let text):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if fractional.date(from: text) != nil { return .valid }
            if ISO8601DateFormatter().date(from: text) != nil { return .valid }
            return .invalidTimestamp
        case .bool, .integer, .number, .other:
            return .invalidTimestamp
        }
    }
}

// MARK: - Responses

/// `GET /api/servers/:id/usage`.
public struct ServerUsageDTO: Codable, Sendable, Equatable, CanonicalJSONBody {
    public var agents: Int
    public var machines: Int
    public var channels: Int

    public init(agents: Int, machines: Int, channels: Int) {
        self.agents = agents
        self.machines = machines
        self.channels = channels
    }

    public func jsonBody() -> String {
        "{\"agents\":\(agents),\"machines\":\(machines),\"channels\":\(channels)}"
    }
}

/// One daemon row inside the machine-offline notification payload.
public struct SystemNotificationMachineDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    func jsonBody() -> String {
        "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name))}"
    }
}

/// Localized-copy parameters of the machine-offline notification.
public struct SystemNotificationCopyParamsDTO: Codable, Sendable, Equatable {
    public var machineNames: String
    public var machineCount: Int
    public var activeAgentCount: Int

    public init(machineNames: String, machineCount: Int, activeAgentCount: Int) {
        self.machineNames = machineNames
        self.machineCount = machineCount
        self.activeAgentCount = activeAgentCount
    }

    func jsonBody() -> String {
        "{\"machineNames\":\(jsonString(machineNames)),\"machineCount\":\(machineCount),\"activeAgentCount\":\(activeAgentCount),\"targetDaemonVersion\":null}"
    }
}

/// Copy keys for the machine-offline notification.
public struct SystemNotificationCopyDTO: Codable, Sendable, Equatable {
    public var titleKey: String
    public var bodyKey: String
    public var actionLabelKey: String
    public var params: SystemNotificationCopyParamsDTO

    public init(
        titleKey: String,
        bodyKey: String,
        actionLabelKey: String,
        params: SystemNotificationCopyParamsDTO
    ) {
        self.titleKey = titleKey
        self.bodyKey = bodyKey
        self.actionLabelKey = actionLabelKey
        self.params = params
    }

    func jsonBody() -> String {
        "{\"titleKey\":\(jsonString(titleKey)),\"bodyKey\":\(jsonString(bodyKey)),\"actionLabelKey\":\(jsonString(actionLabelKey)),\"params\":\(params.jsonBody())}"
    }
}

/// The target of the machine-offline notification.
public struct SystemNotificationActionDTO: Codable, Sendable, Equatable {
    public var label: String
    public var targetType: String
    public var targetId: String

    public init(label: String, targetType: String, targetId: String) {
        self.label = label
        self.targetType = targetType
        self.targetId = targetId
    }

    func jsonBody() -> String {
        "{\"label\":\(jsonString(label)),\"targetType\":\(jsonString(targetType)),\"targetId\":\(jsonString(targetId))}"
    }
}

/// The evaluation block embedded in the machine-offline payload.
public struct SystemNotificationEvaluationDTO: Codable, Sendable, Equatable {
    public var clock: String
    public var evaluatedAt: Date
    public var offlineAfterMs: Int
    public var statusAuthority: String
    public var runKind: String
    public var versionAuthority: String

    public init(
        clock: String,
        evaluatedAt: Date,
        offlineAfterMs: Int,
        statusAuthority: String,
        runKind: String,
        versionAuthority: String
    ) {
        self.clock = clock
        self.evaluatedAt = evaluatedAt
        self.offlineAfterMs = offlineAfterMs
        self.statusAuthority = statusAuthority
        self.runKind = runKind
        self.versionAuthority = versionAuthority
    }

    func jsonBody() -> String {
        "{\"clock\":\(jsonString(clock)),\"evaluatedAt\":\(jsonString(RuntimeUsageISO.string(evaluatedAt))),\"offlineAfterMs\":\(offlineAfterMs),\"statusAuthority\":\(jsonString(statusAuthority)),\"runKind\":\(jsonString(runKind)),\"versionAuthority\":\(jsonString(versionAuthority))}"
    }
}

/// The machine-offline payload.
public struct SystemNotificationPayloadDTO: Codable, Sendable, Equatable {
    public var machines: [SystemNotificationMachineDTO]
    public var activeAgentCount: Int
    public var evaluation: SystemNotificationEvaluationDTO

    public init(
        machines: [SystemNotificationMachineDTO],
        activeAgentCount: Int,
        evaluation: SystemNotificationEvaluationDTO
    ) {
        self.machines = machines
        self.activeAgentCount = activeAgentCount
        self.evaluation = evaluation
    }

    func jsonBody() -> String {
        let rows = machines.map { $0.jsonBody() }.joined(separator: ",")
        return "{\"machines\":[\(rows)],\"activeAgentCount\":\(activeAgentCount),\"targetDaemonVersion\":null,\"evaluation\":\(evaluation.jsonBody())}"
    }
}

/// One `machine.offline` notification.
public struct SystemNotificationDTO: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var schemaVersion: Int
    public var state: String
    public var kind: String
    public var title: String
    public var body: String
    public var copy: SystemNotificationCopyDTO
    public var action: SystemNotificationActionDTO
    public var payload: SystemNotificationPayloadDTO

    public init(
        id: String,
        type: String,
        schemaVersion: Int,
        state: String,
        kind: String,
        title: String,
        body: String,
        copy: SystemNotificationCopyDTO,
        action: SystemNotificationActionDTO,
        payload: SystemNotificationPayloadDTO
    ) {
        self.id = id
        self.type = type
        self.schemaVersion = schemaVersion
        self.state = state
        self.kind = kind
        self.title = title
        self.body = body
        self.copy = copy
        self.action = action
        self.payload = payload
    }

    func jsonBody() -> String {
        "{\"id\":\(jsonString(id)),\"type\":\(jsonString(type)),\"schemaVersion\":\(schemaVersion),\"state\":\(jsonString(state)),\"kind\":\(jsonString(kind)),\"title\":\(jsonString(title)),\"body\":\(jsonString(body)),\"copy\":\(copy.jsonBody()),\"action\":\(action.jsonBody()),\"payload\":\(payload.jsonBody())}"
    }
}

/// Client read/dismiss policy of the system-notification feed.
public struct SystemNotificationsClientStateDTO: Codable, Sendable, Equatable {
    public var read: String
    public var dismiss: String

    public init(read: String, dismiss: String) {
        self.read = read
        self.dismiss = dismiss
    }

    func jsonBody() -> String {
        "{\"read\":\(jsonString(read)),\"dismiss\":\(jsonString(dismiss))}"
    }
}

/// `GET /api/servers/:id/system-notifications`.
public struct SystemNotificationsDTO: Codable, Sendable, Equatable, CanonicalJSONBody {
    public var contractVersion: String
    public var generatedAt: Date
    public var snapshotMode: String
    public var clientState: SystemNotificationsClientStateDTO
    public var notifications: [SystemNotificationDTO]

    public init(
        contractVersion: String,
        generatedAt: Date,
        snapshotMode: String,
        clientState: SystemNotificationsClientStateDTO,
        notifications: [SystemNotificationDTO]
    ) {
        self.contractVersion = contractVersion
        self.generatedAt = generatedAt
        self.snapshotMode = snapshotMode
        self.clientState = clientState
        self.notifications = notifications
    }

    public func jsonBody() -> String {
        let rows = notifications.map { $0.jsonBody() }.joined(separator: ",")
        return "{\"contractVersion\":\(jsonString(contractVersion)),\"generatedAt\":\(jsonString(RuntimeUsageISO.string(generatedAt))),\"snapshotMode\":\(jsonString(snapshotMode)),\"clientState\":\(clientState.jsonBody()),\"notifications\":[\(rows)]}"
    }
}

/// The machine projection of one system-attention incident.
public struct SystemAttentionMachineDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    func jsonBody() -> String {
        "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name))}"
    }
}

/// One `usage_limit_reached` system-attention notification.
public struct SystemAttentionNotificationDTO: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var severity: String
    public var state: String
    public var activatedAt: Date
    public var lastObservedAt: Date
    public var seenAt: Date?
    public var machine: SystemAttentionMachineDTO
    public var provider: String
    public var windowKey: String
    public var resetsAt: Date?
    public var affectedAgentIds: [String]

    public init(
        id: String,
        kind: String,
        severity: String,
        state: String,
        activatedAt: Date,
        lastObservedAt: Date,
        seenAt: Date?,
        machine: SystemAttentionMachineDTO,
        provider: String,
        windowKey: String,
        resetsAt: Date?,
        affectedAgentIds: [String]
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.state = state
        self.activatedAt = activatedAt
        self.lastObservedAt = lastObservedAt
        self.seenAt = seenAt
        self.machine = machine
        self.provider = provider
        self.windowKey = windowKey
        self.resetsAt = resetsAt
        self.affectedAgentIds = affectedAgentIds
    }

    func jsonBody() -> String {
        let agents = affectedAgentIds.map(jsonString).joined(separator: ",")
        let seen = seenAt.map { jsonString(RuntimeUsageISO.string($0)) } ?? "null"
        let resets = resetsAt.map { jsonString(RuntimeUsageISO.string($0)) } ?? "null"
        return "{\"id\":\(jsonString(id)),\"kind\":\(jsonString(kind)),\"severity\":\(jsonString(severity)),\"state\":\(jsonString(state)),\"activatedAt\":\(jsonString(RuntimeUsageISO.string(activatedAt))),\"lastObservedAt\":\(jsonString(RuntimeUsageISO.string(lastObservedAt))),\"seenAt\":\(seen),\"machine\":\(machine.jsonBody()),\"provider\":\(jsonString(provider)),\"windowKey\":\(jsonString(windowKey)),\"resetsAt\":\(resets),\"affectedAgentIds\":[\(agents)]}"
    }
}

/// `GET /api/servers/:id/system-notifications-v2`.
public struct SystemAttentionDTO: Codable, Sendable, Equatable, CanonicalJSONBody {
    public var contractVersion: String
    public var generatedAt: Date
    public var snapshotMode: String
    public var unseenCount: Int
    public var notifications: [SystemAttentionNotificationDTO]

    public init(
        contractVersion: String,
        generatedAt: Date,
        snapshotMode: String,
        unseenCount: Int,
        notifications: [SystemAttentionNotificationDTO]
    ) {
        self.contractVersion = contractVersion
        self.generatedAt = generatedAt
        self.snapshotMode = snapshotMode
        self.unseenCount = unseenCount
        self.notifications = notifications
    }

    public func jsonBody() -> String {
        let rows = notifications.map { $0.jsonBody() }.joined(separator: ",")
        return "{\"contractVersion\":\(jsonString(contractVersion)),\"generatedAt\":\(jsonString(RuntimeUsageISO.string(generatedAt))),\"snapshotMode\":\(jsonString(snapshotMode)),\"unseenCount\":\(unseenCount),\"notifications\":[\(rows)]}"
    }
}

/// The single-key `{"status": …}` diagnostic body.
public struct RuntimeStatusDTO: Codable, Sendable, Equatable, CanonicalJSONBody {
    public var status: String

    public init(status: String) {
        self.status = status
    }

    public func jsonBody() -> String {
        "{\"status\":\(jsonString(status))}"
    }
}

/// `GET …/diagnostic/session-transcript`. The diagnostic read model is empty in
/// this build; the published session id is always null.
public struct SessionTranscriptDTO: Codable, Sendable, Equatable, CanonicalJSONBody {
    public var sessionId: String?
    public var transcript: [String]

    public init(sessionId: String? = nil, transcript: [String] = []) {
        self.sessionId = sessionId
        self.transcript = transcript
    }

    public func jsonBody() -> String {
        "{\"sessionId\":null,\"transcript\":[]}"
    }
}

/// `POST …/feedback/:reportId/transcript` acceptance.
public struct TranscriptFeedbackAcceptedDTO: Codable, Sendable, Equatable, CanonicalJSONBody {
    public var accepted: Bool
    public var feedbackReportId: String
    public var agentId: String

    public init(accepted: Bool = true, feedbackReportId: String, agentId: String) {
        self.accepted = accepted
        self.feedbackReportId = feedbackReportId
        self.agentId = agentId
    }

    public func jsonBody() -> String {
        "{\"accepted\":true,\"feedbackReportId\":\(jsonString(feedbackReportId)),\"agentId\":\(jsonString(agentId))}"
    }
}

/// `POST /api/share-artifacts/message-selection`.
public struct ShareArtifactDTO: Codable, Sendable, Equatable, CanonicalJSONBody {
    public var id: String
    public var url: String
    public var imageUrl: String

    public init(id: String, url: String, imageUrl: String) {
        self.id = id
        self.url = url
        self.imageUrl = imageUrl
    }

    public func jsonBody() -> String {
        "{\"id\":\(jsonString(id)),\"url\":\(jsonString(url)),\"imageUrl\":\(jsonString(imageUrl))}"
    }
}

/// The two public URLs a share artifact publishes.
public enum ShareArtifactURL {
    public static func share(id: String, shareBase: String) -> String {
        let base = shareBase.hasSuffix("/") ? String(shareBase.dropLast()) : shareBase
        return base + "/" + id
    }

    public static func image(id: String, serverId: String, serverBase: String, cdnBase: String?) -> String {
        if let cdnBase {
            let base = cdnBase.hasSuffix("/") ? String(cdnBase.dropLast()) : cdnBase
            return "\(base)/\(serverId)/share-artifacts/\(id).png"
        }
        let base = serverBase.hasSuffix("/") ? String(serverBase.dropLast()) : serverBase
        return base + "/share/" + id + ".png"
    }
}
