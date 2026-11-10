import Foundation
import RaftObjectStorage
import RaftShared

/// A server-generated onboarding artifact could not be produced faithfully. The
/// caller releases the opener claim and writes no sent stamp, so the next
/// activation retries the same idempotent step.
enum OnboardingBriefingArtifactError: Error, Sendable, Equatable {
    /// The deployment requires durable object storage but none is configured.
    case storageUnavailable
    /// A stable projection id already points at a different attachment row.
    case projectionConflict
    /// The reply's attachment could not be linked by the message owner.
    case replyRejected
}

/// The owner onboarding briefing. Upstream `triggerOwnerOnboardingOnAgentActivation`
/// (`services/onboardingService.ts:820-994`).
///
/// The briefing is a transient, agent-only system wake. It is never a channel
/// message and never a `message:new`; the visible opener messages are a
/// separate, idempotent producer (upstream `sendOwnerOpenerV2`). The owner's
/// survey answer travels inside the wake, and the one-shot sent stamp is
/// written only after the delivery admission returned a typed acceptance.
///
/// The pinned deployment has `onboarding_opener_v2` default-ON (migration 0144
/// turns the flag on for every server). This port has no flag-provisioning
/// migration, so a missing row is the pinned default: opener-v2 enabled. An
/// explicitly provisioned flag (enabled/kill switch/rules/default) still
/// decides. The legacy `buildOnboardingInstruction` path is not emitted by this
/// slice; an explicitly disabled flag returns `.openerDisabled` and stamps
/// nothing rather than posting opener content under the wrong contract.
public enum OnboardingBriefingOutcome: Sendable, Equatable {
    case sent(agentId: String, channelId: String, messageIds: [String], noticeCommandId: UUID)
    case noServer
    case notOwner
    case notEligible
    case noOnboardingAgent
    case openerDisabled
    case surveyPending
    case noOwnerPreferences
    case alreadyBriefed
    case alreadySent
    case agentInactive
    case claimUnavailable
    case targetChannelUnavailable
    case noticeDropped(AgentExecutionNoticeDropReason)
    case failed
}

public struct OnboardingBriefingService: Sendable {
    private let channels: ServersAndChannelsStore
    private let profiles: AuthProfileStore
    private let agents: AgentsRuntimeStore
    private let messages: MessagesAndThreadsStore
    private let oauth: OAuthLedger
    private let execution: AgentExecutionService
    private let now: @Sendable () -> Date

    init(
        channels: ServersAndChannelsStore,
        profiles: AuthProfileStore,
        agents: AgentsRuntimeStore,
        messages: MessagesAndThreadsStore,
        oauth: OAuthLedger,
        execution: AgentExecutionService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.channels = channels
        self.profiles = profiles
        self.agents = agents
        self.messages = messages
        self.oauth = oauth
        self.execution = execution
        self.now = now
    }

