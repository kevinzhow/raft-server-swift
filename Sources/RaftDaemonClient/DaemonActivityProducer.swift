import Foundation

/// Builds the daemon→server `agent:activity` frame: only fact-typed detail kinds
/// cross the wire, producer conclusions and weak kinds are dropped with a typed
/// reason, and status entries lose their `activity`/`activityKind` conclusions.
/// Ported from the upstream daemon producer.
public enum AgentActivityDetailKinds {
    public static let all: Set<String> = [
        "none", "message_received", "freshness_hold", "starting", "runtime_starting", "idle",
        "running_command", "checking_messages", "compacting_context", "compaction_finished",
        "compaction_stale", "reviewing_changes", "review_finished", "review_stale",
        "runtime_reconnecting", "runtime_error", "runtime_crashed", "runtime_unavailable",
        "runtime_stalled", "delivery_unconsumed", "wake_crash_loop_blocked",
        "terminal_failure_paused", "stalled_recovery", "stopped", "ready",
        "runtime_interrupted", "machine_disconnected", "computer_started", "computer_restarted",
        "computer_upgraded", "computer_operation_failed", "daemon_activity", "external_activity",
        "synthetic_repair", "slock_action", "system_message", "runtime_progress",
        "provider_request_status", "model_request_started", "model_response_started",
        "tool_started", "tool_end", "thinking_started", "thinking_end", "subagent_activity", "other",
    ]
    public static let nonFact: Set<String> = [
        "none", "daemon_activity", "external_activity", "slock_action", "other",
    ]
    public static func isKnown(_ kind: String) -> Bool { all.contains(kind) }
}

public struct DaemonActivityEntry: Sendable, Equatable {
    public var kind: String
    public var detail: String?
    public var detailKind: String?
    public var activity: String?
    public var activityKind: String?

    public init(kind: String, detail: String? = nil, detailKind: String? = nil, activity: String? = nil, activityKind: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.detailKind = detailKind
        self.activity = activity
        self.activityKind = activityKind
    }

    /// The wire copy: a status entry drops the producer's activity conclusions.
    var normalized: DaemonActivityEntry {
        guard kind == "status" else { return self }
        return DaemonActivityEntry(kind: kind, detail: detail, detailKind: detailKind)
    }
}

public struct DaemonActivityInput: Sendable {
    public var agentId: String
    public var activityKind: String
    public var detail: String
    public var detailKind: String?
    public var entries: [DaemonActivityEntry]?
    public var launchId: String?
    public var daemonInstanceId: String?
    public var probeId: String?
    public var clientSeq: Int?
    public var producerFactId: String?
    public var observedAtMs: Int?
    public var isHeartbeat: Bool

    public init(
        agentId: String, activityKind: String, detail: String, detailKind: String?,
        entries: [DaemonActivityEntry]? = nil, launchId: String? = nil, daemonInstanceId: String? = nil,
        probeId: String? = nil, clientSeq: Int? = nil, producerFactId: String? = nil,
        observedAtMs: Int? = nil, isHeartbeat: Bool
    ) {
        self.agentId = agentId
        self.activityKind = activityKind
        self.detail = detail
        self.detailKind = detailKind
        self.entries = entries
        self.launchId = launchId
        self.daemonInstanceId = daemonInstanceId
        self.probeId = probeId
        self.clientSeq = clientSeq
        self.producerFactId = producerFactId
        self.observedAtMs = observedAtMs
        self.isHeartbeat = isHeartbeat
    }
}

public struct DaemonActivityDrop: Sendable, Equatable {
    public var agentId: String
    public var activity: String
    public var detailKind: String
    public var reason: String
    public var isHeartbeat: Bool
}

public struct DaemonActivityMessage: Sendable, Equatable {
    public var type = "agent:activity"
    public var agentId: String
    public var detail: String
    public var detailKind: String
    public var entries: [DaemonActivityEntry]?
    public var launchId: String?
    public var daemonInstanceId: String?
    public var probeId: String?
    public var clientSeq: Int?
    public var producerFactId: String?
    public var observedAtMs: Int?
    public var isHeartbeat: Bool

    /// The envelope never carries the producer's conclusion fields.
    public var hasActivityField: Bool { false }
    public var hasActivityKindField: Bool { false }
}

public enum DaemonActivityBuildResult: Sendable, Equatable {
    case ok(message: DaemonActivityMessage)
    case drop(DaemonActivityDrop)
}

public enum DaemonActivityProducer {
    public static func normalizeEntries(_ entries: [DaemonActivityEntry]) -> [DaemonActivityEntry] {
        entries.map(\.normalized)
    }

    public static func dropTraceAttrs(_ drop: DaemonActivityDrop) -> [String: Any] {
        [
            "agentId": drop.agentId,
            "activity": drop.activity,
            "detail_kind": drop.detailKind,
            "reason": drop.reason,
            "is_heartbeat": drop.isHeartbeat,
        ]
    }

    public static func projection(kind: String) -> (activityKind: String, detailKind: String) {
        kind == "thinking"
            ? ("thinking", "thinking_started")
            : ("working", "model_response_started")
    }

    public static func runtimeEventEndsThinking(_ kind: String) -> Bool {
        ["text", "tool_call", "tool_output", "compaction_started", "compaction_finished",
         "review_started", "review_finished", "turn_end", "error"].contains(kind)
    }

    public static func build(_ input: DaemonActivityInput) -> DaemonActivityBuildResult {
        guard let detailKind = input.detailKind, AgentActivityDetailKinds.isKnown(detailKind) else {
            return .drop(DaemonActivityDrop(
                agentId: input.agentId, activity: input.activityKind,
                detailKind: input.detailKind ?? "non_string",
                reason: "unknown_activity_detail_kind", isHeartbeat: input.isHeartbeat
            ))
        }
        if AgentActivityDetailKinds.nonFact.contains(detailKind) {
            return .drop(DaemonActivityDrop(
                agentId: input.agentId, activity: input.activityKind, detailKind: detailKind,
                reason: "non_fact_activity_detail_kind", isHeartbeat: input.isHeartbeat
            ))
        }
        let entries = input.entries.map(normalizeEntries)
        return .ok(message: DaemonActivityMessage(
            agentId: input.agentId, detail: input.detail, detailKind: detailKind,
            entries: entries, launchId: input.launchId, daemonInstanceId: input.daemonInstanceId,
            probeId: input.probeId, clientSeq: input.clientSeq, producerFactId: input.producerFactId,
            observedAtMs: input.observedAtMs, isHeartbeat: input.isHeartbeat
        ))
    }
}
