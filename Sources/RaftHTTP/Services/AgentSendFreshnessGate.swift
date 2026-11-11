import Foundation

/// What one agent send route asks the shared freshness gate.
///
/// The two send routes differ only in their declared surface: the credential
/// route accepts exact-seq proofs, seen cards and withheld context and never
/// exempts a formal mention; the legacy machine-on-behalf route accepts
/// `seenUpToSeq`/draft markers and exempts a formal mention inside the
/// left-exclusive freshness range. Everything the gate itself does — the
/// boundary, the attention range, the hold decision, the bounded context, the
/// read checkpoint and the retained event/activity rows — is shared.
struct AgentSendFreshnessRequest: Sendable {
    enum Policy: Sendable {
        /// `/internal/agent-api/send`: hold on newer attention, no E1 exemption.
        case credential
        /// `/internal/agent/:id/send`: exempt a formal mention, then hold.
        case legacy
    }

    var agentId: String
    var serverId: String
    var channelId: String
    var targetRef: String
    var policy: Policy
    var seenUpToSeq: Int?
    var seenExactSeqs: [Int] = []
    /// Credential-only reviewer isolation; the legacy route ignores it.
    var withheld: Bool = false
    var draftReholdCount: Int = 0
    var draftReplacedExisting: Bool = false
    var isSendDraft: Bool = false
    var continueAnyway: Bool = false
    /// Title the hold activity entry carries (the routes differ on drafts).
    var holdActivityTitle: String = "Send held by freshness check"
}

/// The retained facts of a freshness hold, already decided.
struct AgentSendHeldFacts: Sendable {
    var targetType: String
    var boundarySource: String
    var boundarySeq: Int
    var boundaryMessageId: String?
    var latestSeq: Int
    var latestMessageId: String?
    var attentionCount: Int
    var shownCount: Int
    var omittedCount: Int
    var holdCount: Int
    var formalMentionCount: Int
    var producerFactId: String
    /// Renderable held envelopes; empty for a withheld (reviewer-isolation) hold.
    var heldMessages: [String]
    var firstShownSeq: Int?
    var continueAnywaySuggested: Bool
    var withheld: Bool
}

/// The facts a route needs when the gate lets the send proceed.
struct AgentSendProceedFacts: Sendable {
    var targetType: String
    /// Attention messages in the freshness range; the legacy continue event
    /// reports this count.
    var newMessageCount: Int
    /// The formal mention that exempted the hold (legacy only), when any.
    var exemptedMentionMessageId: String?
}

enum AgentSendFreshnessOutcome: Sendable {
    case proceed(AgentSendProceedFacts)
    case held(AgentSendHeldFacts)
}

