import Foundation

// MARK: - Requests

/// `POST /api/agents/:id/migration/cancel` request body.
///
/// The retired handler parsed the raw body and read three keys. This decoder
/// keeps that tolerance byte-for-byte instead of failing the typed route:
///
/// - a root that is not a JSON object reads as an empty request;
/// - `migrationId` is tracked by *presence* (a `null` counts), because the
///   route answers `MIGRATION_REF_INVALID` for it before anything else;
/// - `migrationRef` is a string or absent, so a number or `null` reads as
///   absent and the service publishes the same `MIGRATION_REF_INVALID`;
/// - `expectedRevision` accepts any JSON number for which
///   `rounded() == value`; the legacy `as? NSNumber` read a JSON boolean as
///   1/0 too, so `true`/`false` stay accepted;
/// - a non-string `reason` reads as absent and the service falls back to
///   `user_canceled`.
public struct AgentMigrationCancelRequest: Codable, Sendable, Equatable {
    public var migrationRef: String?
    /// The raw JSON number (booleans map to 1/0). The service applies the
    /// legacy integrality and `>= 1` check, so a fractional value publishes
    /// `MIGRATION_REVISION_INVALID` rather than a decode failure.
    public var expectedRevision: Double?
    public var reason: String?
    /// `true` when the body carried the retired `migrationId` key.
    public var includesMigrationID: Bool

    private enum CodingKeys: String, CodingKey {
        case migrationRef
        case expectedRevision
        case reason
    }

    public init() {
        migrationRef = nil
        expectedRevision = nil
        reason = nil
        includesMigrationID = false
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        // A non-object root read as an empty object in the retired parser, so
        // the request stays empty instead of rejecting the body.
        guard let dynamic = try? decoder.container(keyedBy: AgentMigrationJSONKey.self) else { return }
        let keys = Set(dynamic.allKeys.map(\.stringValue))
        includesMigrationID = keys.contains("migrationId")

        let refKey = AgentMigrationJSONKey(stringValue: "migrationRef")!
        migrationRef = (try? dynamic.decodeIfPresent(String.self, forKey: refKey)) ?? nil

        let revisionKey = AgentMigrationJSONKey(stringValue: "expectedRevision")!
        if let boolean = try? dynamic.decode(Bool.self, forKey: revisionKey) {
            expectedRevision = boolean ? 1 : 0
        } else {
            expectedRevision = (try? dynamic.decodeIfPresent(Double.self, forKey: revisionKey)) ?? nil
        }

        let reasonKey = AgentMigrationJSONKey(stringValue: "reason")!
        reason = (try? dynamic.decodeIfPresent(String.self, forKey: reasonKey)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(migrationRef, forKey: .migrationRef)
        try container.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

/// One dynamic JSON object key, used to read keys the published shape does not
/// name (the request records that `migrationId` was present).
private struct AgentMigrationJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

// MARK: - Migration status

/// The `migration` member of `GET /api/agents/:id/migration` and of the cancel
/// reply. A hosted row and a Computer row publish different key sets, so the
/// two projections stay separate types.
public enum AgentMigrationStatusPayload: Codable, Sendable, Equatable {
    case machine(MachineAgentMigrationStatus)
    case hosted(HostedAgentMigrationStatus)

    var jsonBody: OrderedJSON {
        switch self {
        case .machine(let status): status.jsonBody
        case .hosted(let status): status.jsonBody
        }
    }
}

/// `{"migration": …}` for the status and cancel operations. `null` is the
/// three published bytes when the agent has no migration row.
public struct AgentMigrationStatusResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var migration: AgentMigrationStatusPayload?

    init(migration: AgentMigrationStatusPayload? = nil) {
        self.migration = migration
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("migration", migration?.jsonBody ?? .null)])
    }
}

/// The Computer migration projection (`targetKind: "computer"`).
public struct MachineAgentMigrationStatus: Codable, Sendable, Equatable {
    public var migrationRef: String
    public var agentId: String
    public var state: String
    public var revision: Int
    public var sourceMachineId: String
    public var targetMachineId: String
    public var provider: String
    public var failureReason: String?
    public var autoStartFailureStage: String?
    public var autoStartFailureCode: String?
    public var transportErrorCode: String?
    public var transportErrorMessage: String?
    public var transportLostAt: String?
    public var transportTeardownAt: String?
    public var flippedAt: String?
    public var arrivedAt: String?
    public var completedAt: String?
    public var canceledAt: String?
    public var cancelReason: String?
    public var cancelDispatchAttempts: Int
    public var cancelLastDispatchAt: String?
    public var cancelErrorCode: String?

