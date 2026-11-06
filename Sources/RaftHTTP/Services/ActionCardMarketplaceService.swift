import Foundation
import RaftShared

/// The idempotency seam for `POST /internal/agent-api/tasks`.
///
/// The retired handler reused the agent-API idempotency ledger, which is keyed
/// by `(agent, route, idempotencyKey)` and fingerprints the raw JSON object.
/// That ledger still belongs to the unmigrated managed-MCP catalog, so the
/// service takes a small typed port: the directory supplies a parse+lookup and
/// a store closure, and no untyped dictionary or reply surface leaks into this
/// file.
public struct ActionCardTaskIdempotency: Sendable {
    public enum Lookup: Sendable, Equatable {
        /// No stored key for this `(agent, route)`.
        case miss
        /// A stored 200 body for the same request; published unchanged.
        case replay(body: String)
        /// The key was used for a different request; the published 409 body.
        case conflict(body: String)
    }

    public var lookup: @Sendable (_ agentId: String, _ route: String, _ rawBody: String) -> Lookup
    public var store: @Sendable (_ agentId: String, _ route: String, _ rawBody: String, _ body: String) -> Void

    public init(
        lookup: @escaping @Sendable (String, String, String) -> Lookup,
        store: @escaping @Sendable (String, String, String, String) -> Void
    ) {
        self.lookup = lookup
        self.store = store
    }

    /// A port that never replays; useful for callers that do not wire the
    /// legacy ledger.
    public static let disabled = ActionCardTaskIdempotency(
        lookup: { _, _, _ in .miss },
        store: { _, _, _, _ in }
    )
}

/// Domain failure for the agent task and inbox operations.
///
/// Every case publishes the exact bytes the retired handler built: the shared
/// `{"error","code"}` credential refusals, the scope refusal, the task-specific
/// objects, and the inbox 503. `Respond.swift` prints `errorBody` verbatim.
public enum ActionCardMarketplaceError: DomainError, Equatable {
    case missingAuthorization
    case invalidToken
    case invalidAgentCredential
    case capabilityNotAuthorized(capability: String)
    case missingScope(scope: String)
    case invalidTaskDeleteRequest
    case invalidTaskConvertRequest
    case invalidTaskRequest
    case invalidResourceReceipt
    case invalidTaskAssignRequest
    case taskNotFound
    case taskNotFoundForAssignment
    case messageNotFound
    case messageAlreadyTask
    case assigneeNotAssignable
    case taskDeleteForbidden
    case inboxUnavailable
    case invalidInboxView
    case invalidInboxLimit
    case invalidBeforeSeq
    case idempotencyKeyReused(body: String)

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidToken, .invalidAgentCredential:
            401
        case .capabilityNotAuthorized, .missingScope, .taskDeleteForbidden:
            403
        case .taskNotFound, .taskNotFoundForAssignment, .messageNotFound, .assigneeNotAssignable:
            404
        case .messageAlreadyTask, .idempotencyKeyReused:
            409
        case .inboxUnavailable:
            503
        case .invalidTaskDeleteRequest, .invalidTaskConvertRequest, .invalidTaskRequest,
             .invalidResourceReceipt, .invalidTaskAssignRequest, .invalidInboxView,
             .invalidInboxLimit, .invalidBeforeSeq:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidToken:
            "Invalid or expired token"
        case .invalidAgentCredential:
            "Invalid agent credential"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .missingScope:
            "missing required scope"
        case .invalidTaskDeleteRequest:
            "Invalid task delete request"
        case .invalidTaskConvertRequest:
            "Invalid task convert request"
        case .invalidTaskRequest:
            "Invalid task request"
        case .invalidResourceReceipt:
            "Invalid resource receipt"
        case .invalidTaskAssignRequest:
            "Invalid task assign request"
        case .taskNotFound, .taskNotFoundForAssignment:
            "Task not found"
        case .messageNotFound:
            "Message not found"
        case .messageAlreadyTask:
            "Message is already a task"
        case .assigneeNotAssignable:
            "Assignee is not assignable"
        case .taskDeleteForbidden:
            "Only the task creator can delete it"
        case .inboxUnavailable:
            "The agent inbox is unavailable"
        case .invalidInboxView:
            "view must be unread or mentions"
        case .invalidInboxLimit:
            "limit must be between 1 and 100"
        case .invalidBeforeSeq:
            "before_seq must be a positive integer"
        case .idempotencyKeyReused:
            "This idempotencyKey was already used for a different request"
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .missingAuthorization:
            return Self.credentialBody(error: "Missing or invalid Authorization header", code: "auth_required")
        case .invalidToken:
            return Self.credentialBody(error: "Invalid or expired token", code: "auth_required")
        case .invalidAgentCredential:
            return Self.credentialBody(error: "Invalid agent credential", code: "auth_required")
        case .capabilityNotAuthorized(let capability):
            var body = OrderedJSONObject()
            body.append("error", "Agent credential is not authorized for this capability")
            body.append("code", "capability_not_authorized")
            body.append("requiredCapability", capability)
            return body.json
        case .missingScope(let scope):
            var body = OrderedJSONObject()
            body.append("error", "missing required scope")
            body.append("requiredScope", scope)
            body.append("reason", "missing_scope")
            return body.json
        case .taskNotFoundForAssignment:
            var body = OrderedJSONObject()
            body.append("error", "Task not found")
            body.append("code", "assignee_not_assignable")
            return body.json
        case .assigneeNotAssignable:
            var body = OrderedJSONObject()
            body.append("error", "Assignee is not assignable")
            body.append("code", "assignee_not_assignable")
            return body.json
        case .taskDeleteForbidden:
            var body = OrderedJSONObject()
            body.append("error", "Only the task creator can delete it")
            body.append("code", "task_delete_forbidden")
            return body.json
        case .inboxUnavailable:
            var body = OrderedJSONObject()
            body.append("error", "The agent inbox is unavailable")
            body.append("code", "INBOX_UNAVAILABLE")
            body.append("suggestedNextAction", "Retry after the inbox service recovers.")
            return body.json
        case .idempotencyKeyReused(let body):
            return .raw(body)
        case .invalidTaskDeleteRequest, .invalidTaskConvertRequest, .invalidTaskRequest,
             .invalidResourceReceipt, .invalidTaskAssignRequest, .taskNotFound, .messageNotFound,
             .messageAlreadyTask, .invalidInboxView, .invalidInboxLimit, .invalidBeforeSeq:
            return nil
        }
    }

    private static func credentialBody(error: String, code: String) -> OrderedJSON {
        var body = OrderedJSONObject()
        body.append("error", error)
        body.append("code", code)
        return body.json
    }
}

