import Foundation

/// Exported-row contract for the launch runtime-readiness (phase 5) and
/// activation-delivery (phase 6) legs: enter/close rows carry a closed identity
/// spine and pair by `state_instance_id`; `transition_seq` is ordering only.
/// Ported from the upstream daemon module (task #149).
public enum LaunchTransition {
    public static let readinessSpan = "launch_runtime_readiness_transition"
    public static let activationSpan = "launch_activation_delivery_transition"

    public static let forbiddenAttrSubstrings: [String] = [
        "prompt", "payload", "stderr", "message_text", "text", "token", "secret",
        "credential", "api_key", "apikey", "cwd", "home", "path", "endpoint", "env",
    ]

    public struct Identity: Sendable, Equatable {
        public var agentLaunchId: String?
        public var agentId: String
        public var serverId: String?
        public var machineId: String?
        public var runtime: String
        public var driver: String
        public var launchSource: String

        public init(
            agentLaunchId: String?, agentId: String, serverId: String?, machineId: String?,
            runtime: String, driver: String, launchSource: String
        ) {
            self.agentLaunchId = agentLaunchId
            self.agentId = agentId
            self.serverId = serverId
            self.machineId = machineId
            self.runtime = runtime
            self.driver = driver
            self.launchSource = launchSource
        }

        var attrs: [String: Any] {
            var values: [String: Any] = [
                "agent_id": agentId,
                "runtime": runtime,
                "driver": driver,
                "launch_source": launchSource,
            ]
            values["agent_launch_id"] = agentLaunchId ?? NSNull()
            values["server_id"] = serverId ?? NSNull()
            values["machine_id"] = machineId ?? NSNull()
            return values
        }
    }

    public struct ReadinessState: Sendable, Equatable {
        public var stateInstanceId: String
        public var enterSeq: Int
        public var identity: Identity
        public var fenceKind: String
        public var deadlineUnixMs: Int?
        public var negativeEvidenceBucket: String?

        public init(
            stateInstanceId: String, enterSeq: Int, identity: Identity, fenceKind: String,
            deadlineUnixMs: Int?, negativeEvidenceBucket: String? = nil
        ) {
            self.stateInstanceId = stateInstanceId
            self.enterSeq = enterSeq
            self.identity = identity
            self.fenceKind = fenceKind
            self.deadlineUnixMs = deadlineUnixMs
            let bucket = identity.agentLaunchId == nil ? "missing_launch_id" : nil
            self.negativeEvidenceBucket = negativeEvidenceBucket ?? bucket
        }
    }

    public struct ActivationState: Sendable, Equatable {
        public var stateInstanceId: String
        public var enterSeq: Int
        public var identity: Identity
        public var negativeEvidenceBucket: String?

        public init(stateInstanceId: String, enterSeq: Int, identity: Identity, negativeEvidenceBucket: String? = nil) {
            self.stateInstanceId = stateInstanceId
            self.enterSeq = enterSeq
            self.identity = identity
            self.negativeEvidenceBucket = negativeEvidenceBucket ?? (identity.agentLaunchId == nil ? "missing_launch_id" : nil)
        }
    }

    public static func readinessNegativeEvidence(_ identity: Identity) -> String? {
        identity.agentLaunchId == nil ? "missing_launch_id" : nil
    }

    public static func buildReadinessEnterAttrs(_ state: ReadinessState) -> [String: Any] {
        var attrs = state.identity.attrs
        attrs["phase"] = "runtime_readiness"
        attrs["span_name"] = readinessSpan
        attrs["transition_kind"] = "enter"
        attrs["phase_result"] = "entered"
        attrs["state"] = "awaiting_runtime_ready"
        attrs["state_instance_id"] = state.stateInstanceId
        attrs["transition_seq"] = state.enterSeq
        attrs["is_wait_state"] = true
        attrs["fence_kind"] = state.fenceKind
        if let deadline = state.deadlineUnixMs { attrs["deadline_unix_ms"] = deadline }
        if let bucket = state.negativeEvidenceBucket { attrs["negative_evidence_bucket"] = bucket }
        return attrs
    }

    public static func buildReadinessCloseAttrs(_ state: ReadinessState, closeResult: String, closeSeq: Int) -> [String: Any] {
        var attrs = state.identity.attrs
        attrs["phase"] = "runtime_readiness"
        attrs["span_name"] = readinessSpan
        attrs["transition_kind"] = "close"
        attrs["state"] = "awaiting_runtime_ready"
        attrs["state_instance_id"] = state.stateInstanceId
        attrs["transition_seq"] = closeSeq
        attrs["close_result"] = closeResult
        if let bucket = state.negativeEvidenceBucket { attrs["negative_evidence_bucket"] = bucket }
        return attrs
    }

