import Foundation
import RaftShared

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
                        activatedAgentId: String? = nil) -> OnboardingBriefingOutcome {
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
            guard let delivered = try sendOwnerOpenerV2(serverId: serverId, ownerId: ownerId,
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
        // stamp, and retry on the next activation. Visible messages are already
        // idempotent, so the retry is invisible to the human.
        let receipt: AgentExecutionNoticeReceipt
        do {
            receipt = try execution.requestNotice(AgentExecutionNoticeRequest(
                serverId: serverId, agentId: agent.id, channelId: opener.channelId,
                channelName: opener.channelName, channelType: "channel",
                content: OnboardingBriefingContent.ledgerInstruction(
                    userName: owner.name,
                    locationHint: "#\(opener.channelName) channel",
                    messageIds: opener.messageIds,
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
    public func connectionReady(serverId: String) {
        guard let server = oauth.serverProfile(id: serverId) else { return }
        let snapshot = channels.onboardingSnapshot(serverId: serverId, userId: server.ownerId)
        guard let agentId = snapshot.agentId else { return }
        _ = deliverOwnerFacts(serverId: serverId)
        _ = trigger(serverId: serverId, activatedAgentId: agentId)
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
    }

    /// Upstream `sendOwnerOpenerV2`: four visible agent messages in the owner's
    /// `onboarding-owner` channel, else the enabled `#all`. Every message is
    /// committed with the upstream `agentSendKey`, so a replay (claim released,
    /// next activation) never posts a second copy and the ledger message ids
    /// stay aligned with the four topics.
    ///
    /// The Team-Mode artifact is deferred: the port has no transfer-intent /
    /// attachment-projection writer for a server-generated `text/html` object,
    /// so there is no thread reply and no `team_mode_artifact_attachment_id`
    /// ledger line (the upstream line is conditional). The four visible
    /// messages themselves are posted.
    private func sendOwnerOpenerV2(serverId: String, ownerId: String,
                                   agentId: String, sentAt: Date) throws -> OwnerOpenerDelivery? {
        guard let owner = profiles.account(userId: ownerId),
              let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId,
              let target = ownerOpenerTargetChannel(serverId: serverId, ownerId: ownerId) else {
            return nil
        }
        let senderName = agent.displayName.isEmpty ? agent.name : agent.displayName
        ensureOwnerOpenerMembership(target: target, ownerId: ownerId, agentId: agentId)
        let relay = RealtimeRelayService(messages: messages)
        var ids: [String] = []
        for message in OnboardingBriefingContent.openerMessages(userName: owner.name) {
            let key = "\(OnboardingBriefingContent.openerV2Version):\(serverId):\(ownerId):\(message.topic)"
            let candidate = StoredHumanMessage(
                id: UUID().uuidString.lowercased(), channelId: target.id, senderId: agentId,
                content: message.content, messageType: "chat", senderType: "agent", createdAt: sentAt
            )
            switch messages.commitAgentSendOnce(
                candidate, agentSendKey: key, attachmentIds: [], channelId: target.id,
                uploaderId: agentId, ledger: MessageLedgerPort(oauth: oauth)
            ) {
            case .existing(let existing):
                ids.append(existing.id)
            case .committed(let committed):
                ids.append(committed.id)
                try AgentExecutionPublication.publish(
                    room: "channel:\(target.id)", event: "message:new", identity: committed.id,
                    payloadJSON: AgentExecutionPublication.messagePayload(committed, senderName: senderName)
                ) { relay.emit($0, $1, $2) }
            case .rejected:
                return nil
            }
        }
        return OwnerOpenerDelivery(channelId: target.id, channelName: target.name, messageIds: ids)
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