/// Agent task create/convert/delete/assign/resource-receipt plus the agent
/// inbox conversation list.
///
/// The row state lives in `TasksAndRemindersStore`, `MessagesAndThreadsStore`,
/// `InboxFactStore`, `ServersAndChannelsStore`, `AuthProfileStore`,
/// `AgentsRuntimeStore` and `ManagedMCPAndCardsStore`; every read-modify-write
/// that used to run under the directory lock is one store critical section.
/// This type returns ordered DTOs and throws `ActionCardMarketplaceError`
/// instead of building a reply, and reads the OAuth ledger for authorization.
public struct ActionCardMarketplaceService: Sendable {
    private let tasks: TasksAndRemindersStore
    private let messages: MessagesAndThreadsStore
    private let inboxFacts: InboxFactStore
    private let channels: ServersAndChannelsStore
    private let accounts: AuthProfileStore
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let cards: ManagedMCPAndCardsStore
    private let oauth: OAuthLedger
    /// The typed credential/grant decisions of the selected feedback-locator
    /// domain. The slice only calls its pure decision functions.
    private let locator: FeedbackLocatorService
    private let idempotency: ActionCardTaskIdempotency
    /// Bridges the directory's message-append policy; the message ledger is
    /// owned by an unmigrated domain and still mirrors into the OAuth ledger.
    private let appendHumanMessage: @Sendable (StoredHumanMessage) -> Int
    /// Legacy `serializeJSON` for the resource-receipt notes payload.
    private let serializeReceipt: @Sendable (JSONValue) -> String
    private let now: @Sendable () -> Date
    private let makeId: @Sendable () -> String

