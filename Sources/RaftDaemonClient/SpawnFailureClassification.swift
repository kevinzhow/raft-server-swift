import Foundation
import Synchronization

/// Typed agent launch failures: every failure the daemon can name carries a
/// stable code, and classification decides by code only — message text never
/// decides. Ported from the upstream daemon classifier.
public final class SpawnFailureError: Error, Sendable {
    struct Snapshot: Sendable {
        var code: String
        var message: String
        var cause: SpawnFailureError?
        var reason: String?
        var model: String?
        var runtimeId: String?
        var status: Int?
        var materializationKind: String?
        var recordedMajor: Int?
        var installedVersion: String?
        var failures: Int?
    }

    private let state: Mutex<Snapshot>

    // Setters are individual mutations, not a transaction across properties.
    // Compound consumers capture one snapshot rather than combining getters.
    public var code: String {
        get { state.withLock { $0.code } }
        set { state.withLock { $0.code = newValue } }
    }
    public var message: String {
        get { state.withLock { $0.message } }
        set { state.withLock { $0.message = newValue } }
    }
    public var cause: SpawnFailureError? {
        get { state.withLock { $0.cause } }
        set { state.withLock { $0.cause = newValue } }
    }
    public var reason: String? {
        get { state.withLock { $0.reason } }
        set { state.withLock { $0.reason = newValue } }
    }
    public var model: String? {
        get { state.withLock { $0.model } }
        set { state.withLock { $0.model = newValue } }
    }
    public var runtimeId: String? {
        get { state.withLock { $0.runtimeId } }
        set { state.withLock { $0.runtimeId = newValue } }
    }
    public var status: Int? {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }
    public var materializationKind: String? {
        get { state.withLock { $0.materializationKind } }
        set { state.withLock { $0.materializationKind = newValue } }
    }
    public var recordedMajor: Int? {
        get { state.withLock { $0.recordedMajor } }
        set { state.withLock { $0.recordedMajor = newValue } }
    }
    public var installedVersion: String? {
        get { state.withLock { $0.installedVersion } }
        set { state.withLock { $0.installedVersion = newValue } }
    }
    public var failures: Int? {
        get { state.withLock { $0.failures } }
        set { state.withLock { $0.failures = newValue } }
    }

    func snapshot() -> Snapshot { state.withLock { $0 } }

    public init(
        code: String,
        message: String,
        cause: SpawnFailureError? = nil,
        reason: String? = nil,
        model: String? = nil,
        runtimeId: String? = nil,
        status: Int? = nil,
        materializationKind: String? = nil,
        recordedMajor: Int? = nil,
        installedVersion: String? = nil,
        failures: Int? = nil
    ) {
        self.state = Mutex(Snapshot(
            code: code, message: message, cause: cause, reason: reason, model: model,
            runtimeId: runtimeId, status: status, materializationKind: materializationKind,
            recordedMajor: recordedMajor, installedVersion: installedVersion, failures: failures
        ))
    }

    public static func versionTooOld(displayName: String, actualVersion: String, testedGoodVersion: String) -> SpawnFailureError {
        SpawnFailureError(
            code: "runtime_version_too_old",
            message: "\(displayName) CLI \(actualVersion) is known incompatible with this Raft runtime. "
                + "Update \(displayName) to the latest version before starting the agent; "
                + "\(displayName) \(testedGoodVersion) is known to work."
        )
    }

    public static func modelNotFound(runtimeId: String, model: String) -> SpawnFailureError {
        SpawnFailureError(
            code: "model_not_found",
            message: "Model \(model) is not available for the \(runtimeId) runtime on this computer",
            model: model, runtimeId: runtimeId
        )
    }

    public static func executableNotFound(runtimeId: String, message: String, reason: String? = nil) -> SpawnFailureError {
        SpawnFailureError(code: "runtime_not_found", message: message, reason: reason, runtimeId: runtimeId)
    }

    public static func agentProxyBind(_ message: String) -> SpawnFailureError {
        SpawnFailureError(code: "agent_proxy_bind_failed", message: message)
    }

    public static func providerMaterialization(kind: String, status: Int? = nil, message: String) -> SpawnFailureError {
        SpawnFailureError(
            code: "provider_connection_materialization_failed",
            message: message, status: status, materializationKind: kind
        )
    }

