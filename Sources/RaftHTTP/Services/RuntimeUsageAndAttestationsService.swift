import Foundation

/// Typed failures for the server-usage, system-attention and attested
/// diagnostic surface.
///
/// Every case names the published error object. `bodyJSON` keeps the archive's
/// member order for the multi-key bodies (`{"status": …}`,
/// `{"error": …,"code": …}` and the 413 upload cap); the single-key
/// `{"error": …}` cases fall back to `errorMessage`.
public enum RuntimeUsageAndAttestationsError: CanonicalDomainErrorBody, Equatable {
    case unauthorized
    case serverNotFound
    case notAMemberOfServer
    case guestsCannotAccessServerManagementData
    case invalidSystemAttentionIncident
    case systemAttentionIncidentNotFound
    case notJoinable
    case notAccessible
    case invalidRequest
    case machineNotFoundInThisServer
    case agentNotFoundInThisServer
    case agentNotAssignedToMachine
    case editAgentsCapabilityRequired
    case machineOffline
    case notFound
    case agentNotFound
    case forbidden
    case invalidTranscriptRequest
    case invalidReportGeneratedAt
    case guestsCannotCreateShareArtifacts
    case imageRequired
    case shareArtifactTooLarge
    case shareArtifactMustBePNG
    case channelIdRequired
    case noChannelAccess

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .guestsCannotAccessServerManagementData, .notAMemberOfServer,
             .editAgentsCapabilityRequired, .forbidden,
             .guestsCannotCreateShareArtifacts, .noChannelAccess:
            403
        case .serverNotFound, .systemAttentionIncidentNotFound, .notJoinable,
             .notAccessible, .machineNotFoundInThisServer, .agentNotFoundInThisServer,
             .notFound, .agentNotFound:
            404
        case .invalidSystemAttentionIncident, .invalidRequest,
             .agentNotAssignedToMachine, .invalidTranscriptRequest,
             .invalidReportGeneratedAt, .imageRequired, .channelIdRequired:
            400
        case .machineOffline:
            409
        case .shareArtifactTooLarge:
            413
        case .shareArtifactMustBePNG:
            415
        }
    }

    /// The published upstream `error` text. `{"status": …}` failures never use
    /// it for the wire body; `bodyJSON` is the exact contract.
    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .serverNotFound:
            "Server not found"
        case .notAMemberOfServer:
            "Not a member of this server"
        case .guestsCannotAccessServerManagementData:
            "Guests cannot access server management data"
        case .invalidSystemAttentionIncident:
            "Invalid system attention incident"
        case .systemAttentionIncidentNotFound:
            "System attention incident not found"
        case .notJoinable:
            "NOT_JOINABLE"
        case .notAccessible:
            "NOT_ACCESSIBLE"
        case .invalidRequest:
            "INVALID_REQUEST"
        case .machineNotFoundInThisServer:
            "Machine not found in this server"
        case .agentNotFoundInThisServer:
            "Agent not found in this server"
        case .agentNotAssignedToMachine:
            "Agent is not assigned to this machine"
        case .editAgentsCapabilityRequired:
            "The `editAgents` capability or human creator authority is required to view agent diagnostics"
        case .machineOffline:
            "Computer is offline"
        case .notFound:
            "Not found"
        case .agentNotFound:
            "Agent not found"
        case .forbidden:
            "Forbidden"
        case .invalidTranscriptRequest:
            "Invalid transcript request"
        case .invalidReportGeneratedAt:
            "reportGeneratedAt must be an ISO timestamp"
        case .guestsCannotCreateShareArtifacts:
            "Guests cannot create share artifacts"
        case .imageRequired:
            "image is required"
        case .shareArtifactTooLarge:
            "Max 10MB per image"
        case .shareArtifactMustBePNG:
            "Share artifact must be a PNG image"
        case .channelIdRequired:
            "channelId is required"
        case .noChannelAccess:
            "You do not have access to this channel"
        }
    }

    public var errorCode: String? {
        switch self {
        case .machineOffline:
            "machine_offline"
        default:
            nil
        }
    }

    public var bodyJSON: String {
        switch self {
        case .notJoinable:
            "{\"status\":\"NOT_JOINABLE\"}"
        case .notAccessible:
            "{\"status\":\"NOT_ACCESSIBLE\"}"
        case .invalidRequest:
            "{\"status\":\"INVALID_REQUEST\"}"
        case .machineOffline:
            "{\"error\":\"Computer is offline\",\"code\":\"machine_offline\"}"
        case .shareArtifactTooLarge:
            "{\"error\":\"Max 10MB per image\",\"errorCode\":\"SHARE_ARTIFACT_TOO_LARGE\",\"maxBytes\":10485760}"
        default:
            "{\"error\":\(jsonString(errorMessage))}"
        }
    }
}

