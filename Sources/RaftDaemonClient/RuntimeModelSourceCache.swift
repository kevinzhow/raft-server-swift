import Foundation

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
public final class RuntimeModelSourceCache: @unchecked Sendable {
    public typealias Detect = @Sendable (RuntimeModelDetectMode) async -> RuntimeModelSourceOutcome

    private struct Entry {
        var outcome: RuntimeModelSourceOutcome
        var atMs: Int
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Int
    private let freshMs: Int
    private var entries: [String: Entry] = [:]
    private var refreshing: Set<String> = []

    public init(now: @escaping @Sendable () -> Int, freshMs: Int = runtimeModelCacheFreshMs) {
        self.now = now
        self.freshMs = freshMs
    }

    public func read(
        runtime: String,
        detect: @escaping Detect,
        force: Bool = false
    ) async -> (outcome: RuntimeModelSourceOutcome, cache: RuntimeModelCacheRead) {
        let entry = lock.withLock { force ? nil : entries[runtime] }
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
        lock.lock(); defer { lock.unlock() }
        return entries[runtime]?.outcome
    }

    /// Record a detection run elsewhere (the connect-time catalog push), so it
    /// warms the cache too.
    public func store(runtime: String, outcome: RuntimeModelSourceOutcome) {
        lock.lock(); defer { lock.unlock() }
        if case .live = outcome {
            entries[runtime] = Entry(outcome: outcome, atMs: now())
        } else if !Self.isTransientFailure(outcome) {
            entries[runtime] = nil
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
        lock.lock()
        if refreshing.contains(runtime) { lock.unlock(); return }
        refreshing.insert(runtime)
        lock.unlock()
        Task { [weak self] in
            guard let self else { return }
            _ = await self.detectAndStore(runtime: runtime) { await detect("background") }
            // A thrown refresh leaves the previous list in place; async closures
            // here are non-throwing, so only the final cleanup is needed.
            self.lock.withLock { self.refreshing.remove(runtime) }
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
