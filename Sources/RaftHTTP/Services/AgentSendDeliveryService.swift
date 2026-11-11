import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Domain failure for the agent send, delivery-ack, activity-ingest and
/// agent-thread operations.
///
/// `status`, `errorMessage` and `errorCode` are the published values; the
/// canonical `DomainError` body already prints `error` then the optional
/// `code`, so the legacy `{"error": …,"code": …}` bytes need no override.
public enum AgentSendDeliveryError: DomainError, Equatable {
    case missingAuthorization
    case invalidToken
    case agentNotFound
    case invalidTarget
    case agentNotParentMember
    case threadNotFound
    case channelNotFound
    case agentNotChannelMember
    case channelArchived
    case capabilityNotAuthorized
    case activityInvalid
    case transcriptPathForbidden
    case statusInvalid
    case detailInvalid
    case detailTooLong
    case invalidThreadUnfollow
    case targetMustBeThread
    case receiveAckEmpty
    // The legacy machine-on-behalf send surface.
    case machineAuthenticationRequired
    case invalidMachineAPIKey
    case agentNotAssignedToMachine
    case targetRequired
    case legacyBodyInvalid([AgentSendRequest.Issue])
    case missingAgentScope(scope: String)
    case channelTargetNotFound(target: String)
    case threadTargetNotFound(target: String)
    case forbiddenChannelTarget
    case forbiddenThreadTarget
    case peerNotFound(peer: String)
    case selfDM
    // `dmTargetResolutionError.ts` refusals; the legacy machine send answers
    // the exact `{error, code, suggestedNextAction}` bodies.
    case dmTargetAmbiguous(name: String)
    case dmTargetInvalidPeerKind(rawPeer: String, suffix: String?)
    case dmTargetNotSendable
    case migrationReceiptReadOnly(target: String)

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidToken, .machineAuthenticationRequired,
             .invalidMachineAPIKey:
            401
        case .dmTargetNotSendable:
            403
        case .agentNotParentMember, .agentNotChannelMember, .capabilityNotAuthorized,
             .agentNotAssignedToMachine, .missingAgentScope, .forbiddenChannelTarget,
             .forbiddenThreadTarget:
            403
        case .agentNotFound, .threadNotFound, .channelNotFound, .channelTargetNotFound,
             .threadTargetNotFound, .peerNotFound:
            404
        case .dmTargetAmbiguous, .migrationReceiptReadOnly:
            409
        case .dmTargetInvalidPeerKind:
            400
        case .channelArchived:
            409
        case .invalidTarget, .activityInvalid, .transcriptPathForbidden, .statusInvalid,
             .detailInvalid, .detailTooLong, .invalidThreadUnfollow, .targetMustBeThread,
             .receiveAckEmpty, .targetRequired, .legacyBodyInvalid, .selfDM:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidToken:
            "Invalid or expired token"
        case .agentNotFound:
            "Agent not found"
        case .invalidTarget:
            "Invalid target"
        case .agentNotParentMember:
            "Agent is not a member of the parent channel"
        case .threadNotFound:
            "Thread not found"
        case .channelNotFound:
            "Channel not found"
        case .agentNotChannelMember:
            "Agent is not a member of this channel"
        case .channelArchived:
            "This channel is archived"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .activityInvalid:
            "Invalid activity ingest"
        case .transcriptPathForbidden:
            "transcript_path is not accepted"
        case .statusInvalid:
            "Invalid agent status"
        case .detailInvalid:
            "Invalid status detail"
        case .detailTooLong:
            "Status detail is too long"
        case .invalidThreadUnfollow:
            "Invalid thread unfollow request"
        case .targetMustBeThread:
            "Target must be a thread"
        case .receiveAckEmpty:
            "seqs or messageIds must be a non-empty array"
        case .machineAuthenticationRequired:
            "Missing machine API key"
        case .invalidMachineAPIKey:
            "Invalid machine API key"
        case .agentNotAssignedToMachine:
            "This agent is not assigned to your machine"
        case .targetRequired:
            "target is required"
        case .legacyBodyInvalid:
            "Invalid legacy agent send body"
        case .missingAgentScope:
            "missing required scope"
        case .channelTargetNotFound(let target):
            "Channel not found: \(target)"
        case .threadTargetNotFound(let target):
            "Thread target not found or not replyable: \(target). Use #channel:<id> or dm:@peer:<id> where <id> is the parent message's short id (the msg= field, as in replyTarget); when a message id is given the parent message must exist and belong to that parent target."
        case .forbiddenChannelTarget:
            "Agent cannot post in this channel - not a member. If you were @mentioned and need to respond, DM the person who mentioned you and let them know you're not in the channel."
        case .forbiddenThreadTarget:
            "Agent cannot post in this thread - not a member of the parent channel. Following a thread grants listen access only; joining the parent channel is required to send. If you were @mentioned and need to respond, DM the person who mentioned you and let them know you're not in the channel."
        case .peerNotFound(let peer):
            "User or agent not found: @\(peer)"
        case .selfDM:
            "Cannot create a DM with yourself"
        case .dmTargetAmbiguous(let name):
            DMTargetResolutionWire.ambiguous(name).message
        case .dmTargetInvalidPeerKind(let rawPeer, let suffix):
            DMTargetResolutionWire.invalidPeerKind(rawPeer: rawPeer, suffix: suffix).message
        case .dmTargetNotSendable:
            DMTargetResolutionWire.privateReminderSurface().message
        case .migrationReceiptReadOnly(let target):
            DMTargetResolutionWire.migrationReceiptReadOnly(target: target).message
        }
    }

    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidToken:
            "auth_required"
        case .channelArchived:
            "channel_archived"
        case .capabilityNotAuthorized:
            "capability_not_authorized"
        case .activityInvalid:
            "activity_invalid"
        case .transcriptPathForbidden:
            "transcript_path_forbidden"
        case .statusInvalid:
            "status_invalid"
        case .detailInvalid:
            "detail_invalid"
        case .detailTooLong:
            "detail_too_long"
        case .legacyBodyInvalid:
            "legacy_agent_send_contract_invalid"
        case .agentNotFound, .invalidTarget, .agentNotParentMember, .threadNotFound,
             .channelNotFound, .agentNotChannelMember, .invalidThreadUnfollow,
             .targetMustBeThread, .receiveAckEmpty, .machineAuthenticationRequired,
             .invalidMachineAPIKey, .agentNotAssignedToMachine, .targetRequired,
             .missingAgentScope, .channelTargetNotFound, .threadTargetNotFound,
             .forbiddenChannelTarget, .forbiddenThreadTarget, .peerNotFound, .selfDM,
             .dmTargetAmbiguous, .dmTargetInvalidPeerKind, .dmTargetNotSendable,
             .migrationReceiptReadOnly:
            nil
        }
    }

    /// The two legacy error shapes whose bodies are not the plain
    /// `{"error": …[, "code": …]}` object.
    public var errorBody: OrderedJSON? {
        switch self {
        case .legacyBodyInvalid(let issues):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "legacy_agent_send_contract_invalid")
            body.append("issues", .array(issues.map { issue in
                .object([
                    OrderedJSONField("path", issue.path),
                    OrderedJSONField("message", issue.message),
                ])
            }))
            return body.json
        case .missingAgentScope(let scope):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("requiredScope", scope)
            body.append("reason", "missing_scope")
            return body.json
        case .dmTargetAmbiguous(let name):
            return DMTargetResolutionWire.ambiguous(name).body
        case .dmTargetInvalidPeerKind(let rawPeer, let suffix):
            return DMTargetResolutionWire.invalidPeerKind(rawPeer: rawPeer, suffix: suffix).body
        case .dmTargetNotSendable:
            return DMTargetResolutionWire.privateReminderSurface().body
        case .migrationReceiptReadOnly(let target):
            return DMTargetResolutionWire.migrationReceiptReadOnly(target: target).body
        default:
            return nil
        }
    }
}