    init(_ record: MachineMigrationRecord) {
        migrationRef = record.supportRef
        agentId = record.agentId
        state = record.state
        revision = record.revision
        sourceMachineId = record.sourceMachineId
        targetMachineId = record.targetMachineId
        provider = record.transportProvider
        failureReason = record.failureReason
        autoStartFailureStage = record.autoStartFailureStage
        autoStartFailureCode = record.autoStartFailureCode
        transportErrorCode = record.transportErrorCode
        transportErrorMessage = record.transportErrorMessage
        transportLostAt = AgentMigrationTimestamps.string(record.transportLostAt)
        transportTeardownAt = AgentMigrationTimestamps.string(record.transportTeardownAt)
        flippedAt = AgentMigrationTimestamps.string(record.flippedAt)
        arrivedAt = AgentMigrationTimestamps.string(record.arrivedAt)
        completedAt = AgentMigrationTimestamps.string(record.completedAt)
        canceledAt = AgentMigrationTimestamps.string(record.canceledAt)
        cancelReason = record.cancelReason
        cancelDispatchAttempts = record.cancelDispatchAttempts
        cancelLastDispatchAt = AgentMigrationTimestamps.string(record.cancelLastDispatchAt)
        cancelErrorCode = record.cancelErrorCode
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("migrationRef", .string(migrationRef)),
            OrderedJSONField("agentId", .string(agentId)),
            OrderedJSONField("state", .string(state)),
            OrderedJSONField("revision", .int(revision)),
            OrderedJSONField("sourceMachineId", .string(sourceMachineId)),
            OrderedJSONField("targetKind", .string("computer")),
            OrderedJSONField("targetMachineId", .string(targetMachineId)),
            OrderedJSONField("provider", .string(provider)),
            OrderedJSONField("failureReason", .stringOrNull(failureReason)),
            OrderedJSONField("autoStartFailureStage", .stringOrNull(autoStartFailureStage)),
            OrderedJSONField("autoStartFailureCode", .stringOrNull(autoStartFailureCode)),
            OrderedJSONField("abortReason", .null),
            OrderedJSONField("transportErrorCode", .stringOrNull(transportErrorCode)),
            OrderedJSONField("transportErrorMessage", .stringOrNull(transportErrorMessage)),
            OrderedJSONField("transportLostAt", .stringOrNull(transportLostAt)),
            OrderedJSONField("transportTeardownAt", .stringOrNull(transportTeardownAt)),
            OrderedJSONField("readyAt", .null),
            OrderedJSONField("flippedAt", .stringOrNull(flippedAt)),
            OrderedJSONField("arrivedAt", .stringOrNull(arrivedAt)),
            OrderedJSONField("completedAt", .stringOrNull(completedAt)),
            OrderedJSONField("abortedAt", .null),
            OrderedJSONField("canceledAt", .stringOrNull(canceledAt)),
            OrderedJSONField("cancelReason", .stringOrNull(cancelReason)),
            OrderedJSONField("cancelNeedsAttention", .bool(false)),
            OrderedJSONField("cancelDispatchAttempts", .int(cancelDispatchAttempts)),
            OrderedJSONField("cancelLastDispatchAt", .stringOrNull(cancelLastDispatchAt)),
            OrderedJSONField("cancelErrorCode", .stringOrNull(cancelErrorCode)),
            OrderedJSONField("cancelErrorMessage", .null),
        ])
    }
}

/// The hosted migration projection (`targetKind: "hosted"`), the same shape the
/// hosted-migration routes publish for their own rows.
public struct HostedAgentMigrationStatus: Codable, Sendable, Equatable {
    public var migrationRef: String
    public var agentId: String
    public var state: String
    public var revision: Int
    public var sourceMachineId: String?
    public var canceledAt: String?
    public var cancelReason: String?
    public var cancelDispatchAttempts: Int
    public var cancelLastDispatchAt: String?
    public var cancelErrorCode: String?

