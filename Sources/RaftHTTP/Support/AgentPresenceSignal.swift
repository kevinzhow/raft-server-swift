import Foundation

/// Server-owned projection of the daemon's presence facts.
///
/// Upstream derives an agent's live activity from the canonical `detailKind`
/// table in `services/agentLifecycleReducer.ts` (pinned v1.21.23-source.1), never
/// from a producer-supplied conclusion. A frame with an explicit weak or
/// unknown detail kind is a current-protocol violation and is dropped; only a
/// genuinely old frame without `detailKind` may carry its own `activity` /
/// `activityKind` (one-version compatibility window).
enum AgentPresenceSignal {
    struct Activity: Sendable, Equatable {
        var activity: String
        var detailKind: String
    }

    /// Pinned `CANONICAL_DAEMON_ACTIVITY_BY_DETAIL_KIND`.
    static let activityByDetailKind: [String: String] = [
        "message_received": "working",
        "freshness_hold": "working",
        "starting": "working",
        "runtime_starting": "working",
        "idle": "online",
        "running_command": "working",
        "checking_messages": "working",
        "compacting_context": "working",
        "compaction_finished": "working",
        "compaction_stale": "working",
        "reviewing_changes": "working",
        "review_finished": "working",
        "review_stale": "working",
        "runtime_reconnecting": "working",
        "runtime_error": "error",
        "runtime_crashed": "offline",
        "runtime_unavailable": "offline",
        "runtime_stalled": "error",
        "stalled_recovery": "working",
        "stopped": "offline",
        "ready": "online",
        "runtime_interrupted": "offline",
        "machine_disconnected": "offline",
        "computer_started": "online",
        "computer_restarted": "online",
        "computer_upgraded": "online",
        "computer_operation_failed": "error",
        "synthetic_repair": "online",
        "system_message": "working",
        "runtime_progress": "working",
        "delivery_unconsumed": "online",
        "wake_crash_loop_blocked": "offline",
        "terminal_failure_paused": "offline",
        "model_request_started": "working",
        "provider_request_status": "working",
        "model_response_started": "working",
        "tool_started": "working",
        "tool_end": "working",
        "thinking_started": "thinking",
        "thinking_end": "working",
        "subagent_activity": "working",
    ]

    /// `isAgentActivity` in `packages/shared`.
    static let legacyActivities: Set<String> = ["online", "thinking", "working", "error", "offline"]

    /// `normalizeDaemonAgentStatus`: `sleeping` is a live runtime; only the two
    /// process states cross the persistence boundary.
    static func reportedStatus(_ raw: String) -> String? {
        if raw == "sleeping" { return "active" }
        return raw == "active" || raw == "inactive" ? raw : nil
    }

    /// The next persisted status, or nil when the signal must be ignored.
    /// A manual stop is an operator intent: a daemon that comes back active
    /// cannot undo it, and `inactive` preserves the stored `stopped` value.
    static func nextPersistedStatus(reported: String, persisted: String) -> String? {
        switch reported {
        case "active":
            return persisted == "stopped" ? nil : "active"
        case "inactive":
            return persisted == "stopped" ? "stopped" : "inactive"
        default:
            return nil
        }
    }

    /// `reduceDaemonActivitySignal`: canonical detail kind first, then the
    /// one-version legacy activity. Explicit weak/unknown kinds return nil.
    static func activity(detailKind: String?, legacyActivity: String?) -> Activity? {
        if let detailKind {
            guard let activity = activityByDetailKind[detailKind] else { return nil }
            return Activity(activity: activity, detailKind: detailKind)
        }
        guard let legacyActivity, legacyActivities.contains(legacyActivity) else { return nil }
        return Activity(activity: legacyActivity, detailKind: "other")
    }

    /// `planReadyReconcileAction`: what a complete daemon `ready` says about one
    /// assigned agent. `running` is the daemon's `runningAgents` report; `status`
    /// is the persisted agent status; `resetActive` is a live reset window.
    enum ReadyReconcileAction: Sendable, Equatable {
        case forceStopAndStayOffline
        case markActiveOnline
        case markWakeableNotRunning
        case markInactiveOffline
        case stayOffline
    }

    static func readyReconcileAction(status: String, running: Bool, resetActive: Bool) -> ReadyReconcileAction {
        if running {
            if status == "stopped" || resetActive { return .forceStopAndStayOffline }
            return .markActiveOnline
        }
        if status != "active" { return .stayOffline }
        return resetActive ? .markInactiveOffline : .markWakeableNotRunning
    }

    /// The persisted status and live activity one ready-reconcile action writes.
    /// A nil status keeps the persisted value (`dbStatus.kind = skip`).
    struct ReadyPresence: Sendable, Equatable {
        var status: String?
        var activity: String
        var detail: String
        var detailKind: String
    }

