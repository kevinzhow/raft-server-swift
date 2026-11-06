import Foundation

/// The not-yet-migrated session and credential decisions the reminder service
/// needs. Each enters as a closure wired by the directory accessor.
public struct ManagedMCPAgentCatalogDependencies: Sendable {
    /// The user id behind a live access token.
    var sessionUserId: @Sendable (_ authorization: String?) -> String?
    /// The capability a bearer agent credential lacks, or nil when the
    /// request is allowed.
    var deniedCapability: @Sendable (_ authorization: String?, _ capability: String) -> String?
    var now: @Sendable () -> Date

    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        deniedCapability: @escaping @Sendable (String?, String) -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionUserId = sessionUserId
        self.deniedCapability = deniedCapability
        self.now = now
    }
}

extension ManagedMCPAgentCatalogDependencies {
    init(auth: AuthCoreService, locator: FeedbackLocatorService, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            deniedCapability: locator.deniedCapability,
            now: now
        )
    }
}

/// App reminders for the owner list, the internal machine routes and the
/// agent-api routes, plus the saved-message write.
///
/// The reminder ledger lives in `TasksAndRemindersStore`: every version-bound
/// write is one critical section there. This type decides who may call and maps
/// ledger outcomes to DTOs and typed refusals.
public struct ManagedMCPAgentCatalogService: Sendable {
    let reminders: TasksAndRemindersStore
    let machines: MachinesAndComputersStore
    let agents: AgentsRuntimeStore
    let oauth: OAuthLedger
    let dependencies: ManagedMCPAgentCatalogDependencies

    init(
        reminders: TasksAndRemindersStore,
        machines: MachinesAndComputersStore,
        agents: AgentsRuntimeStore,
        oauth: OAuthLedger,
        dependencies: ManagedMCPAgentCatalogDependencies
    ) {
        self.reminders = reminders
        self.machines = machines
        self.agents = agents
        self.oauth = oauth
        self.dependencies = dependencies
    }

    // MARK: - Owner list (`GET /api/reminders`)

