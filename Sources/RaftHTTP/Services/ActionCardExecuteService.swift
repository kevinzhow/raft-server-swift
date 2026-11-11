import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Action-card execution and the agent task claim / update-status surfaces.
///
/// Every operation owns its policy and its ledger access here: the service
/// reads `TasksAndRemindersStore`, `MessagesAndThreadsStore`,
/// `ServersAndChannelsStore`, `AgentsRuntimeStore` and
/// `MachinesAndComputersStore`, returns the published `JSONBodyConvertible`
/// DTOs, and throws `DomainError`. The send operation additionally keeps the
/// legacy single `sendFreshnessCommitLock` critical section in
/// `ManagedMCPAndCardsStore.withSendCommit`; the domains that have not
/// migrated yet enter as injected closures (`AgentSendDependencies`).
public struct ActionCardExecuteService: Sendable {
    private let tasks: TasksAndRemindersStore
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let oauth: OAuthLedger
    private let feedbackLocators: FeedbackLocatorService
    private let cards: ManagedMCPAndCardsStore
    private let prepare: ActionCardPrepareService
    private let catalog: TaskCatalogService
    private let freshness: AgentSendFreshnessGate
    private let dependencies: AgentSendDependencies
    private let now: @Sendable () -> Date
    private let makeMessageId: @Sendable () -> String

    init(
        tasks: TasksAndRemindersStore,
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        oauth: OAuthLedger,
        feedbackLocators: FeedbackLocatorService,
        cards: ManagedMCPAndCardsStore,
        prepare: ActionCardPrepareService,
        catalog: TaskCatalogService,
        ownership: AssistantOwnershipQuery,
        suppression: MessageSuppressionService,
        mentions: MessageMentionsService,
        ledger: MessageLedgerPort
    ) {
        self.init(
            tasks: tasks,
            messages: messages,
            channels: channels,
            agents: agents,
            machines: machines,
            oauth: oauth,
            feedbackLocators: feedbackLocators,
            cards: cards,
            prepare: prepare,
            catalog: catalog,
            dependencies: AgentSendDependencies(
                ownership: ownership,
                channels: channels,
                messages: messages,
                suppression: suppression,
                mentionService: mentions,
                ledger: ledger
            )
        )
    }

    init(
        tasks: TasksAndRemindersStore,
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        oauth: OAuthLedger,
        feedbackLocators: FeedbackLocatorService,
        cards: ManagedMCPAndCardsStore,
        prepare: ActionCardPrepareService,
        catalog: TaskCatalogService,
        dependencies: AgentSendDependencies,
        now: @escaping @Sendable () -> Date = { Date() },
        makeMessageId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.tasks = tasks
        self.messages = messages
        self.channels = channels
        self.agents = agents
        self.machines = machines
        self.oauth = oauth
        self.feedbackLocators = feedbackLocators
        self.cards = cards
        self.prepare = prepare
        self.catalog = catalog
        self.freshness = AgentSendFreshnessGate(
            messages: messages,
            channels: channels,
            prepare: prepare,
            oauth: oauth
        )
        self.dependencies = dependencies
        self.now = now
        self.makeMessageId = makeMessageId
    }

    // MARK: - GET /internal/agent-api/tasks

    /// The agent task list for one `#channel` reference. Authorization is the
    /// legacy `agentTaskAuth` credential check, then the grant for `task:read`.
    public func agentTasksList(
        authorization: String?,
        legacyAgentId: String?,
        channelRef: String?
    ) throws -> AgentTasksListResponse {
        if let denial = capabilityDenial(authorization, required: "tasks") {
            throw denial
        }
        let identity = try taskAuth(authorization: authorization, legacyAgentId: legacyAgentId)
        try requireGrant(agentId: identity.agentId, scope: "task:read")
        guard let channelRef else { throw ActionCardExecuteError.channelNotFound }
        let channelId = try resolvedTaskChannel(
            serverId: identity.serverId,
            agentId: identity.agentId,
            reference: channelRef
        )
        return AgentTasksListResponse(
            tasks: tasks.taskRows(channelId: channelId).map { task in
                AgentTasksListResponse.Task(
                    id: task.id,
                    channelId: task.channelId,
                    title: task.title,
                    status: task.status,
                    taskNumber: task.taskNumber,
                    description: task.description
                )
            }
        )
    }

    // MARK: - POST /internal/agent-api/tasks/claim

