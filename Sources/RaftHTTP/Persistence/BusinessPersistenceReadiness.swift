import RaftShared
import Synchronization

public enum BusinessPersistencePhase: String, Sendable {
    case loading, loaded, active, failed, closed
}

public struct BusinessPersistenceReadiness: Sendable {
    public let phase: BusinessPersistencePhase
    public let writerEpoch: Int64?
    public let isReady: Bool
}

/// A monotonic, bounded-freshness lease observation for synchronous transport
/// authorization. This is never a substitute for checking the fenced lease at CAS.
final class BusinessPersistenceReadinessState: Sendable {
    private struct State: Sendable {
        var phase = BusinessPersistencePhase.loading
        var epoch: Int64?
        var lastHealthy: ContinuousClock.Instant?
    }
    private let state = Mutex(State())
    private let freshness: Duration = .milliseconds(500)

    func snapshot() -> BusinessPersistenceReadiness {
        let now = ContinuousClock.now
        return state.withLock { stored in
            let fresh = stored.lastHealthy.map { $0.duration(to: now) <= freshness } ?? false
            return BusinessPersistenceReadiness(
                phase: stored.phase, writerEpoch: stored.epoch,
                isReady: stored.phase == .active && fresh
            )
        }
    }

    func observedHealthy(epoch: Int64) {
        let now = ContinuousClock.now
        state.withLock { stored in
            guard stored.phase != .failed && stored.phase != .closed else { return }
            stored.epoch = epoch
            stored.lastHealthy = now
        }
    }

    func loaded() { state.withLock { if $0.phase == .loading { $0.phase = .loaded } } }
    func activate() { state.withLock { if $0.phase == .loaded { $0.phase = .active } } }

    func stop(_ phase: BusinessPersistencePhase) {
        state.withLock { stored in
            if stored.phase != .failed { stored.phase = phase }
            stored.lastHealthy = nil
        }
    }
}
