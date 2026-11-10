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
}
