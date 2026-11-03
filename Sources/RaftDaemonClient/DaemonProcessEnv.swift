import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Process-environment patching for the daemon: an agent session may hold a
/// temporary `process.env` overlay across awaits, and every child spawned in
/// that window must build its environment from the ambient (unpatched) copy.
/// Ported from the upstream daemon helper (task #28).
public enum DaemonProcessEnv {
    actor Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private static let gate = Gate()
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var activePrevious: [String: String?] = [:]

    /// Current environment as a dictionary, with any active patch undone.
    public static func ambient() -> [String: String] {
        var env = currentEnvironment()
        let previous = snapshotActivePrevious()
        for (key, value) in previous {
            if let value {
                env[key] = value
            } else {
                env[key] = nil
            }
        }
        return env
    }

    /// Runs `body` with `patch` applied to the real process environment and
    /// restores the prior values afterwards. Overlays serialize.
    public static func withProcessEnvPatch<T>(
        _ patch: [String: String]?,
        removeFirst: [String] = [],
        body: () async throws -> T
    ) async rethrows -> T {
        var keys = Set(removeFirst)
        keys.formUnion((patch ?? [:]).keys)
        guard !keys.isEmpty else { return try await body() }
        await gate.acquire()
        var previous: [String: String?] = [:]
        for key in keys {
            previous[key] = currentEnvironment()[key]
            unsetenvValue(key)
        }
        for (key, value) in patch ?? [:] {
            setenvValue(key, value)
        }
        setActivePrevious(previous)
        defer {
            setActivePrevious([:])
            restore(previous)
            Task { await gate.release() }
        }
        return try await body()
    }

    private static func snapshotActivePrevious() -> [String: String?] {
        stateLock.withLock { activePrevious }
    }

    private static func setActivePrevious(_ value: [String: String?]) {
        stateLock.withLock { activePrevious = value }
    }

    private static func restore(_ previous: [String: String?]) {
        for (key, value) in previous {
            if let value {
                setenvValue(key, value)
            } else {
                unsetenvValue(key)
            }
        }
    }

    private static func currentEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    private static func setenvValue(_ key: String, _ value: String) {
        #if canImport(Glibc)
        setenv(key, value, 1)
        #endif
    }

    private static func unsetenvValue(_ key: String) {
        #if canImport(Glibc)
        unsetenv(key)
        #endif
    }
}

/// Classifies WSL kernels for daemon telemetry. Ported from upstream.
public enum DaemonOsVariant {
    public static func classify(kernelRelease: String) -> String? {
        let lower = kernelRelease.lowercased()
        if lower.contains("microsoft-standard") || lower.contains("wsl2") { return "wsl2" }
        if lower.contains("microsoft") { return "wsl1" }
        return nil
    }

    public static func detect(
        platform: String = "linux",
        kernelRelease: () -> String? = {
            try? String(contentsOfFile: "/proc/sys/kernel/osrelease", encoding: .utf8)
        }
    ) -> String? {
        guard platform == "linux" else { return nil }
        guard let release = kernelRelease() else { return nil }
        return classify(kernelRelease: release)
    }
}
