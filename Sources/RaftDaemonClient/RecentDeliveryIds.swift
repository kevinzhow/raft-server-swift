import Foundation
import Synchronization

/// Bounded set of recently delivered ids; entries expire by age and the oldest
/// ones are dropped when the cap is reached. Behaviour matches the upstream
/// daemon helper (task #1295).
public final class RecentDeliveryIds: Sendable {
    private struct State: Sendable {
        var order: [String] = []
        var seenAt: [String: Int] = [:]
    }
    private let state = Mutex(State())
    private let maxEntries: Int
    private let maxAgeMs: Int

    public init(maxEntries: Int, maxAgeMs: Int) {
        self.maxEntries = maxEntries
        self.maxAgeMs = maxAgeMs
    }

    public func remember(_ id: String, now: Int) {
        state.withLock {
            $0.order.removeAll { $0 == id }
            $0.order.append(id)
            $0.seenAt[id] = now
            while $0.order.count > maxEntries, let oldest = $0.order.first {
                $0.order.removeFirst()
                $0.seenAt[oldest] = nil
            }
        }
    }

    public func has(_ id: String, now: Int) -> Bool {
        state.withLock {
            guard let seen = $0.seenAt[id] else { return false }
            if now - seen >= maxAgeMs {
                $0.order.removeAll { $0 == id }
                $0.seenAt[id] = nil
                return false
            }
            return true
        }
    }

    public var size: Int {
        state.withLock { $0.seenAt.count }
    }
}
