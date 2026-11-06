import Foundation

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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionUserId = sessionUserId
        self.oauth = oauth
        self.tasks = tasks
        self.agentTasks = agentTasks
        self.feedbackLocators = feedbackLocators
        self.now = now
    }

    // MARK: - Shared task-channel policy

    /// The channel write policy the task routes share: a participant may write,
    /// a plain channel is readable by any server member, everything else is
    /// invisible.
    static func channelAccess(
        oauth: OAuthLedger,
        serverId: String,
        channelId: String,
        userId: String
    ) -> TaskChannelAccess {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return .missing
        }
        if oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return .write
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        return type == "channel" ? .readOnly : .missing
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
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw TasksAndLabsError.notAMember
        }
        let status: String?
        switch Self.statusFilter(rawQuery) {
        case .invalid: throw TasksAndLabsError.invalidTaskStatus
        case .valid(let value): status = value
        }
        switch Self.channelAccess(oauth: oauth, serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: throw TasksAndLabsError.channelNotFound
        case .readOnly, .write: break
        }
        let rows = tasks.tasks(channelId: channelId, status: status)
        return ChannelTaskListResponse(tasks: rows.map(ActionCardTaskPayload.init))
    }

    // MARK: - GET /api/tasks/channel/:channelId/number/:taskNumber

    public func getChannelTaskByNumber(
        authorization: String?,
        serverId: String,
        channelId: String,
        taskNumber: Int
    ) throws -> ChannelTaskResponse {
        guard let userId = sessionUserId(authorization) else { throw TasksAndLabsError.unauthorized }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw TasksAndLabsError.notAMember
        }
        switch Self.channelAccess(oauth: oauth, serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: throw TasksAndLabsError.channelNotFound
        case .readOnly, .write: break
        }
        guard let task = tasks.task(channelId: channelId, taskNumber: taskNumber) else {
            throw TasksAndLabsError.taskNotFound
        }
        return ChannelTaskResponse(task: ActionCardTaskPayload(task))
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
              let channelId = agentTasks.taskChannel(
                  serverId: auth.serverId, agentId: auth.agentId, reference: channelRef
              ),
              let taskNumber = body.taskNumber,
              let title = body.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else {
            throw TasksAndLabsError.invalidTaskRequest
        }
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
            amendedByName: oauth.agentRuntimeInfo(id: auth.agentId)?.name ?? "agent",
            now: now()
        ) else {
            throw TasksAndLabsError.taskNotFound
        }
        return .amended(ActionCardTaskPayload(task))
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
    ) throws -> ActionCardTaskPayload {
        guard let userId = sessionUserId(authorization) else { throw TasksAndLabsError.unauthorized }
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
        guard let existing = tasks.task(id: taskId) else { throw TasksAndLabsError.taskNotFound }
        let channelId = existing.channelId
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw TasksAndLabsError.notAMember
        }
        if (oauth.channelType(id: channelId) ?? "channel") != "channel",
           !oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            throw TasksAndLabsError.taskNotFound
        }
        if let assignee {
            if assignee.type == "user" {
                guard oauth.isChannelParticipant(channelId: channelId, userId: assignee.id),
                      oauth.memberRole(serverId: serverId, userId: assignee.id) != nil
                else {
                    throw TasksAndLabsError.assigneeNotInChannel
                }
            } else {
                guard let agent = oauth.agentRuntimeInfo(id: assignee.id),
                      agent.serverId == serverId, !agent.deleted
                else {
                    throw TasksAndLabsError.assigneeNotInChannel
                }
            }
        }
        switch tasks.reassign(
            taskId: taskId,
            assigneeId: assignee?.id,
            assigneeType: assignee?.type,
            expectedRevision: expectedRevision,
            actorId: userId
        ) {
        case .notFound:
            throw TasksAndLabsError.taskNotFound
        case .done:
            throw TasksAndLabsError.doneTaskCannotBeReassigned
        case .conflict(let currentRevision):
            throw TasksAndLabsError.taskChangedConcurrently(currentRevision: currentRevision)
        case .unchanged(let task), .reassigned(let task):
            return ActionCardTaskPayload(task)
        }
    }
}