    /// The claim pass. Authorization (capability, then writer, then grant) runs
    /// before the body shape and the freshness gate, matching the published
    /// 401/403 → 400 order.
    public func agentTaskClaim(
        authorization: String?,
        legacyAgentId: String?,
        body: AgentTaskClaimRequest?
    ) throws -> AgentTaskClaimOutcome {
        if let denial = capabilityDenial(authorization, required: "tasks") {
            throw denial
        }
        guard let writer = taskWriter(authorization: authorization, legacyAgentId: legacyAgentId) else {
            throw FeedbackLocatorError.invalidAccessToken
        }
        try requireGrant(agentId: writer.agentId, scope: "task:write")
        guard let body,
              let channelRef = body.channel,
              !(body.taskNumbers.isEmpty && body.messageIds.isEmpty)
        else {
            throw ActionCardExecuteError.invalidTaskClaim
        }
        let channelId = try resolvedTaskChannel(
            serverId: writer.serverId,
            agentId: writer.agentId,
            reference: channelRef
        )
        // Upstream `assertAgentApiTaskWritableChannel` runs before the freshness
        // gate and before any task lookup or conversion: a thread target is the
        // pinned 409, `canAgentPostToChannel` is the 403, and an archived
        // channel is the 409 `channel_archived`. Membership alone is not
        // writability, so an archived or private surface must not be converted
        // just because the agent is a member. The decision is shared with every
        // other task write in `AgentTaskCredentials`.
        switch credentials.taskWriteBoundary(
            serverId: writer.serverId, agentId: writer.agentId,
            channelId: channelId, refusesThread: true
        ) {
        case .allowed: break
        case .thread: throw ActionCardExecuteError.threadTaskClaim
        case .notWritable: throw AgentTaskApiError.agentCannotModifyTasks
        case .archived: throw AgentTaskApiError.channelArchived
        }
        if let hold = taskWriteHold(
            agentId: writer.agentId,
            channelId: channelId,
            seenUpToSeq: body.seenUpToSeq,
            actionKey: "claim:\(body.taskNumbers.first ?? 0)"
        ) {
            return .held(hold)
        }
        // Upstream `taskClaim` resolves each `message_ids` entry in the
        // channel, converts a plain top-level message into a task, then claims
        // it in the same request. The store's claim pass only knows existing
        // task records, so the conversion has to happen here. The conversion
        // uses the canonical message-task link (host text as title, one task
        // number across the frozen message-task and canonical rows) so a repeat
        // claim converges on the same row instead of appending a second one.
        var claimMessageIds = body.messageIds
        var convertedMessageIds: Set<String> = []
        if !body.messageIds.isEmpty {
            let legacyMessageMax = messages.humanMessageRows
                .filter { $0.channelId == channelId }
                .compactMap(\.taskNumber)
                .max() ?? 0
            claimMessageIds = body.messageIds.map { reference in
                guard let message = messages.messageForConvert(prefix: reference, channelId: channelId) else {
                    return reference
                }
                switch tasks.ensureMessageTask(
                    channelId: channelId,
                    messageId: message.id,
                    title: message.content,
                    convertedByType: "agent",
                    creatorId: writer.agentId,
                    legacyMessageMaxNumber: legacyMessageMax,
                    now: now()
                ) {
                case .created:
                    convertedMessageIds.insert(message.id)
                case .existing:
                    break
                }
                return message.id
            }
        }
        let results = tasks.claimTasks(
            channelId: channelId,
            agentId: writer.agentId,
            taskNumbers: body.taskNumbers,
            messageIds: claimMessageIds,
            now: now()
        )
        for outcome in results {
            switch outcome {
            case .claimed(let taskNumber, _):
                guard let task = tasks.task(channelId: channelId, taskNumber: taskNumber) else { continue }
                try publishClaimTask(task, created: false)
            case .claimedMessage(_, let taskNumber):
                guard let task = tasks.task(channelId: channelId, taskNumber: taskNumber) else { continue }
                try publishClaimTask(task, created: convertedMessageIds.contains(task.messageId))
            case .taskNotFound, .taskUnavailable, .alreadyClaimedByYou,
                 .messageNotFound, .messageAlreadyClaimedByYou, .rejected:
                continue
            }
        }
        return .claimed(AgentTaskClaimResponse(results: results.map(claimResult)))
    }

    // MARK: - POST /internal/agent-api/tasks/unclaim

    /// The unclaim write. The route's request validator guarantees `channel` and
    /// a positive `task_number`; the service keeps the credential, the grant, the
    /// channel policy and the task row checks in the pinned order:
    /// capability/grant 401/403 → channel 404 → not-joinable 403 → archived 409
    /// → task 404 → store decision 409.
    public func agentTaskUnclaim(
        authorization: String?,
        legacyAgentId: String?,
        channel: String,
        taskNumber: Int
    ) throws -> AgentTaskUnclaimResponse {
        if let denial = capabilityDenial(authorization, required: "tasks") {
            throw denial
        }
        guard let writer = taskWriter(authorization: authorization, legacyAgentId: legacyAgentId) else {
            throw FeedbackLocatorError.invalidAccessToken
        }
        try requireGrant(agentId: writer.agentId, scope: "task:write")
        let channelId = try resolvedTaskChannel(
            serverId: writer.serverId, agentId: writer.agentId, reference: channel
        )
        try requireTaskWritable(serverId: writer.serverId, agentId: writer.agentId, channelId: channelId)
        guard let task = tasks.task(channelId: channelId, taskNumber: taskNumber) else {
            throw AgentTaskApiError.taskNotFound
        }
        switch tasks.unclaimForAgent(taskId: task.id, agentId: writer.agentId, now: now()) {
        case .notFound: throw AgentTaskApiError.taskNotFound
        case .done: throw AgentTaskApiError.taskDone
        case .unassigned: throw AgentTaskApiError.taskNotAssigned
        case .changedConcurrently: throw AgentTaskApiError.taskChangedConcurrently
        case .unclaimed: return AgentTaskUnclaimResponse()
        }
    }

    /// The shared write boundary for every task route: `canAgentPostToChannel`
    /// then the archived row, with no thread special case (the routes that
    /// refuse threads call `taskWriteBoundary(refusesThread: true)` instead).
    func requireTaskWritable(serverId: String, agentId: String, channelId: String) throws {
        switch credentials.taskWriteBoundary(
            serverId: serverId, agentId: agentId, channelId: channelId, refusesThread: false
        ) {
        case .allowed: break
        case .thread: throw AgentTaskApiError.agentCannotModifyTasks
        case .notWritable: throw AgentTaskApiError.agentCannotModifyTasks
        case .archived: throw AgentTaskApiError.channelArchived
        }
    }

    // MARK: - POST /internal/agent-api/tasks/update-status