    public static func sessionNeedsReset(runtimeId: String, failures: Int) -> SpawnFailureError {
        SpawnFailureError(
            code: "session_needs_reset",
            message: "This agent's runtime session failed context compaction several times in a row: its conversation no longer fits the model, so resuming it cannot succeed.",
            runtimeId: runtimeId, failures: failures
        )
    }

    public static func sessionRuntimeMismatch(
        runtimeId: String, reason: String, recordedMajor: Int?, installedVersion: String
    ) -> SpawnFailureError {
        let origin: String
        if reason == "record_unreadable" {
            origin = "an OpenCode version Raft can no longer tell (its session record is unreadable)"
        } else if let recordedMajor {
            origin = "OpenCode \(recordedMajor).x"
        } else {
            origin = "an earlier OpenCode line (its major version was not recorded)"
        }
        return SpawnFailureError(
            code: "session_runtime_mismatch",
            message: "The \(runtimeId) session was created by \(origin) and cannot be resumed with the installed OpenCode \(installedVersion)",
            runtimeId: runtimeId, recordedMajor: recordedMajor, installedVersion: installedVersion
        )
    }
}

public struct SpawnFailureClassification: Equatable, Sendable {
    public var reason: String
    public var detail: String
    public var userMessage: String
    public var lookupReason: String?
}

public struct StartFailureActivity: Equatable, Sendable {
    public struct SpawnFailure: Equatable, Sendable {
        public var reason: String
        public var model: String?
        public var lookupReason: String?
    }
    public var detail: String
    public var spawnFailure: SpawnFailure
}

public enum SpawnFailureClassifier {
    public static let resetSessionGuidance = "To start a new session, someone who can manage this agent can open Restart / Reset and choose Reset Session & Restart "
        + "(shown as Reset Model for members). This stops current work and clears the runtime conversation context, "
        + "while keeping Raft messages and workspace files, including MEMORY.md."

    static let launchLookupReasons: Set<String> = ["not_on_path", "lookup_timed_out", "lookup_permission_denied", "lookup_failed"]
    static let probeLookupReasons: [String: String] = [
        "not_installed": "not_on_path",
        "probe_timeout": "lookup_timed_out",
        "permission_denied": "lookup_permission_denied",
        "probe_failed": "lookup_failed",
    ]

    private struct ErrorSnapshots {
        let root: SpawnFailureError.Snapshot?
        let cause: SpawnFailureError.Snapshot?

        init(_ error: SpawnFailureError?) {
            let root = error?.snapshot()
            self.root = root
            // Keep the original root + direct-cause bound. Never acquire two
            // node locks together or resample the root through a self-cause.
            if let cause = root?.cause {
                self.cause = cause === error ? root : cause.snapshot()
            } else {
                self.cause = nil
            }
        }
    }

    public static func spawnFailureCode(of error: SpawnFailureError?) -> String? {
        guard let code = error?.snapshot().code, !code.isEmpty else { return nil }
        return code
    }