    static func readyPresence(_ action: ReadyReconcileAction) -> ReadyPresence {
        switch action {
        case .forceStopAndStayOffline:
            return ReadyPresence(status: nil, activity: "offline", detail: "Stopped", detailKind: "stopped")
        case .markActiveOnline, .markWakeableNotRunning:
            // `broadcastReadyOnline` writes online with an empty detail and the
            // weak `none` kind; `markWakeableNotRunning` keeps the persisted
            // status (the runtime process is absent but the agent is wakeable).
            return ReadyPresence(status: action == .markActiveOnline ? "active" : nil,
                                 activity: "online", detail: "", detailKind: "none")
        case .markInactiveOffline:
            return ReadyPresence(status: "inactive", activity: "offline",
                                 detail: "Runtime interrupted", detailKind: "runtime_interrupted")
        case .stayOffline:
            return ReadyPresence(status: nil, activity: "offline",
                                 detail: "Runtime interrupted", detailKind: "runtime_interrupted")
        }
    }

    /// A stopped persisted status reads the explicit stopped detail; the planner
    /// itself receives the narrowed status so the detail is selected here.
    static func readyPresence(_ action: ReadyReconcileAction, status: String) -> ReadyPresence {
        var presence = readyPresence(action)
        if action == .stayOffline, status == "stopped" {
            presence.detail = "Stopped"
            presence.detailKind = "stopped"
        }
        return presence
    }

    /// `isFreshBusyActivity`: a transient working/thinking observation younger
    /// than the activity stale window is not overwritten by a ready broadcast.
    /// A missing observation time is treated as current: the local snapshot has
    /// no reliable age, so the busy fact is preserved rather than guessed away.
    static let activityStaleSeconds: TimeInterval = 90
    static let readyOnlineDedupeSeconds: TimeInterval = 1

    static func isFreshBusyActivity(activity: String?, detailKind: String?,
                                    observedAt: Date?, now: Date) -> Bool {
        guard let activity, activity == "working" || activity == "thinking" else { return false }
        if activity == "working", detailKind == "starting" || detailKind == "runtime_starting" { return false }
        guard let observedAt else { return true }
        return now.timeIntervalSince(observedAt) <= activityStaleSeconds
    }

    /// `reduceMachineDisconnectLifecycle`: preserve the persisted status; the
    /// visible activity is the transport-loss fact.
    static let machineDisconnectedPresence = ReadyPresence(
        status: nil, activity: "offline", detail: "Machine disconnected", detailKind: "machine_disconnected")

    /// `planSequencedStatus` (RFC 069 §8): status frames compare only inside one
    /// daemon process; an unsequenced frame keeps the legacy accept path.
    enum SequencedStatusVerdict: Sendable, Equatable {
        case unsequenced
        case accept(daemonInstanceId: String, clientSeq: Int64)
        case staleInstance
        case staleSequence
    }

    static func sequencedStatus(frameDaemonInstanceId: String?, frameClientSeq: Int64?,
                                connectionDaemonInstanceId: String?,
                                last: (daemonInstanceId: String, clientSeq: Int64)?) -> SequencedStatusVerdict {
        guard let frameDaemonInstanceId, let frameClientSeq, let connectionDaemonInstanceId else {
            return .unsequenced
        }
        if frameDaemonInstanceId != connectionDaemonInstanceId { return .staleInstance }
        if let last, last.daemonInstanceId == frameDaemonInstanceId, frameClientSeq <= last.clientSeq {
            return .staleSequence
        }
        return .accept(daemonInstanceId: frameDaemonInstanceId, clientSeq: frameClientSeq)
    }

    /// The read projection behind `GET /api/agents`.
    ///
    /// A retained daemon/HTTP observation wins. Without one, upstream derives
    /// `online` for an `active` agent whose machine is reachable and `offline`
    /// otherwise (`resolveDerivedActivity`); a manual stop always reads
    /// `offline`/`Stopped` before any cache lookup.
    static func visiblePresence(
        recorded: (activity: String, detail: String)?,
        status: String?,
        machineReachable: Bool
    ) -> (activity: String, detail: String) {
        if status == "stopped" { return ("offline", "Stopped") }
        if let recorded { return recorded }
        return (status == "active" && machineReachable ? "online" : "offline", "")
    }

    /// RFC 071 §9 / upstream `terminalBlockView` + `terminalBlockDetail`: the
    /// server-authored offline activity that shows why automatic wakes stopped.
    /// `needs_manual` wins over a pause. The pause text matches upstream
    /// `new Date(ms).toISOString()`; the failure kind is omitted because this
    /// port does not retain the last failure kind. Needs-manual never says it
    /// will retry, and always names the required manual start.
    static func terminalBlock(needsManual: String?, blockedUntil: Date?, now: Date)
        -> (detail: String, detailKind: String)? {
        if let needsManual {
            let why: String
            switch needsManual {
            case "outcome_evidence_lost": why = "Runtime outcome reports for this agent were lost."
            case "daemon_outcome_storage_unreliable": why = "This computer can no longer report runtime outcomes for this agent."
            default: why = "The previous runtime process could not be confirmed stopped."
            }
            return ("Automatic wake stopped: \(why) A manual start is needed.", "terminal_failure_paused")
        }
        guard let blockedUntil, now < blockedUntil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ("Automatic wake paused until \(formatter.string(from: blockedUntil)) after repeated runtime failures. "
                + "The next message, reminder or manual start after that retries; a manual start lifts it now.",
                "terminal_failure_paused")
    }
}