    public static func buildActivationEnterAttrs(_ state: ActivationState) -> [String: Any] {
        var attrs = state.identity.attrs
        attrs["phase"] = "activation_delivery"
        attrs["span_name"] = activationSpan
        attrs["transition_kind"] = "enter"
        attrs["phase_result"] = "entered"
        attrs["state"] = "awaiting_activation_delivery"
        attrs["state_instance_id"] = state.stateInstanceId
        attrs["transition_seq"] = state.enterSeq
        attrs["is_wait_state"] = true
        attrs["fence_kind"] = "none"
        if let bucket = state.negativeEvidenceBucket { attrs["negative_evidence_bucket"] = bucket }
        return attrs
    }

    public static func buildActivationCloseAttrs(
        _ state: ActivationState, closeResult: String, closeSeq: Int, deliveredVia: String? = nil
    ) -> [String: Any] {
        var attrs = state.identity.attrs
        attrs["phase"] = "activation_delivery"
        attrs["span_name"] = activationSpan
        attrs["transition_kind"] = "close"
        attrs["state"] = "awaiting_activation_delivery"
        attrs["state_instance_id"] = state.stateInstanceId
        attrs["transition_seq"] = closeSeq
        attrs["close_result"] = closeResult
        if let deliveredVia { attrs["delivered_via"] = deliveredVia }
        if let bucket = state.negativeEvidenceBucket { attrs["negative_evidence_bucket"] = bucket }
        return attrs
    }

    public struct Row {
        public var name: String
        public var attrs: [String: Any]
        public init(name: String, attrs: [String: Any]) {
            self.name = name
            self.attrs = attrs
        }
    }

    public struct PairingViolation: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    /// Contract assertion: one enter, exactly one later close per
    /// (agent_launch_id, state_instance_id), unique transition_seq, and no
    /// forbidden attr leaks (Q8 scrub). Rows may arrive unsorted.
    public static func assertPairing(context: String, rows: [Row], spanName: String) throws {
        let matching = rows.filter { $0.name == spanName }
        for row in matching {
            for key in row.attrs.keys {
                let lower = key.lowercased()
                if key == "launch_source" || key == "span_name" { continue }
                if forbiddenAttrSubstrings.contains(where: { lower.contains($0) }) {
                    throw PairingViolation(message: "launch readiness pairing violation after \(context): forbidden attr key \"\(key)\"")
                }
            }
        }
        var seenSeqs = Set<Int>()
        for row in matching {
            let seq = (row.attrs["transition_seq"] as? NSNumber)?.intValue ?? 0
            if seenSeqs.contains(seq) {
                throw PairingViolation(message: "launch readiness pairing violation after \(context): transition_seq \(seq) reused (must be monotonic/unique ordering)")
            }
            seenSeqs.insert(seq)
        }
        var opens: [String: Int] = [:]
        var closes: [String: Int] = [:]
        for row in matching {
            let launchId = (row.attrs["agent_launch_id"] as? String) ?? "null"
            let instanceId = (row.attrs["state_instance_id"] as? String) ?? "null"
            let key = "\(launchId)::\(instanceId)"
            if (row.attrs["transition_kind"] as? String) == "enter" {
                opens[key, default: 0] += 1
            } else if (row.attrs["transition_kind"] as? String) == "close" {
                closes[key, default: 0] += 1
            }
        }
        for (key, enterCount) in opens {
            if enterCount != 1 {
                throw PairingViolation(message: "launch readiness pairing violation after \(context): \(enterCount) enters for \(key)")
            }
            let closeCount = closes[key] ?? 0
            if closeCount != 1 {
                throw PairingViolation(message: "launch readiness pairing violation after \(context): enter without exactly-one close for \(key) (closes=\(closeCount))")
            }
        }
        for key in closes.keys where opens[key] == nil {
            throw PairingViolation(message: "launch readiness pairing violation after \(context): close without enter for \(key)")
        }
    }

    public static func assertReadinessPairing(context: String, rows: [Row]) throws {
        try assertPairing(context: context, rows: rows, spanName: readinessSpan)
    }

    public static func assertActivationPairing(context: String, rows: [Row]) throws {
        try assertPairing(context: context, rows: rows, spanName: activationSpan)
    }
}
