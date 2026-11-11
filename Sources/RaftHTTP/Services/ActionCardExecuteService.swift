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
        guard let channelRef,
              let channelId = taskChannel(
                  serverId: identity.serverId,
                  agentId: identity.agentId,
                  reference: channelRef
              )
        else {
            throw ActionCardExecuteError.channelNotFound
        }
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
              let channelId = taskChannel(
                  serverId: writer.serverId,
                  agentId: writer.agentId,
                  reference: channelRef
              )
        else {
            throw ActionCardExecuteError.invalidTaskClaim
        }
        if let hold = taskWriteHold(
            agentId: writer.agentId,
            channelId: channelId,
            seenUpToSeq: body.seenUpToSeq,
            actionKey: "claim:\(body.taskNumbers.first ?? 0)"
        ) {
            return .held(hold)
        }
        let results = tasks.claimTasks(
            channelId: channelId,
            agentId: writer.agentId,
            taskNumbers: body.taskNumbers,
            messageIds: body.messageIds,
            now: now()
        )
        return .claimed(AgentTaskClaimResponse(results: results.map(Self.claimResult)))
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
        guard let channelId = taskChannel(
            serverId: writer.serverId, agentId: writer.agentId, reference: channel
        ) else {
            throw AgentTaskApiError.agentOrChannelNotFound
        }
        guard canAgentModifyTasks(serverId: writer.serverId, agentId: writer.agentId, channelId: channelId) else {
            throw AgentTaskApiError.agentCannotModifyTasks
        }
        guard !isChannelArchived(channelId) else { throw AgentTaskApiError.channelArchived }
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

    /// Upstream `channelService.canAgentPostToChannel`: the enabled `#all`
    /// surface is open to every agent in the server; every other channel needs
    /// an actual agent membership.
    private func canAgentModifyTasks(serverId: String, agentId: String, channelId: String) -> Bool {
        guard let channel = channels.postableChannel(id: channelId), channel.serverId == serverId else { return false }
        if channel.kind == "channel", oauth.allChannelId(serverId: serverId) == channelId { return true }
        return channel.memberIds.contains(agentId)
            || oauth.channelAgentIds(channelId: channelId).contains(agentId)
    }

    private func isChannelArchived(_ channelId: String) -> Bool {
        channels.postableChannel(id: channelId)?.archived == true || oauth.channelArchivedAt(id: channelId) != nil
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
              let channelId = taskChannel(
                  serverId: writer.serverId,
                  agentId: writer.agentId,
                  reference: channelRef
              ),
              let taskNumber = body.taskNumber,
              let status = body.status,
              TaskCatalogPolicy.validTaskStatuses.contains(status)
        else {
            throw ActionCardExecuteError.invalidTaskStatus
        }
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
        if trimmed.lowercased().hasPrefix("dm:@reminders") {
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
        if let assistantOwner = dependencies.assistantOwner(identity.agentId, identity.serverId) {
            guard trimmed.hasPrefix("dm:@") else {
                throw AgentSendError.assistantChannelForbidden
            }
            var raw = String(trimmed.dropFirst("dm:@".count))
            if let suffixStart = raw.lastIndex(of: ":") { raw = String(raw[..<suffixStart]) }
            if let tilde = raw.firstIndex(of: "~") { raw = String(raw[..<tilde]) }
            let resolution = prepare.resolveDMPeer(
                serverId: identity.serverId,
                agentId: identity.agentId,
                name: raw,
                kind: nil
            )
            guard case .resolved(let peerId, _, _) = resolution, peerId == assistantOwner else {
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
                throw AgentSendError.migrationReceiptReadOnly
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

    /// `#channel[:shortId]` and `dm:@name[~kind][:shortId]` target resolution.
    private func resolveSendChannel(
        trimmed: String,
        identity: (agentId: String, serverId: String)
    ) throws -> String {
        if trimmed.hasPrefix("#") {
            var raw = String(trimmed.dropFirst())
            var suffix: String?
            if let colon = raw.lastIndex(of: ":") {
                suffix = String(raw[raw.index(after: colon)...])
                raw = String(raw[..<colon])
            }
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
                if let suffix, !suffix.isEmpty {
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
        if trimmed.hasPrefix("dm:@") {
            var raw = String(trimmed.dropFirst("dm:@".count))
            var suffix: String?
            if let colon = raw.lastIndex(of: ":") {
                suffix = String(raw[raw.index(after: colon)...])
                raw = String(raw[..<colon])
            }
            var kind: String?
            if let tilde = raw.firstIndex(of: "~") {
                kind = String(raw[raw.index(after: tilde)...])
                raw = String(raw[..<tilde])
            }
            let resolution = prepare.resolveDMPeer(
                serverId: identity.serverId,
                agentId: identity.agentId,
                name: raw,
                kind: kind
            )
            switch resolution {
            case .resolved:
                break
            case .ambiguous(let name):
                throw AgentSendError.dmTargetAmbiguous(name: name)
            case .invalidKind(let kind, _):
                throw AgentSendError.dmTargetInvalidKind(kind: kind)
            case .notFound:
                throw AgentSendError.dmTargetNotFound
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
            if let suffix, !suffix.isEmpty {
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
        throw AgentSendError.channelNotFound
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
        AgentTaskCredentials(agents: agents, machines: machines, channels: channels, cards: cards, oauth: oauth)
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

    private static func claimResult(_ outcome: TasksAndRemindersStore.TaskClaimOutcome) -> AgentTaskClaimResult {
        switch outcome {
        case .taskNotFound(let taskNumber):
            return .taskNotFound(taskNumber: taskNumber)
        case .taskUnavailable(let taskNumber):
            return .taskUnavailable(taskNumber: taskNumber)
        case .alreadyClaimedByYou(let taskNumber):
            return .alreadyClaimedByYou(taskNumber: taskNumber)
        case .alreadyClaimed(let taskNumber):
            return .alreadyClaimed(taskNumber: taskNumber)
        case .claimed(let taskNumber, let messageId):
            return .claimed(taskNumber: taskNumber, messageId: messageId)
        case .messageNotFound(let prefix):
            return .messageNotFound(prefix: prefix)
        case .messageAlreadyClaimedByYou(let messageId, let taskNumber):
            return .messageAlreadyClaimedByYou(messageId: messageId, taskNumber: taskNumber)
        case .messageAlreadyClaimed(let messageId, let taskNumber):
            return .messageAlreadyClaimed(messageId: messageId, taskNumber: taskNumber)
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
