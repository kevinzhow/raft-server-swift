import Foundation
import Synchronization

/// How long a live model list is served without a refresh.
public let runtimeModelCacheFreshMs = 60_000

/// How a cached read was answered: `fresh` (young live list, no detection),
/// `stale` (older live list returned at once while a background refresh runs),
/// `miss` (nothing usable, caller waits), `forced` (caller bypassed the cache).
public enum RuntimeModelCacheRead: String, Sendable, Equatable {
    case fresh, stale, miss, forced
}

public typealias RuntimeModelDetectMode = String

/// Stale-while-revalidate cache of each runtime's detected model list, so
/// opening a create/edit form does not wait on a CLI listing every time.
/// Only a live list is cached; a definitive non-live answer drops the entry; a
/// transient failure keeps the previous list. Ported from the upstream daemon
/// cache.
public final class RuntimeModelSourceCache: Sendable {
    public typealias Detect = @Sendable (RuntimeModelDetectMode) async -> RuntimeModelSourceOutcome

    private struct Entry: Sendable {
        var outcome: RuntimeModelSourceOutcome
        var atMs: Int
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var refreshing: Set<String> = []
    }
    private let state = Mutex(State())
    private let now: @Sendable () -> Int
    private let freshMs: Int

    public init(now: @escaping @Sendable () -> Int, freshMs: Int = runtimeModelCacheFreshMs) {
        self.now = now
        self.freshMs = freshMs
    }

    public func read(
        runtime: String,
        detect: @escaping Detect,
        force: Bool = false
    ) async -> (outcome: RuntimeModelSourceOutcome, cache: RuntimeModelCacheRead) {
        let entry = state.withLock { force ? nil : $0.entries[runtime] }
        if let entry {
            if now() - entry.atMs < freshMs { return (entry.outcome, .fresh) }
            refreshInBackground(runtime: runtime, detect: detect)
            return (entry.outcome, .stale)
        }
        let outcome = await detectAndStore(runtime: runtime) { await detect("foreground") }
        return (outcome, force ? .forced : .miss)
    }

    /// Observer/test seam: the currently cached outcome for a runtime, if any.
    public func cachedOutcome(runtime: String) -> RuntimeModelSourceOutcome? {
        return state.withLock { state in
            return state.entries[runtime]?.outcome
        }
    }

    /// Record a detection run elsewhere (the connect-time catalog push), so it
    /// warms the cache too.
    public func store(runtime: String, outcome: RuntimeModelSourceOutcome) {
        let liveEntry: Entry?
        if case .live = outcome {
            liveEntry = Entry(outcome: outcome, atMs: now())
        } else {
            liveEntry = nil
        }
        state.withLock { state in
            if let liveEntry {
                state.entries[runtime] = liveEntry
            } else if !Self.isTransientFailure(outcome) {
                state.entries[runtime] = nil
            }
        }
    }

    private func detectAndStore(
        runtime: String,
        detect: @Sendable () async -> RuntimeModelSourceOutcome
    ) async -> RuntimeModelSourceOutcome {
        let outcome = await detect()
        store(runtime: runtime, outcome: outcome)
        return outcome
    }

    private func refreshInBackground(runtime: String, detect: @escaping Detect) {
        let shouldRefresh = state.withLock { state in
            if state.refreshing.contains(runtime) { return false }
            state.refreshing.insert(runtime)
            return true
        }
        guard shouldRefresh else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.detectAndStore(runtime: runtime) { await detect("background") }
            // A thrown refresh leaves the previous list in place; async closures
            // here are non-throwing, so only the final cleanup is needed.
            self.state.withLock { $0.refreshing.remove(runtime) }
        }
    }

    static func isTransientFailure(_ outcome: RuntimeModelSourceOutcome) -> Bool {
        guard case .error(let retryable, let code, let reason) = outcome, retryable else { return false }
        guard let code else { return true }
        if code == "detect_timeout" || code == "detect_failed" { return true }
        // A lookup that did not decide (e.g. Windows cold-start probe_timeout)
        // is not a confirmed absence; only not_installed (or no reason) drops.
        return code == "runtime_not_found" && reason != nil && reason != "not_installed"
    }
}