    /// The status write. The non-admin transition rules, the resource-receipt
    /// gate and the write are one `TasksAndRemindersStore` critical section.
    public func agentTaskUpdateStatus(
        authorization: String?,
        legacyAgentId: String?,
        body: AgentTaskStatusUpdateRequest?
    ) throws -> AgentTaskStatusUpdateOutcome {
        if let denial = capabilityDenial(authorization, required: "tasks") {
            throw denial
        }
        guard let writer = taskWriter(authorization: authorization, legacyAgentId: legacyAgentId) else {
            throw FeedbackLocatorError.invalidAccessToken
        }
        try requireGrant(agentId: writer.agentId, scope: "task:write")
        guard let body,
              let channelRef = body.channel,
              let taskNumber = body.taskNumber,
              let status = body.status,
              TaskCatalogPolicy.validTaskStatuses.contains(status)
        else {
            throw ActionCardExecuteError.invalidTaskStatus
        }
        let channelId = try resolvedTaskChannel(
            serverId: writer.serverId,
            agentId: writer.agentId,
            reference: channelRef
        )
        try requireTaskWritable(serverId: writer.serverId, agentId: writer.agentId, channelId: channelId)
        if let hold = taskWriteHold(
            agentId: writer.agentId,
            channelId: channelId,
            seenUpToSeq: body.seenUpToSeq,
            actionKey: "update:\(taskNumber)"
        ) {
            return .held(hold)
        }
        let isAdmin = oauth.agentRole(serverId: writer.serverId, agentId: writer.agentId) == "admin"
        switch tasks.updateTaskStatus(
            channelId: channelId,
            taskNumber: taskNumber,
            status: status,
            agentId: writer.agentId,
            isAdmin: isAdmin,
            now: now()
        ) {
        case .notFound:
            throw ActionCardExecuteError.taskNotFound
        case .inProgressToTodoForbidden:
            throw ActionCardExecuteError.inProgressToTodo
        case .todoToTerminalForbidden(let status):
            throw ActionCardExecuteError.todoToTerminal(status: status)
        case .resourceReceiptRequired:
            throw ActionCardExecuteError.resourceReceiptRequired
        case .updated(let task):
            return .updated(AgentTaskStatusUpdateResponse(task: Self.taskDetail(task)))
        }
    }

    // MARK: - POST /internal/agent-api/send and /internal/agent-api/v2/send

    /// Posts an agent message to a `#channel`, a `#channel:shortId` thread or a
    /// `dm:@name[~kind][:shortId]` conversation.
    ///
    /// The gate (freshness + channel/peer cards) and the commit it protects run
    /// under the one `ManagedMCPAndCardsStore.withSendCommit` lock, which is the
    /// legacy `sendFreshnessCommitLock`: two concurrent first replies cannot both
    /// pass the gate before either lands. The reply is fully rendered here; the
    /// feature layer only projects it through `Respond.swift`.
    public func agentSendMessage(
        authorization: String?,
        body: AgentSendMessageRequest?,
        v2: Bool
    ) throws -> any JSONBodyConvertible {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocators.identityResolution(authorization: authorization, capability: "send") {
        case .success(let agentId, let serverId):
            identity = (agentId, serverId)
        case .missingAuthorization:
            throw FeedbackLocatorError.missingAuthorization
        case .invalidAccessToken:
            throw FeedbackLocatorError.invalidAccessToken
        case .capabilityNotAuthorized(let capability):
            throw FeedbackLocatorError.capabilityNotAuthorized(capability: capability)
        case .invalidAgentCredential:
            throw FeedbackLocatorError.invalidAgentCredential
        }
        guard let body, let target = body.target else {
            throw AgentSendError.invalidSendRequest
        }
        let content = body.content ?? ""
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTarget = Self.parseSendTarget(trimmed)
        if let parsedTarget, parsedTarget.isDM,
           Self.isReservedReminderPeer(parsedTarget.peerPart) {
            throw AgentSendError.reminderTargetNotSendable
        }
        let isSendDraft = body.sendDraft
        let isContinueAnyway = body.continueAnyway
        if body.continueFlag {
            throw AgentSendError.continueUnsupported
        }
        if isContinueAnyway && !isSendDraft {
            throw AgentSendError.continueAnywayRequiresDraft
        }
        if let assistantOwner = dependencies.postingOwner(identity.agentId, identity.serverId) {
            // Upstream checks the assistant's raw owner binding after resolving
            // the DM target's explicit kind. Do not strip `~kind` or a
            // non-8-hex colon suffix first: either would turn a different
            // conversation into the owner's DM (or the reverse) and answer the
            // wrong 403.
            guard let parsedTarget, parsedTarget.isDM else {
                throw AgentSendError.assistantChannelForbidden
            }
            let peer = parsedTarget.peer
            guard !peer.name.isEmpty else {
                throw Self.dmTargetMiss(parsedTarget)
            }
            let resolution = prepare.resolveDMPeer(
                serverId: identity.serverId,
                agentId: identity.agentId,
                name: peer.name,
                kind: peer.kind
            )
            switch resolution {
            case .resolved(let peerId, _, _):
                guard peerId == assistantOwner else {
                    throw AgentSendError.assistantChannelForbidden
                }
            case .ambiguous(let name):
                throw AgentSendError.dmTargetAmbiguous(name: name)
            case .invalidKind(let kind, let rawName):
                let rawPeer = peer.kind.map { "\(peer.name)~\($0)" } ?? rawName
                throw AgentSendError.dmTargetInvalidPeerKind(rawPeer: rawPeer, suffix: kind)
            case .notFound:
                throw AgentSendError.assistantChannelForbidden
            }
        }
        let reconcileOnly = body.reconcileOnly
        guard reconcileOnly || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentSendError.contentRequired
        }
        var attachmentIds: [String] = []
        if let rawAttachments = body.attachmentIds, rawAttachments != .null {
            guard case .array(let values) = rawAttachments else {
                throw AgentSendError.attachmentIdInvalid(entry: 1)
            }
            for (index, value) in values.enumerated() {
                guard case .string(let id) = value, ServerScope.isUUID(id) else {
                    throw AgentSendError.attachmentIdInvalid(entry: index + 1)
                }
                attachmentIds.append(id)
            }
        }
        let idempotencyKey = body.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var sendReceiptKey: String?
        if !idempotencyKey.isEmpty {
            let key = "\(identity.serverId)\n\(identity.agentId)\n\(idempotencyKey)"
            sendReceiptKey = key
            let receipt = cards.sendReceipt(key: key)
            if reconcileOnly {
                guard let receipt else {
                    return AgentSendReconcileNotFoundResponse()
                }
                return AgentSendReconcileCommittedResponse(
                    messageId: receipt.messageId,
                    messageSeq: receipt.messageSeq
                )
            }
            if let receipt {
                let mismatch: String?
                if receipt.target != trimmed {
                    mismatch = "target"
                } else if receipt.content != content {
                    mismatch = "content"
                } else if receipt.attachmentIds != attachmentIds {
                    mismatch = "attachments"
                } else {
                    mismatch = nil
                }
                if let mismatch {
                    throw AgentSendError.idempotencyKeyReused(mismatch: mismatch)
                }
                return AgentSendReceiptResponse(
                    messageId: receipt.messageId,
                    messageSeq: receipt.messageSeq,
                    channelId: messages.channelId(forMessageId: receipt.messageId) ?? "",
                    content: receipt.content
                )
            }
        }

