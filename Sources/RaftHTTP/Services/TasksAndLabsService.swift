import Foundation
import RaftShared

/// Domain failure for the server task routes: the channel task reads, the
/// assignee write and the agent task amend.
///
/// Every case is one published refusal. The agent credential and grant
/// refusals of the amend route are `FeedbackLocatorError`s, thrown unchanged.
public enum TasksAndLabsError: DomainError, Equatable {
    /// The task routes' plain missing-session refusal.
    case unauthorized
    case notAMember
    case invalidTaskStatus
    case channelNotFound
    case taskNotFound
    case invalidTaskRequest
    case invalidAssignment
    case expectedRevisionNotInteger
    case assigneeNotInChannel
    case doneTaskCannotBeReassigned
    case taskChangedConcurrently(currentRevision: Int)

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .notAMember:
            403
        case .channelNotFound, .taskNotFound:
            404
        case .invalidTaskStatus, .invalidTaskRequest, .invalidAssignment, .expectedRevisionNotInteger:
            400
        case .assigneeNotInChannel, .doneTaskCannotBeReassigned, .taskChangedConcurrently:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .notAMember:
            "Not a member of this server"
        case .invalidTaskStatus:
            "status must be a single valid task status"
        case .channelNotFound:
            "Channel not found"
        case .taskNotFound:
            "Task not found"
        case .invalidTaskRequest:
            "Invalid task request"
        case .invalidAssignment:
            "Invalid assignment"
        case .expectedRevisionNotInteger:
            "expectedRevision must be an integer"
        case .assigneeNotInChannel:
            "Assignee is not in this channel"
        case .doneTaskCannotBeReassigned:
            "A done task cannot be reassigned"
        case .taskChangedConcurrently:
            "Task changed concurrently"
        }
    }

    /// The concurrent-change refusal publishes `currentRevision` after `error`.
    public var errorBody: OrderedJSON? {
        switch self {
        case .taskChangedConcurrently(let currentRevision):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("currentRevision", currentRevision),
            ])
        case .unauthorized, .notAMember, .invalidTaskStatus, .channelNotFound, .taskNotFound,
             .invalidTaskRequest, .invalidAssignment, .expectedRevisionNotInteger,
             .assigneeNotInChannel, .doneTaskCannotBeReassigned:
            nil
        }
    }
}

/// Server tasks: the channel task list and number lookup, the human assignee
/// write and the agent task amend.
///
/// The service owns the orchestration and returns the published DTOs; every
/// refusal is a `TasksAndLabsError` (or the shared `FeedbackLocatorError` for
/// the agent credential and grant checks). It builds no HTTP reply. The assignee
/// write and the amend are each one `TasksAndRemindersStore` critical section.
public struct TasksAndLabsService: Sendable {
    private let sessionUserId: @Sendable (String?) -> String?
    private let oauth: OAuthLedger
    private let tasks: TasksAndRemindersStore
    private let agentTasks: ActionCardExecuteService
    private let feedbackLocators: FeedbackLocatorService
    private let producer: AgentExecutionTaskProducer
    private let now: @Sendable () -> Date