    /// The idempotent owner trigger. Every caller passes the server's configured
    /// onboarding agent (handoff, survey save, machine ready); the agent gate is
    /// the same equality upstream checks.
    ///
    /// - Parameters:
    ///   - requestedByOwnerId: set by the survey-save route. A caller who is not
    ///     the server's primary owner gets `.notOwner` (upstream checks
    ///     `server.ownerId === req.userId`).
    ///   - activatedAgentId: set by activation/ready callers. Any other agent
    ///     activating is not an onboarding activation.
    public func trigger(serverId: String, requestedByOwnerId: String? = nil,
                        activatedAgentId: String? = nil) async -> OnboardingBriefingOutcome {
        guard let server = oauth.serverProfile(id: serverId) else { return .noServer }
        let ownerId = server.ownerId
        if let requestedByOwnerId, requestedByOwnerId != ownerId { return .notOwner }

        let snapshot = channels.onboardingSnapshot(serverId: serverId, userId: ownerId)
        if let activatedAgentId, activatedAgentId != snapshot.agentId { return .notEligible }

        guard openerV2Enabled(serverId: serverId, ownerId: ownerId) else { return .openerDisabled }

        // The survey is asked one screen after Cindy is created. Returning here
        // claims nothing, so the identical call after the survey save delivers
        // the briefing WITH the role in it.
        guard let owner = profiles.account(userId: ownerId),
              owner.signupSurveyCompletedAt != nil else { return .surveyPending }

        // Upstream `getMemberOnboardingPreferences`: a missing member row means
        // no onboarding prefs. `setupModalReminderOptOut` is intentionally not
        // consulted.
        guard oauth.memberRole(serverId: serverId, userId: ownerId) != nil else { return .noOwnerPreferences }

        let ledger = channels.ownerOpenerLedger(serverId: serverId, ownerId: ownerId)
        if ledger.openerV2SentAt == nil, ledger.dmSentAt != nil { return .alreadyBriefed }
        if ledger.openerV2SentAt != nil { return .alreadySent }

        // Only a live onboarding-agent pointer briefs. A stale/deleted pointer is
        // self-healed (cleared) exactly like upstream `pickOnboardingAgent`;
        // no replacement agent is invented.
        guard let configuredAgentId = snapshot.agentId else { return .noOnboardingAgent }
        guard let agent = oauth.agentRuntimeInfo(id: configuredAgentId), !agent.deleted,
              agent.serverId == serverId else {
            channels.clearOnboardingAgent(serverId: serverId)
            return .noOnboardingAgent
        }
        guard agent.status == "active" else { return .agentInactive }

        let sentAt = now()
        guard let claim = channels.claimOwnerOpener(serverId: serverId, ownerId: ownerId, now: sentAt) else {
            return .claimUnavailable
        }

        let opener: OwnerOpenerDelivery
        do {
            guard let delivered = try await sendOwnerOpenerV2(serverId: serverId, ownerId: ownerId,
                                                              agentId: agent.id, sentAt: sentAt) else {
                channels.releaseOwnerOpenerClaim(serverId: serverId, ownerId: ownerId, token: claim)
                return .targetChannelUnavailable
            }
            opener = delivered
        } catch {
            channels.releaseOwnerOpenerClaim(serverId: serverId, ownerId: ownerId, token: claim)
            return .failed
        }

        // A dropped receipt means the briefing did not happen: warn, do not
        // stamp, and retry on the next activation. Visible messages and the
        // artifact thread are already idempotent, so the retry is invisible to
        // the human.
        let receipt: AgentExecutionNoticeReceipt
        do {
            receipt = try execution.requestNotice(AgentExecutionNoticeRequest(
                serverId: serverId, agentId: agent.id, channelId: opener.channelId,
                channelName: opener.channelName, channelType: "channel",
                content: OnboardingBriefingContent.ledgerInstruction(
                    userName: owner.name,
                    locationHint: "#\(opener.channelName) channel",
                    messageIds: opener.messageIds,
                    artifactAttachmentId: opener.artifactAttachmentId,
                    roleLabel: OnboardingBriefingContent.roleLabel(owner.signupRole),
                    referralLabel: owner.referralSource.flatMap { OnboardingBriefingContent.referralLabel($0) }
                ),
                messageId: "opener-v2-ledger-\(serverId)",
                timestamp: DateText.isoString(sentAt)
            ))
        } catch {
            channels.releaseOwnerOpenerClaim(serverId: serverId, ownerId: ownerId, token: claim)
            return .failed
        }
        guard case .accepted(let commandId) = receipt else {
            channels.releaseOwnerOpenerClaim(serverId: serverId, ownerId: ownerId, token: claim)
            if case .dropped(let reason) = receipt { return .noticeDropped(reason) }
            return .failed
        }

        // The real typed receipt decides the sent stamp. A human handoff
        // acknowledgment never stands in for delivery.
        channels.stampOwnerOpener(
            serverId: serverId, ownerId: ownerId, agentId: agent.id, at: sentAt,
            messageIds: opener.messageIds, version: OnboardingBriefingContent.openerV2Version,
            topics: OnboardingBriefingContent.openerV2Topics
        )
        return .sent(agentId: agent.id, channelId: opener.channelId,
                     messageIds: opener.messageIds, noticeCommandId: commandId)
    }