/// The attested-send gate shared by the credential and legacy send routes.
///
/// It owns one copy of the upstream `evaluateAgentFreshness` /
/// `renderAgentFreshnessHold` decisions: the boundary (client-seen or
/// thread-parent), the left-exclusive attention range with suppressed and
/// self-caused rows removed, formal-mention facts, the hold decision, the
/// bounded three-message context, the read checkpoint and the
/// `gate_triggered` / `e1_exempt` retained rows plus their activity entries.
/// Callers own their own response DTOs, their card/withheld extras and their
/// commit path; the concurrency gate is the caller's commit lock.
struct AgentSendFreshnessGate: Sendable {
    /// Upstream `ATTESTED_SEND_HELD_CONTEXT_LIMIT`.
    static let heldContextLimit = 3

    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let prepare: ActionCardPrepareService
    private let suppression: MessageSuppressionService

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        prepare: ActionCardPrepareService,
        oauth: OAuthLedger
    ) {
        self.messages = messages
        self.channels = channels
        self.prepare = prepare
        self.suppression = MessageSuppressionService(messages: messages, oauth: oauth)
    }

    /// Evaluates one send and records the hold/exemption rows and activity.
    /// Returns `.proceed` when the caller may commit.
    func evaluate(_ request: AgentSendFreshnessRequest) -> AgentSendFreshnessOutcome {
        let snapshot = messages.sendFreshnessSnapshot(channelId: request.channelId, agentId: request.agentId)
        let conversation = channels.postableChannels[request.channelId]
        let storageChannelId = channels.jointProjections.first {
            $0.localChannelId == request.channelId
        }?.canonicalChannelId ?? request.channelId

        func isSelf(_ message: StoredHumanMessage) -> Bool {
            message.senderType == "agent" && message.senderId == request.agentId
        }

        let rows = snapshot.rows.filter { $0.channelId == storageChannelId }
        let latestFromOthers = rows.last { !isSelf($0) }?.seq ?? 0
        let threadParentSeq = conversation?.kind == "thread"
            ? (conversation?.parentMessageId.flatMap { parentId in
                snapshot.rows.first { $0.id == parentId }?.seq
            } ?? 0)
            : 0
        let fallbackBoundarySeq = conversation?.kind == "thread" ? threadParentSeq : 0
        let boundarySeq = min(request.seenUpToSeq ?? fallbackBoundarySeq, latestFromOthers)
        let effectiveExactSeqs = Set(
            request.seenExactSeqs.filter { $0 > boundarySeq && $0 <= latestFromOthers }
        )
        let boundarySource: String
        if request.seenUpToSeq != nil {
            boundarySource = "client_seen"
        } else if !effectiveExactSeqs.isEmpty {
            boundarySource = "client_seen_exact"
        } else if fallbackBoundarySeq > 0 {
            boundarySource = "thread_parent"
        } else {
            boundarySource = "none"
        }
        let hasModelSeenProof = boundarySource == "client_seen"
            || boundarySource == "client_seen_exact"
        let newer = rows.filter {
            $0.seq > boundarySeq
                && !isSelf($0)
                && !effectiveExactSeqs.contains($0.seq)
                && !suppression.isSuppressed($0, agentId: request.agentId)
                && !AgentSendFreshnessPolicy.isSelfCausedExempt($0, agentId: request.agentId)
        }
        let targetType = Self.attestedTargetType(conversation?.kind)
        let attentionCount = newer.count

        // Formal-mention facts over the same left-exclusive range. The legacy
        // route exempts the hold; the credential route only annotates it.
        var formalMentionCount = 0
        var firstMention: (messageId: String, handle: String)?
        for entry in newer {
            guard let mention = snapshot.mentions.first(where: {
                $0.messageId == entry.id
                    && $0.targetType == "agent"
                    && $0.targetId == request.agentId
                    && ($0.notifiableAtSend || $0.notifiedAt != nil)
            }) else { continue }
            formalMentionCount += 1
            if firstMention == nil {
                firstMention = (mention.messageId, mention.handle)
            }
        }

        if request.policy == .legacy, formalMentionCount > 0, let firstMention {
            messages.recordAttestedSendEvent(AttestedSendEventRecord(
                eventType: "e1_exempt",
                agentId: request.agentId,
                messageId: firstMention.messageId,
                metadataJSON: AttestedSendEventMetadata.mentionExemption(
                    mentionMessageId: firstMention.messageId,
                    mentionedHandle: firstMention.handle,
                    newMessageCountSinceLastSeen: attentionCount
                ).jsonBody.render(),
                newMessageCount: attentionCount
            ))
            messages.recordAgentSendActivity(
                agentId: request.agentId,
                title: "Send freshness check passed by mention",
                text: [
                    "target: \(request.targetRef)",
                    "reason: direct @\(firstMention.handle) mention",
                    "new messages: \(Self.messageCountText(attentionCount))",
                ].joined(separator: "\n"),
                producerFactId: nil
            )
            return .proceed(AgentSendProceedFacts(
                targetType: targetType,
                newMessageCount: attentionCount,
                exemptedMentionMessageId: firstMention.messageId
            ))
        }

        guard !request.continueAnyway, !newer.isEmpty else {
            return .proceed(AgentSendProceedFacts(
                targetType: targetType,
                newMessageCount: attentionCount,
                exemptedMentionMessageId: nil
            ))
        }

        let latestSeq = newer[newer.count - 1].seq
        let latestMessageId = newer[newer.count - 1].id
        let shownRows = Array(newer.suffix(Self.heldContextLimit))
        let shownCount = shownRows.count
        let holdCount = hasModelSeenProof ? attentionCount : min(attentionCount, Self.heldContextLimit)
        let omittedCount = hasModelSeenProof ? max(0, attentionCount - shownCount) : 0
        let showedEveryHeldMessage = shownCount >= attentionCount
        let conversationIdentity = prepare.heldConversationIdentity(
            channelId: request.channelId,
            agentId: request.agentId
        )
        let heldMessageJSON = request.withheld ? [] : shownRows.map { message in
            prepare.heldFreshnessMessageJSON(
                seq: message.seq,
                message: message,
                conversationIdentity: conversationIdentity
            )
        }
        if !request.withheld, showedEveryHeldMessage, latestSeq > snapshot.readCursor.seq {
            messages.advanceAgentReadCursors(
                agentId: request.agentId,
                maxSeqByChannel: [request.channelId: latestSeq]
            )
        }
        let reason = boundarySource == "none" || boundarySource == "thread_parent"
            ? "server_first_touch_context"
            : "server_stale_model_boundary"
        let producerFactId = AgentFreshnessIdentity.freshnessDecisionProducerFactId(
            agentId: request.agentId,
            target: request.targetRef,
            reason: reason,
            pendingMaxSeq: latestSeq,
            modelSeenSeq: boundarySource == "client_seen" ? boundarySeq : 0,
            heldMessageCount: shownCount,
            omittedMessageCount: omittedCount
        )
        if !request.withheld {
            let boundaryMessageId: String? = boundarySeq > 0
                ? (conversation?.kind == "thread" && threadParentSeq == boundarySeq
                    ? conversation?.parentMessageId
                    : rows.first { $0.seq == boundarySeq }?.id)
                : nil
            messages.recordAttestedSendEvent(AttestedSendEventRecord(
                eventType: "gate_triggered",
                agentId: request.agentId,
                messageId: nil,
                metadataJSON: AttestedSendEventMetadata.gateTriggered(
                    lastSeenMessageId: boundaryMessageId,
                    latestMessageId: latestMessageId,
                    draftReplacedExisting: request.draftReplacedExisting,
                    newMessageCount: holdCount,
                    boundarySource: boundarySource,
                    boundarySeq: boundarySeq,
                    latestSeq: latestSeq
                ).jsonBody.render(),
                newMessageCount: holdCount
            ))
            messages.recordAgentSendActivity(
                agentId: request.agentId,
                title: request.holdActivityTitle,
                text: "target: \(request.targetRef)\n"
                    + "unreviewed synced context for this target: \(Self.heldContextCountText(shownCount))\n"
                    + "reason: this target's latest synced context was not yet in your reviewed context\n"
                    + "action: review the synced context before sending",
                producerFactId: producerFactId
            )
        }
        return .held(AgentSendHeldFacts(
            targetType: targetType,
            boundarySource: boundarySource,
            boundarySeq: boundarySeq,
            boundaryMessageId: boundarySeq > 0
                ? (conversation?.kind == "thread" && threadParentSeq == boundarySeq
                    ? conversation?.parentMessageId
                    : rows.first { $0.seq == boundarySeq }?.id)
                : nil,
            latestSeq: latestSeq,
            latestMessageId: latestMessageId,
            attentionCount: attentionCount,
            shownCount: shownCount,
            omittedCount: omittedCount,
            holdCount: holdCount,
            formalMentionCount: formalMentionCount,
            producerFactId: producerFactId,
            heldMessages: heldMessageJSON,
            firstShownSeq: shownRows.first?.seq,
            continueAnywaySuggested: request.draftReholdCount >= 3,
            withheld: request.withheld
        ))
    }

    /// `toAttestedSendTargetType`: private and joint channels are `channel`.
    static func attestedTargetType(_ kind: String?) -> String {
        switch kind {
        case "dm": "dm"
        case "thread": "thread"
        default: "channel"
        }
    }

    /// Upstream `formatAttestedMessageCount`.
    static func messageCountText(_ count: Int) -> String {
        "\(count) newer message\(count == 1 ? "" : "s")"
    }

    /// The held activity's count line: `3 messages`, never "newer messages".
    static func heldContextCountText(_ count: Int) -> String {
        "\(count) message\(count == 1 ? "" : "s")"
    }
}