        let mentionSurface = try MessageMentionMarkdown.parse(content)
        let channelId = try resolveSendChannel(
            trimmed: trimmed,
            identity: identity
        )

        return try cards.withSendCommit { () throws -> any JSONBodyConvertible in
            // The outer fast replay check can race another send. Recheck under
            // the same commit gate that appends the message and stores its receipt.
            if let sendReceiptKey, let receipt = cards.sendReceipt(key: sendReceiptKey) {
                if receipt.target != trimmed { throw AgentSendError.idempotencyKeyReused(mismatch: "target") }
                if receipt.content != content { throw AgentSendError.idempotencyKeyReused(mismatch: "content") }
                if receipt.attachmentIds != attachmentIds { throw AgentSendError.idempotencyKeyReused(mismatch: "attachments") }
                return AgentSendReceiptResponse(messageId: receipt.messageId, messageSeq: receipt.messageSeq,
                    channelId: messages.channelId(forMessageId: receipt.messageId) ?? "", content: receipt.content)
            }
            if let channel = channels.postableChannels[channelId],
               channel.name.hasPrefix("migration-receipt-") {
                // The published refusal names the target the caller actually
                // asked for, exactly like `agentWritableTarget.ts:199`.
                throw AgentSendError.migrationReceiptReadOnly(target: trimmed)
            }

            // Freshness gate (SMR-006).
            let seenUpToSeqValue = body.seenUpToSeq
            let hasClientSeenBoundary = seenUpToSeqValue != nil
            let clientSeenUpToSeq = hasClientSeenBoundary
                ? max(0, Int(seenUpToSeqValue!.rounded(.down)))
                : 0
            let withheldMode = body.freshnessContextMode == "withheld"
            let draftReholdCount = max(0, body.draftReholdCount ?? 0)
            let draftReplacedExisting = body.draftReplacedExisting
            let requestedSeenExactSeqs: [Int] = {
                var seen = Set<Int>()
                var values: [Int] = []
                for item in body.seenExactSeqs {
                    guard let number = AgentSendMessageRequest.number(item),
                          number.isFinite else { continue }
                    let value = Int(number.rounded(.down))
                    guard value > 0, seen.insert(value).inserted else { continue }
                    values.append(value)
                }
                return Array(values.prefix(2500))
            }()
            let requestedSendFreshness = isSendDraft || isContinueAnyway || hasClientSeenBoundary
                || !requestedSeenExactSeqs.isEmpty
                || body.draftReholdCount != nil || draftReplacedExisting || withheldMode
            let freshnessEnabled = prepare.sendFreshnessInterfaceEnabled(
                serverId: identity.serverId,
                agentId: identity.agentId
            )
            let forcedFreshness = prepare.sendFreshnessMode() == "force"
            if !freshnessEnabled && requestedSendFreshness {
                throw AgentSendError.freshnessInterfaceDisabled
            }

            var cardFields = AgentSendCardFields()
            var cardHoldReasons: [String] = []
            if case .object(let seenCards)? = body.seenCards, !withheldMode {
                if let rawChannel = seenCards["channel"],
                   let snapshot = prepare.channelCardSnapshot(channelId: channelId) {
                    if case .string(let seenVersion) = rawChannel {
                        if snapshot.rev != seenVersion {
                            cardFields.channelCard = snapshot.json
                            cardFields.channelCardChanged = true
                        }
                    } else {
                        cardFields.channelCard = snapshot.json
                        cardHoldReasons.append("channel_card")
                    }
                }
                if let rawPeer = seenCards["peer"] {
                    let peerCard = prepare.peerCardJSON(
                        channelId: channelId,
                        agentId: identity.agentId
                    )
                    if let peerCard, !isString(rawPeer) {
                        cardFields.peerCard = peerCard
                        cardHoldReasons.append("peer_card")
                    }
                }
            }
            let holdForCards = !cardHoldReasons.isEmpty && !isContinueAnyway

            if freshnessEnabled, (requestedSendFreshness || forcedFreshness), !isContinueAnyway {
                switch freshness.evaluate(AgentSendFreshnessRequest(
                    agentId: identity.agentId,
                    serverId: identity.serverId,
                    channelId: channelId,
                    targetRef: trimmed,
                    policy: .credential,
                    seenUpToSeq: hasClientSeenBoundary ? clientSeenUpToSeq : nil,
                    seenExactSeqs: requestedSeenExactSeqs,
                    withheld: withheldMode,
                    draftReholdCount: draftReholdCount,
                    draftReplacedExisting: draftReplacedExisting
                )) {
                case .proceed:
                    break
                case .held(let facts):
                    if facts.withheld {
                        return AgentSendWithheldResponse(withheldMessageCount: facts.holdCount)
                    }
                    return AgentSendHeldResponse(
                        producerFactId: facts.producerFactId,
                        heldMessages: facts.heldMessages,
                        newMessageCount: facts.holdCount,
                        shownMessageCount: facts.shownCount,
                        omittedMessageCount: facts.omittedCount,
                        seenUpToSeq: facts.latestSeq,
                        seenUpToMessageId: facts.latestMessageId,
                        firstShownSeq: facts.firstShownSeq,
                        formalMentionCount: facts.formalMentionCount,
                        continueAnywaySuggested: facts.continueAnywaySuggested,
                        holdReasons: holdForCards ? (["unread_messages"] + cardHoldReasons) : nil,
                        cards: cardFields
                    )
                }
            }
            if holdForCards {
                return AgentSendHeldForCardsResponse(holdReasons: cardHoldReasons, cards: cardFields)
            }

            let typedMentions = body.mentions
            let mentionResolution = try dependencies.resolvedMentions(
                identity.serverId,
                channelId,
                identity.agentId,
                content,
                v2 ? typedMentions : [],
                v2,
                mentionSurface
            )
            if mentionResolution.bindingConflict { throw AgentSendError.mentionBindingConflict }
            let messageId = makeMessageId()
            let ownSeq: Int
            switch try dependencies.commitAgentSend(
                StoredHumanMessage(
                    id: messageId,
                    channelId: channelId,
                    senderId: identity.agentId,
                    content: content,
                    randomId: nil,
                    attachmentIds: attachmentIds,
                    messageType: "chat",
                    senderType: "agent",
                    mentions: mentionResolution.mentions.map { StoredMessageMention(type: $0.type, id: $0.id, name: $0.name) }
                ),
                attachmentIds,
                channelId,
                identity.agentId
            ) {
            case .duplicate(let id):
                throw AgentSendError.attachmentDuplicate(id)
            case .unavailable(let id):
                throw AgentSendError.attachmentNotFound(id)
            case .alreadyLinked(let id):
                throw AgentSendError.attachmentAlreadyLinked(id)
            case .committed(let seq):
                ownSeq = seq
            }
            // Only a fresh, committed reply can reactivate a sender or eligible
            // resolved mention. Both receipt replay exits remain above this point.
            dependencies.recordThreadReplyFollows(messageId, channelId, identity.serverId,
                                                   identity.agentId, mentionResolution)
            if let sendReceiptKey {
                cards.setSendReceipt(
                    AgentApiSendReceipt(
                        messageId: messageId,
                        messageSeq: ownSeq,
                        target: trimmed,
                        content: content,
                        attachmentIds: attachmentIds
                    ),
                    key: sendReceiptKey
                )
            }
            dependencies.recordMemberMentionRows(
                messageId,
                channelId,
                mentionResolution
            )

            let pendingMentionActions = sendMentionReport(channelId: channelId, messageId: messageId)
            let unresolvedMentionHandles = v2 && !mentionResolution.unresolved.isEmpty
                ? mentionResolution.unresolved
                : nil

            var attention: AgentSendAttention?
            let channel = channels.postableChannels[channelId]
            let joined = agents.agentChannelJoinedAt["\(channelId)\n\(identity.agentId)"]
            let isChannel = channel?.kind == "channel"
            let recent = joined.map { now().timeIntervalSince($0) < 7 * 24 * 3600 } ?? false
            if isChannel, recent,
               agents.claimFirstAgentPost(channelId: channelId, agentId: identity.agentId) {
                let mute = "raft channel mute \"#\(channel?.name ?? "")\""
                let still = "@mentions still reach you, and threads you started stay followed and keep delivering until you unfollow them."
                attention = AgentSendAttention(muteCommand: mute, stillArrives: [still])
            }

            return AgentSendSentResponse(
                messageId: messageId,
                messageSeq: ownSeq,
                channelId: channelId,
                content: content,
                pendingMentionActions: pendingMentionActions,
                unresolvedMentionHandles: unresolvedMentionHandles,
                cards: cardFields,
                attention: attention
            )
        }
    }

    /// A parsed send target. The suffix rule is the pinned `parseChannelRef`:
    /// exactly eight hex characters after a non-leading colon. A colon that is
    /// not an eight-hex suffix is part of the channel or peer name, never a
    /// thread marker. `DM:@` is accepted exactly like `dm:@`.
    private struct ParsedSendTarget {
        enum Prefix { case channel, dm }
        let prefix: Prefix
        let base: String
        let shortId: String?

        var isDM: Bool { prefix == .dm }
        var peerPart: String { base }

        var peer: (name: String, kind: String?) {
            guard let tilde = base.firstIndex(of: "~") else { return (base, nil) }
            return (String(base[..<tilde]), String(base[base.index(after: tilde)...]))
        }
    }

    private static func parseSendTarget(_ trimmed: String) -> ParsedSendTarget? {
        if trimmed.hasPrefix("dm:@") || trimmed.hasPrefix("DM:@") {
            let split = splitShortId(String(trimmed.dropFirst(4)))
            return ParsedSendTarget(prefix: .dm, base: split.base, shortId: split.shortId)
        }
        if trimmed.hasPrefix("#") {
            let split = splitShortId(String(trimmed.dropFirst()))
            return ParsedSendTarget(prefix: .channel, base: split.base, shortId: split.shortId)
        }
        return nil
    }

    private static func splitShortId(_ rest: String) -> (base: String, shortId: String?) {
        guard let colon = rest.lastIndex(of: ":"),
              rest.distance(from: rest.startIndex, to: colon) > 0 else {
            return (rest, nil)
        }
        let shortId = String(rest[rest.index(after: colon)...])
        guard shortId.count == 8, shortId.allSatisfy({ $0.isHexDigit }) else {
            return (rest, nil)
        }
        return (String(rest[..<colon]), shortId.lowercased())
    }

    /// The pinned reserved-handle check strips only a final `~agent`/`~human`
    /// (case-insensitive) before the exact `reminders` comparison. A longer
    /// handle that merely starts with the reserved word stays an ordinary peer.
    private static func dmTargetMiss(_ parsed: ParsedSendTarget) -> AgentSendError {
        parsed.shortId == nil
            ? .dmTargetNotFound(peer: parsed.base)
            : .threadTargetNotFound(detail: "the parent message must exist in this DM")
    }

    private static func isReservedReminderPeer(_ peerPart: String) -> Bool {
        var name = peerPart
        if let tilde = name.firstIndex(of: "~") {
            let suffix = String(name[name.index(after: tilde)...]).lowercased()
            if suffix == "agent" || suffix == "human" {
                name = String(name[..<tilde])
            }
        }
        return name.lowercased() == "reminders"
    }

    /// `#channel[:shortId]` and `dm:@name[~kind][:shortId]` target resolution
    /// with the pinned grammar: an 8-hex suffix only, explicit `~kind` retained
    /// through peer resolution, and the uppercase `DM:@` prefix accepted.
    private func resolveSendChannel(
        trimmed: String,
        identity: (agentId: String, serverId: String)
    ) throws -> String {
        guard let parsed = Self.parseSendTarget(trimmed) else {
            throw AgentSendError.channelNotFound
        }
        if parsed.prefix == .channel {
            let raw = parsed.base
            let suffix = parsed.shortId
            var parentId: String?
            for (id, channel) in channels.postableChannels {
                guard channel.serverId == identity.serverId, channel.name == raw,
                      channel.deletedAt == nil,
                      channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint"
                else { continue }
                if channel.kind == "channel"
                    || channel.memberIds.contains(identity.agentId)
                    || oauth.channelAgentIds(channelId: id).contains(identity.agentId) {
                    parentId = id
                    break
                }
            }
            var resolved: String?
            var pendingAnchorId: String?
            if let parentId {
                if let suffix {
                    let isMember = channels.postableChannels[parentId]?.memberIds.contains(identity.agentId) == true
                        || oauth.channelAgentIds(channelId: parentId).contains(identity.agentId)
                    guard isMember else {
                        let privateParent = channels.postableChannels[parentId]?.kind == "private"
                        throw privateParent
                            ? AgentSendError.threadTargetNotFound(
                                detail: "the parent message must exist in a channel you can read"
                            )
                            : AgentSendError.agentNotParentMember
                    }
                    let anchorId = oauth.historyMessages(channelId: parentId).first {
                        $0.id.hasPrefix(suffix)
                    }?.id
                        ?? messages.humanMessageRows.first {
                            $0.channelId == parentId && $0.id.hasPrefix(suffix)
                        }?.id
                    resolved = dependencies.threadByAnchor(parentId, anchorId ?? "")
                        ?? dependencies.threadById(parentId, suffix)
                        ?? dependencies.threadByAnchorPrefix(parentId, suffix)
                    if resolved == nil, let anchorId {
                        pendingAnchorId = anchorId
                    }
                } else {
                    resolved = parentId
                }
            }
            if let parentId, let pendingAnchorId {
                let threadId = oauth.createThreadChannel(
                    parentChannelId: parentId,
                    parentMessageId: pendingAnchorId
                )
                dependencies.addPostableChannel(
                    identity.serverId,
                    threadId,
                    identity.agentId,
                    "thread",
                    parentId,
                    pendingAnchorId,
                    "thread"
                )
                resolved = threadId
            }
            guard let resolved else {
                if suffix == nil {
                    throw AgentSendError.channelNotFound
                }
                throw AgentSendError.threadTargetNotFound(
                    detail: "the parent message must exist in #\(raw)"
                )
            }
            return resolved
        }

        let rawPeer = parsed.base
        let peer = parsed.peer
        guard !peer.name.isEmpty else {
            throw Self.dmTargetMiss(parsed)
        }
        let resolution = prepare.resolveDMPeer(
            serverId: identity.serverId,
            agentId: identity.agentId,
            name: peer.name,
            kind: peer.kind
        )
        switch resolution {
        case .resolved:
            break
        case .ambiguous(let name):
            throw AgentSendError.dmTargetAmbiguous(name: name)
        case .invalidKind(let kind, let rawName):
            let rawSpelling = peer.kind.map { "\(peer.name)~\($0)" } ?? rawName
            throw AgentSendError.dmTargetInvalidPeerKind(rawPeer: rawSpelling, suffix: kind)
        case .notFound:
            // A DM thread target is a thread miss, not a peer miss: upstream
            // resolves the thread independently of the named peer.
            if parsed.shortId != nil {
                throw AgentSendError.threadTargetNotFound(
                    detail: "the parent message must exist in this DM"
                )
            }
            throw AgentSendError.dmTargetNotFound(peer: rawPeer)
        }
        guard case .resolved(let peerId, let peerKind, let peerName) = resolution else {
            throw AgentSendError.channelNotFound
        }
        let existing = prepare.dmChannelId(
            serverId: identity.serverId,
            agentId: identity.agentId,
            peerId: peerId,
            peerKind: peerKind,
            peerName: peerName
        )
        let dmChannelId: String
        if let existing {
            dmChannelId = existing
        } else {
            dmChannelId = oauth.createDirectChannel(
                serverId: identity.serverId,
                firstUserId: identity.agentId,
                secondUserId: peerId,
                firstKind: .agent,
                secondKind: peerKind == "agent" ? .agent : .human
            )
            dependencies.addPostableChannel(
                identity.serverId, dmChannelId, identity.agentId, "dm", nil, nil, "dm"
            )
            dependencies.addPostableChannel(
                identity.serverId, dmChannelId, peerId, "dm", nil, nil, "dm"
            )
            if peerKind == "human" { oauth.addChannelHuman(channelId: dmChannelId, userId: peerId) }
        }
        if let suffix = parsed.shortId {
            let anchorId = oauth.historyMessages(channelId: dmChannelId).first {
                $0.id.hasPrefix(suffix)
            }?.id
                ?? messages.humanMessageRows.first {
                    $0.channelId == dmChannelId && $0.id.hasPrefix(suffix)
                }?.id
            var resolved = dependencies.threadByAnchor(dmChannelId, anchorId ?? "")
                ?? dependencies.threadById(dmChannelId, suffix)
                ?? dependencies.threadByAnchorPrefix(dmChannelId, suffix)
            if resolved == nil, let anchorId {
                let threadId = oauth.createThreadChannel(
                    parentChannelId: dmChannelId,
                    parentMessageId: anchorId
                )
                dependencies.addPostableChannel(
                    identity.serverId, threadId, identity.agentId, "thread",
                    dmChannelId, anchorId, "thread"
                )
                dependencies.addPostableChannel(
                    identity.serverId, threadId, peerId, "thread",
                    dmChannelId, anchorId, "thread"
                )
                resolved = threadId
            }
            guard let resolved else {
                throw AgentSendError.threadTargetNotFound(
                    detail: "the parent message must exist in this DM"
                )
            }
            return resolved
        }
        return dmChannelId
    }

    private func isString(_ value: JSONValue) -> Bool {
        if case .string = value { return true }
        return false
    }

    /// The report is a projection of the actual retained false rows, including
    /// v2 and human targets. Neither a new UUID nor a second name resolver runs.
    private func sendMentionReport(channelId: String, messageId: String) -> [String] {
        guard let channel = channels.postableChannel(id: channelId),
              channel.kind == "channel" || channel.kind == "thread" else { return [] }
        return messages.state.storedMentions.filter {
            $0.messageId == messageId && $0.channelId == channelId && !$0.notifiableAtSend && $0.notifiedAt == nil
        }.map { mention in
            let avatar = mention.targetType == "agent" ? oauth.agentRuntimeInfo(id: mention.targetId)?.avatarUrl
                : dependencies.targetAvatar(mention.targetType, mention.targetId)
            return MessageMentionRules.pendingMentionActionJSON(mention: mention, avatarUrl: avatar, actions: ["notify"])
        }
    }

    // MARK: - Shared task decisions
    //
    // These are also the bodies behind the directory forwarders the services
    // that have not migrated yet still call, so the policy has one copy.

    private var credentials: AgentTaskCredentials {
        AgentTaskCredentials(
            agents: agents, machines: machines, channels: channels, cards: cards, oauth: oauth,
            accounts: prepare.accountStore,
            reminderSurface: { agentId in feedbackLocators.agentReminderSurfaceChannelId(agentId: agentId) }
        )
    }

    /// The legacy `agentTaskAuth` credential outcome (401s are `DomainError`s).
    func taskAuth(
        authorization: String?,
        legacyAgentId: String?
    ) throws -> (agentId: String, serverId: String) {
        switch credentials.auth(authorization: authorization, legacyAgentId: legacyAgentId) {
        case .missingAuthorization:
            throw FeedbackLocatorError.missingAuthorization
        case .invalidCredential:
            throw FeedbackLocatorError.invalidAccessToken
        case .ok(let agentId, let serverId):
            return (agentId, serverId)
        }
    }

    /// The legacy `agentTaskWriter` writer lookup.
    func taskWriter(
        authorization: String?,
        legacyAgentId: String?
    ) -> (agentId: String, serverId: String)? {
        credentials.writer(authorization: authorization, legacyAgentId: legacyAgentId)
    }

    /// The legacy `agentTaskChannel` reference resolution (`#name` or a raw id).
    func taskChannel(serverId: String, agentId: String, reference: String) -> String? {
        credentials.channel(serverId: serverId, agentId: agentId, reference: reference)
    }

    /// The claim/convert resolution: keeps the caller-fixable DM failures so
    /// the published `DM_TARGET_AMBIGUOUS` / `DM_TARGET_INVALID_PEER_KIND`
    /// bodies survive instead of collapsing into a generic 400/404.
    func resolvedTaskChannel(
        serverId: String,
        agentId: String,
        reference: String
    ) throws -> String {
        try credentials.resolvedChannel(
            serverId: serverId, agentId: agentId, reference: reference, allowThread: true
        )
    }

    /// Publishes the board row for a committed claim. A converted plain host
    /// message only teaches the task board (`task:created`) because the host
    /// row is unchanged; an existing task is `task:updated`. Neither publishes
    /// `message:updated`.
    private func publishClaimTask(_ task: TaskRecord, created: Bool) throws {
        do {
            if created {
                try catalog.publishClaimCreatedTask(task)
            } else {
                try catalog.publishClaimUpdatedTask(task)
            }
        } catch {
            DeferredEffects.markRollbackOnly()
            throw error
        }
    }

    /// The task-write freshness gate. `nil` means the write proceeds; a value
    /// is the published `held` body, built from the newer rows read before the
    /// store decides whether to record the hold.
    func taskWriteHold(
        agentId: String,
        channelId: String,
        seenUpToSeq: Int?,
        actionKey: String
    ) -> AgentTaskWriteHoldResponse? {
        guard let seen = seenUpToSeq else { return nil }
        let newer = messages.humanMessageRows.filter {
            $0.channelId == channelId && $0.senderId != agentId && $0.seq > seen
        }
        switch tasks.decideTaskWriteHold(
            agentId: agentId,
            channelId: channelId,
            seen: seen,
            actionKey: actionKey,
            newerMessages: newer
        ) {
        case .proceed:
            return nil
        case .held(let latest):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let held = newer.sorted { $0.seq < $1.seq }.prefix(5).map { message in
                AgentTaskHeldMessage(
                    id: message.id,
                    seq: message.seq,
                    content: message.content,
                    senderId: message.senderId,
                    createdAt: formatter.string(from: message.createdAt)
                )
            }
            return AgentTaskWriteHoldResponse(
                heldMessages: Array(held),
                newMessageCount: newer.count,
                seenUpToSeq: latest
            )
        }
    }

    // MARK: - Private projections

    private func capabilityDenial(_ authorization: String?, required: String) -> FeedbackLocatorError? {
        switch feedbackLocators.capabilityDecision(authorization: authorization, capability: required) {
        case .allowed:
            return nil
        case .denied(let capability):
            return .capabilityNotAuthorized(capability: capability)
        }
    }

    private func requireGrant(agentId: String, scope: String) throws {
        switch feedbackLocators.grantDecision(agentId: agentId, scope: scope) {
        case .allowed:
            break
        case .missingScope(let missing):
            throw FeedbackLocatorError.missingScope(scope: missing)
        }
    }

    /// Project one store observation into the published result. A conflict is
    /// built only from the same facts the writer used: the canonical assignee
    /// handle, the observed status and claim instant, and this request's
    /// observation time. Closed/done/self rejections carry no effect boundary.
    private func claimResult(_ outcome: TasksAndRemindersStore.TaskClaimOutcome) -> AgentTaskClaimResult {
        switch outcome {
        case .taskNotFound(let taskNumber):
            return .taskNotFound(taskNumber: taskNumber)
        case .taskUnavailable(let taskNumber):
            return .taskUnavailable(taskNumber: taskNumber)
        case .alreadyClaimedByYou(let taskNumber):
            return .alreadyClaimedByYou(taskNumber: taskNumber)
        case .rejected(let taskNumber, let messageId, let facts):
            guard facts.reason == "already assigned",
                  let assigneeType = facts.assigneeType,
                  let assigneeId = facts.assigneeId
            else {
                return .rejected(
                    taskNumber: taskNumber, messageId: messageId,
                    reason: facts.reason, conflict: nil
                )
            }
            let name = credentials.taskActorName(type: assigneeType, id: assigneeId)
            let reason = name.map { "already assigned to @\($0)" } ?? "already assigned to <unresolved>"
            let conflict = AgentTaskClaimConflict(
                currentAssigneeType: assigneeType,
                currentAssigneeName: name,
                taskStatus: facts.status,
                claimedAt: facts.claimedAt.map(DateText.isoString),
                observedAt: DateText.isoString(now())
            )
            return .rejected(taskNumber: taskNumber, messageId: messageId, reason: reason, conflict: conflict)
        case .claimed(let taskNumber, let messageId):
            return .claimed(taskNumber: taskNumber, messageId: messageId)
        case .messageNotFound(let prefix):
            return .messageNotFound(prefix: prefix)
        case .messageAlreadyClaimedByYou(let messageId, let taskNumber):
            return .messageAlreadyClaimedByYou(messageId: messageId, taskNumber: taskNumber)
        case .claimedMessage(let messageId, let taskNumber):
            return .claimedMessage(messageId: messageId, taskNumber: taskNumber)
        }
    }

    private static func taskDetail(_ task: TaskRecord) -> AgentTaskDetail {
        let formatter = ISO8601DateFormatter()
        return AgentTaskDetail(
            id: task.id,
            channelId: task.channelId,
            messageId: task.messageId,
            title: task.title,
            status: task.status,
            taskNumber: task.taskNumber,
            claimedById: task.assigneeId,
            claimedByType: task.assigneeType,
            claimedAt: task.claimedAt.map { formatter.string(from: $0) },
            revision: task.revision,
            requiresResourceReceipt: task.requiresResourceReceipt
        )
    }
}