    public static func classify(_ error: SpawnFailureError?) -> SpawnFailureClassification {
        let snapshots = ErrorSnapshots(error)
        let detail = snapshots.root?.message ?? "unknown error"
        let rawCode = snapshots.root?.code ?? ""
        let reason = rawCode == "ENOENT" ? "runtime_not_found" : (rawCode.isEmpty ? "runtime_spawn_failed" : rawCode)
        switch reason {
        case "runtime_version_too_old":
            return .init(reason: reason, detail: detail, userMessage: detail)
        case "provider_connection_materialization_failed":
            let typed = typedCause(snapshots, code: reason)
            let safeDetail: String
            if typed?.materializationKind == "http", let status = typed?.status {
                safeDetail = "Provider connection materialization failed (HTTP \(status))"
            } else if typed?.materializationKind == "invalid_payload" {
                safeDetail = "Provider connection materialization returned an invalid payload"
            } else if typed?.materializationKind == "invalid_environment" {
                safeDetail = "Provider connection materialization returned an invalid environment"
            } else {
                safeDetail = "Provider connection materialization failed"
            }
            return .init(reason: reason, detail: detail, userMessage: "\(safeDetail). Check Server Settings → AI Providers and retry.")
        case "agent_proxy_bind_failed":
            return .init(reason: reason, detail: detail,
                         userMessage: "Local agent proxy could not start. Check if another daemon or service is using the required local port.")
        case "runner_credential_mint_failed":
            return .init(reason: reason, detail: detail,
                         userMessage: "Runner credential mint failed. Ensure the server is deployed and the daemon binary is compatible.")
        case "model_not_found":
            let typed = typedCause(snapshots, code: reason)
            let model = typed?.model ?? "the configured model"
            return .init(reason: reason, detail: detail,
                         userMessage: "Model \(model) is not available for this runtime on this computer: it may have been renamed or removed in this runtime version, or its provider has no usable API key here. Choose another model, or fix the provider's key, in the agent's settings.")
        case "runtime_not_found":
            let verdict = lookupVerdict(snapshots)
            let userMessage: String
            if let verdict {
                userMessage = verdict.reason == "not_on_path"
                    ? "Runtime executable not found. Ensure the required CLI is installed and available on PATH."
                    : verdict.message
            } else {
                userMessage = "Could not confirm whether the runtime executable is available on this computer. Retry, or check the Computer's status."
            }
            return .init(reason: reason, detail: detail, userMessage: userMessage, lookupReason: verdict?.reason)
        case "model_not_configured":
            let typed = typedCause(snapshots, code: reason)
            let model = typed?.model ?? "the configured model"
            return .init(reason: reason, detail: detail,
                         userMessage: "Model \(model) is not configured for this runtime on this computer. Choose a configured model in the agent's settings, or add it to the runtime's configuration there, then restart the agent.")
        case "session_needs_reset":
            return .init(reason: reason, detail: detail,
                         userMessage: "This agent's runtime session failed context compaction several times in a row: its conversation no longer fits the model, so resuming it cannot succeed. " + resetSessionGuidance)
        case "session_runtime_mismatch":
            return .init(reason: reason, detail: detail,
                         userMessage: "\(detail). Sessions do not carry across runtime major versions, so automatic restarts are paused. "
                            + resetSessionGuidance
                            + " Alternatively, install the runtime version line the session was created with and restart the agent.")
        case "runtime_login_required":
            return .init(reason: reason, detail: detail,
                         userMessage: "The runtime needs you to log in on this computer before it can start. Log in to the runtime there, then restart the agent.")
        case "runtime_config_invalid":
            return .init(reason: reason, detail: detail,
                         userMessage: "The runtime's configuration on this computer is invalid, so the agent cannot start. Fix the runtime configuration there, then restart the agent.")
        default:
            return .init(reason: "runtime_spawn_failed", detail: detail,
                         userMessage: "Runtime failed to start. Check the Computer logs for details and retry.")
        }
    }

    private static func typedCause(_ snapshots: ErrorSnapshots, code: String) -> SpawnFailureError.Snapshot? {
        if snapshots.root?.code == code { return snapshots.root }
        if snapshots.cause?.code == code { return snapshots.cause }
        return nil
    }

    private static func lookupVerdict(_ snapshots: ErrorSnapshots) -> (reason: String, message: String)? {
        for candidate in [snapshots.root, snapshots.cause] {
            guard let candidate, let raw = candidate.reason else { continue }
            if launchLookupReasons.contains(raw) {
                return (raw, candidate.message)
            }
            if let mapped = probeLookupReasons[raw] {
                return (mapped, candidate.message)
            }
        }
        return nil
    }

    /// The `runtime_unavailable` activity of a failed start; the model rides
    /// along only for the model reasons, bounded, and the lookup verdict only
    /// for `runtime_not_found`.
    public static func startFailureActivity(_ classification: SpawnFailureClassification, model: String?) -> StartFailureActivity {
        let carriesModel = (classification.reason == "model_not_found" || classification.reason == "model_not_configured")
            && !(model ?? "").isEmpty
        let carriesLookup = classification.reason == "runtime_not_found" && classification.lookupReason != nil
        return StartFailureActivity(
            detail: classification.userMessage,
            spawnFailure: .init(
                reason: classification.reason,
                model: carriesModel ? String((model ?? "").prefix(128)) : nil,
                lookupReason: carriesLookup ? classification.lookupReason : nil
            )
        )
    }
}