/// Agent send, delivery ack, activity ingest, thread-follow and integration
/// routes.
///
/// Every operation used to live in a directory extension and take the
/// directory lock. Each now runs against the store that owns its rows:
/// machine credentials come from `MachinesAndComputersStore`, channels from
/// `ServersAndChannelsStore`, message/cursor rows from
/// `MessagesAndThreadsStore`, activity/credential/hosted rows from
/// `AgentsRuntimeStore`, thread follows from `ThreadFollowStore`, and
/// integration logins from `ManagedMCPAndCardsStore`.
///
/// Three bridges stay injected because those domains are not migrated yet:
/// `searchVisible` is the message-visibility policy in `SearchMentionsService`,
/// `commitSend` is the one attachment-validating agent append path, and
/// `integrationServices` is a typed projection of the OAuth ledger's client
/// rows, so this file never names an untyped JSON dictionary.
public struct AgentSendDeliveryService: Sendable {
    private let machines: MachinesAndComputersStore
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let agents: AgentsRuntimeStore
    private let threadFollows: ThreadFollowStore
    private let managedMCP: ManagedMCPAndCardsStore
    private let oauth: OAuthLedger
    private let prepare: ActionCardPrepareService
    private let freshness: AgentSendFreshnessGate
    private let assistantOwner: @Sendable (_ agentId: String, _ serverId: String) -> String?
    private let searchVisible: @Sendable (_ messageChannelId: String, _ serverId: String?, _ viewer: SearchViewer) -> Bool
    private let commitSend: @Sendable (StoredHumanMessage, [String], String, String) throws -> AgentSendAppendOutcome
    private let integrationServices: @Sendable (_ serverId: String) -> [AgentIntegrationServiceSnapshot]
    /// The persisted-chat frontend publisher (`emitPersistedMessageToFrontend`):
    /// joins the DM/thread audience, then emits the canonical `message:new`,
    /// `dm:new` or `thread:updated`. The default keeps focused service tests
    /// silent; the HTTP composition installs the real socket relay.
    private let publishCommittedMessage: @Sendable (StoredHumanMessage) -> Void
    private let now: @Sendable () -> Date
    private let makeMessageId: @Sendable () -> String

