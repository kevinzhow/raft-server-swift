import Foundation

/// A replaced process can keep writing for a while, and every stdout chunk or
/// parsed event from it is rejected. Recording each one flooded traces, so per
/// process × reason × source the first output rejection is recorded and later
/// ones are counted, re-recorded at most once per window with
/// `suppressed_count`. Input rejections are one per send attempt. Ported from
/// the upstream daemon fence.
public final class RuntimeProcessBindingFence {
    public static let outputRejectionTraceWindowMs = 10_000

    public final class RuntimeToken {
        public init() {}
    }

    public struct Process {
        public var runtime: RuntimeToken
        public var driverId: String
        public var launchId: String?
        public var sessionId: String?
        public var processInstanceId: String
        public init(runtime: RuntimeToken, driverId: String, launchId: String?, sessionId: String?, processInstanceId: String) {
            self.runtime = runtime
            self.driverId = driverId
            self.launchId = launchId
            self.sessionId = sessionId
            self.processInstanceId = processInstanceId
        }
    }

    public struct Binding: Sendable, Equatable {
        public var agentId: String
        public var serverId: String?
        public var machineId: String?
        public var configuredRuntimeId: String
        public var driverId: String
        public var initialLaunchId: String?
        public var activeLaunchId: String?
        public var startSessionId: String?
        public var activeSessionId: String?
        public var processInstanceId: String
        public init(
            agentId: String, serverId: String?, machineId: String?, configuredRuntimeId: String,
            driverId: String, initialLaunchId: String?, activeLaunchId: String?,
            startSessionId: String?, activeSessionId: String?, processInstanceId: String
        ) {
            self.agentId = agentId
            self.serverId = serverId
            self.machineId = machineId
            self.configuredRuntimeId = configuredRuntimeId
            self.driverId = driverId
            self.initialLaunchId = initialLaunchId
            self.activeLaunchId = activeLaunchId
            self.startSessionId = startSessionId
            self.activeSessionId = activeSessionId
            self.processInstanceId = processInstanceId
        }
    }

    public struct SendResult: Sendable, Equatable {
        public var accepted: Bool
        public var reason: String?
        public init(accepted: Bool, reason: String? = nil) {
            self.accepted = accepted
            self.reason = reason
        }
    }

    private struct RejectionWindow {
        var lastRecordedMs: Int
        var suppressed: Int
    }

    private let getCurrentProcess: (String) -> Process?
    private let recordTrace: (String, [String: Any]) -> Void
    private let now: () -> Int
    private var bindings: [ObjectIdentifier: Binding] = [:]
    private var outputRejections: [ObjectIdentifier: [String: RejectionWindow]] = [:]

    public init(
        getCurrentProcess: @escaping (String) -> Process?,
        recordTrace: @escaping (String, [String: Any]) -> Void,
        now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.getCurrentProcess = getCurrentProcess
        self.recordTrace = recordTrace
        self.now = now
    }

    public func bind(token: RuntimeToken, binding: Binding) {
        bindings[ObjectIdentifier(token)] = binding
    }

    public func getBinding(token: RuntimeToken) -> Binding? {
        bindings[ObjectIdentifier(token)]
    }

    /// Returns whether output from this process may still be accepted.
    @discardableResult
    public func acceptOutput(agentId: String, process: Process, source: String) -> Bool {
        let token = process.runtime
        guard let validation = validate(agentId: agentId, process: process) else { return true }
        recordOutputRejection(agentId: agentId, process: process, reason: validation, source: source)
        return false
    }

    /// Sends input through the process when the binding still matches; a
    /// rejected send is recorded once per attempt and never collapsed.
    public func send(
        agentId: String,
        process: Process,
        input: [String: Any],
        source: String
    ) -> SendResult {
        guard let validation = validate(agentId: agentId, process: process) else {
            return .init(accepted: true)
        }
        recordRejection(agentId: agentId, process: process, reason: validation, direction: "input", source: source, sessionId: input["sessionId"] as? String)
        return .init(accepted: false, reason: validation)
    }

    /// nil when the binding is valid, otherwise the mismatch reason.
    private func validate(agentId: String, process: Process) -> String? {
        guard let binding = bindings[ObjectIdentifier(process.runtime)] else { return "binding_missing" }
        guard let current = getCurrentProcess(agentId) else { return "inactive_process_generation" }
        if current.processInstanceId != process.processInstanceId { return "inactive_process_generation" }
        if binding.agentId != agentId { return "agent_mismatch" }
        if binding.processInstanceId != process.processInstanceId { return "process_instance_mismatch" }
        if let launch = process.launchId, binding.activeLaunchId != launch { return "launch_mismatch" }
        if let session = process.sessionId, binding.activeSessionId != session { return "session_mismatch" }
        return nil
    }

    private func recordOutputRejection(agentId: String, process: Process, reason: String, source: String) {
        let token = ObjectIdentifier(process.runtime)
        let key = "\(reason)|\(source)"
        let currentMs = now()
        var windows = outputRejections[token] ?? [:]
        if var window = windows[key] {
            if currentMs - window.lastRecordedMs < Self.outputRejectionTraceWindowMs {
                window.suppressed += 1
                windows[key] = window
                outputRejections[token] = windows
                return
            }
            let suppressed = window.suppressed
            window.suppressed = 0
            window.lastRecordedMs = currentMs
            windows[key] = window
            outputRejections[token] = windows
            recordTrace("daemon.agent.runtime_binding.rejected", [
                "agent_id": agentId,
                "process_instance_id": process.processInstanceId,
                "direction": "output",
                "source": source,
                "reason": reason,
                "suppressed_count": suppressed,
            ])
            return
        }
        windows[key] = RejectionWindow(lastRecordedMs: currentMs, suppressed: 0)
        outputRejections[token] = windows
        recordTrace("daemon.agent.runtime_binding.rejected", [
            "agent_id": agentId,
            "process_instance_id": process.processInstanceId,
            "direction": "output",
            "source": source,
            "reason": reason,
            "suppressed_count": 0,
        ])
    }

    private func recordRejection(
        agentId: String, process: Process, reason: String, direction: String, source: String, sessionId: String?
    ) {
        var attrs: [String: Any] = [
            "agent_id": agentId,
            "process_instance_id": process.processInstanceId,
            "direction": direction,
            "source": source,
            "reason": reason,
        ]
        if let sessionId { attrs["session_id"] = sessionId }
        recordTrace("daemon.agent.runtime_binding.rejected", attrs)
    }
}