    init(_ record: HostedMigrationRecord) {
        migrationRef = record.supportRef
        agentId = record.agentId
        state = record.state
        revision = record.revision
        sourceMachineId = record.sourceMachineId
        canceledAt = AgentMigrationTimestamps.string(record.canceledAt)
        cancelReason = record.cancelReason
        cancelDispatchAttempts = record.cancelDispatchAttempts
        cancelLastDispatchAt = AgentMigrationTimestamps.string(record.cancelLastDispatchAt)
        cancelErrorCode = record.cancelErrorCode
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("migrationRef", .string(migrationRef)),
            OrderedJSONField("agentId", .string(agentId)),
            OrderedJSONField("state", .string(state)),
            OrderedJSONField("revision", .int(revision)),
            OrderedJSONField("sourceMachineId", .stringOrNull(sourceMachineId)),
            OrderedJSONField("targetKind", .string("hosted")),
            OrderedJSONField("targetMachineId", .null),
            OrderedJSONField("provider", .string("antiproton")),
            OrderedJSONField("failureReason", .null),
            OrderedJSONField("abortReason", .null),
            OrderedJSONField("transportErrorCode", .null),
            OrderedJSONField("transportErrorMessage", .null),
            OrderedJSONField("readyAt", .null),
            OrderedJSONField("flippedAt", .null),
            OrderedJSONField("arrivedAt", .null),
            OrderedJSONField("completedAt", .null),
            OrderedJSONField("abortedAt", .null),
            OrderedJSONField("canceledAt", .stringOrNull(canceledAt)),
            OrderedJSONField("cancelReason", .stringOrNull(cancelReason)),
            OrderedJSONField("cancelNeedsAttention", .bool(false)),
            OrderedJSONField("cancelDispatchAttempts", .int(cancelDispatchAttempts)),
            OrderedJSONField("cancelLastDispatchAt", .stringOrNull(cancelLastDispatchAt)),
            OrderedJSONField("cancelErrorCode", .stringOrNull(cancelErrorCode)),
            OrderedJSONField("cancelErrorMessage", .null),
        ])
    }
}

/// `agent:migration-updated` realtime payload for either record kind.
///
/// The published frame keeps the projection's literals (authority `source`,
/// zero dispatch attempts and a `null` `canceledAt`) even when the record was
/// just canceled, so the payload is built from the record's identity and state
/// only.
struct AgentMigrationUpdatedPayload: Codable, Sendable, Equatable, JSONBodyConvertible {
    var agentId: String
    var migrationRef: String
    var state: String
    var revision: Int
    var updatedAt: String

    init(agentId: String, migrationRef: String, state: String, revision: Int, updatedAt: Date) {
        self.agentId = agentId
        self.migrationRef = migrationRef
        self.state = state
        self.revision = revision
        self.updatedAt = AgentMigrationTimestamps.string(updatedAt) ?? ""
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agentId", .string(agentId)),
            OrderedJSONField("migrationRef", .string(migrationRef)),
            OrderedJSONField("state", .string(state)),
            OrderedJSONField("revision", .int(revision)),
            OrderedJSONField("authority", .string("source")),
            OrderedJSONField("disposition", .null),
            OrderedJSONField("needsAttention", .bool(false)),
            OrderedJSONField("dispatchAttempts", .int(0)),
            OrderedJSONField("attentionDeadlineAt", .null),
            OrderedJSONField("sourceAcknowledgedAt", .null),
            OrderedJSONField("targetAcknowledgedAt", .null),
            OrderedJSONField("targetOutcome", .null),
            OrderedJSONField("canceledAt", .null),
            OrderedJSONField("updatedAt", .string(updatedAt)),
        ])
    }
}

// MARK: - External diagnostics

/// `GET /api/agents/:id/external-diagnostics`: everything the agent panel's
/// "Copy diagnostic info" shows, without the push endpoint or its secret.
public struct ExternalAgentDiagnosticsResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var agentId: String
    public var provider: ExternalAgentProviderDiagnostics?
    public var presence: ExternalAgentPresenceDiagnostics
    public var status: ExternalAgentStatusDiagnostics
    public var push: ExternalAgentPushDiagnostics
    public var events: ExternalAgentCursorDiagnostics
    public var connections: [ExternalAgentConnectionDiagnostics]

    init(
        agentId: String,
        provider: ExternalAgentProviderDiagnostics?,
        presence: ExternalAgentPresenceDiagnostics,
        status: ExternalAgentStatusDiagnostics,
        push: ExternalAgentPushDiagnostics,
        events: ExternalAgentCursorDiagnostics,
        connections: [ExternalAgentConnectionDiagnostics]
    ) {
        self.agentId = agentId
        self.provider = provider
        self.presence = presence
        self.status = status
        self.push = push
        self.events = events
        self.connections = connections
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agentId", .string(agentId)),
            OrderedJSONField("runtime", .string("external")),
            OrderedJSONField("provider", provider?.jsonBody ?? .null),
            OrderedJSONField("presence", presence.jsonBody),
            OrderedJSONField("status", status.jsonBody),
            OrderedJSONField("push", push.jsonBody),
            OrderedJSONField("events", events.jsonBody),
            OrderedJSONField("connections", .array(connections.map(\.jsonBody))),
        ])
    }
}