    /// Binds the delivery domain to its concrete visibility and ledger owners.
    /// Integration rows are projected on every query, in the ledger's order.
    init(
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        agents: AgentsRuntimeStore,
        threadFollows: ThreadFollowStore,
        managedMCP: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        prepare: ActionCardPrepareService,
        search: SearchMentionsService,
        ledger: MessageLedgerPort,
        publishCommittedMessage: @escaping @Sendable (StoredHumanMessage) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        makeMessageId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.init(
            machines: machines,
            channels: channels,
            messages: messages,
            agents: agents,
            threadFollows: threadFollows,
            managedMCP: managedMCP,
            oauth: oauth,
            prepare: prepare,
            assistantOwner: { agentId, _ in
                // POST authority uses the RAW retained assistant binding: the
                // pinned `assistantMayPostTo` reads `assistant_owner_user_id`
                // regardless of the `identity_borrowing` display flag or the
                // owner's current server membership. `liveOwner` stays the
                // display/context query elsewhere.
                AssistantOwnershipQuery(agents: agents, oauth: oauth).rawOwner(agentId: agentId)
            },
            searchVisible: search.messageVisible,
            commitSend: { message, attachmentIds, channelId, uploaderId in
                messages.commitAgentSend(
                    message,
                    attachmentIds: attachmentIds,
                    channelId: channelId,
                    uploaderId: uploaderId,
                    ledger: ledger
                )
            },
            integrationServices: { serverId in
                oauth.integrationServices(serverId: serverId).map(AgentIntegrationProjection.snapshot)
            },
            publishCommittedMessage: publishCommittedMessage,
            now: now,
            makeMessageId: makeMessageId
        )
    }

    init(
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        agents: AgentsRuntimeStore,
        threadFollows: ThreadFollowStore,
        managedMCP: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        prepare: ActionCardPrepareService,
        assistantOwner: @escaping @Sendable (String, String) -> String?,
        searchVisible: @escaping @Sendable (String, String?, SearchViewer) -> Bool,
        commitSend: @escaping @Sendable (StoredHumanMessage, [String], String, String) throws -> AgentSendAppendOutcome,
        integrationServices: @escaping @Sendable (String) -> [AgentIntegrationServiceSnapshot],
        publishCommittedMessage: @escaping @Sendable (StoredHumanMessage) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        makeMessageId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.machines = machines
        self.channels = channels
        self.messages = messages
        self.agents = agents
        self.threadFollows = threadFollows
        self.managedMCP = managedMCP
        self.oauth = oauth
        self.prepare = prepare
        self.freshness = AgentSendFreshnessGate(
            messages: messages,
            channels: channels,
            prepare: prepare,
            oauth: oauth
        )
        self.assistantOwner = assistantOwner
        self.searchVisible = searchVisible
        self.commitSend = commitSend
        self.integrationServices = integrationServices
        self.publishCommittedMessage = publishCommittedMessage
        self.now = now
        self.makeMessageId = makeMessageId
    }

    // MARK: - POST /internal/agent/:agentId/send

