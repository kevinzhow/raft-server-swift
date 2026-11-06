import Foundation

/// Domain failure for the three agent-migration-status operations: the
/// published status projection, the cancellation and the external diagnostics
/// view. The feature layer owns the wire encoding; each case owns the status,
/// the published `error` text and, for the coded failures, the machine code.
public enum AgentMigrationStatusError: DomainError, Equatable {
    case unauthorized
    case agentMissing
    case diagnosticsForbidden
    case migrationStatusForbidden
    case migrationCancelForbidden
    case agentNotExternal
    case migrationRefInvalid
    case migrationRevisionInvalid
    case migrationNotFound
    case migrationRevisionStale
    case migrationNotCancelable

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .agentMissing, .migrationNotFound:
            404
        case .diagnosticsForbidden, .migrationStatusForbidden, .migrationCancelForbidden:
            403
        case .agentNotExternal, .migrationRefInvalid, .migrationRevisionInvalid:
            400
        case .migrationRevisionStale, .migrationNotCancelable:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .agentMissing:
            "Agent not found"
        case .diagnosticsForbidden:
            "Forbidden"
        case .migrationStatusForbidden:
            "Agent migration status requires creator or server admin authority"
        case .migrationCancelForbidden:
            "Agent migration cancel requires creator or server admin authority"
        case .agentNotExternal:
            "External diagnostics require an external Agent"
        case .migrationRefInvalid:
            "migrationRef is required"
        case .migrationRevisionInvalid:
            "expectedRevision must be a positive integer"
        case .migrationNotFound:
            "Migration not found"
        case .migrationRevisionStale:
            "The migration changed since this action was shown"
        case .migrationNotCancelable:
            "This migration can no longer be canceled"
        }
    }

    public var errorCode: String? {
        switch self {
        case .unauthorized, .diagnosticsForbidden:
            nil
        case .agentMissing:
            "agent_missing"
        case .migrationStatusForbidden, .migrationCancelForbidden:
            "not_supported"
        case .agentNotExternal:
            "agent_not_external"
        case .migrationRefInvalid:
            "MIGRATION_REF_INVALID"
        case .migrationRevisionInvalid:
            "MIGRATION_REVISION_INVALID"
        case .migrationNotFound:
            "MIGRATION_NOT_FOUND"
        case .migrationRevisionStale:
            "MIGRATION_REVISION_STALE"
        case .migrationNotCancelable:
            "MIGRATION_NOT_CANCELABLE"
        }
    }

    /// The legacy coded failure prints the machine code before the message.
    /// The canonical default is the opposite order, so the domain owns its
    /// tree; a failure without a code keeps the plain `{"error": …}` bytes.
    public var errorBody: OrderedJSON? {
        guard let errorCode else { return nil }
        return .object([
            OrderedJSONField("code", errorCode),
            OrderedJSONField("error", errorMessage),
        ])
    }
}