/// Server usage, system attention and agent-attestation read models: share
/// artifacts, transcripts and mention-delivery diagnostics.
///
/// The service owns the authorization order and the published read models; the
/// machine, agent, message and system-attention rows stay in their per-domain
/// stores, each read behind that store's own lock. It holds no
/// `EmailLoginDirectory` and no lock of its own.
public struct RuntimeUsageAndAttestationsService: Sendable {
    private static let usageLimitAttentionContract = "server-system-attention-v1"
    private static let systemNotificationsContract = "server-system-notifications-v1"

    private let machines: MachinesAndComputersStore
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let agents: AgentsRuntimeStore
    private let oauth: OAuthLedger
    /// Session lookup still lives on the directory; the composition root
    /// injects it so the service stays directory-free.
    private let sessionUserId: @Sendable (String?) -> String?
    /// `taskChannelAccess` is the unmigrated channel write policy; a `false`
    /// answer is the archive's `.missing` case.
    private let channelAccess: @Sendable (String, String, String) -> Bool
    private let now: @Sendable () -> Date
    private let makeArtifactId: @Sendable () -> String

    init(
        machines: MachinesAndComputersStore,
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        agents: AgentsRuntimeStore,
        oauth: OAuthLedger,
        sessionUserId: @escaping @Sendable (String?) -> String?,
        channelAccess: @escaping @Sendable (String, String, String) -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        makeArtifactId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.machines = machines
        self.messages = messages
        self.channels = channels
        self.agents = agents
        self.oauth = oauth
        self.sessionUserId = sessionUserId
        self.channelAccess = channelAccess
        self.now = now
        self.makeArtifactId = makeArtifactId
    }

    // MARK: - Server usage (`GET /api/servers/:id/usage`)

