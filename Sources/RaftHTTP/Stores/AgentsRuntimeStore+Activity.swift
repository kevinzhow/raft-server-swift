import Foundation

extension AgentsRuntimeStore {
    /// One activity-ingest pass over an agent's status rows.
    ///
    /// The legacy loop updated adopted/occurredAt/activities as it went and
    /// committed the dedupe set only after the last event, so a later invalid
    /// status leaves the earlier status writes in place. The outcome preserves
    /// that: `invalidStatus`/`detailInvalid`/`detailTooLong` return before the
    /// event-id commit.
    enum ActivityIngestOutcome: Sendable, Equatable {
        case applied(accepted: Int, rejected: Int)
        case invalidStatus
        case detailInvalid
        case detailTooLong
    }

    func applyActivityIngest(
        agentId: String,
        events: [AgentActivityEvent],
        now: @Sendable () -> Date
    ) -> ActivityIngestOutcome {
        let standardStatuses: Set<String> = ["working", "thinking", "online", "error", "offline"]
        return withState { state in
            var accepted = 0
            var rejected = 0
            var seen = state.agentActivityEventIds[agentId] ?? []
            for event in events {
                guard let eventId = event.eventId,
                      let occurred = event.occurredAt
                else {
                    rejected += 1
                    continue
                }
                if seen.contains(eventId) {
                    rejected += 1
                    continue
                }
                let status = event.status
                if let status, !standardStatuses.contains(status), status != "failed" {
                    return .invalidStatus
                }
                var detailText = ""
                if let detail = event.detail {
                    guard case .string(let text) = detail else { return .detailInvalid }
                    if text.count > 200 { return .detailTooLong }
                    detailText = text
                }
                let effective = min(occurred, now())
                seen.insert(eventId)
                accepted += 1
                let isStandardStatus = status.map { standardStatuses.contains($0) } ?? false
                if isStandardStatus, let status {
                    state.agentStatusAdopted.insert(agentId)
                    if effective >= (state.agentStatusOccurredAt[agentId] ?? .distantPast) {
                        state.agentStatusOccurredAt[agentId] = effective
                        state.agentActivities[agentId] = (activity: status, detail: detailText)
                    }
                } else if let hookName = event.hookEventName, !state.agentStatusAdopted.contains(agentId) {
                    let hookStatus: String
                    switch hookName {
                    case "PreToolUse": hookStatus = "working"
                    case "PostToolUseFailure": hookStatus = "error"
                    case "Stop", "SessionEnd": hookStatus = "online"
                    default: hookStatus = "working"
                    }
                    if effective >= (state.agentStatusOccurredAt[agentId] ?? .distantPast) {
                        state.agentStatusOccurredAt[agentId] = effective
                        state.agentActivities[agentId] = (activity: hookStatus, detail: "")
                    }
                }
            }
            state.agentActivityEventIds[agentId] = seen
            return .applied(accepted: accepted, rejected: rejected)
        }
    }

    /// The first-post attention hint: the membership check and the "already
    /// posted" insertion are one critical section, so two concurrent first
    /// sends cannot both publish the drive-by hint.
    func claimFirstAgentPost(channelId: String, agentId: String) -> Bool {
        return withState { state in
            let key = "\(channelId)\n\(agentId)"
            if state.agentChannelPosted.contains(key) { return false }
            state.agentChannelPosted.insert(key)
            return true
        }
    }
}

// MARK: - Human message create: delivery ledger

extension AgentsRuntimeStore {
    /// A DM delivery to a stopped agent is dropped as `wake_suppressed` and
    /// reported to the v2 sender. The status check and the ledger append are
    /// one critical section, so a stop that lands between them cannot leave a
    /// delivery for an agent that was not stopped.
    func recordStoppedAgentDelivery(agentId: String, messageId: String, channelType: String) -> Bool {
        return withState { state in
            guard state.serverAgents[agentId]?.status == "stopped" else { return false }
            state.storedAgentDeliveries.append((agentId: agentId, messageId: messageId, channelType: channelType))
            return true
        }
    }

    /// The upstream `wake_suppressed` warning is not limited to the manual stop
    /// intent: a recovery-gated agent drops the delivery too. Keep the same
    /// sender-visible ledger facts without inventing a `stopped` status.
    func recordSuppressedAgentDelivery(agentId: String, messageId: String, channelType: String) {
        withState { state in
            state.storedAgentDeliveries.append((agentId: agentId, messageId: messageId, channelType: channelType))
        }
    }

    /// OAuth is the membership authority. This writes only its existing local
    /// projection; real delivery is staged through AgentExecutionService.
    func recordMentionMembership(channelId: String, agentId: String) {
        withState { state in
            _ = state.channelAgentMembers[channelId, default: []].insert(agentId)
        }
    }
}