    /// Posts an agent message on behalf of the machine that owns the agent.
    ///
    /// The pinned order is machine authentication (401), the legacy body
    /// schema (400 with `issues`), agent existence/server (404), machine
    /// ownership (403), the `message:send` grant (403), the body semantics
    /// (`--continue`, content, `--send-draft --anyway`, target), target
    /// resolution, the freshness mode refusal (403) and only then the
    /// freshness gate plus the attachment-validating append. Every branch
    /// returns the pin's published text; no refusal writes a message row.
    public func agentSend(
        authorization: String?,
        agentId: String,
        body: AgentSendRequest?
    ) throws -> any JSONBodyConvertible {
        // Upstream mounts `validateLegacyAgentSendBody` before
        // `requireAgentScope`, so the shared gate is entered in two phases:
        // machine authentication first, body validation second, then the
        // agent/server/ownership/grant half.
        let principal = try legacyMachineGate.machinePrincipal(authorization: authorization)
        let request = body ?? AgentSendRequest()
        guard request.issues.isEmpty else {
            throw AgentSendDeliveryError.legacyBodyInvalid(request.issues)
        }
        let actor = try legacyMachineGate.actor(
            principal: principal,
            agentId: agentId,
            requiredScope: "message:send"
        )
        let agent = actor.agent
        let serverId = actor.serverId

        if request.continueFlag {
            throw AgentSendError.continueUnsupported
        }
        guard let content = request.content, !content.isEmpty else {
            throw AgentSendError.contentRequired
        }
        let isSendDraft = request.sendDraft
        let isContinueAnyway = request.continueAnyway
        if isContinueAnyway && !isSendDraft {
            throw AgentSendError.continueAnywayRequiresDraft
        }
        guard let target = request.effectiveTarget else {
            throw AgentSendDeliveryError.targetRequired
        }

        let mode = prepare.sendFreshnessMode()
        let freshnessEnabled = prepare.sendFreshnessInterfaceEnabled(
            serverId: serverId,
            agentId: agent.id
        )
        let requestedFreshness = isSendDraft || isContinueAnyway
            || request.seenUpToSeq != nil
            || request.draftReholdCount != nil
            || request.draftReplacedExisting
        if !freshnessEnabled && requestedFreshness {
            throw AgentSendError.freshnessInterfaceDisabled
        }
        let shouldRunFreshness = freshnessEnabled && (requestedFreshness || mode == "force")

        let resolved = try resolveLegacyTarget(agent: agent, target: target)
        if resolved.archived {
            throw AgentSendDeliveryError.channelArchived
        }

        let seenUpToSeq = request.seenUpToSeq.map { max(0, Int($0.rounded(.down))) }
        let draftReholdCount = request.draftReholdCount.map { max(0, Int($0.rounded(.down))) } ?? 0
        let idempotencyKey = (request.idempotencyKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let receiptKey = idempotencyKey.isEmpty
            ? nil
            : "\(serverId)\n\(agent.id)\n\(idempotencyKey)"

        func replay() throws -> AgentSendResponse? {
            guard let receiptKey, let receipt = managedMCP.sendReceipt(key: receiptKey) else { return nil }
            if receipt.target != target { throw AgentSendError.idempotencyKeyReused(mismatch: "target") }
            if receipt.content != content { throw AgentSendError.idempotencyKeyReused(mismatch: "content") }
            if receipt.attachmentIds != request.attachmentIds {
                throw AgentSendError.idempotencyKeyReused(mismatch: "attachments")
            }
            return AgentSendResponse(messageId: receipt.messageId, messageSeq: receipt.messageSeq)
        }

        func commit() throws -> AgentSendResponse {
            let messageId = makeMessageId()
            var committed = StoredHumanMessage(
                id: messageId,
                channelId: resolved.channelId,
                senderId: agent.id,
                content: content,
                randomId: nil,
                attachmentIds: request.attachmentIds,
                messageType: "chat",
                senderType: "agent"
            )
            let seq: Int
            switch try commitSend(
                committed,
                request.attachmentIds,
                resolved.channelId,
                agent.id
            ) {
            case .duplicate(let id):
                throw AgentSendError.attachmentDuplicate(id)
            case .unavailable(let id):
                throw AgentSendError.attachmentNotFound(id)
            case .alreadyLinked(let id):
                throw AgentSendError.attachmentAlreadyLinked(id)
            case .committed(let committedSeq):
                seq = committedSeq
            }
            if let receiptKey {
                managedMCP.setSendReceipt(
                    AgentApiSendReceipt(
                        messageId: messageId,
                        messageSeq: seq,
                        target: target,
                        content: content,
                        attachmentIds: request.attachmentIds
                    ),
                    key: receiptKey
                )
            }
            committed.seq = seq
            publishCommittedMessage(committed)
            return AgentSendResponse(messageId: messageId, messageSeq: seq)
        }

        func recordContinueEvent(_ sent: AgentSendResponse, newMessageCount: Int) {
            let result = isContinueAnyway ? "committed_anyway" : "committed"
            messages.recordAttestedSendEvent(AttestedSendEventRecord(
                eventType: "continue",
                agentId: agent.id,
                messageId: sent.messageId,
                metadataJSON: AttestedSendEventMetadata.continueEvent(
                    continueAnyway: isContinueAnyway
                ).jsonBody.render(),
                newMessageCount: newMessageCount,
                result: result
            ))
            let title = isContinueAnyway ? "Send draft sent anyway" : "Send draft sent"
            messages.recordAgentSendActivity(
                agentId: agent.id,
                title: title,
                text: [
                    "target: \(target)",
                    "freshness updates: \(AgentSendFreshnessGate.messageCountText(newMessageCount))",
                    isContinueAnyway
                        ? "decision: sent anyway after reviewing freshness context"
                        : "decision: saved draft freshness check passed when sent",
                ].joined(separator: "\n"),
                producerFactId: nil
            )
        }

        if let replayed = try replay() { return replayed }

        guard shouldRunFreshness else {
            return try commit()
        }
        // The upstream target freshness gate: the gate read, its retained
        // rows and the append it protects are one critical section, so two
        // concurrent first replies cannot both pass before either lands.
        return try managedMCP.withSendCommit { () throws -> any JSONBodyConvertible in
            if let replayed = try replay() { return replayed }
            let holdTitle = draftReholdCount > 0 || isSendDraft
                ? "Send draft held"
                : "Send held by freshness check"
            let outcome = freshness.evaluate(AgentSendFreshnessRequest(
                agentId: agent.id,
                serverId: serverId,
                channelId: resolved.channelId,
                targetRef: target,
                policy: .legacy,
                seenUpToSeq: seenUpToSeq,
                draftReholdCount: draftReholdCount,
                draftReplacedExisting: request.draftReplacedExisting,
                isSendDraft: isSendDraft,
                continueAnyway: isContinueAnyway,
                holdActivityTitle: holdTitle
            ))
            let proceed: AgentSendProceedFacts
            switch outcome {
            case .proceed(let facts):
                proceed = facts
            case .held(let facts):
                return LegacyAgentSendHeldResponse(
                    producerFactId: facts.producerFactId,
                    heldMessages: facts.heldMessages,
                    newMessageCount: facts.holdCount,
                    shownMessageCount: facts.shownCount,
                    omittedMessageCount: facts.omittedCount,
                    seenUpToSeq: facts.latestSeq,
                    seenUpToMessageId: facts.latestMessageId,
                    formalMentionCount: facts.formalMentionCount,
                    continueAnywaySuggested: facts.continueAnywaySuggested
                )
            }
            let sent = try commit()
            if isSendDraft {
                recordContinueEvent(sent, newMessageCount: proceed.newMessageCount)
            }
            return sent
        }
    }

    // MARK: - Legacy target resolution

    /// Upstream `resolveWritableAgentTarget` for the legacy route.
    private func resolveLegacyTarget(
        agent: OAuthLedger.AgentRuntimeInfo,
        target: String
    ) throws -> (channelId: String, kind: String, archived: Bool) {
        // `parseChannelRef` is the one suffix rule: only a full 8-hex suffix
        // is a thread id. Any other `:...` stays in the base target, so a
        // `dm:@peer:1` / `#room:1` can never create or join a phantom thread.
        let parsedRef = AgentChannelRef.parse(target)
        if target.hasPrefix("dm:@") || target.hasPrefix("DM:@") {
            let peerPart = String(parsedRef.baseRef.dropFirst(4))
            let suffix = parsedRef.threadShortId
            let channelId = try resolveLegacyDM(
                agent: agent,
                rawPeer: peerPart,
                suffix: suffix,
                target: target
            )
            let channel = channels.postableChannel(id: channelId)
            return (channelId, channel?.kind ?? "dm", channel?.archived ?? false)
        }
        if target.hasPrefix("#") {
            let raw = String(parsedRef.baseRef.dropFirst())
            let suffix = parsedRef.threadShortId
            guard let parent = channels.postableChannel(serverId: agent.serverId, name: raw),
                  parent.channel.kind == "channel"
                    || parent.channel.kind == "private"
                    || parent.channel.kind == "joint"
            else {
                throw AgentSendDeliveryError.channelTargetNotFound(target: target)
            }
            // A private/joint parent the agent cannot see is the neutral
            // not-found cloak, exactly like `resolveChannelByName`; only a
            // visible parent that refuses posting is the 403.
            let member = channels.postableChannel(id: parent.id)?.memberIds.contains(agent.id) == true
                || oauth.channelAgentIds(channelId: parent.id).contains(agent.id)
            guard parent.channel.kind == "channel" || member else {
                throw suffix == nil
                    ? AgentSendDeliveryError.channelTargetNotFound(target: target)
                    : AgentSendDeliveryError.threadTargetNotFound(target: target)
            }
            if let suffix {
                guard agentCanPost(agentId: agent.id, serverId: agent.serverId, channelId: parent.id) else {
                    throw AgentSendDeliveryError.forbiddenThreadTarget
                }
                let threadId = try resolveOrCreateLegacyThread(
                    agent: agent,
                    parentChannelId: parent.id,
                    suffix: suffix,
                    target: target
                )
                let thread = channels.postableChannel(id: threadId)
                return (threadId, "thread", thread?.archived ?? false)
            }
            guard agentCanPost(agentId: agent.id, serverId: agent.serverId, channelId: parent.id) else {
                throw AgentSendDeliveryError.forbiddenChannelTarget
            }
            return (parent.id, parent.channel.kind, parent.channel.archived)
        }
        // Upstream classifies a bare `@peer` as a legacy DM, but
        // `resolveWritableAgentTarget` only resolves `dm:@peer` and `#channel`
        // references, so this is the plain not-found reply.
        throw AgentSendDeliveryError.channelTargetNotFound(target: target)
    }

    private func resolveLegacyDM(
        agent: OAuthLedger.AgentRuntimeInfo,
        rawPeer: String,
        suffix: String?,
        target: String
    ) throws -> String {
        var peerName = rawPeer
        var kind: String?
        if let tilde = peerName.firstIndex(of: "~") {
            kind = String(peerName[peerName.index(after: tilde)...])
            peerName = String(peerName[..<tilde])
        }
        // Upstream strips only a trailing `~agent` / `~human` before comparing
        // the reserved reminders handle, so `dm:@reminders~bot` stays the
        // unknown-peer-kind refusal instead of becoming sendable-reminder.
        let reminderRef = rawPeer.replacingOccurrences(
            of: #"~(agent|human)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if reminderRef.lowercased() == "reminders" {
            throw AgentSendDeliveryError.dmTargetNotSendable
        }
        // `resolveWritableAgentTarget` takes the thread-shaped arm for any
        // last `:` plus any-length hex run. That arm never creates a DM: a
        // fallback lookup only reuses an existing one, otherwise the route's
        // plain not-found applies (`agentWritableTarget.ts:228-233, 245-249`).
        let threadShaped = suffix == nil && AgentChannelRef.isThreadShapedPeer(rawPeer)
        let resolution = prepare.resolveDMPeer(
            serverId: agent.serverId,
            agentId: agent.id,
            name: peerName,
            kind: kind
        )
        let peerId: String
        let peerKind: String
        let resolvedName: String
        switch resolution {
        case .resolved(let id, let peerType, let name):
            peerId = id
            peerKind = peerType
            resolvedName = name
        case .ambiguous(let name):
            throw AgentSendDeliveryError.dmTargetAmbiguous(name: name)
        case .invalidKind(let invalidKind, _):
            throw AgentSendDeliveryError.dmTargetInvalidPeerKind(
                rawPeer: rawPeer, suffix: invalidKind
            )
        case .notFound:
            if threadShaped {
                throw AgentSendDeliveryError.channelTargetNotFound(target: target)
            }
            // `resolveDMPeer` excludes the caller from the agent roster; the
            // pinned resolver includes it so `dm:@<self>` is the self-DM 400.
            // The name comparison is exact: a case variant is an unknown peer.
            if kind != "human", agent.name == peerName {
                throw AgentSendDeliveryError.selfDM
            }
            throw AgentSendDeliveryError.peerNotFound(peer: rawPeer)
        }
        if threadShaped {
            guard let existing = prepare.dmChannelId(
                serverId: agent.serverId,
                agentId: agent.id,
                peerId: peerId,
                peerKind: peerKind,
                peerName: resolvedName
            ) else {
                throw AgentSendDeliveryError.channelTargetNotFound(target: target)
            }
            guard agentCanPost(agentId: agent.id, serverId: agent.serverId, channelId: existing) else {
                throw AgentSendDeliveryError.forbiddenChannelTarget
            }
            return existing
        }
        // A migration receipt is a one-way notice: the pinned writable-target
        // resolver answers the read-only conflict before any sendability or
        // self-DM classification.
        if peerKind == "agent", peerId == agent.id, resolvedName.hasPrefix("migration-receipt-") {
            throw AgentSendDeliveryError.migrationReceiptReadOnly(target: target)
        }
        if let owner = assistantOwner(agent.id, agent.serverId), peerId != owner {
            // RFC 074 §2: an assistant may open a DM only with its owner.
            throw AgentSendDeliveryError.forbiddenChannelTarget
        }
        if peerKind == "agent", peerId == agent.id {
            throw AgentSendDeliveryError.selfDM
        }
        let dmChannelId: String
        if let existing = prepare.dmChannelId(
            serverId: agent.serverId,
            agentId: agent.id,
            peerId: peerId,
            peerKind: peerKind,
            peerName: resolvedName
        ) {
            guard agentCanPost(agentId: agent.id, serverId: agent.serverId, channelId: existing) else {
                throw AgentSendDeliveryError.forbiddenChannelTarget
            }
            dmChannelId = existing
        } else {
            dmChannelId = oauth.createDirectChannel(
                serverId: agent.serverId,
                firstUserId: agent.id,
                secondUserId: peerId,
                firstKind: .agent,
                secondKind: peerKind == "agent" ? .agent : .human
            )
            channels.addPostableChannel(
                serverId: agent.serverId,
                channelId: dmChannelId,
                memberId: agent.id,
                kind: "dm",
                parentChannelId: nil,
                parentMessageId: nil,
                name: nil
            )
            channels.addPostableChannel(
                serverId: agent.serverId,
                channelId: dmChannelId,
                memberId: peerId,
                kind: "dm",
                parentChannelId: nil,
                parentMessageId: nil,
                name: nil
            )
            if peerKind == "human" {
                oauth.addChannelHuman(channelId: dmChannelId, userId: peerId)
            }
        }
        guard let suffix else { return dmChannelId }
        return try resolveOrCreateLegacyThread(
            agent: agent,
            parentChannelId: dmChannelId,
            suffix: suffix,
            target: target,
            peerId: peerKind == "agent" ? peerId : nil
        )
    }

    private func resolveOrCreateLegacyThread(
        agent: OAuthLedger.AgentRuntimeInfo,
        parentChannelId: String,
        suffix: String,
        target: String,
        peerId: String? = nil
    ) throws -> String {
        // `MESSAGE_SHORT_ID_RE` is case-insensitive; UUIDs are stored lowercase,
        // so the 8-hex suffix is compared in its canonical lowercase form.
        let shortId = suffix.lowercased()
        if let existing = channels.historyThread(parentId: parentChannelId, idPrefix: shortId)
            ?? channels.historyThread(parentId: parentChannelId, anchorPrefix: shortId) {
            return existing
        }
        let anchorId = oauth.historyMessages(channelId: parentChannelId).first {
            $0.id.lowercased().hasPrefix(shortId)
        }?.id
            ?? messages.humanMessageRows.first {
                $0.channelId == parentChannelId && $0.id.lowercased().hasPrefix(shortId)
            }?.id
        guard let anchorId else {
            throw AgentSendDeliveryError.threadTargetNotFound(target: target)
        }
        if let existing = channels.historyThread(parentId: parentChannelId, anchorMessageId: anchorId) {
            return existing
        }
        let threadId = oauth.createThreadChannel(
            parentChannelId: parentChannelId,
            parentMessageId: anchorId
        )
        var members = [agent.id]
        if let peerId, !members.contains(peerId) { members.append(peerId) }
        for member in members {
            channels.addPostableChannel(
                serverId: agent.serverId,
                channelId: threadId,
                memberId: member,
                kind: "thread",
                parentChannelId: parentChannelId,
                parentMessageId: anchorId,
                name: "thread"
            )
        }
        return threadId
    }

    /// Upstream `canAgentPostToChannel`: the assistant owner-DM confinement
    /// comes first (raw retained binding), then the enabled `#all` surface is
    /// open to every agent in the server; every other channel needs an actual
    /// agent membership, including public ones.
    private func agentCanPost(agentId: String, serverId: String, channelId: String) -> Bool {
        AgentPostAuthority(oauth: oauth, channels: channels, agents: agents)
            .canPost(serverId: serverId, agentId: agentId, channelId: channelId)
    }

    // MARK: - POST /internal/agent/:agentId/receive-ack

    /// `POST /internal/agent/:agentId/receive-ack` — legacy delivery ack.
    ///
    /// The volatile delivery buffer ack is not modeled here (the port has no
    /// orchestrator). Pre-model-seen daemons additionally get the per-channel
    /// usability checkpoint this route always kept; a daemon that advertises
    /// the model-seen boundary capability is a volatile ack only, so legacy
    /// state can never masquerade as freshness proof.
    ///
    /// The cursor decision and the version bump are one
    /// `MessagesAndThreadsStore` critical section.
    public func legacyAgentReceiveAck(
        authorization: String?,
        agentId: String,
        body: AgentReceiveAckRequest?
    ) throws -> OkResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentSendDeliveryError.missingAuthorization
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        let credential = machines.machineCredential(apiKey: apiKey, agentId: agentId)
        guard let serverId = credential.machine?.serverId ?? credential.legacy?.serverId else {
            throw AgentSendDeliveryError.invalidToken
        }
        if let legacy = credential.legacy, legacy.agentId != agentId {
            throw AgentSendDeliveryError.agentNotFound
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
            throw AgentSendDeliveryError.agentNotFound
        }
        let request = body ?? AgentReceiveAckRequest()
        guard !request.seqs.isEmpty || !request.messageIds.isEmpty else {
            throw AgentSendDeliveryError.receiveAckEmpty
        }
        if credential.modelSeenCapability || request.seqs.isEmpty {
            return OkResponse()
        }

        let channelSnapshot = channels.deliveryAckChannelSnapshot()
        let messageSnapshot = messages.deliveryAckMessageSnapshot()
        var maxSeqByChannel: [String: Int] = [:]
        for seq in request.seqs {
            for row in messageSnapshot.rows where row.seq == seq {
                let storageId = row.channelId
                let localId = channelSnapshot.jointProjections.first {
                    $0.canonicalChannelId == storageId && $0.serverId == serverId
                }?.localChannelId ?? storageId
                guard let channel = channelSnapshot.channels[localId] else { continue }
                let isMember: Bool
                if channel.kind == "thread", let parentId = channel.parentChannelId {
                    isMember = channelSnapshot.channels[parentId]?.memberIds.contains(agentId) == true
                        || oauth.channelAgentIds(channelId: parentId).contains(agentId)
                        || messageSnapshot.threadFollows.values.contains {
                            $0.serverId == serverId && $0.userId == agentId && $0.threadChannelId == localId
                        }
                } else {
                    isMember = channel.memberIds.contains(agentId)
                        || oauth.channelAgentIds(channelId: localId).contains(agentId)
                }
                guard isMember else { continue }
                maxSeqByChannel[localId] = max(maxSeqByChannel[localId] ?? 0, seq)
            }
        }
        messages.advanceAgentReadCursors(agentId: agentId, maxSeqByChannel: maxSeqByChannel)
        return OkResponse()
    }