    /// The `machine:online` analogue: on every authenticated ready frame, first
    /// re-establish who the owner is, then retry the idempotent opener trigger.
    /// Owner facts are deliberately not gated on the opener trigger, so a
    /// server that finished onboarding still re-teaches its agent the owner's
    /// facts on every wake.
    public func connectionReady(serverId: String) async {
        guard let server = oauth.serverProfile(id: serverId) else { return }
        let snapshot = channels.onboardingSnapshot(serverId: serverId, userId: server.ownerId)
        guard let agentId = snapshot.agentId else { return }
        _ = deliverOwnerFacts(serverId: serverId)
        _ = await trigger(serverId: serverId, activatedAgentId: agentId)
    }

    /// Upstream `deliverOwnerFactsContext`. Recomputed from the database on
    /// every wake; no stamp, no dedupe. A dropped delivery is not lost — the
    /// next wake recomputes and hands it over again.
    @discardableResult
    public func deliverOwnerFacts(serverId: String) -> Bool {
        guard let server = oauth.serverProfile(id: serverId),
              let owner = profiles.account(userId: server.ownerId) else { return false }
        let snapshot = channels.onboardingSnapshot(serverId: serverId, userId: server.ownerId)
        guard let agentId = snapshot.agentId,
              let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
            return false
        }
        let receipt: AgentExecutionNoticeReceipt
        do {
            receipt = try execution.requestNotice(AgentExecutionNoticeRequest(
                serverId: serverId, agentId: agentId,
                channelId: "onboarding-context", channelName: "onboarding-context",
                channelType: "channel",
                content: OnboardingBriefingContent.ownerFacts(
                    ownerName: owner.name, displayName: owner.displayName,
                    roleLabel: OnboardingBriefingContent.roleLabel(owner.signupRole),
                    referralLabel: owner.referralSource.flatMap { OnboardingBriefingContent.referralLabel($0) }
                ),
                messageId: "onboarding-owner-facts-\(serverId)",
                timestamp: DateText.isoString(now())
            ))
        } catch {
            return false
        }
        guard case .accepted = receipt else { return false }
        return true
    }

    // MARK: - Owner opener visible messages

    private struct OwnerOpenerDelivery {
        let channelId: String
        let channelName: String
        let messageIds: [String]
        /// The Team-Mode artifact attachment id, when the thread step produced
        /// one. Upstream's ledger line is conditional on it.
        let artifactAttachmentId: String?
    }

    /// Upstream `sendOwnerOpenerV2`: four visible agent messages in the owner's
    /// `onboarding-owner` channel, else the enabled `#all`. Every message is
    /// committed with the upstream `agentSendKey`, so a replay (claim released,
    /// next activation) never posts a second copy and the ledger message ids
    /// stay aligned with the four topics.
    ///
    /// The second message's thread is part of the same producer: the canonical
    /// thread under that message, the generated `text/html` artifact attachment
    /// written through the ordinary attachment storage, and the
    /// `team-mode-thread` reply that carries it. The thread reply stays out of
    /// the ledger's message-id list, exactly like upstream.
    private func sendOwnerOpenerV2(serverId: String, ownerId: String,
                                   agentId: String, sentAt: Date) async throws -> OwnerOpenerDelivery? {
        guard let owner = profiles.account(userId: ownerId),
              let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId,
              let target = ownerOpenerTargetChannel(serverId: serverId, ownerId: ownerId) else {
            return nil
        }
        let senderName = agent.displayName.isEmpty ? agent.name : agent.displayName
        ensureOwnerOpenerMembership(target: target, ownerId: ownerId, agentId: agentId)
        let relay = RealtimeRelayService(messages: messages)
        var ids: [String] = []
        var artifactAttachmentId: String?
        for message in OnboardingBriefingContent.openerMessages(userName: owner.name) {
            let key = "\(OnboardingBriefingContent.openerV2Version):\(serverId):\(ownerId):\(message.topic)"
            let candidate = StoredHumanMessage(
                id: UUID().uuidString.lowercased(), channelId: target.id, senderId: agentId,
                content: message.content, messageType: "chat", senderType: "agent", createdAt: sentAt
            )
            let committed: StoredHumanMessage
            switch messages.commitAgentSendOnce(
                candidate, agentSendKey: key, attachmentIds: [], channelId: target.id,
                uploaderId: agentId, ledger: MessageLedgerPort(oauth: oauth)
            ) {
            case .existing(let existing):
                committed = existing
            case .committed(let newlyCommitted):
                committed = newlyCommitted
                try AgentExecutionPublication.publish(
                    room: "channel:\(target.id)", event: "message:new", identity: committed.id,
                    payloadJSON: AgentExecutionPublication.messagePayload(committed, senderName: senderName)
                ) { relay.emit($0, $1, $2) }
            case .rejected:
                return nil
            }
            ids.append(committed.id)
            if message.attachesTeamModeArtifact {
                artifactAttachmentId = try await ensureTeamModeArtifactThread(
                    serverId: serverId, ownerId: ownerId, agentId: agentId,
                    parentMessage: committed, senderName: senderName, sentAt: sentAt
                )
            }
        }
        return OwnerOpenerDelivery(channelId: target.id, channelName: target.name,
                                   messageIds: ids, artifactAttachmentId: artifactAttachmentId)
    }

    /// Upstream `getOrCreateThread` (`channelService.ts:8076`) +
    /// `createOwnerOpenerArtifactAttachment` (`onboardingService.ts:243-299`) +
    /// the `team-mode-thread` reply, re-executed idempotently:
    ///
    /// - the thread is the canonical thread under the parent opener message;
    /// - the attachment id is the upstream stable UUID, and its object bytes are
    ///   written before the referencing row through the same storage the upload
    ///   routes use;
    /// - the reply is keyed by `<version>:<server>:<owner>:team-mode-thread`, so
    ///   a replay reuses the committed reply and never publishes twice.
    ///
    /// Returns the artifact attachment id for the conditional ledger line.
    private func ensureTeamModeArtifactThread(
        serverId: String, ownerId: String, agentId: String,
        parentMessage: StoredHumanMessage, senderName: String, sentAt: Date
    ) async throws -> String {
        let parentChannelId = parentMessage.channelId
        let threadId: String
        switch channels.findOrCreateThread(
            serverId: serverId, parentChannelId: parentChannelId,
            parentMessageId: parentMessage.id, creatorId: agentId,
            threadChannels: ThreadChannelCommand(oauth: oauth)
        ) {
        case .existing(let id), .created(let id):
            threadId = id
        }
        // The artifact is read by its intended audience through the ordinary
        // attachment authority. This port's attachment reads use actual thread
        // membership for thread scopes (the same model comment threads use), so
        // the owner and the authoring agent are explicit members.
        for memberId in [ownerId, agentId] {
            channels.addPostableChannel(
                serverId: serverId, channelId: threadId, memberId: memberId, kind: "thread",
                parentChannelId: parentChannelId, parentMessageId: parentMessage.id, name: "thread"
            )
        }

        let artifactID = OnboardingBriefingContent.teamModeArtifactAttachmentID(
            serverId: serverId, ownerId: ownerId)
        if let existing = messages.attachmentRow(id: artifactID) {
            try Self.validateArtifact(existing, threadId: threadId, agentId: agentId)
        } else {
            let bytes = try OnboardingBriefingContent.teamModeArtifactBytes()
            let storage = messages.withState { ($0.attachmentObjectStorage, $0.requiresDurableAttachmentStorage) }
            let reference: AttachmentObjectReference?
            if let objectStorage = storage.0 {
                // Objects are written before the referencing row, like every other
                // attachment. The stable id makes a retry overwrite the same key.
                reference = try await objectStorage.put(attachmentID: artifactID, bytes: bytes)
            } else if storage.1 {
                throw OnboardingBriefingArtifactError.storageUnavailable
            } else {
                reference = nil
            }
            // A concurrent producer may have committed the same stable row while
            // the object was written; never replace a different projection.
            if let existing = messages.attachmentRow(id: artifactID) {
                try Self.validateArtifact(existing, threadId: threadId, agentId: agentId)
            } else {
                messages.recordServerGeneratedAttachment(
                    ChannelAttachment(
                        id: artifactID, channelId: threadId, uploaderId: agentId,
                        filename: OnboardingBriefingContent.teamModeArtifactFilename,
                        messageId: nil, messagePosition: nil,
                        mimeType: OnboardingBriefingContent.teamModeArtifactMimeType,
                        sizeBytes: bytes.count, uploaderType: "agent", createdAt: sentAt,
                        storageKey: reference?.objectKey
                    ),
                    reference: reference,
                    developmentBytes: reference == nil ? bytes : nil
                )
            }
        }
        // The reply is driven by its own `agentSendKey`; replay reuses the
        // committed row, so this is safe even when the attachment row already
        // exists (for example, a producer that failed between the two writes in
        // an older graph).
        try postTeamModeReply(
            serverId: serverId, ownerId: ownerId, agentId: agentId, threadId: threadId,
            artifactID: artifactID, parentMessage: parentMessage, senderName: senderName, sentAt: sentAt
        )
        return artifactID
    }

    private static func validateArtifact(
        _ row: ChannelAttachment, threadId: String, agentId: String
    ) throws {
        guard row.channelId == threadId,
              row.uploaderId == agentId,
              row.uploaderType == "agent",
              row.filename == OnboardingBriefingContent.teamModeArtifactFilename,
              row.mimeType == OnboardingBriefingContent.teamModeArtifactMimeType else {
            throw OnboardingBriefingArtifactError.projectionConflict
        }
    }

    /// Upstream's artifact reply body. It is a normal agent message: the thread
    /// follow rows are written before the publication, and the reply is deduped
    /// by its `agentSendKey`.
    private func postTeamModeReply(
        serverId: String, ownerId: String, agentId: String, threadId: String,
        artifactID: String, parentMessage: StoredHumanMessage, senderName: String, sentAt: Date
    ) throws {
        let key = "\(OnboardingBriefingContent.openerV2Version):\(serverId):\(ownerId):team-mode-thread"
        let candidate = StoredHumanMessage(
            id: UUID().uuidString.lowercased(), channelId: threadId, senderId: agentId,
            content: OnboardingBriefingContent.teamModeReplyContent,
            attachmentIds: [artifactID], messageType: "chat", senderType: "agent", createdAt: sentAt
        )
        switch messages.commitAgentSendOnce(
            candidate, agentSendKey: key, attachmentIds: [artifactID], channelId: threadId,
            uploaderId: agentId, ledger: MessageLedgerPort(oauth: oauth)
        ) {
        case .existing:
            // The first commit already wrote the follow rows and published.
            return
        case .committed(let committed):
            // Upstream writes the sender's `replied` follow first; the parent
            // author's `authored` follow is skipped when it is the same agent.
            messages.applyThreadReplyFollows(
                serverId: serverId, threadChannelId: threadId,
                parentMessageId: parentMessage.id, senderId: agentId, mentioned: []
            )
            try publishTeamModeReply(committed, threadId: threadId, senderName: senderName)
        case .rejected:
            throw OnboardingBriefingArtifactError.replyRejected
        }
    }

    /// The published reply is the canonical message manifest: it carries the
    /// retained attachment row's seven-field object (id, filename, mimeType,
    /// sizeBytes, width, height, thumbnailUrl), not an id stub, and the
    /// creation-time thread conversation context the frontend reads.
    private func publishTeamModeReply(
        _ message: StoredHumanMessage, threadId: String, senderName: String
    ) throws {
        guard let thread = channels.postableChannel(id: threadId) else { return }
        let agent = oauth.agentRuntimeInfo(id: message.senderId)
        let sender = CanonicalMessagePayload.Sender(
            name: senderName,
            description: agent?.description.flatMap { $0.isEmpty ? nil : $0 },
            membershipStatus: nil
        )
        let attachments = messages.orderedAttachmentRows(for: message)
            .compactMap { $0.row }
            .map(CanonicalMessagePayload.Attachment.init)
        let payload = CanonicalMessagePayload(
            message: message,
            sender: sender,
            attachments: attachments,
            mentions: message.mentions,
            conversationContext: messageConversationContext(
                channel: thread, channels: channels.state.postableChannels)
        ).jsonBody.render()
        let relay = RealtimeRelayService(messages: messages)
        try AgentExecutionPublication.publish(
            room: "channel:\(threadId)", event: "message:new", identity: message.id,
            payloadJSON: payload
        ) { relay.emit($0, $1, $2) }
    }

    struct OwnerOpenerChannel {
        let id: String
        let name: String
        let kind: String
    }

    /// Upstream `pickOwnerOpenerTargetChannel`: the owner's `onboarding-owner`
    /// channel first, then the enabled (non-private) `#all`.
    func ownerOpenerTargetChannel(serverId: String, ownerId: String) -> OwnerOpenerChannel? {
        let state = channels.state
        let usable = state.postableChannels.compactMap { id, channel -> OwnerOpenerChannel? in
            guard channel.serverId == serverId, channel.deletedAt == nil, !channel.archived,
                  ["channel", "private"].contains(channel.kind),
                  channel.memberIds.contains(ownerId) else { return nil }
            return OwnerOpenerChannel(id: id, name: channel.name, kind: channel.kind)
        }.sorted { $0.id < $1.id }
        if let ownerChannel = usable.first(where: { $0.name == "onboarding-owner" }) {
            return ownerChannel
        }
        if let all = usable.first(where: { $0.name == "all" && $0.kind == "channel" }) {
            return all
        }
        // `#all` membership is implicit for every server human upstream, so a
        // postable row that has not recorded the owner still resolves here when
        // its channel record is the enabled all-channel.
        guard let allId = oauth.allChannelId(serverId: serverId), oauth.channelType(id: allId) == "channel" else {
            return nil
        }
        return OwnerOpenerChannel(id: allId, name: "all", kind: "channel")
    }

    /// Upstream adds the owner and the onboarding agent to the target channel.
    /// Both owner ids live here already for `#all`; a private
    /// `onboarding-owner` channel created by a different producer may not.
    private func ensureOwnerOpenerMembership(target: OwnerOpenerChannel, ownerId: String, agentId: String) {
        let serverId = oauth.channelServerId(target.id) ?? ""
        channels.addPostableChannel(serverId: serverId, channelId: target.id,
                                    memberId: ownerId, kind: target.kind, name: target.name)
        channels.addPostableChannel(serverId: serverId, channelId: target.id,
                                    memberId: agentId, kind: target.kind, name: target.name)
        oauth.addChannelHuman(channelId: target.id, userId: ownerId)
        oauth.addChannelAgent(channelId: target.id, agentId: agentId)
    }

    // MARK: - Gates

    /// Pinned `onboarding_opener_v2` default. Migration 0144 sets the row's
    /// `default_enabled = true` for every deployment; this port has no such
    /// migration, so an absent row is the pinned default rather than a rollout
    /// gate. A provisioned row (explicit default, rules, kill switch) decides.
    private func openerV2Enabled(serverId: String, ownerId: String) -> Bool {
        let evaluation = agents.evaluateFeatureFlag(
            key: "onboarding_opener_v2", userId: ownerId, serverId: serverId,
            platform: nil, client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        )
        if evaluation.reason == "missing_flag" { return true }
        return evaluation.enabled
    }
}