/// Migration status, cancellation, provider position and the external
/// diagnostics view for one agent.
///
/// The service owns the published order (owner/administrator/creator authority
/// before any migration read), returns a typed DTO whose key order is the
/// legacy key order, and throws `AgentMigrationStatusError`; it never builds a
/// reply, JSON or header set. The two migration record families live in
/// different stores, so each cancel decision runs as one store critical section
/// per family: the store checks presence, revision and state and writes the
/// cancelled record under the same lock.
public struct AgentMigrationStatusService: Sendable {
    private let sessionUserId: @Sendable (String?) -> String?
    private let oauth: OAuthLedger
    private let agents: AgentsRuntimeStore
    private let emitRealtime: @Sendable (_ room: String, _ event: String, _ payload: String) -> Void
    private let cancelDispatch: @Sendable (
        _ machineId: String,
        _ role: String,
        _ migrationRef: String,
        _ transportGeneration: String,
        _ stopAgent: Bool
    ) -> Void
    private let now: @Sendable () -> Date

    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        oauth: OAuthLedger,
        agents: AgentsRuntimeStore,
        emitRealtime: @escaping @Sendable (String, String, String) -> Void,
        cancelDispatch: @escaping @Sendable (String, String, String, String, Bool) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionUserId = sessionUserId
        self.oauth = oauth
        self.agents = agents
        self.emitRealtime = emitRealtime
        self.cancelDispatch = cancelDispatch
        self.now = now
    }

    /// `GET /api/agents/:id/external-diagnostics`.
    public func externalDiagnostics(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> ExternalAgentDiagnosticsResponse {
        let agent = try authorized(
            authorization: authorization,
            serverId: serverId,
            agentId: agentId,
            forbidden: .diagnosticsForbidden
        ).agent
        guard agent.runtime == "external" else { throw AgentMigrationStatusError.agentNotExternal }
        let facts = agents.externalDiagnosticsFacts(agentId: agentId)
        let online = facts.lastSeenAt.map { now().timeIntervalSince($0) <= 120 } ?? false
        // The published view reduces the registered endpoint to its host; the
        // URL path and the delivered secret never leave the store.
        let endpointHost = facts.pushWebhookURL.flatMap { URLComponents(string: $0)?.host }

        let provider: ExternalAgentProviderDiagnostics?
        if let position = facts.providerPosition {
            provider = ExternalAgentProviderDiagnostics(
                kind: position.provider,
                state: position.state,
                providerAgentId: position.providerAgentId,
                syncPending: position.syncPending,
                lastErrorCode: position.lastErrorCode,
                lastErrorAt: AgentMigrationTimestamps.string(position.lastErrorAt),
                activatedAt: AgentMigrationTimestamps.string(position.activatedAt)
            )
        } else if let hosted = facts.hostedRuntime {
            provider = ExternalAgentProviderDiagnostics(
                kind: "antiproton",
                state: hosted.state,
                providerAgentId: nil,
                syncPending: false,
                lastErrorCode: nil,
                lastErrorAt: nil,
                activatedAt: AgentMigrationTimestamps.string(hosted.createdAt)
            )
        } else {
            provider = nil
        }

        let connections = facts.hostedRuntime == nil
            ? [ExternalAgentConnectionDiagnostics(provider: "github", state: "not_applicable", account: nil, reason: nil)]
            : [ExternalAgentConnectionDiagnostics(
                provider: "github",
                state: "unavailable",
                account: nil,
                reason: "Cloud connections are not enabled for this server"
            )]

        return ExternalAgentDiagnosticsResponse(
            agentId: agentId,
            provider: provider,
            presence: ExternalAgentPresenceDiagnostics(
                lastSeenAt: AgentMigrationTimestamps.string(facts.lastSeenAt),
                online: online
            ),
            status: ExternalAgentStatusDiagnostics(
                activity: facts.activity,
                statusProtocolAdoptedAt: AgentMigrationTimestamps.string(facts.statusProtocolAdoptedAt)
            ),
            push: ExternalAgentPushDiagnostics(
                registered: facts.pushWebhookURL != nil,
                endpointHost: endpointHost
            ),
            events: ExternalAgentCursorDiagnostics(
                lastCursorPullAt: AgentMigrationTimestamps.string(facts.cursorLastPulledAt),
                pendingCursorAckCount: facts.cursorPendingAcks
            ),
            connections: connections
        )
    }

    /// `GET /api/agents/:id/migration`. A hosted row wins over a Computer row,
    /// which is the order the legacy read used.
    public func migrationStatus(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> AgentMigrationStatusResponse {
        _ = try authorized(
            authorization: authorization,
            serverId: serverId,
            agentId: agentId,
            forbidden: .migrationStatusForbidden
        )
        if let hosted = agents.hostedMigrations[agentId] {
            return AgentMigrationStatusResponse(migration: .hosted(HostedAgentMigrationStatus(hosted)))
        }
        if let machine = agents.machineMigration(agentId: agentId, serverId: serverId) {
            return AgentMigrationStatusResponse(migration: .machine(MachineAgentMigrationStatus(machine)))
        }
        return AgentMigrationStatusResponse()
    }

    /// `POST /api/agents/:id/migration/cancel`. Authority runs before the body
    /// is validated, so a member cannot learn whether a reference exists.
    public func cancelMigration(
        authorization: String?,
        serverId: String,
        agentId: String,
        request: AgentMigrationCancelRequest
    ) throws -> AgentMigrationStatusResponse {
        _ = try authorized(
            authorization: authorization,
            serverId: serverId,
            agentId: agentId,
            forbidden: .migrationCancelForbidden
        )
        // The retired internal `migrationId` is refused before the reference is
        // read, exactly like the legacy object cast.
        guard !request.includesMigrationID else { throw AgentMigrationStatusError.migrationRefInvalid }
        guard let migrationRef = request.migrationRef,
              migrationRef.range(of: "^mig_[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil
        else { throw AgentMigrationStatusError.migrationRefInvalid }
        let expectedRevision = try Self.expectedRevision(from: request)
        let reason = request.reason ?? "user_canceled"
        let current = now()

        switch agents.cancelHostedMigration(
            agentId: agentId,
            serverId: serverId,
            migrationRef: migrationRef,
            expectedRevision: expectedRevision,
            reason: reason,
            now: current
        ) {
        case .canceled(let migration):
            emitMigrationUpdated(serverId: serverId, migration: migration)
            return AgentMigrationStatusResponse(migration: .hosted(HostedAgentMigrationStatus(migration)))
        case .stale:
            throw AgentMigrationStatusError.migrationRevisionStale
        case .terminal:
            throw AgentMigrationStatusError.migrationNotCancelable
        case .missing:
            break
        }

        switch agents.cancelMachineMigration(
            agentId: agentId,
            serverId: serverId,
            migrationRef: migrationRef,
            expectedRevision: expectedRevision,
            reason: reason,
            now: current
        ) {
        case .canceled(let migration):
            cancelDispatch(
                migration.sourceMachineId,
                "source",
                migration.supportRef,
                migration.transportGeneration,
                false
            )
            cancelDispatch(
                migration.targetMachineId,
                "target",
                migration.supportRef,
                migration.transportGeneration,
                false
            )
            emitMigrationUpdated(serverId: serverId, migration: migration)
            return AgentMigrationStatusResponse(migration: .machine(MachineAgentMigrationStatus(migration)))
        case .stale:
            throw AgentMigrationStatusError.migrationRevisionStale
        case .terminal:
            throw AgentMigrationStatusError.migrationNotCancelable
        case .missing:
            throw AgentMigrationStatusError.migrationNotFound
        }
    }

    /// The published authority order: session, then agent/Server membership,
    /// then owner/administrator/creator. The 403 body differs per operation, so
    /// the caller names the failure.
    private func authorized(
        authorization: String?,
        serverId: String,
        agentId: String,
        forbidden: AgentMigrationStatusError
    ) throws -> (userId: String, agent: OAuthLedger.AgentManagementInfo) {
        guard let userId = sessionUserId(authorization) else {
            throw AgentMigrationStatusError.unauthorized
        }
        guard let agent = oauth.agentManagementInfo(id: agentId),
              !agent.deleted,
              agent.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            throw AgentMigrationStatusError.agentMissing
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            throw forbidden
        }
        return (userId, agent)
    }

    /// The retired parser read `expectedRevision` through `as? NSNumber`: any
    /// JSON number whose value is integral and `>= 1` passed, and a JSON
    /// boolean bridged to 1/0. An out-of-`Int` magnitude saturated to
    /// `Int.min` there, which fails the same `>= 1` gate.
    private static func expectedRevision(from request: AgentMigrationCancelRequest) throws -> Int {
        guard let raw = request.expectedRevision, raw.rounded() == raw else {
            throw AgentMigrationStatusError.migrationRevisionInvalid
        }
        let value: Int
        if raw >= Double(Int.min), raw < Double(Int.max) {
            value = Int(raw)
        } else {
            value = Int.min
        }
        guard value >= 1 else { throw AgentMigrationStatusError.migrationRevisionInvalid }
        return value
    }

    /// `agent:migration-updated` for every owner/administrator of the Server.
    /// The frame payload keeps the projection's literals even after a
    /// cancellation, so it is built from the record identity and state only.
    private func emitMigrationUpdated(serverId: String, migration: HostedMigrationRecord) {
        emitMigrationUpdated(
            serverId: serverId,
            agentId: migration.agentId,
            migrationRef: migration.supportRef,
            state: migration.state,
            revision: migration.revision
        )
    }

    private func emitMigrationUpdated(serverId: String, migration: MachineMigrationRecord) {
        emitMigrationUpdated(
            serverId: serverId,
            agentId: migration.agentId,
            migrationRef: migration.supportRef,
            state: migration.state,
            revision: migration.revision
        )
    }

    private func emitMigrationUpdated(
        serverId: String,
        agentId: String,
        migrationRef: String,
        state: String,
        revision: Int
    ) {
        let members = oauth.memberIdsWithRoles(serverId: serverId)
        for member in members where member.role == "owner" || member.role == "admin" {
            let payload = AgentMigrationUpdatedPayload(
                agentId: agentId,
                migrationRef: migrationRef,
                state: state,
                revision: revision,
                updatedAt: now()
            )
            emitRealtime("user:\(member.id)", "agent:migration-updated", payload.jsonBody.render())
        }
    }
}