    // MARK: - POST /internal/agent/:agentId/runtime-profile/migration-done

    /// Deprecated acknowledgement. A missing `migrationKey` keeps the `noop`
    /// field; a present one (including an empty string decoded from a malformed
    /// body) omits it.
    public func runtimeProfileMigrationDone(
        authorization: String?,
        agentId: String,
        body: AgentRuntimeProfileMigrationDTO?
    ) throws -> AgentRuntimeProfileMigrationResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentSendDeliveryError.missingAuthorization
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        guard let machine = machines.machine(apiKey: apiKey) else {
            throw AgentSendDeliveryError.invalidToken
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machine.serverId else {
            throw AgentSendDeliveryError.agentNotFound
        }
        let migrationKey = body?.migrationKey ?? ""
        return AgentRuntimeProfileMigrationResponse(noop: migrationKey.isEmpty)
    }

    // MARK: - Hosted-agent flag

    /// Marks an agent as hosted by the profile/creation flows. This is not an
    /// HTTP operation; the test seam and the join-link policy share it.
    public func markAgentHosted(agentId: String) {
        agents.markHosted(agentId: agentId)
    }

    // MARK: - POST /internal/agent-api/activity

    /// `POST /internal/agent-api/activity`.
    ///
    /// The v1 schema only reports unknown fields (and rejects
    /// `transcript_path`); the standard schema folds status/hook events into the
    /// agent's presence rows. Status adoption, occurrence timestamps, activity
    /// detail and the dedupe set are applied by one `AgentsRuntimeStore`
    /// critical section, matching the legacy loop's partial-write behavior.
    public func agentActivityIngest(
        authorization: String?,
        body: AgentActivityIngestRequest?
    ) throws -> AgentActivityIngestResponse {
        guard let credential = useCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              credential.scopes.contains("read")
        else {
            throw AgentSendDeliveryError.capabilityNotAuthorized
        }
        guard let body else {
            throw AgentSendDeliveryError.activityInvalid
        }
        if body.schema == "raft-agent-activity-ingest.v1" {
            let allowed: Set<String> = [
                "eventId", "hookEventName", "toolName", "toolInput", "truncated",
                "tool_use_id", "exit_code", "ok", "subagent",
            ]
            var ignored: Set<String> = []
            for event in body.events {
                for key in event.fields.keys where !allowed.contains(key) {
                    if key == "transcript_path" {
                        throw AgentSendDeliveryError.transcriptPathForbidden
                    }
                    ignored.insert(key)
                }
            }
            return AgentActivityIngestResponse(
                acceptedCount: body.events.count,
                rejectedCount: 0,
                droppedCount: body.dropped,
                ignoredFields: ignored.sorted()
            )
        }
        switch agents.applyActivityIngest(agentId: agent.id, events: body.events, now: now) {
        case .applied(let accepted, let rejected):
            return AgentActivityIngestResponse(
                acceptedCount: accepted,
                rejectedCount: rejected,
                droppedCount: 0
            )
        case .invalidStatus:
            throw AgentSendDeliveryError.statusInvalid
        case .detailInvalid:
            throw AgentSendDeliveryError.detailInvalid
        case .detailTooLong:
            throw AgentSendDeliveryError.detailTooLong
        }
    }

