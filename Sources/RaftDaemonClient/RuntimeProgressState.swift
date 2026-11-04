import Foundation

/// The daemon's derived runtime-progress clock. Only runtime app events and
/// explicit internal-progress observations refresh it or clear a latched stall;
/// stall age anchors on the later of the last runtime event and the current
/// turn start, while `lastEventAgeMs` keeps its literal telemetry meaning.
/// Ported from the upstream daemon state.
public final class RuntimeProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEventAtMs: Int
    private var lastEventKindValue: String?
    private var staleSinceMs: Int?
    private var turnStartedAtMs: Int?

    public init(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        self.lastEventAtMs = nowMs
    }

    public var lastEventAt: Int {
        lock.lock(); defer { lock.unlock() }
        return lastEventAtMs
    }

    public var lastEventKind: String? {
        lock.lock(); defer { lock.unlock() }
        return lastEventKindValue
    }

    public var staleSince: Int? {
        lock.lock(); defer { lock.unlock() }
        return staleSinceMs
    }

    public var isStale: Bool {
        lock.lock(); defer { lock.unlock() }
        return staleSinceMs != nil
    }

    public func ageMs(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> Int {
        lock.lock(); defer { lock.unlock() }
        return nowMs - max(lastEventAtMs, turnStartedAtMs ?? lastEventAtMs)
    }

    /// Time since the last runtime event, ignoring the turn-start anchor; this is
    /// what `last_event_age_*` telemetry reports.
    public func lastEventAgeMs(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> Int {
        lock.lock(); defer { lock.unlock() }
        return nowMs - lastEventAtMs
    }

    public func noteTurnStarted(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        lock.lock(); defer { lock.unlock() }
        turnStartedAtMs = nowMs
    }

    public func noteRuntimeEvent(eventKind: String? = nil, nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        lock.lock(); defer { lock.unlock() }
        lastEventAtMs = nowMs
        lastEventKindValue = eventKind
        staleSinceMs = nil
    }

    public func noteInternalProgress(observedAtMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        lock.lock(); defer { lock.unlock() }
        lastEventAtMs = observedAtMs
        staleSinceMs = nil
    }

    @discardableResult
    public func markStale(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> Int {
        lock.lock(); defer { lock.unlock() }
        if staleSinceMs == nil { staleSinceMs = nowMs }
        return staleSinceMs!
    }
}