    init(
        tasks: TasksAndRemindersStore,
        messages: MessagesAndThreadsStore,
        inboxFacts: InboxFactStore,
        channels: ServersAndChannelsStore,
        accounts: AuthProfileStore,
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        cards: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        locator: FeedbackLocatorService,
        idempotency: ActionCardTaskIdempotency = .disabled,
        appendHumanMessage: @escaping @Sendable (StoredHumanMessage) -> Int,
        serializeReceipt: @escaping @Sendable (JSONValue) -> String,
        now: @escaping @Sendable () -> Date = { Date() },
        makeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.tasks = tasks
        self.messages = messages
        self.inboxFacts = inboxFacts
        self.channels = channels
        self.accounts = accounts
        self.agents = agents
        self.machines = machines
        self.cards = cards
        self.oauth = oauth
        self.locator = locator
        self.idempotency = idempotency
        self.appendHumanMessage = appendHumanMessage
        self.serializeReceipt = serializeReceipt
        self.now = now
        self.makeId = makeId
    }

    // MARK: - POST /internal/agent-api/tasks/delete
    //          POST /internal/agent/:agentId/tasks/delete

    public func deleteTask(
        authorization: String?,
        body: AgentTaskDeleteRequest?,
        legacyAgentId: String? = nil
    ) throws -> ActionCardTaskDeleteResponse {
        if let denial = capabilityDenial(authorization, required: "tasks") { throw denial }
        guard let writer = taskWriter(authorization, legacyAgentId: legacyAgentId) else {
            throw ActionCardMarketplaceError.invalidToken
        }
        if let denial = grantDenial(agentId: writer.agentId, scope: "task:write") { throw denial }
        guard let body,
              let channelRef = body.channel,
              let channelId = taskChannel(
                  serverId: writer.serverId,
                  agentId: writer.agentId,
                  reference: channelRef
              ),
              let taskNumber = body.taskNumber
        else {
            throw ActionCardMarketplaceError.invalidTaskDeleteRequest
        }
        let isAdmin = oauth.agentRole(serverId: writer.serverId, agentId: writer.agentId) == "admin"
        switch tasks.deleteTask(
            channelId: channelId,
            taskNumber: taskNumber,
            agentId: writer.agentId,
            isAdmin: isAdmin
        ) {
        case .notFound:
            throw ActionCardMarketplaceError.taskNotFound
        case .forbidden:
            throw ActionCardMarketplaceError.taskDeleteForbidden
        case .deleted:
            return ActionCardTaskDeleteResponse()
        }
    }

    // MARK: - POST /internal/agent-api/tasks/convert
    //          POST /internal/agent/:agentId/tasks/convert

    public func convertTask(
        authorization: String?,
        body: AgentTaskConvertRequest?,
        legacyAgentId: String? = nil
    ) throws -> ActionCardTaskConvertResponse {
        if let denial = capabilityDenial(authorization, required: "tasks") { throw denial }
        guard let writer = taskWriter(authorization, legacyAgentId: legacyAgentId) else {
            throw ActionCardMarketplaceError.invalidToken
        }
        if let denial = grantDenial(agentId: writer.agentId, scope: "task:write") { throw denial }
        guard let body,
              let channelRef = body.channel,
              let channelId = taskChannel(
                  serverId: writer.serverId,
                  agentId: writer.agentId,
                  reference: channelRef
              ),
              let messageRef = body.messageId
        else {
            throw ActionCardMarketplaceError.invalidTaskConvertRequest
        }
        guard let message = messages.messageForConvert(prefix: messageRef, channelId: channelId) else {
            throw ActionCardMarketplaceError.messageNotFound
        }
        switch tasks.convertMessage(
            channelId: channelId,
            messageId: message.id,
            creatorId: writer.agentId,
            now: now()
        ) {
        case .alreadyTask:
            throw ActionCardMarketplaceError.messageAlreadyTask
        case .created(let record):
            return ActionCardTaskConvertResponse(task: record)
        }
    }

    // MARK: - POST /internal/agent-api/tasks
    //          POST /internal/agent/:agentId/tasks