    // MARK: - GET /internal/agent-api/threads

    /// Lists the agent's active, visible thread follows, newest first.
    public func agentThreadList(authorization: String?) throws -> AgentThreadListResponse {
        guard let credential = useCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentSendDeliveryError.invalidToken
        }
        guard credential.scopes.contains("read") else {
            throw AgentSendDeliveryError.capabilityNotAuthorized
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = threadFollows.all()
            .filter { $0.serverId == agent.serverId && $0.agentId == agent.id && $0.unfollowedAt == nil }
            .filter {
                searchVisible($0.threadChannelId, agent.serverId, .agent(agent.id))
            }
            .sorted { $0.followedAt > $1.followedAt }
            .compactMap { follow -> AgentThreadListEntry? in
                guard let thread = channels.postableChannel(id: follow.threadChannelId),
                      let parentChannelId = thread.parentChannelId,
                      let parent = channels.postableChannel(id: parentChannelId)
                else { return nil }
                let short = String(follow.parentMessageId.prefix(8))
                return AgentThreadListEntry(
                    target: "#\(parent.name):\(short)",
                    threadChannelId: follow.threadChannelId,
                    parentChannelRef: "#\(parent.name)",
                    parentMessageId: follow.parentMessageId,
                    parentMessageShortId: short,
                    followedAt: formatter.string(from: follow.followedAt),
                    reason: follow.reason,
                    doneAt: follow.doneAt.map { formatter.string(from: $0) }
                )
            }
        return AgentThreadListResponse(threads: rows)
    }