    /// The session lookup belongs to the auth domain and enters as a closure; the
    /// agent task credential, channel resolution and freshness gate are the
    /// action-card execute service's.
    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        oauth: OAuthLedger,
        tasks: TasksAndRemindersStore,
        agentTasks: ActionCardExecuteService,
        feedbackLocators: FeedbackLocatorService,
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        profiles: AuthProfileStore,
        flags: AgentsRuntimeStore,
        execution: AgentExecutionService? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionUserId = sessionUserId
        self.oauth = oauth
        self.tasks = tasks
        self.agentTasks = agentTasks
        self.feedbackLocators = feedbackLocators
        self.producer = AgentExecutionTaskProducer(messages: messages, channels: channels, profiles: profiles, oauth: oauth, flags: flags, execution: execution)
        self.now = now
    }

    // MARK: - Shared task-channel policy

    /// The channel write policy the task routes share: a participant may write,
    /// a plain channel is readable by any server member, everything else is
    /// invisible.
    static func channelAccess(
        oauth: OAuthLedger,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        flags: AgentsRuntimeStore,
        serverId: String,
        channelId: String,
        userId: String
    ) -> TaskChannelAccess {
        let reads = HumanChannelReadAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: flags)
        guard reads.authority(channelId: channelId, serverId: serverId, userId: userId) != nil else { return .missing }
        // Node authorizeTaskAction makes Guest read-only for every mutation.
        if oauth.memberRole(serverId: serverId, userId: userId) == "guest" { return .readOnly }
        return oauth.isChannelParticipant(channelId: channelId, userId: userId) ? .write : .readOnly
    }

    /// The `?status=` filter: no occurrence is no filter, more than one or an
    /// unknown value is invalid.
    enum StatusFilter: Equatable {
        case valid(String?)
        case invalid
    }

    static func statusFilter(_ rawQuery: String?) -> StatusFilter {
        guard let rawQuery else { return .valid(nil) }
        let statusOccurrences = rawQuery.split(separator: "&").filter { $0.hasPrefix("status=") }
        guard statusOccurrences.count <= 1 else { return .invalid }
        guard let occurrence = statusOccurrences.first else { return .valid(nil) }
        let value = String(occurrence.dropFirst("status=".count)).removingPercentEncoding ?? ""
        guard TaskCatalogPolicy.validTaskStatuses.contains(value) else { return .invalid }
        return .valid(value)
    }

    // MARK: - GET /api/tasks/channel/:channelId

    public func listChannelTasks(
        authorization: String?,
        serverId: String,
        channelId: String,
        rawQuery: String?
    ) throws -> ChannelTaskListResponse {
        guard let userId = sessionUserId(authorization) else { throw TasksAndLabsError.unauthorized }
        guard !serverId.isEmpty else { throw MessageSendError.missingServerId }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId) else {
            throw TasksAndLabsError.notAMember
        }
        let status: String?
        switch Self.statusFilter(rawQuery) {
        case .invalid: throw TasksAndLabsError.invalidTaskStatus
        case .valid(let value): status = value
        }
        switch Self.channelAccess(oauth: oauth, channels: producer.channels, messages: producer.messages, flags: producer.flags, serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: throw TasksAndLabsError.channelNotFound
        case .readOnly, .write: break
        }
        guard let surface = producer.surfaces(for: channelId).first(where: { $0.channelId == channelId && $0.serverId == serverId }) else {
            throw TasksAndLabsError.channelNotFound
        }
        let rows = tasks.tasks(channelId: producer.storageChannelId(channelId), status: status)
        return ChannelTaskListResponse(tasks: rows.map { producer.project($0, to: surface).projection })
    }

    // MARK: - GET /api/tasks/channel/:channelId/number/:taskNumber

    public func getChannelTaskByNumber(
        authorization: String?,
        serverId: String,
        channelId: String,
        taskNumber: Int
    ) throws -> ChannelTaskResponse {
        guard let userId = sessionUserId(authorization) else { throw TasksAndLabsError.unauthorized }
        guard !serverId.isEmpty else { throw MessageSendError.missingServerId }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId) else {
            throw TasksAndLabsError.notAMember
        }
        switch Self.channelAccess(oauth: oauth, channels: producer.channels, messages: producer.messages, flags: producer.flags, serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: throw TasksAndLabsError.channelNotFound
        case .readOnly, .write: break
        }
        guard let surface = producer.surfaces(for: channelId).first(where: { $0.channelId == channelId && $0.serverId == serverId }),
              let task = tasks.task(channelId: producer.storageChannelId(channelId), taskNumber: taskNumber) else {
            throw TasksAndLabsError.taskNotFound
        }
        return ChannelTaskResponse(task: producer.project(task, to: surface).projection)
    }

    // MARK: - GET /api/tasks/:taskId/history

    /// The canonical append-only task timeline.
    ///
    /// Order mirrors upstream `routes/tasks.ts`: the global auth/verification/
    /// server middleware, then `requireTaskInServer`'s task + channel read
    /// checks. A legacy task (no host message / no canonical row) answers the
    /// service's 409 message; canonical events come only from rows that carry
    /// the complete `task_events` group.
    public func taskHistory(
        authorization: String?,
        serverId: String,
        taskId: String
    ) throws -> TaskHistoryResponse {
        guard let userId = sessionUserId(authorization) else {
            throw TaskHistoryError.authRequired(bearerPresent: authorization?.hasPrefix("Bearer ") == true)
        }
        guard producer.profiles.isEmailVerified(userId: userId) else {
            throw TaskHistoryError.emailVerificationRequired
        }
        guard !serverId.isEmpty else { throw TaskHistoryError.missingServerId }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId) else {
            throw TaskHistoryError.notServerMember
        }
        guard let task = tasks.task(id: taskId),
              producer.readableTaskSurface(task, serverId: serverId, userId: userId) != nil
        else {
            throw TaskHistoryError.taskNotFound
        }
        guard task.hasHostMessage else { throw TaskHistoryError.legacyTask }
        return TaskHistoryResponse(events: canonicalTaskEvents(taskId: task.id))
    }

    /// The `task_events` projection both the human and the agent history reads
    /// publish. Rows without the complete event group are skipped; an
    /// unresolvable actor keeps `actorName` null rather than inventing a name.
    func canonicalTaskEvents(taskId: String) -> [TaskHistoryEventDTO] {
        tasks.publishedTaskEvents(taskId: taskId).compactMap { record -> TaskHistoryEventDTO? in
            guard let history = record.history else { return nil }
            return TaskHistoryEventDTO(
                id: history.id,
                seq: history.seq,
                eventType: record.eventType,
                actorType: record.actorType,
                actorName: Self.taskHistoryActorName(
                    type: record.actorType, id: history.actorId, oauth: oauth, profiles: producer.profiles),
                payloadJSON: history.payloadJSON,
                createdAt: DateText.isoString(history.createdAt)
            )
        }
    }

    // MARK: - GET /internal/agent-api/tasks/history

    /// The credential-surface task history read.
    ///
    /// Order: credential capability (`tasks`), the `task:read` grant, the
    /// channel reference (404 `Agent or channel not found`), the task row
    /// (404 `Task not found`), then the canonical-only guard (409). The
    /// request validator has already guaranteed `channel` and a positive
    /// `task_number`.
    public func agentTaskHistory(
        authorization: String?,
        legacyAgentId: String?,
        channelRef: String,
        taskNumber: Int
    ) throws -> AgentTaskHistoryResponse {
        let identity = try agentTasks.taskAuth(authorization: authorization, legacyAgentId: legacyAgentId)
        switch feedbackLocators.grantDecision(agentId: identity.agentId, scope: "task:read") {
        case .allowed: break
        case .missingScope(let scope): throw FeedbackLocatorError.missingScope(scope: scope)
        }
        let channelId = try agentTasks.resolvedTaskChannel(
            serverId: identity.serverId, agentId: identity.agentId, reference: channelRef
        )
        guard let task = tasks.task(channelId: channelId, taskNumber: taskNumber) else {
            throw AgentTaskApiError.taskNotFound
        }
        guard task.hasHostMessage else { throw AgentTaskApiError.legacyTaskHistory }
        return AgentTaskHistoryResponse(
            task: AgentTaskCardProjection(
                taskNumber: task.taskNumber,
                title: task.title,
                description: task.description,
                revision: task.revision
            ),
            events: canonicalTaskEvents(taskId: task.id)
        )
    }

    // MARK: - GET /internal/agent/:id/tasks (legacy machine surface)

    /// The legacy machine task list. `LegacyAgentSurfaceService` has already
    /// authenticated the machine and checked the `task:read` grant; this method
    /// owns the channel resolution, the `?status` filter and the projection.
    public func legacyAgentTasks(
        agent: OAuthLedger.AgentRuntimeInfo,
        channelRef: String,
        rawQuery: String?
    ) throws -> LegacyAgentTaskListResponse {
        guard let channelId = agentTasks.taskChannel(
            serverId: agent.serverId, agentId: agent.id, reference: channelRef
        ) else {
            throw AgentTaskApiError.agentOrChannelNotFound
        }
        guard let surface = producer.surfaces(for: channelId).first(where: {
            $0.channelId == channelId && $0.serverId == agent.serverId
        }) else {
            throw AgentTaskApiError.agentOrChannelNotFound
        }
        let status: String?
        switch Self.statusFilter(rawQuery) {
        case .invalid: throw AgentTaskApiError.invalidStatusFilter
        case .valid(let value): status = value
        }
        let rows = tasks.tasks(channelId: producer.storageChannelId(channelId), status: status)
        return LegacyAgentTaskListResponse(tasks: rows.map { row in
            LegacyAgentTaskProjection(base: producer.project(row, to: surface).projection)
        })
    }

    private static func taskHistoryActorName(
        type: String, id: String?, oauth: OAuthLedger, profiles: AuthProfileStore
    ) -> String? {
        guard let id else { return nil }
        switch type {
        case "user": return profiles.account(userId: id)?.name
        case "agent": return oauth.agentRuntimeInfo(id: id)?.name
        default: return nil
        }
    }

    // MARK: - POST /internal/agent-api/tasks/amend

    /// Amends one task's title and description.
    ///
    /// The credential and the `task:write` grant are checked first. The freshness
    /// gate is evaluated twice, exactly as the retired handler did; a held write
    /// answers `200` with the hold body and changes nothing.
    public func amendTask(
        authorization: String?,
        legacyAgentId: String?,
        body: AgentTaskAmendRequest?
    ) throws -> AgentTaskAmendResponse {
        let auth = try agentTasks.taskAuth(authorization: authorization, legacyAgentId: legacyAgentId)
        switch feedbackLocators.grantDecision(agentId: auth.agentId, scope: "task:write") {
        case .allowed: break
        case .missingScope(let scope): throw FeedbackLocatorError.missingScope(scope: scope)
        }
        guard let body,
              let channelRef = body.channel,
              let taskNumber = body.taskNumber,
              let title = body.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else {
            throw TasksAndLabsError.invalidTaskRequest
        }
        let channelId = try agentTasks.resolvedTaskChannel(
            serverId: auth.serverId, agentId: auth.agentId, reference: channelRef
        )
        try agentTasks.requireTaskWritable(
            serverId: auth.serverId, agentId: auth.agentId, channelId: channelId
        )
        for _ in 0..<2 {
            if let hold = agentTasks.taskWriteHold(
                agentId: auth.agentId, channelId: channelId,
                seenUpToSeq: body.seenUpToSeq, actionKey: "amend:\(taskNumber)"
            ) {
                return .held(hold)
            }
        }
        guard let task = tasks.amendTask(
            channelId: channelId,
            taskNumber: taskNumber,
            title: title,
            description: body.description,
            actorId: auth.agentId,
            amendedByName: oauth.agentRuntimeInfo(id: auth.agentId)?.name ?? "agent",
            now: now()
        ) else {
            throw TasksAndLabsError.taskNotFound
        }
        return .amended(ActionCardTaskPayload(task))
    }

    public func bindingExecution(_ execution: AgentExecutionService?) -> Self {
        Self(sessionUserId: sessionUserId, oauth: oauth, tasks: tasks, agentTasks: agentTasks,
             feedbackLocators: feedbackLocators, messages: producer.messages, channels: producer.channels,
             profiles: producer.profiles, flags: producer.flags, execution: execution, now: now)
    }

    // MARK: - PATCH /api/tasks/:taskId/assignee

    /// Reassigns (or clears) one task.
    ///
    /// The body shape is checked before the task lookup, the membership and
    /// channel-visibility checks before the assignee checks. The done check, the
    /// expected-revision check and the write are one store critical section.
    public func assignTask(
        authorization: String?,
        serverId: String,
        taskId: String,
        body: TaskAssigneePatchRequest?
    ) throws -> CanonicalTaskResponse {
        guard let userId = sessionUserId(authorization) else { throw TasksAndLabsError.unauthorized }
        guard !serverId.isEmpty else { throw MessageSendError.missingServerId }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId) else {
            throw TasksAndLabsError.notAMember
        }
        guard let existing = tasks.task(id: taskId),
              let local = producer.readableTaskSurface(existing, serverId: serverId, userId: userId)
        else { throw TasksAndLabsError.taskNotFound }
        if producer.channels.postableChannel(id: local.channelId)?.deletedAt != nil {
            throw ManagedMCPAssignmentsError.channelDeletedTerminalOnly
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != "guest",
              oauth.isChannelParticipant(channelId: local.channelId, userId: userId)
        else { throw ManagedMCPAssignmentsError.joinChannelToChangeTasks }
        guard oauth.channelArchivedAt(id: local.channelId) == nil else { throw ChannelMembershipError.channelArchived }
        guard let body else { throw TasksAndLabsError.invalidAssignment }
        let assignee: (type: String, id: String)?
        switch body.assignee {
        case .absent, .invalid: throw TasksAndLabsError.invalidAssignment
        case .cleared: assignee = nil
        case .set(let type, let id): assignee = (type, id)
        }
        let expectedRevision: Int?
        switch body.expectedRevision {
        case .none: expectedRevision = nil
        case .value(let value): expectedRevision = value
        case .invalid: throw TasksAndLabsError.expectedRevisionNotInteger
        }
        let channelId = local.channelId
        if let assignee {
            guard producer.assigneeEligible(type: assignee.type, id: assignee.id,
                taskChannelId: existing.channelId, local: local)
            else { throw TasksAndLabsError.assigneeNotInChannel }
        }
        guard let noticeSurface = producer.assignmentNoticeSurface(taskChannelId: existing.channelId,
            assigneeType: assignee?.type, assigneeId: assignee?.id, caller: local)
        else { throw TasksAndLabsError.assigneeNotInChannel }
        let surfaces = producer.surfaces(for: channelId)
        if let assignee, assignee.type == "agent", oauth.agentRuntimeInfo(id: assignee.id)?.runtime == "codex",
           existing.assigneeId != assignee.id || existing.assigneeType != assignee.type {
            try producer.requireDeliveryTransaction(surfaces: [], assigneeId: assignee.id)
        }
        switch tasks.reassign(
            taskId: taskId,
            assigneeId: assignee?.id,
            assigneeType: assignee?.type,
            expectedRevision: expectedRevision,
            actorId: userId, now: now()
        ) {
        case .notFound:
            throw TasksAndLabsError.taskNotFound
        case .done:
            throw TasksAndLabsError.doneTaskCannotBeReassigned
        case .conflict(let currentRevision):
            throw TasksAndLabsError.taskChangedConcurrently(currentRevision: currentRevision)
        case .unchanged(let task):
            return CanonicalTaskResponse(task: producer.project(task, to: local))
        case .reassigned(let task):
            do {
                let relay = RealtimeRelayService(messages: producer.messages)
                for surface in surfaces {
                    let payload = OrderedJSON.object([.init("channelId", surface.channelId), .init("task", producer.project(task, to: surface).jsonBody)])
                    try AgentExecutionPublication.publish(room: "channel:\(surface.channelId)", event: "task:updated",
                        identity: "\(task.id):\(task.revision)", payloadJSON: payload.render(), emit: { relay.emit($0, $1, $2) })
                }
                try producer.assignmentNotice(task: task, surface: noticeSurface, actorId: userId)
            } catch {
                DeferredEffects.markRollbackOnly()
                if let error = error as? AgentExecutionError {
                    throw AgentExecutionProducerError(operation: "assign task", underlying: error)
                }
                throw error
            }
            return CanonicalTaskResponse(task: producer.project(task, to: local))
        }
    }
}