    /// Counts live agents, daemon machines and human channels. A guest gets the
    /// published 403; a non-member gets the 404 that hides the server.
    public func serverUsage(authorization: String?, serverId: String) throws -> ServerUsageDTO {
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeUsageAndAttestationsError.serverNotFound
        }
        guard role != "guest" else {
            throw RuntimeUsageAndAttestationsError.guestsCannotAccessServerManagementData
        }
        let agentCount = oauth.serverAgents(serverId: serverId).count
        let machineRows = machines.state.machines
        let machineCount = machineRows.filter { $0.serverId == serverId }.count
        let channelCount = oauth.channelsForServer(
            serverId: serverId,
            userId: userId,
            includeArchived: true
        )
        .filter {
            ($0.type == "channel" || $0.type == "private") && oauth.channelArchivedAt(id: $0.id) == nil
        }
        .count
        return ServerUsageDTO(agents: agentCount, machines: machineCount, channels: channelCount)
    }

    // MARK: - System notifications (`GET /api/servers/:id/system-notifications`)

    /// The per-server machine-offline feed. Managed Computers are excluded
    /// because their daemon column is not a raw daemon; an offline daemon with
    /// active agents is an error, one without is a warning.
    public func serverSystemNotifications(
        authorization: String?,
        serverId: String
    ) throws -> SystemNotificationsDTO {
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeUsageAndAttestationsError.notAMemberOfServer
        }
        let generatedAt = now()
        guard role != "guest" else {
            return Self.systemNotifications(generatedAt: generatedAt, notifications: [])
        }

        let machineSnapshot = machines.state
        let agentSnapshot = agents.state
        let rows = machineSnapshot.machines.filter { $0.serverId == serverId }
        let online = machineSnapshot.machineOnline
        let computerMachineIds = Set(machineSnapshot.computers.compactMap { computer -> String? in
            guard computer.serverId == serverId, computer.revokedAt == nil else { return nil }
            return computer.machineId
        })
        var activeByMachine: [String: Int] = [:]
        for agent in agentSnapshot.serverAgents.values
        where agent.serverId == serverId && agent.status == "active" {
            if let machineId = agentSnapshot.agentMachineIds[agent.id] {
                activeByMachine[machineId, default: 0] += 1
            }
        }

        let rawDaemons = rows
            .filter { !computerMachineIds.contains($0.id) }
            .sorted { $0.id < $1.id }
        let offline = rawDaemons.filter { online[$0.id] != true }
        guard !offline.isEmpty else {
            return Self.systemNotifications(generatedAt: generatedAt, notifications: [])
        }

        let activeCount = offline.reduce(0) { $0 + (activeByMachine[$1.id] ?? 0) }
        let names = offline.map(\.name).joined(separator: ", ")
        let singular = offline.count == 1
        let title = "\(names) \(singular ? "is" : "are") offline"
        let body = activeCount > 0
            ? "\(activeCount) \(activeCount == 1 ? "agent is" : "agents are") active on \(singular ? "this computer" : "these computers") and can't run until \(singular ? "it reconnects" : "they reconnect")."
            : "No agents are active on \(singular ? "this computer" : "these computers") right now — reconnect when you need \(singular ? "it" : "them") next."
        let ids = offline.map(\.id).joined(separator: ",")
        let machineRefs = offline.map { SystemNotificationMachineDTO(id: $0.id, name: $0.name) }
        let copyTitle = singular ? "machine.offline.title.one" : "machine.offline.title.many"
        let copyBody = activeCount > 0
            ? (singular ? "machine.offline.body.active.one" : "machine.offline.body.active.many")
            : (singular ? "machine.offline.body.idle.one" : "machine.offline.body.idle.many")
        let notification = SystemNotificationDTO(
            id: "machine-offline:\(ids)",
            type: "machine.offline",
            schemaVersion: 1,
            state: "active",
            kind: activeCount > 0 ? "error" : "warning",
            title: title,
            body: body,
            copy: SystemNotificationCopyDTO(
                titleKey: copyTitle,
                bodyKey: copyBody,
                actionLabelKey: "common.view",
                params: SystemNotificationCopyParamsDTO(
                    machineNames: names,
                    machineCount: offline.count,
                    activeAgentCount: activeCount
                )
            ),
            action: SystemNotificationActionDTO(
                label: "View",
                targetType: "machine",
                targetId: offline[0].id
            ),
            payload: SystemNotificationPayloadDTO(
                machines: machineRefs,
                activeAgentCount: activeCount,
                evaluation: SystemNotificationEvaluationDTO(
                    clock: "server",
                    evaluatedAt: generatedAt,
                    offlineAfterMs: 0,
                    statusAuthority: "canonical_machine_read_model",
                    runKind: "raw_daemon",
                    versionAuthority: "latest_daemon_release"
                )
            )
        )
        return Self.systemNotifications(generatedAt: generatedAt, notifications: [notification])
    }

    static func systemNotifications(
        generatedAt: Date,
        notifications: [SystemNotificationDTO]
    ) -> SystemNotificationsDTO {
        SystemNotificationsDTO(
            contractVersion: systemNotificationsContract,
            generatedAt: generatedAt,
            snapshotMode: "replace",
            clientState: SystemNotificationsClientStateDTO(
                read: "none",
                dismiss: "local_by_notification_id"
            ),
            notifications: notifications
        )
    }

    // MARK: - System attention (`GET /api/servers/:id/system-notifications-v2`)

    /// The per-recipient usage-limit attention feed. Non-members and members
    /// without owner/admin authority get the published empty snapshot (not an
    /// error), matching the archive.
    public func listSystemAttention(
        authorization: String?,
        serverId: String
    ) throws -> SystemAttentionDTO {
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        let generatedAt = now()
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            return Self.systemAttention(generatedAt: generatedAt, notifications: [])
        }
        guard channels.usageLimitAttentionServers.contains(serverId) else {
            return Self.systemAttention(generatedAt: generatedAt, notifications: [])
        }
        let incidents = messages.systemAttentionNotifications(serverId: serverId, userId: userId)
        let machineRows = machines.state.machines
        let notifications = incidents.map { row -> SystemAttentionNotificationDTO in
            let incident = row.incident
            let machineName = machineRows.first { $0.id == incident.machineId }?.name ?? ""
            return SystemAttentionNotificationDTO(
                id: incident.id,
                kind: "usage_limit_reached",
                severity: "warning",
                state: "active",
                activatedAt: incident.activatedAt,
                lastObservedAt: incident.lastObservedAt,
                seenAt: row.seenAt,
                machine: SystemAttentionMachineDTO(id: incident.machineId, name: machineName),
                provider: incident.provider,
                windowKey: incident.windowKey,
                resetsAt: incident.resetsAt,
                affectedAgentIds: incident.affectedAgentIds
            )
        }
        return Self.systemAttention(generatedAt: generatedAt, notifications: notifications)
    }

    static func systemAttention(
        generatedAt: Date,
        notifications: [SystemAttentionNotificationDTO]
    ) -> SystemAttentionDTO {
        SystemAttentionDTO(
            contractVersion: usageLimitAttentionContract,
            generatedAt: generatedAt,
            snapshotMode: "replace",
            unseenCount: notifications.reduce(0) { $0 + ($1.seenAt == nil ? 1 : 0) },
            notifications: notifications
        )
    }

    /// `POST /api/servers/:id/system-notifications-v2/:incidentId/seen`.
    public func markSystemAttentionSeen(
        authorization: String?,
        serverId: String,
        incidentId: String
    ) throws -> OkResponse {
        try systemAttentionReceipt(
            authorization: authorization,
            serverId: serverId,
            incidentId: incidentId,
            dismiss: false
        )
    }

    /// `POST /api/servers/:id/system-notifications-v2/:incidentId/dismiss`.
    public func dismissSystemAttention(
        authorization: String?,
        serverId: String,
        incidentId: String
    ) throws -> OkResponse {
        try systemAttentionReceipt(
            authorization: authorization,
            serverId: serverId,
            incidentId: incidentId,
            dismiss: true
        )
    }

    private func systemAttentionReceipt(
        authorization: String?,
        serverId: String,
        incidentId: String,
        dismiss: Bool
    ) throws -> OkResponse {
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        guard ServerScope.isUUID(incidentId) else {
            throw RuntimeUsageAndAttestationsError.invalidSystemAttentionIncident
        }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            throw RuntimeUsageAndAttestationsError.systemAttentionIncidentNotFound
        }
        // The enabled flag, the incident lookup and the receipt write share one
        // store critical section, so a concurrent mark cannot resurrect a
        // dismissal from a stale read.
        let enabled = channels.usageLimitAttentionServers.contains(serverId)
        guard messages.recordSystemAttentionReceipt(
            serverId: serverId,
            incidentId: incidentId,
            userId: userId,
            attentionEnabled: enabled,
            dismiss: dismiss,
            now: now()
        ) else {
            throw RuntimeUsageAndAttestationsError.systemAttentionIncidentNotFound
        }
        return OkResponse()
    }

    // MARK: - Mention-delivery diagnostics

    /// `GET …/diagnostic/mention-delivery/:messageId`.
    ///
    /// The archive answers every outcome with a `{"status": …}` body: a
    /// malformed message id is `NOT_JOINABLE` before authentication, an unseen
    /// or unassigned agent is `NOT_ACCESSIBLE`, and the healthy path is
    /// `NOT_JOINABLE` because delivery diagnostics are not joinable in this
    /// build.
    public func mentionDeliveryDiagnostic(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String,
        messageId: String
    ) throws -> RuntimeStatusDTO {
        guard ServerScope.isUUID(messageId) else {
            return RuntimeStatusDTO(status: "NOT_JOINABLE")
        }
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              let agent = oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            throw RuntimeUsageAndAttestationsError.notAccessible
        }
        let machineRows = machines.state.machines
        let assigned = agents.state.agentMachineIds[agentId] == machineId
        let machineMatches = machineRows.contains { $0.id == machineId && $0.serverId == serverId }
        guard machineMatches, assigned else {
            throw RuntimeUsageAndAttestationsError.notAccessible
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            throw RuntimeUsageAndAttestationsError.notAccessible
        }
        return RuntimeStatusDTO(status: "NOT_JOINABLE")
    }

    /// `POST …/diagnostic/mention-delivery/:messageId/redrive`.
    public func redriveMentionDelivery(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String,
        messageId: String,
        body: String
    ) throws -> RuntimeStatusDTO {
        guard ServerScope.isUUID(messageId) else {
            return RuntimeStatusDTO(status: "NOT_JOINABLE")
        }
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              let agent = oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            throw RuntimeUsageAndAttestationsError.notAccessible
        }
        let machineRows = machines.state.machines
        let assigned = agents.state.agentMachineIds[agentId] == machineId
        let machineMatches = machineRows.contains { $0.id == machineId && $0.serverId == serverId }
        guard machineMatches, assigned else {
            throw RuntimeUsageAndAttestationsError.notAccessible
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            throw RuntimeUsageAndAttestationsError.notAccessible
        }
        guard RuntimeUsageDiagnosticBody.mentionRedriveAccepted(body) else {
            throw RuntimeUsageAndAttestationsError.invalidRequest
        }
        return RuntimeStatusDTO(status: "NOT_JOINABLE")
    }

    // MARK: - Session transcript

    /// `GET …/agents/:agentId/diagnostic/session-transcript`. The machine must
    /// exist and be online, the agent must be assigned to it, and the caller
    /// must be an owner, an admin or the agent's human creator.
    public func agentSessionTranscript(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String
    ) throws -> SessionTranscriptDTO {
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeUsageAndAttestationsError.serverNotFound
        }
        let machineSnapshot = machines.state
        let machineExists = machineSnapshot.machines.contains {
            $0.id == machineId && $0.serverId == serverId
        }
        let assignedMachine = agents.state.agentMachineIds[agentId]
        let online = machineSnapshot.machineOnline[machineId] == true
        guard machineExists else {
            throw RuntimeUsageAndAttestationsError.machineNotFoundInThisServer
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            throw RuntimeUsageAndAttestationsError.agentNotFoundInThisServer
        }
        guard assignedMachine == machineId else {
            throw RuntimeUsageAndAttestationsError.agentNotAssignedToMachine
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            throw RuntimeUsageAndAttestationsError.editAgentsCapabilityRequired
        }
        guard online else {
            throw RuntimeUsageAndAttestationsError.machineOffline
        }
        return SessionTranscriptDTO()
    }

    // MARK: - Transcript feedback

    /// `POST …/feedback/:reportId/transcript`. Owner, admin or the agent's
    /// human creator may upload; a present `reportGeneratedAt` must be an ISO
    /// timestamp.
    public func submitTranscriptFeedback(
        authorization: String?,
        serverId: String,
        agentId: String,
        reportId: String,
        body: String
    ) throws -> TranscriptFeedbackAcceptedDTO {
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw RuntimeUsageAndAttestationsError.notAMemberOfServer
        }
        guard reportId.wholeMatch(
            of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        ) != nil else {
            throw RuntimeUsageAndAttestationsError.notFound
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            throw RuntimeUsageAndAttestationsError.agentNotFound
        }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            throw RuntimeUsageAndAttestationsError.forbidden
        }
        switch RuntimeUsageDiagnosticBody.transcriptFeedback(body) {
        case .valid:
            break
        case .malformed:
            throw RuntimeUsageAndAttestationsError.invalidTranscriptRequest
        case .invalidTimestamp:
            throw RuntimeUsageAndAttestationsError.invalidReportGeneratedAt
        }
        return TranscriptFeedbackAcceptedDTO(feedbackReportId: reportId, agentId: agentId)
    }

    // MARK: - Share artifacts (`POST /api/share-artifacts/message-selection`)

    /// A PNG screenshot becomes a public share page plus the image behind it.
    /// The image bytes are stored exactly as uploaded, so the OG card
    /// advertises the real dimensions.
    public func createShareArtifact(
        authorization: String?,
        serverId: String,
        channelId: String?,
        image: (bytes: Data, sizeBytes: Int)?,
        serverBase: String,
        shareBase: String,
        cdnBase: String?
    ) throws -> ShareArtifactDTO {
        guard let userId = sessionUserId(authorization) else {
            throw RuntimeUsageAndAttestationsError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeUsageAndAttestationsError.notAMemberOfServer
        }
        guard role != "guest" else {
            throw RuntimeUsageAndAttestationsError.guestsCannotCreateShareArtifacts
        }
        let maxBytes = 10 * 1024 * 1024
        guard let image, image.sizeBytes > 0, !image.bytes.isEmpty else {
            throw RuntimeUsageAndAttestationsError.imageRequired
        }
        guard image.sizeBytes <= maxBytes else {
            throw RuntimeUsageAndAttestationsError.shareArtifactTooLarge
        }
        guard Self.isPNG(image.bytes) else {
            throw RuntimeUsageAndAttestationsError.shareArtifactMustBePNG
        }
        guard let channelId else {
            throw RuntimeUsageAndAttestationsError.channelIdRequired
        }
        guard channelAccess(serverId, channelId, userId) else {
            throw RuntimeUsageAndAttestationsError.noChannelAccess
        }
        let id = makeArtifactId()
        let size = Self.pngDimensions(image.bytes)
        messages.insertShareArtifact(
            id: id,
            bytes: image.bytes,
            width: size.width,
            height: size.height,
            serverId: serverId,
            createdAt: now()
        )
        return ShareArtifactDTO(
            id: id,
            url: ShareArtifactURL.share(id: id, shareBase: shareBase),
            imageUrl: ShareArtifactURL.image(
                id: id,
                serverId: serverId,
                serverBase: serverBase,
                cdnBase: cdnBase
            )
        )
    }

    static func isPNG(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// Width and height from the PNG IHDR chunk, falling back to 1x1.
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int) {
        guard data.count >= 24 else { return (1, 1) }
        let bytes = [UInt8](data[16..<24])
        let width = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[4..<8].reduce(0) { $0 << 8 | Int($1) }
        return (width > 0 ? width : 1, height > 0 ? height : 1)
    }
}