/// The provider position when one exists, otherwise the hosted runtime's state.
public struct ExternalAgentProviderDiagnostics: Codable, Sendable, Equatable {
    public var kind: String
    public var state: String
    public var providerAgentId: String?
    public var syncPending: Bool
    public var lastErrorCode: String?
    public var lastErrorAt: String?
    public var activatedAt: String?

    init(
        kind: String,
        state: String,
        providerAgentId: String?,
        syncPending: Bool,
        lastErrorCode: String?,
        lastErrorAt: String?,
        activatedAt: String?
    ) {
        self.kind = kind
        self.state = state
        self.providerAgentId = providerAgentId
        self.syncPending = syncPending
        self.lastErrorCode = lastErrorCode
        self.lastErrorAt = lastErrorAt
        self.activatedAt = activatedAt
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("kind", .string(kind)),
            OrderedJSONField("state", .string(state)),
            OrderedJSONField("providerAgentId", .stringOrNull(providerAgentId)),
            OrderedJSONField("syncPending", .bool(syncPending)),
            OrderedJSONField("lastErrorCode", .stringOrNull(lastErrorCode)),
            OrderedJSONField("lastErrorAt", .stringOrNull(lastErrorAt)),
            OrderedJSONField("activatedAt", .stringOrNull(activatedAt)),
        ])
    }
}

public struct ExternalAgentPresenceDiagnostics: Codable, Sendable, Equatable {
    public var lastSeenAt: String?
    public var online: Bool

    init(lastSeenAt: String?, online: Bool) {
        self.lastSeenAt = lastSeenAt
        self.online = online
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("lastSeenAt", .stringOrNull(lastSeenAt)),
            OrderedJSONField("online", .bool(online)),
            OrderedJSONField("onlineWindowMs", .int(120_000)),
        ])
    }
}

public struct ExternalAgentStatusDiagnostics: Codable, Sendable, Equatable {
    public var activity: String
    public var statusProtocolAdoptedAt: String?

    init(activity: String, statusProtocolAdoptedAt: String?) {
        self.activity = activity
        self.statusProtocolAdoptedAt = statusProtocolAdoptedAt
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("activity", .string(activity)),
            OrderedJSONField("statusProtocolAdoptedAt", .stringOrNull(statusProtocolAdoptedAt)),
        ])
    }
}

public struct ExternalAgentPushDiagnostics: Codable, Sendable, Equatable {
    public var registered: Bool
    public var endpointHost: String?

    init(registered: Bool, endpointHost: String?) {
        self.registered = registered
        self.endpointHost = endpointHost
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("registered", .bool(registered)),
            OrderedJSONField("enabled", .bool(registered)),
            OrderedJSONField("endpointHost", .stringOrNull(endpointHost)),
            OrderedJSONField("disabledReason", .null),
            OrderedJSONField("disabledAt", .null),
            OrderedJSONField("consecutiveFailures", .int(0)),
            OrderedJSONField("lastAttemptAt", .null),
            OrderedJSONField("lastDeliveryAt", .null),
            OrderedJSONField("lastError", .null),
            OrderedJSONField("nextAttemptAt", .null),
        ])
    }
}

public struct ExternalAgentCursorDiagnostics: Codable, Sendable, Equatable {
    public var lastCursorPullAt: String?
    public var pendingCursorAckCount: Int

    init(lastCursorPullAt: String?, pendingCursorAckCount: Int) {
        self.lastCursorPullAt = lastCursorPullAt
        self.pendingCursorAckCount = pendingCursorAckCount
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("lastCursorPullAt", .stringOrNull(lastCursorPullAt)),
            OrderedJSONField("pendingCursorAckCount", .int(pendingCursorAckCount)),
        ])
    }
}

public struct ExternalAgentConnectionDiagnostics: Codable, Sendable, Equatable {
    public var provider: String
    public var state: String
    public var account: String?
    public var reason: String?

    init(provider: String, state: String, account: String?, reason: String?) {
        self.provider = provider
        self.state = state
        self.account = account
        self.reason = reason
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("provider", .string(provider)),
            OrderedJSONField("state", .string(state)),
            OrderedJSONField("account", .stringOrNull(account)),
            OrderedJSONField("reason", .stringOrNull(reason)),
        ])
    }
}

/// The published migration timestamps carry fractional seconds, which
/// `JSONEncoder`'s date strategies do not reproduce; the projection stores the
/// formatted string and the ordered writer publishes it as a JSON string.
enum AgentMigrationTimestamps {
    static func string(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