    // MARK: - POST /internal/agent/:agentId/threads/unfollow
    // MARK: - POST /internal/agent-api/threads/unfollow

    /// Unfollows one thread by id or `#channel:shortId` reference.
    public func agentThreadUnfollow(
        authorization: String?,
        body: AgentThreadUnfollowRequest?,
        legacyAgentId: String? = nil
    ) throws -> OkResponse {
        guard let writer = taskWriter(authorization, legacyAgentId: legacyAgentId),
              let agent = oauth.agentRuntimeInfo(id: writer.agentId), !agent.deleted
        else {
            throw AgentSendDeliveryError.invalidToken
        }
        if let credential = useCredential(authorization), !credential.scopes.contains("read") {
            throw AgentSendDeliveryError.capabilityNotAuthorized
        }
        guard let body, let threadRef = body.thread, !threadRef.isEmpty else {
            throw AgentSendDeliveryError.invalidThreadUnfollow
        }
        if threadRef.hasPrefix("#"), !threadRef.contains(":") {
            throw AgentSendDeliveryError.targetMustBeThread
        }
        var threadId: String?
        if threadRef.hasPrefix("#"), let colon = threadRef.firstIndex(of: ":") {
            let channelName = String(threadRef[threadRef.index(after: threadRef.startIndex)..<colon])
            let short = String(threadRef[threadRef.index(after: colon)...])
            if let parent = channels.postableChannelIncludingDeleted(serverId: agent.serverId, name: channelName) {
                threadId = channels.threadChannel(parentChannelId: parent.id, shortId: short)?.id
            }
        } else {
            threadId = threadRef
        }
        guard let resolved = threadId,
              let thread = channels.postableChannel(id: resolved),
              thread.serverId == agent.serverId,
              thread.kind == "thread",
              thread.deletedAt == nil
        else {
            throw AgentSendDeliveryError.threadNotFound
        }
        guard searchVisible(resolved, agent.serverId, .agent(agent.id)) else {
            throw AgentSendDeliveryError.threadNotFound
        }
        threadFollows.markUnfollowed(
            serverId: agent.serverId,
            agentId: agent.id,
            threadChannelId: resolved,
            at: now()
        )
        return OkResponse()
    }

