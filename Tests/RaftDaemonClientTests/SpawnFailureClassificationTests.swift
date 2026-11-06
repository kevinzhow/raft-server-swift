import Foundation
import Synchronization
import Testing
import RaftDaemonClient

typealias Classifier = SpawnFailureClassifier
typealias Failure = SpawnFailureError

@Test func classifySpawnFailureIdentifiesAKnownIncompatibleRuntimeVersion() {
    let error = Failure.versionTooOld(displayName: "Claude Code", actualVersion: "2.1.59", testedGoodVersion: "2.1.220")
    let result = Classifier.classify(error)
    #expect(result.reason == "runtime_version_too_old")
    #expect(result.userMessage == error.message)
}

@Test func missingModelIsNamedByCodeNotAsAMissingExecutable() {
    let error = Failure.modelNotFound(runtimeId: "builtin", model: "deepseek/deepseek-v4-flash-vision-exp")
    let result = Classifier.classify(error)
    #expect(result.reason == "model_not_found")
    #expect(result.userMessage.contains("deepseek/deepseek-v4-flash-vision-exp"))
    #expect(!result.userMessage.lowercased().contains("executable"))
    #expect(result.userMessage.contains("renamed or removed"))
    #expect(result.userMessage.contains("API key"))
    #expect(result.detail == error.message)
}

@Test func everyKnownReasonIsDecidedByCodeNeverByMessageText() {
    let cases: [(Failure?, String)] = [
        (Failure.executableNotFound(runtimeId: "codex", message: "Cannot resolve a compatible Codex CLI app-server entry point"), "runtime_not_found"),
        (Failure(code: "ENOENT", message: "spawn claude ENOENT"), "runtime_not_found"),
        (Failure.agentProxyBind("Agent Credential Proxy local proxy failed to bind 127.0.0.1 after 3 attempts"), "agent_proxy_bind_failed"),
        (Failure.providerMaterialization(kind: "http", status: 503, message: "Provider connection materialization failed (HTTP 503): secret=x"), "provider_connection_materialization_failed"),
        (Failure(code: "runner_credential_mint_failed", message: "runner_credential_mint_failed: fetch failed"), "runner_credential_mint_failed"),
        (Failure(code: "", message: "spawn claude ENOENT"), "runtime_spawn_failed"),
        (Failure(code: "", message: "Agent Credential Proxy local proxy failed to bind"), "runtime_spawn_failed"),
        (Failure(code: "", message: "Provider connection materialization failed (HTTP 503)"), "runtime_spawn_failed"),
        (Failure(code: "EPERM", message: "weird"), "runtime_spawn_failed"),
    ]
    for (specimen, expected) in cases {
        #expect(Classifier.classify(specimen).reason == expected, "\(specimen?.message ?? "nil")")
    }
    let http = Classifier.classify(Failure.providerMaterialization(kind: "http", status: 503, message: "x secret=poison"))
    #expect(http.userMessage == "Provider connection materialization failed (HTTP 503). Check Server Settings → AI Providers and retry.")
    let env = Classifier.classify(Failure.providerMaterialization(kind: "invalid_environment", message: "y"))
    #expect(env.userMessage.contains("invalid environment"))
}

