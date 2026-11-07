import Foundation
import Synchronization

/// The daemon's derived runtime-progress clock. Only runtime app events and
/// explicit internal-progress observations refresh it or clear a latched stall;
/// stall age anchors on the later of the last runtime event and the current
/// turn start, while `lastEventAgeMs` keeps its literal telemetry meaning.
/// Ported from the upstream daemon state.
public final class RuntimeProgressState: Sendable {
    private struct State: Sendable {
        var lastEventAtMs: Int
        var lastEventKind: String? = nil
        var staleSinceMs: Int? = nil
        var turnStartedAtMs: Int? = nil
    }

    private let state: Mutex<State>

    public init(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        state = Mutex(State(lastEventAtMs: nowMs))
    }

    public var lastEventAt: Int {
        state.withLock { $0.lastEventAtMs }
    }

    public var lastEventKind: String? {
        state.withLock { $0.lastEventKind }
    }

    public var staleSince: Int? {
        state.withLock { $0.staleSinceMs }
    }

    public var isStale: Bool {
        state.withLock { $0.staleSinceMs != nil }
    }

    public func ageMs(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> Int {
        state.withLock { nowMs - max($0.lastEventAtMs, $0.turnStartedAtMs ?? $0.lastEventAtMs) }
    }

    /// Time since the last runtime event, ignoring the turn-start anchor; this is
    /// what `last_event_age_*` telemetry reports.
    public func lastEventAgeMs(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> Int {
        state.withLock { nowMs - $0.lastEventAtMs }
    }

    public func noteTurnStarted(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        state.withLock { $0.turnStartedAtMs = nowMs }
    }

    public func noteRuntimeEvent(eventKind: String? = nil, nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        state.withLock {
            $0.lastEventAtMs = nowMs
            $0.lastEventKind = eventKind
            $0.staleSinceMs = nil
        }
    }

    public func noteInternalProgress(observedAtMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        state.withLock {
            $0.lastEventAtMs = observedAtMs
            $0.staleSinceMs = nil
        }
    }

    @discardableResult
    public func markStale(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> Int {
        state.withLock {
            if $0.staleSinceMs == nil { $0.staleSinceMs = nowMs }
            return $0.staleSinceMs!
        }
    }
}