    // MARK: - GET /internal/agent-api/integrations

    /// Lists the server's integration services plus the agent's active logins.
    public func agentIntegrationList(authorization: String?) throws -> AgentIntegrationListResponse {
        guard let credential = useCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentSendDeliveryError.invalidToken
        }
        let services = integrationServices(agent.serverId)
        let active = managedMCP.agentIntegrationLogins.values
            .filter { $0.serverId == agent.serverId && $0.agentId == agent.id }
            .sorted { $0.loggedInAt < $1.loggedInAt }
            .compactMap { login -> AgentIntegrationActiveLogin? in
                guard let service = services.first(where: { $0.id == login.clientId }) else { return nil }
                return AgentIntegrationActiveLogin(
                    clientId: service.clientId ?? "",
                    agentManifestUrl: service.agentManifestUrl,
                    agentManifestUrlSource: service.agentManifestUrlSource
                )
            }
        let resolved = services.map { service -> AgentIntegrationServiceSnapshot in
            guard let id = service.id,
                  let state = oauth.getAppInstallationSetup(clientRecordId: id, serverId: agent.serverId)
            else { return service }
            return service.withSetup(AgentIntegrationSetup(
                status: state.status.rawValue,
                url: state.url,
                description: state.description,
                revision: state.revision
            ))
        }
        return AgentIntegrationListResponse(services: resolved, activeLogins: active)
    }

    // MARK: - Credentials

    /// The shared legacy machine/agent-ownership gate. The send route uses the
    /// two-phase form to keep body validation between machine auth and scope.
    private var legacyMachineGate: LegacyAgentMachineGate {
        LegacyAgentMachineGate(
            agents: agents,
            machines: machines,
            oauth: oauth,
            cards: managedMCP
        )
    }

    /// The shared `sk_agent_*` credential check: revoked or absent credentials
    /// are `nil`, a live one is marked used by the store in one critical section.
    private func useCredential(_ authorization: String?) -> (agentId: String, scopes: [String])? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return agents.useAgentCredential(token: token, now: now())
    }

    /// The write-route identity: an `sk_agent_*` credential, or the legacy
    /// machine key plus the path agent id.
    private func taskWriter(
        _ authorization: String?,
        legacyAgentId: String?
    ) -> (agentId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        if let credential = agents.agentCredential(token: token), credential.revokedAt == nil,
           let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted {
            return (agent.id, agent.serverId)
        }
        if let machine = machines.machine(apiKey: token),
           let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return (agent.id, agent.serverId)
        }
        return nil
    }
}