@Test func runtimeNotFoundCarriesTheResolverVerdictAndOnlyAConfirmedMissKeepsTheInstallCopy() {
    let install = "Runtime executable not found. Ensure the required CLI is installed and available on PATH."
    let missing = Classifier.classify(Failure.executableNotFound(runtimeId: "codex", message: "`codex` was not found on PATH.", reason: "not_on_path"))
    #expect(missing.reason == "runtime_not_found")
    #expect(missing.lookupReason == "not_on_path")
    #expect(missing.userMessage == install)

    for reason in ["lookup_timed_out", "lookup_permission_denied", "lookup_failed"] {
        let message = "The PATH lookup for `codex` did not finish within 1000 ms. This is not evidence that codex is missing. (\(reason))"
        let undecided = Classifier.classify(Failure.executableNotFound(runtimeId: "codex", message: message, reason: reason))
        #expect(undecided.reason == "runtime_not_found")
        #expect(undecided.lookupReason == reason)
        #expect(undecided.userMessage == message)
        #expect(!undecided.userMessage.contains("installed"))
        let activity = Classifier.startFailureActivity(undecided, model: "gpt-5")
        #expect(activity.spawnFailure.reason == "runtime_not_found")
        #expect(activity.spawnFailure.lookupReason == reason)
    }

    let wrapped = Classifier.classify(Failure(
        code: "runtime_not_found", message: "wrapped",
        cause: Failure.executableNotFound(runtimeId: "codex", message: "lookup failed", reason: "lookup_failed")
    ))
    #expect(wrapped.lookupReason == "lookup_failed")

    let neutral = "Could not confirm whether the runtime executable is available on this computer. Retry, or check the Computer's status."
    for noVerdict in [
        Failure.executableNotFound(runtimeId: "codex", message: "spawn codex ENOENT"),
        Failure.executableNotFound(runtimeId: "codex", message: "node unavailable", reason: "node_unavailable"),
        Failure(code: "ENOENT", message: "spawn codex ENOENT"),
    ] {
        let classified = Classifier.classify(noVerdict)
        #expect(classified.reason == "runtime_not_found")
        #expect(classified.lookupReason == nil)
        #expect(classified.userMessage == neutral)
        #expect(!classified.userMessage.contains("installed"))
    }

    for (probeReason, launchReason, installCopy) in [
        ("not_installed", "not_on_path", true),
        ("probe_timeout", "lookup_timed_out", false),
        ("permission_denied", "lookup_permission_denied", false),
        ("probe_failed", "lookup_failed", false),
    ] {
        let message = "The PATH lookup for `grok` ended as \(probeReason)."
        let classified = Classifier.classify(Failure.executableNotFound(runtimeId: "grok", message: message, reason: probeReason))
        #expect(classified.lookupReason == launchReason)
        #expect(classified.userMessage == (installCopy ? install : message))
        #expect(Classifier.startFailureActivity(classified, model: nil).spawnFailure.lookupReason == launchReason)
    }
    #expect(Classifier.classify(Failure.executableNotFound(runtimeId: "grok", message: "x", reason: "unsupported_version")).lookupReason == nil)

    let other = Classifier.classify(Failure(code: "", message: "boom", reason: "lookup_timed_out"))
    #expect(other.reason == "runtime_spawn_failed")
    #expect(other.lookupReason == nil)
    #expect(Classifier.startFailureActivity(other, model: nil).spawnFailure.reason == "runtime_spawn_failed")
}

@Test func compactionStuckSessionIsSessionNeedsResetWithTheWayOut() {
    let classified = Classifier.classify(Failure.sessionNeedsReset(runtimeId: "builtin", failures: 3))
    #expect(classified.reason == "session_needs_reset")
    #expect(classified.userMessage.contains("failed context compaction several times in a row"))
    #expect(classified.userMessage.contains("open Restart / Reset and choose Reset Session & Restart"))
    #expect(Classifier.startFailureActivity(classified, model: "deepseek/v4").spawnFailure.reason == "session_needs_reset")
}

@Test func sessionFromAnotherRuntimeMajorLineIsSessionRuntimeMismatch() {
    let classified = Classifier.classify(Failure.sessionRuntimeMismatch(
        runtimeId: "opencode", reason: "major_mismatch", recordedMajor: 1, installedVersion: "2.0.27"
    ))
    #expect(classified.reason == "session_runtime_mismatch")
    #expect(classified.userMessage.contains("created by OpenCode 1.x and cannot be resumed with the installed OpenCode 2.0.27"))
    #expect(classified.userMessage.contains("automatic restarts are paused"))
    #expect(classified.userMessage.contains("open Restart / Reset and choose Reset Session & Restart"))
    #expect(classified.userMessage.contains("install the runtime version line the session was created with"))
    #expect(Classifier.startFailureActivity(classified, model: "opencode/gpt-5-nano").spawnFailure.reason == "session_runtime_mismatch")

    let unknown = Classifier.classify(Failure.sessionRuntimeMismatch(runtimeId: "opencode", reason: "unrecorded", recordedMajor: nil, installedVersion: "2.0.27"))
    #expect(unknown.userMessage.contains("its major version was not recorded"))
    let unreadable = Classifier.classify(Failure.sessionRuntimeMismatch(runtimeId: "opencode", reason: "record_unreadable", recordedMajor: nil, installedVersion: "1.19.0"))
    #expect(unreadable.reason == "session_runtime_mismatch")
    #expect(unreadable.userMessage.contains("session record is unreadable"))
}