    public func createTasks(
        authorization: String?,
        body: AgentTaskCreateRequest?,
        rawBody: String,
        legacyAgentId: String? = nil
    ) throws -> ActionCardTaskCreateResponse {
        if let denial = capabilityDenial(authorization, required: "tasks") { throw denial }
        let auth: (agentId: String, serverId: String)
        switch taskAuth(authorization, legacyAgentId: legacyAgentId) {
        case .missingAuthorization:
            throw ActionCardMarketplaceError.missingAuthorization
        case .invalidCredential:
            throw ActionCardMarketplaceError.invalidToken
        case .ok(let agentId, let serverId):
            auth = (agentId, serverId)
        }
        if let denial = grantDenial(agentId: auth.agentId, scope: "task:write") { throw denial }
        guard let body,
              let channelRef = body.channel,
              let channelId = taskChannel(
                  serverId: auth.serverId,
                  agentId: auth.agentId,
                  reference: channelRef
              ),
              body.hasTasksKey,
              body.hasValidTasks
        else {
            throw ActionCardMarketplaceError.invalidTaskRequest
        }
        if let replay = try idempotencyReplay(agentId: auth.agentId, rawBody: rawBody) {
            return replay
        }
        let titles = body.tasks.compactMap { task -> String? in
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        guard !titles.isEmpty, titles.count == body.tasks.count else {
            throw ActionCardMarketplaceError.invalidTaskRequest
        }
        var assignee: (id: String, type: String, name: String)?
        if let rawAssignee = body.assignee, !rawAssignee.isEmpty {
            guard let resolved = resolveAssignee(
                channelId: channelId,
                rawAssignee: rawAssignee
            ) else {
                throw ActionCardMarketplaceError.assigneeNotAssignable
            }
            assignee = resolved
        }
        let created = tasks.appendTaskBatch(
            channelId: channelId,
            titles: titles,
            creatorId: auth.agentId,
            now: now()
        )
        let ids = created.map(\.id)
        let resourceFlags = body.tasks.map(\.createsResource)
        if resourceFlags.contains(true) {
            tasks.markRequiresResourceReceipt(taskIds: ids, flags: resourceFlags)
        }
        var receipt: ActionCardTaskAssignmentReceipt?
        if let assignee {
            let updated = tasks.applyAssignment(
                taskIds: ids,
                assigneeId: assignee.id,
                assigneeType: assignee.type
            )
            for task in updated {
                inboxFacts.append(StoredInboxFact(
                    messageId: task.messageId,
                    receiverType: assignee.type,
                    receiverId: assignee.id,
                    channelId: channelId,
                    serverId: auth.serverId,
                    personalMention: true,
                    unreadEligible: true
                ))
            }
            let receiptId = makeId()
            let receiptContent = "@\(assignee.name) assigned you: \(titles.first ?? "task")"
            _ = appendHumanMessage(StoredHumanMessage(
                id: receiptId,
                channelId: channelId,
                senderId: auth.agentId,
                content: receiptContent,
                randomId: nil,
                messageType: "task_assignment",
                senderType: "agent"
            ))
            inboxFacts.append(StoredInboxFact(
                messageId: receiptId,
                receiverType: assignee.type,
                receiverId: assignee.id,
                channelId: channelId,
                serverId: auth.serverId,
                personalMention: true,
                unreadEligible: true
            ))
            receipt = ActionCardTaskAssignmentReceipt(
                messageId: receiptId,
                content: receiptContent,
                assignee: "@\(assignee.name)"
            )
        }
        let rows = tasks.tasks(ids: ids)
        let response = ActionCardTaskCreateResponse(
            taskIds: ids,
            tasks: rows,
            assignmentReceipt: receipt
        )
        idempotency.store(auth.agentId, "taskCreate", rawBody, response.jsonBody.render())
        return response
    }

    // MARK: - POST /internal/agent-api/tasks/resource-receipt

    public func resourceReceipt(
        authorization: String?,
        body: AgentTaskResourceReceiptRequest?
    ) throws -> ActionCardTaskResourceReceiptResponse {
        guard let writer = taskWriter(authorization, legacyAgentId: nil) else {
            throw ActionCardMarketplaceError.invalidToken
        }
        if let denial = grantDenial(agentId: writer.agentId, scope: "task:write") { throw denial }
        guard let body,
              let channelRef = body.channel,
              let channelId = taskChannel(
                  serverId: writer.serverId,
                  agentId: writer.agentId,
                  reference: channelRef
              ),
              let taskNumber = body.taskNumber,
              let receipt = body.receipt
        else {
            throw ActionCardMarketplaceError.invalidResourceReceipt
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = formatter.date(from: receipt.expiry) else {
            throw ActionCardMarketplaceError.invalidResourceReceipt
        }
        let receiptJSON = serializeReceipt(receipt.payload)
        let reminder = ReminderRecord(
            id: makeId(),
            serverId: writer.serverId,
            ownerAgentId: writer.agentId,
            title: "Resource receipt expiry: \(receipt.object)",
            fireAt: expiry,
            notes: receiptJSON,
            channelId: channelId
        )
        let stored: (task: TaskRecord, reminder: ReminderRecord)
        switch tasks.storeResourceReceipt(
            channelId: channelId,
            taskNumber: taskNumber,
            receiptJSON: receiptJSON,
            reminder: reminder
        ) {
        case .notFound:
            throw ActionCardMarketplaceError.taskNotFound
        case .stored(let task, let reminder):
            stored = (task, reminder)
        }
        let agentName = oauth.agentRuntimeInfo(id: writer.agentId)?.name ?? "agent"
        return ActionCardTaskResourceReceiptResponse(
            taskNumber: stored.task.taskNumber,
            expiryFollowup: ActionCardTaskExpiryFollowup(
                ownerAgentId: writer.agentId,
                owner: "@\(agentName)",
                msgId: stored.task.messageId,
                targetChannelId: channelId,
                reminderId: stored.reminder.id,
                fireAt: receipt.expiry
            )
        )
    }

    // MARK: - POST /internal/agent-api/tasks/assign

    public func assignTask(
        authorization: String?,
        body: AgentTaskAssignRequest?
    ) throws -> ActionCardTaskPayload {
        if let denial = capabilityDenial(authorization, required: "tasks") { throw denial }
        guard let token = bearerToken(authorization),
              let credential = agents.useAgentCredential(token: token, now: now()),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw ActionCardMarketplaceError.invalidToken
        }
        if let denial = grantDenial(agentId: agent.id, scope: "task:write") { throw denial }
        guard let body,
              let channelRef = body.channel,
              let channelId = taskChannel(
                  serverId: agent.serverId,
                  agentId: agent.id,
                  reference: channelRef
              ),
              let taskNumber = body.taskNumber,
              let rawAssignee = body.assignee, !rawAssignee.isEmpty
        else {
            throw ActionCardMarketplaceError.invalidTaskAssignRequest
        }
        guard let resolved = resolveAssignee(channelId: channelId, rawAssignee: rawAssignee) else {
            throw ActionCardMarketplaceError.assigneeNotAssignable
        }
        switch tasks.assignTask(
            channelId: channelId,
            taskNumber: taskNumber,
            assigneeId: resolved.id,
            assigneeType: resolved.type
        ) {
        case .notFound:
            throw ActionCardMarketplaceError.taskNotFoundForAssignment
        case .assigned(let task):
            return ActionCardTaskPayload(task)
        }
    }

    // MARK: - GET /internal/agent-api/inbox/conversations

    public func inboxConversations(
        authorization: String?,
        limit rawLimit: String?,
        beforeSeq rawBefore: String?,
        view rawView: String?
    ) throws -> ActionCardInboxResponse {
        let identity: (agentId: String, serverId: String)
        switch locator.identityResolution(authorization: authorization, capability: "read") {
        case .success(let agentId, let serverId):
            identity = (agentId, serverId)
        case .missingAuthorization:
            throw ActionCardMarketplaceError.missingAuthorization
        case .invalidAccessToken:
            throw ActionCardMarketplaceError.invalidToken
        case .capabilityNotAuthorized(let capability):
            throw ActionCardMarketplaceError.capabilityNotAuthorized(capability: capability)
        case .invalidAgentCredential:
            throw ActionCardMarketplaceError.invalidAgentCredential
        }
        guard (agents.agentInboxAvailable ?? true) else {
            throw ActionCardMarketplaceError.inboxUnavailable
        }
        let view = rawView ?? "unread"
        guard view == "unread" || view == "mentions" else {
            throw ActionCardMarketplaceError.invalidInboxView
        }
        let limit: Int
        if let rawLimit, !rawLimit.isEmpty {
            guard let parsed = Int(rawLimit), parsed >= 1, parsed <= 100 else {
                throw ActionCardMarketplaceError.invalidInboxLimit
            }
            limit = parsed
        } else {
            limit = 20
        }
        var before: Int?
        if let rawBefore, !rawBefore.isEmpty {
            guard let parsed = Int(rawBefore), parsed > 0 else {
                throw ActionCardMarketplaceError.invalidBeforeSeq
            }
            before = parsed
        }

        let serverId = identity.serverId
        let agentId = identity.agentId
        let snapshot = messages.inboxSnapshot()
        let channelRows = channels.postableChannels
        let jointProjections = channels.jointProjections
        let accountRows = accounts.accounts
        var rows: [ActionCardInboxItem] = []

        func latestMessage(_ storageChannelId: String) -> (seq: Int, message: StoredHumanMessage?) {
            let channelMessages = snapshot.messages.filter { $0.channelId == storageChannelId }
            guard let last = channelMessages.max(by: { $0.seq < $1.seq }) else { return (0, nil) }
            return (last.seq, last)
        }
        func senderName(_ message: StoredHumanMessage?) -> String? {
            guard let message else { return nil }
            if let external = message.externalSenderName { return external }
            if message.senderId == "system" { return "system" }
            return accountRows.values.first { $0.id == message.senderId }?.name
                ?? oauth.agentRuntimeInfo(id: message.senderId)?.name
        }
        func mentionStats(channelId: String) -> (count: Int, maxSeq: Int?) {
            let ids = Set(snapshot.mentions.filter {
                $0.targetType == "agent" && $0.targetId == agentId && $0.channelId == channelId
            }.map(\.messageId))
            guard !ids.isEmpty else { return (0, nil) }
            let channelMessages = snapshot.messages.filter { $0.channelId == channelId }
            var maxSeq: Int?
            for message in channelMessages where ids.contains(message.id) {
                maxSeq = message.seq
            }
            return (ids.count, maxSeq)
        }

        // Channel and DM rows.
        for (id, channel) in channelRows {
            guard channel.serverId == serverId, channel.deletedAt == nil else { continue }
            let visible = channel.kind == "channel"
                || channel.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: id).contains(agentId)
            guard visible else { continue }
            var target: String
            var kind: String
            if channel.kind == "dm", channel.name.hasPrefix("migration-receipt-"), channel.memberIds == [agentId] {
                target = "dm:@\(channel.name)"
                kind = "dm"
            } else if channel.kind == "dm" {
                let peer = channel.memberIds.compactMap { member -> (String, String)? in
                    guard member != agentId,
                          let account = accountRows.values.first(where: { $0.id == member }),
                          oauth.memberRole(serverId: serverId, userId: member) != nil
                    else { return nil }
                    return (member, account.name)
                }.first
                guard let peer else { continue }
                target = "dm:@\(peer.1)"
                kind = "dm"
            } else if channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint" {
                target = "#\(channel.name)"
                kind = "channel"
            } else {
                continue
            }
            let storage = jointProjections.first { $0.localChannelId == id }?.canonicalChannelId ?? id
            let latest = latestMessage(storage)
            guard latest.seq > 0 else { continue }
            let cursor = snapshot.readCursors["\(id)\n\(agentId)"]?.seq ?? 0
            let unread = snapshot.messages.filter {
                $0.channelId == storage && $0.seq > cursor && $0.senderId != agentId
            }.count
            let mentions = mentionStats(channelId: storage)
            rows.append(ActionCardInboxItem(
                target: target,
                kind: kind,
                unread: unread,
                mentions: mentions.count,
                lastReadSeq: cursor,
                activitySeq: latest.seq,
                latestSenderName: senderName(latest.message) ?? "",
                latestAt: latest.message.map { EmailLoginDirectory.isoMillis($0.createdAt) }
            ))
        }

