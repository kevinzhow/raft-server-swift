import Foundation

/// Bounded set of recently delivered ids; entries expire by age and the oldest
/// ones are dropped when the cap is reached. Behaviour matches the upstream
/// daemon helper (task #1295).
public final class RecentDeliveryIds: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var seenAt: [String: Int] = [:]
    private let maxEntries: Int
    private let maxAgeMs: Int

    public init(maxEntries: Int, maxAgeMs: Int) {
        self.maxEntries = maxEntries
        self.maxAgeMs = maxAgeMs
    }

    public func remember(_ id: String, now: Int) {
        lock.lock()
        order.removeAll { $0 == id }
        order.append(id)
        seenAt[id] = now
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            seenAt[oldest] = nil
        }
        lock.unlock()
    }

    public func has(_ id: String, now: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let seen = seenAt[id] else { return false }
        if now - seen >= maxAgeMs {
            order.removeAll { $0 == id }
            seenAt[id] = nil
            return false
        }
        return true
    }

    public var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return seenAt.count
    }
}