@Test func concurrentSpawnCodeUpdatesKeepTheConfiguredModelInClassification() {
    let error = Failure(code: "model_not_found", message: "unchanged detail", model: "configured-model")
    let readers = Mutex(3)
    let invalid = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 4) { worker in
        if worker == 0 {
            while readers.withLock({ $0 > 0 }) {
                error.code = "model_not_configured"
                error.code = "model_not_found"
            }
        } else {
            defer { readers.withLock { $0 -= 1 } }
            for _ in 0..<3_000 {
                let result = Classifier.classify(error)
                if !["model_not_found", "model_not_configured"].contains(result.reason)
                    || !result.userMessage.contains("Model configured-model ")
                    || result.detail != "unchanged detail" {
                    invalid.withLock { $0 += 1 }
                }
            }
        }
    }
    #expect(invalid.withLock { $0 } == 0, "classification must not resample code when selecting typed model metadata")
}

@Test func concurrentSpawnCodeReadsNeverReturnAnEmptyCode() {
    let error = Failure(code: "ENOENT", message: "not a classifier input")
    let readers = Mutex(3)
    let invalid = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 4) { worker in
        if worker == 0 {
            while readers.withLock({ $0 > 0 }) {
                error.code = ""
                error.code = "ENOENT"
            }
        } else {
            defer { readers.withLock { $0 -= 1 } }
            for _ in 0..<3_000 {
                if let code = Classifier.spawnFailureCode(of: error), code != "ENOENT" {
                    invalid.withLock { $0 += 1 }
                }
            }
        }
    }
    #expect(invalid.withLock { $0 } == 0)
}

@Test func concurrentCauseReplacementKeepsEachResolverVerdictWithItsMessage() {
    let timeout = Failure(code: "runtime_not_found", message: "lookup timed out", reason: "lookup_timed_out")
    let denied = Failure(code: "runtime_not_found", message: "lookup denied", reason: "lookup_permission_denied")
    let error = Failure(code: "runtime_not_found", message: "outer detail", cause: timeout)
    let readers = Mutex(3)
    let invalid = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 4) { worker in
        if worker == 0 {
            while readers.withLock({ $0 > 0 }) {
                error.cause = denied
                error.cause = timeout
            }
        } else {
            defer { readers.withLock { $0 -= 1 } }
            for _ in 0..<2_000 {
                let result = Classifier.classify(error)
                let valid = (result.lookupReason == "lookup_timed_out" && result.userMessage == "lookup timed out")
                    || (result.lookupReason == "lookup_permission_denied" && result.userMessage == "lookup denied")
                if !valid || result.detail != "outer detail" { invalid.withLock { $0 += 1 } }
            }
        }
    }
    #expect(invalid.withLock { $0 } == 0)
}

@Test func mutableSpawnCausesKeepTheOriginalDepthAndCodeRules() {
    let deep = Failure(code: "runtime_not_found", message: "deep verdict", reason: "lookup_failed")
    let direct = Failure(code: "runtime_not_found", message: "direct verdict", cause: deep)
    let error = Failure(code: "runtime_not_found", message: "outer detail", cause: direct)
    #expect(Classifier.classify(error).lookupReason == nil, "a grandchild cause is outside the existing classifier bound")
    direct.reason = "probe_timeout"
    let result = Classifier.classify(error)
    #expect(result.lookupReason == "lookup_timed_out")
    #expect(result.userMessage == "direct verdict")
    #expect(result.detail == "outer detail")
    error.cause = error
    defer { error.cause = nil }
    #expect(Classifier.classify(error).lookupReason == nil, "self causes must not recurse or lock the node twice")
    error.code = ""
    error.message = "model_not_found: ENOENT"
    #expect(Classifier.classify(error).reason == "runtime_spawn_failed", "mutable message text still cannot decide the code")
}