        // Followed thread rows.
        for follow in snapshot.threadFollows.values where follow.userId == agentId && follow.serverId == serverId {
            guard let thread = channelRows[follow.threadChannelId], thread.deletedAt == nil,
                  let parentId = thread.parentChannelId,
                  let parent = channelRows[parentId], parent.deletedAt == nil
            else { continue }
            let visible = thread.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: follow.threadChannelId).contains(agentId)
                || parent.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: parentId).contains(agentId)
            guard visible else { continue }
            let storage = jointProjections.first {
                $0.localChannelId == follow.threadChannelId
            }?.canonicalChannelId ?? follow.threadChannelId
            let latest = latestMessage(storage)
            guard latest.seq > 0 else { continue }
            let cursor = snapshot.readCursors["\(follow.threadChannelId)\n\(agentId)"]?.seq ?? 0
            let unread = snapshot.messages.filter {
                $0.channelId == storage && $0.seq > cursor && $0.senderId != agentId
            }.count
            let mentions = mentionStats(channelId: storage)
            let parentShort = String((thread.parentMessageId ?? "").prefix(8))
            let target: String
            if parent.kind == "dm" {
                let peer = parent.memberIds.compactMap { member -> String? in
                    guard member != agentId,
                          let account = accountRows.values.first(where: { $0.id == member }),
                          oauth.memberRole(serverId: serverId, userId: member) != nil
                    else { return nil }
                    return account.name
                }.first ?? "unknown"
                target = "dm:@\(peer):\(parentShort)"
            } else {
                target = "#\(parent.name):\(parentShort)"
            }
            rows.append(ActionCardInboxItem(
                target: target,
                kind: "thread",
                unread: unread,
                mentions: mentions.count,
                lastReadSeq: cursor,
                activitySeq: latest.seq,
                latestSenderName: senderName(latest.message) ?? "",
                latestAt: latest.message.map { EmailLoginDirectory.isoMillis($0.createdAt) }
            ))
        }

        let totals = (
            conversations: rows.count,
            dms: rows.filter { $0.kind == "dm" }.count,
            mentions: rows.filter { $0.mentions > 0 }.count
        )
        var filtered = rows
        if view == "mentions" {
            filtered = filtered.filter { $0.mentions > 0 }
        } else {
            filtered = filtered.filter { $0.unread > 0 || $0.mentions > 0 }
        }
        if let before {
            filtered = filtered.filter { $0.activitySeq < before }
        }
        filtered.sort { left, right in
            if left.activitySeq != right.activitySeq { return left.activitySeq > right.activitySeq }
            return left.target < right.target
        }
        let hasMore = filtered.count > limit
        let page = Array(filtered.prefix(limit))
        return ActionCardInboxResponse(
            view: view,
            items: page,
            conversations: totals.conversations,
            dms: totals.dms,
            mentionConversations: totals.mentions,
            hasMore: hasMore,
            nextBeforeSeq: hasMore ? page.last?.activitySeq : nil
        )
    }

    // MARK: - Credential and channel policy

    private func bearerToken(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    /// The legacy `agentCapabilityDenial`: a live credential that does not
    /// carry `required` is the only refusal (anything else passes here).
    private func capabilityDenial(
        _ authorization: String?,
        required: String
    ) -> ActionCardMarketplaceError? {
        guard let token = bearerToken(authorization),
              let credential = agents.agentCredential(token: token),
              credential.revokedAt == nil
        else { return nil }
        return credential.scopes.contains(required)
            ? nil
            : .capabilityNotAuthorized(capability: required)
    }

    /// The legacy `agentGrantDenial`: an agent without a stored grant row has
    /// every grantable scope.
    private func grantDenial(agentId: String, scope: String) -> ActionCardMarketplaceError? {
        guard let grants = cards.agentGrantSets[agentId], !grants.contains(scope) else { return nil }
        return .missingScope(scope: scope)
    }

    private enum TaskAuthResult {
        case missingAuthorization
        case invalidCredential
        case ok(agentId: String, serverId: String)
    }

    /// The legacy `agentTaskAuth` reading order: credential path first (a live
    /// credential without `tasks` is the published invalid-token 401), then the
    /// machine key plus the path agent id.
    private func taskAuth(
        _ authorization: String?,
        legacyAgentId: String?
    ) -> TaskAuthResult {
        guard let token = bearerToken(authorization) else { return .missingAuthorization }
        let credential = agents.agentCredential(token: token)
        let machine = machines.machines.first { $0.apiKey == token }
        if let credential, credential.revokedAt == nil {
            guard credential.scopes.contains("tasks") else { return .invalidCredential }
            guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
                return .invalidCredential
            }
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        return .invalidCredential
    }

    /// The legacy `agentTaskWriter`: write routes accept both an `sk_agent_*`
    /// credential and the legacy machine key plus path agent id.
    private func taskWriter(
        _ authorization: String?,
        legacyAgentId: String?
    ) -> (agentId: String, serverId: String)? {
        guard let token = bearerToken(authorization) else { return nil }
        let credential = agents.agentCredential(token: token)
        let machine = machines.machines.first { $0.apiKey == token }
        if let credential, credential.revokedAt == nil,
           let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted {
            return (agent.id, agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return (agent.id, agent.serverId)
        }
        return nil
    }

    /// The legacy `agentTaskChannel` reference resolution.
    private func taskChannel(serverId: String, agentId: String, reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let channelRows = channels.postableChannels
        if trimmed.hasPrefix("#") {
            let name = String(trimmed.dropFirst())
            for (id, channel) in channelRows {
                guard channel.serverId == serverId, channel.name == name, channel.deletedAt == nil else { continue }
                guard channel.kind == "channel"
                    || channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
                else { continue }
                return id
            }
            return nil
        }
        guard channelRows[trimmed]?.serverId == serverId else { return nil }
        return trimmed
    }

    /// Resolves `@handle` to exactly one visible agent or human channel member.
    /// Both matches or neither is the published `assignee_not_assignable`.
    private func resolveAssignee(
        channelId: String,
        rawAssignee: String
    ) -> (id: String, type: String, name: String)? {
        let handle = rawAssignee.hasPrefix("@") ? String(rawAssignee.dropFirst()) : rawAssignee
        let lowered = handle.lowercased()
        let agentMatch = oauth.channelAgentIds(channelId: channelId)
            .compactMap { oauth.agentRuntimeInfo(id: $0) }
            .first { $0.name.lowercased() == lowered || $0.displayName.lowercased() == lowered }
        let channelHumans = oauth.channelHumanIds(channelId: channelId)
        let humanMatch = channelHumans.compactMap { userId in
            accounts.accounts.values.first { $0.id == userId }
        }.first { $0.name.lowercased() == lowered }
        guard (agentMatch == nil) != (humanMatch == nil) else { return nil }
        if let agentMatch {
            return (agentMatch.id, "agent", agentMatch.name)
        }
        if let humanMatch {
            return (humanMatch.id, "user", humanMatch.name)
        }
        return nil
    }

    /// The legacy idempotency lookup, which runs after the request shape check
    /// and before title validation.
    private func idempotencyReplay(
        agentId: String,
        rawBody: String
    ) throws -> ActionCardTaskCreateResponse? {
        switch idempotency.lookup(agentId, "taskCreate", rawBody) {
        case .miss:
            return nil
        case .replay(let body):
            return ActionCardTaskCreateResponse(replayedBody: body)
        case .conflict(let body):
            throw ActionCardMarketplaceError.idempotencyKeyReused(body: body)
        }
    }
}

extension EmailLoginDirectory {
    // Task credential/channel/freshness forwarders for the services that have
    // not migrated yet. The policy lives in `ActionCardExecuteService`; these
    // only keep the legacy signatures those callers already hold.

    func agentTaskAuth(authorization: String?, legacyAgentId: String?) -> AgentTaskAuthResult {
        do {
            let identity = try actionCardExecute.taskAuth(
                authorization: authorization,
                legacyAgentId: legacyAgentId
            )
            return .ok(agentId: identity.agentId, serverId: identity.serverId)
        } catch let error as any DomainError {
            return .refused(Self.json(Int(error.status), error.publishedErrorBody.render()))
        } catch {
            return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
    }

    func agentTaskWriter(_ authorization: String?, legacyAgentId: String?) -> (agentId: String, serverId: String)? {
        actionCardExecute.taskWriter(authorization: authorization, legacyAgentId: legacyAgentId)
    }

    func agentTaskChannel(serverId: String, agentId: String, reference: String) -> String? {
        actionCardExecute.taskChannel(serverId: serverId, agentId: agentId, reference: reference)
    }

    func taskWriteFreshnessHold(
        agentId: String,
        channelId: String,
        seenUpToSeq: Int?,
        actionKey: String
    ) -> AgentTaskWriteHoldResponse? {
        actionCardExecute.taskWriteHold(
            agentId: agentId,
            channelId: channelId,
            seenUpToSeq: seenUpToSeq,
            actionKey: actionKey
        )
    }
}