    public func listReminders(
        authorization: String?, serverId: String, ownerAgentId: String?
    ) throws -> ReminderOwnerListResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ManagedMCPAgentCatalogError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ManagedMCPAgentCatalogError.notAServerMember
        }
        let serverAgents = oauth.serverAgents(serverId: serverId)
        if let ownerAgentId, !ownerAgentId.isEmpty {
            guard let agent = serverAgents.first(where: { $0.id == ownerAgentId }) else {
                throw ManagedMCPAgentCatalogError.agentNotFound
            }
            guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
                throw ManagedMCPAgentCatalogError.forbidden
            }
            return ownerList(reminders.reminders(ownedBy: [ownerAgentId]))
        }
        let visibleAgentIds: Set<String>
        if role == "owner" || role == "admin" {
            visibleAgentIds = Set(serverAgents.map { $0.id })
        } else {
            visibleAgentIds = Set(serverAgents.filter { $0.creatorUserId == userId }.map { $0.id })
        }
        return ownerList(reminders.reminders(ownedBy: visibleAgentIds))
    }

    private func ownerList(_ rows: [ReminderRecord]) -> ReminderOwnerListResponse {
        ReminderOwnerListResponse(reminders: rows.map {
            ReminderOwnerListResponse.Item(
                id: $0.id, title: $0.title, ownerAgentId: $0.ownerAgentId, fireAt: $0.fireAt
            )
        })
    }

    // MARK: - Internal machine routes (`/internal/agent/:agentId/reminders`)

    public func legacyReminderList(
        authorization: String?, agentId: String, status: String?
    ) throws -> ReminderSummaryListResponse {
        let machine = try machineIdentity(authorization)
        guard agentOnServer(agentId, serverId: machine.serverId) != nil else {
            throw ManagedMCPAgentCatalogError.agentNotFound
        }
        return try summaryList(serverId: machine.serverId, ownerAgentId: agentId, status: status)
    }

    public func legacyReminderCreate(
        authorization: String?, agentId: String, body: ReminderCreateRequest?,
        delivery: ReminderDeliveryPreparation
    ) throws -> ReminderCreateCompletion {
        let machine = try machineIdentity(authorization)
        guard let agent = agentOnServer(agentId, serverId: machine.serverId) else {
            throw ManagedMCPAgentCatalogError.agentNotFound
        }
        if remindersMoved(serverId: machine.serverId) { throw ManagedMCPAgentCatalogError.remindersMovedToApp }
        guard agent.runtime != "external" else {
            throw ManagedMCPAgentCatalogError.externalAgentsCannotRemind
        }
        return try create(serverId: machine.serverId, ownerAgentId: agentId, body: body, delivery: delivery)
    }

    public func legacyReminderCancel(
        authorization: String?, agentId: String, reminderId: String, body: ReminderCancelRequest?
    ) throws -> ReminderEnvelopeResponse {
        _ = try machineIdentity(authorization)
        let expected = body?.expectedVersion ?? 0
        switch reminders.cancelReminder(reminderId: reminderId, ownerAgentId: agentId, expectedVersion: expected) {
        case .notFound:
            throw ManagedMCPAgentCatalogError.reminderNotFound
        case .conflict(let current):
            throw ManagedMCPAgentCatalogError.reminderVersionConflict(currentVersion: current)
        case .invalid:
            throw ManagedMCPAgentCatalogError.invalidReminderUpdate
        case .ok(let version):
            let title = reminders.reminderRow(id: reminderId)?.title ?? ""
            return ReminderEnvelopeResponse(
                reminder: ReminderSummary(id: reminderId, status: "canceled", version: version, title: title),
                ownerAgentId: agentId
            )
        }
    }

    public func legacyReminderSnooze(
        authorization: String?, agentId: String, reminderId: String, body: ReminderSnoozeRequest?
    ) throws -> ReminderEnvelopeResponse {
        let machine = try machineIdentity(authorization)
        if remindersMoved(serverId: machine.serverId) { throw ManagedMCPAgentCatalogError.remindersMovedToApp }
        guard let row = reminders.reminderRow(id: reminderId), row.status != "canceled" else {
            throw ManagedMCPAgentCatalogError.reminderNotFound
        }
        let fireAt = try resolveFireAt(body?.fireAt, body?.delaySeconds)
        return try mutationReply(
            reminders.snoozeReminder(reminderId: reminderId, ownerAgentId: agentId, expectedVersion: nil, fireAt: fireAt),
            reminderId: reminderId, ownerAgentId: agentId
        )
    }

    public func legacyReminderUpdate(
        authorization: String?, agentId: String, reminderId: String, body: ReminderUpdateRequest?
    ) throws -> ReminderEnvelopeResponse {
        let machine = try machineIdentity(authorization)
        if remindersMoved(serverId: machine.serverId) { throw ManagedMCPAgentCatalogError.remindersMovedToApp }
        guard reminders.reminderRow(id: reminderId) != nil else {
            throw ManagedMCPAgentCatalogError.reminderNotFound
        }
        guard let body else { throw ManagedMCPAgentCatalogError.invalidReminderUpdate }
        return try mutationReply(update(reminderId: reminderId, ownerAgentId: agentId, body: body),
                                 reminderId: reminderId, ownerAgentId: agentId)
    }

    public func legacyReminderLog(
        authorization: String?, agentId: String, reminderId: String
    ) throws -> ReminderLogResponse {
        _ = try machineIdentity(authorization)
        guard reminders.ownerAgentId(reminderId: reminderId) == agentId else {
            throw ManagedMCPAgentCatalogError.reminderNotFound
        }
        return eventLog(reminderId)
    }

    // MARK: - Agent-api routes (`/internal/agent-api/reminders`)

    public func agentApiReminderCancel(
        authorization: String?, reminderId: String
    ) throws -> ReminderEnvelopeResponse {
        try requireCapability(authorization, "tasks")
        let agent = try credentialAgent(authorization)
        guard reminders.reminderRow(id: reminderId) != nil else {
            throw ManagedMCPAgentCatalogError.reminderNotFound
        }
        return try mutationReply(
            reminders.cancelReminder(reminderId: reminderId, ownerAgentId: agent.id, expectedVersion: nil),
            reminderId: reminderId, ownerAgentId: agent.id
        )
    }

    public func agentApiReminderSnooze(
        authorization: String?, reminderId: String, body: ReminderSnoozeRequest?
    ) throws -> ReminderEnvelopeResponse {
        let agent = try credentialAgent(authorization)
        guard reminders.reminderRow(id: reminderId) != nil else {
            throw ManagedMCPAgentCatalogError.reminderNotFound
        }
        let fireAt = try resolveFireAt(body?.fireAt, body?.delaySeconds)
        return try mutationReply(
            reminders.snoozeReminder(reminderId: reminderId, ownerAgentId: agent.id, expectedVersion: nil, fireAt: fireAt),
            reminderId: reminderId, ownerAgentId: agent.id
        )
    }

    public func agentApiReminderUpdate(
        authorization: String?, reminderId: String, body: ReminderUpdateRequest?
    ) throws -> ReminderEnvelopeResponse {
        let agent = try credentialAgent(authorization)
        guard reminders.reminderRow(id: reminderId) != nil else {
            throw ManagedMCPAgentCatalogError.reminderNotFound
        }
        guard let body else { throw ManagedMCPAgentCatalogError.invalidReminderUpdate }
        return try mutationReply(update(reminderId: reminderId, ownerAgentId: agent.id, body: body),
                                 reminderId: reminderId, ownerAgentId: agent.id)
    }

    public func agentApiReminderLog(
        authorization: String?, reminderId: String
    ) throws -> ReminderLogResponse {
        let agent = try credentialAgent(authorization)
        guard reminders.ownerAgentId(reminderId: reminderId) == agent.id else {
            throw ManagedMCPAgentCatalogError.reminderNotFound
        }
        return eventLog(reminderId)
    }

    public func agentApiReminderList(
        authorization: String?, status: String?
    ) throws -> ReminderSummaryListResponse {
        let agent = try credentialAgent(authorization)
        return try summaryList(serverId: agent.serverId, ownerAgentId: agent.id, status: status)
    }

    public func agentApiReminderCreate(
        authorization: String?, body: ReminderCreateRequest?, delivery: ReminderDeliveryPreparation
    ) throws -> ReminderCreateCompletion {
        try requireCapability(authorization, "tasks")
        let agent = try credentialAgent(authorization)
        guard agent.runtime != "external" else {
            throw ManagedMCPAgentCatalogError.externalAgentsCannotRemind
        }
        return try create(serverId: agent.serverId, ownerAgentId: agent.id, body: body, delivery: delivery)
    }

    // MARK: - Saved message (`POST /api/channels/saved`)

    public func saveChannelMessage(
        authorization: String?, serverId: String, body: SaveChannelMessageRequest?
    ) throws -> OkResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ManagedMCPAgentCatalogError.unauthorized
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ManagedMCPAgentCatalogError.notAServerMember
        }
        guard let messageId = body?.messageId,
              oauth.saveMessage(userId: userId, messageId: messageId)
        else {
            throw ManagedMCPAgentCatalogError.messageNotFound
        }
        return OkResponse()
    }

    // MARK: - Shared steps

    /// The machine behind a bearer key.
    private func machineIdentity(_ authorization: String?) throws -> (machineId: String, serverId: String) {
        guard let authorization, authorization.hasPrefix("Bearer "),
              let machine = machines.machine(apiKey: String(authorization.dropFirst("Bearer ".count)))
        else { throw ManagedMCPAgentCatalogError.unauthorized }
        return (machine.id, machine.serverId)
    }

    private func agentOnServer(_ agentId: String, serverId: String) -> OAuthLedger.AgentRuntimeInfo? {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return nil
        }
        return agent
    }

    private func remindersMoved(serverId: String) -> Bool {
        agents.featureFlagEnabled(key: "reminder_app", serverId: serverId)
    }

    /// The live agent behind a bearer credential; the credential's use is
    /// stamped.
    private func credentialAgent(_ authorization: String?) throws -> OAuthLedger.AgentRuntimeInfo {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ManagedMCPAgentCatalogError.agentTokenInvalid
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.useAgentCredential(token: token, now: Date()),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { throw ManagedMCPAgentCatalogError.agentTokenInvalid }
        return agent
    }

    private func requireCapability(_ authorization: String?, _ capability: String) throws {
        if let denied = dependencies.deniedCapability(authorization, capability) {
            throw FeedbackLocatorError.capabilityNotAuthorized(capability: denied)
        }
    }

    /// `fireAt` when it parses as an ISO time, otherwise a non-negative
    /// `delaySeconds` from now.
    private func resolveFireAt(_ raw: String?, _ delay: Int?) throws -> Date {
        if let raw, let parsed = ISO8601DateFormatter().date(from: raw) { return parsed }
        if let delay, delay >= 0 { return dependencies.now().addingTimeInterval(Double(delay)) }
        throw ManagedMCPAgentCatalogError.fireAtRequired
    }

    private func create(
        serverId: String, ownerAgentId: String, body: ReminderCreateRequest?,
        delivery: ReminderDeliveryPreparation
    ) throws -> ReminderCreateCompletion {
        guard let title = body?.title, let request = body else {
            throw ManagedMCPAgentCatalogError.titleRequired
        }
        guard let messageId = request.msgId, !messageId.isEmpty else {
            throw ManagedMCPAgentCatalogError.messageIdRequired
        }
        let fireAt = try resolveFireAt(request.fireAt, request.delaySeconds)
        let id = reminders.createReminder(
            serverId: serverId, ownerAgentId: ownerAgentId, title: title, fireAt: fireAt,
            notes: request.notes, recurrenceJSON: request.recurrence,
            channelId: request.channelId, threadId: request.threadId,
            actorType: "agent", actorId: ownerAgentId
        )
        let response = ReminderEnvelopeResponse(
            reminder: ReminderSummary(id: id, status: "scheduled", version: 1, title: title),
            ownerAgentId: ownerAgentId
        )
        // The reminder and its scheduled record are committed before recipient
        // reads. A missing transport skips only these post-commit lookups.
        guard case .prepare = delivery,
              let agent = oauth.agentRuntimeInfo(id: ownerAgentId)
        else { return ReminderCreateCompletion(response: response, scheduledDelivery: nil) }
        var recipients: Set<String> = []
        if let creator = agent.creatorUserId { recipients.insert(creator) }
        for member in oauth.memberRoles(serverId: agent.serverId)
        where member.role == "owner" || member.role == "admin" {
            recipients.insert(member.userId)
        }
        guard !recipients.isEmpty else {
            return ReminderCreateCompletion(response: response, scheduledDelivery: nil)
        }
        return ReminderCreateCompletion(
            response: response,
            scheduledDelivery: ReminderScheduledDelivery(
                recipientUserIds: recipients,
                payload: ReminderRealtimePayload(reminderId: id, ownerAgentId: ownerAgentId)
            )
        )
    }

    private func update(
        reminderId: String, ownerAgentId: String, body: ReminderUpdateRequest
    ) -> ReminderMutationOutcome {
        let fireAt = body.fireAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return reminders.updateReminder(
            reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: nil,
            title: body.title, fireAt: fireAt, notes: body.notes
        )
    }

    private func mutationReply(
        _ outcome: ReminderMutationOutcome, reminderId: String, ownerAgentId: String
    ) throws -> ReminderEnvelopeResponse {
        switch outcome {
        case .notFound:
            throw ManagedMCPAgentCatalogError.reminderNotFound
        case .conflict(let current):
            throw ManagedMCPAgentCatalogError.reminderVersionConflict(currentVersion: current)
        case .invalid(let message):
            throw ManagedMCPAgentCatalogError.reminderMutationRefused(message)
        case .ok:
            let row = reminders.reminderRow(id: reminderId)
            return ReminderEnvelopeResponse(
                reminder: ReminderSummary(
                    id: reminderId, status: row?.status ?? "scheduled", version: row?.version ?? 0,
                    title: row?.title ?? "", ownerAgentId: ownerAgentId, fireAt: row?.fireAt
                ),
                ownerAgentId: ownerAgentId
            )
        }
    }

    private func summaryList(
        serverId: String, ownerAgentId: String, status: String?
    ) throws -> ReminderSummaryListResponse {
        let allowed: Set<String> = ["scheduled", "canceled", "fired", "all"]
        var wanted: Set<String>?
        if let status, !status.isEmpty {
            let parts = status.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty, parts.allSatisfy({ allowed.contains($0) }) else {
                throw ManagedMCPAgentCatalogError.invalidStatusFilter
            }
            if !parts.contains("all") { wanted = Set(parts) }
        }
        let rows = reminders.reminders(serverId: serverId, ownerAgentId: ownerAgentId, statuses: wanted)
        return ReminderSummaryListResponse(reminders: rows.map {
            ReminderSummary(
                id: $0.id, status: $0.status, version: $0.version, title: $0.title,
                ownerAgentId: ownerAgentId, fireAt: $0.fireAt
            )
        })
    }

    private func eventLog(_ reminderId: String) -> ReminderLogResponse {
        ReminderLogResponse(events: reminders.reminderEventLog(reminderId: reminderId).map {
            ReminderLogResponse.Event(eventType: $0.eventType, version: $0.version)
        })
    }
}
