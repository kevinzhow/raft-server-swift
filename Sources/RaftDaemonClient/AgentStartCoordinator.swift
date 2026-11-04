import Foundation

/// The queue/lookup boundary for agent starts: one conformance surface, an
/// immutable enqueue time per item, the starting-never-queued policy, capacity
/// gating for the pump, and cancel operations that drain both queue and lookup
/// while letting callbacks observe the pre-clear state. Ported from the
/// upstream daemon coordinator.
public struct AgentStartQueueItem: Sendable, Equatable {
    public var agentId: String
    public var enqueuedAtMs: Int
    public var launchId: String
    public init(agentId: String, enqueuedAtMs: Int, launchId: String) {
        self.agentId = agentId
        self.enqueuedAtMs = enqueuedAtMs
        self.launchId = launchId
    }
}

public enum AgentStartPumpState: Sendable, Equatable {
    case ready(item: AgentStartQueueItem)
    case blocked(reason: String)
    case empty
}

public enum AgentStartDequeueResult: Sendable, Equatable {
    case item(AgentStartQueueItem)
    case empty
}

public enum AgentStartCoordinatorError: Error, Equatable, CustomStringConvertible {
    case alreadyQueued(String)
    case alreadyStarting(String)
    case stillQueued(String)
    public var description: String {
        switch self {
        case .alreadyQueued(let id): "agent \(id) is already queued"
        case .alreadyStarting(let id): "agent \(id) is already starting"
        case .stillQueued(let id): "agent \(id) is still queued"
        }
    }
}

public final class AgentStartCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConcurrentStarts: Int
    private let minStartIntervalMs: Int
    private var queue: [AgentStartQueueItem] = []
    private var queuedIndex: [String: AgentStartQueueItem] = [:]
    private var starting: [String] = []
    private var activeStarts = 0

    public init(maxConcurrentStarts: Int, minStartIntervalMs: Int) {
        self.maxConcurrentStarts = maxConcurrentStarts
        self.minStartIntervalMs = minStartIntervalMs
    }

    public struct Snapshot: Sendable, Equatable {
        public var queuedAgentIds: [String]
        public var startingAgentIds: [String]
        public var queueDepth: Int

        public init(queuedAgentIds: [String], startingAgentIds: [String], queueDepth: Int) {
            self.queuedAgentIds = queuedAgentIds
            self.startingAgentIds = startingAgentIds
            self.queueDepth = queueDepth
        }
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            queuedAgentIds: queue.map(\.agentId),
            startingAgentIds: starting,
            queueDepth: queue.count
        )
    }

    public func getQueued(_ agentId: String) -> AgentStartQueueItem? {
        lock.lock(); defer { lock.unlock() }
        return queuedIndex[agentId]
    }

    public func enqueue(_ item: AgentStartQueueItem) throws {
        lock.lock(); defer { lock.unlock() }
        if queuedIndex[item.agentId] != nil {
            throw AgentStartCoordinatorError.alreadyQueued(item.agentId)
        }
        if starting.contains(item.agentId) {
            throw AgentStartCoordinatorError.alreadyStarting(item.agentId)
        }
        queue.append(item)
        queuedIndex[item.agentId] = item
    }

    public func dequeue() -> AgentStartDequeueResult {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return .empty }
        let item = queue.removeFirst()
        queuedIndex[item.agentId] = nil
        return .item(item)
    }

    public func queueAgeMs(_ agentId: String, nowMs: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let item = queuedIndex[agentId] else { return 0 }
        return nowMs - item.enqueuedAtMs
    }

    public func markStarting(_ agentId: String) throws {
        lock.lock(); defer { lock.unlock() }
        if queuedIndex[agentId] != nil {
            throw AgentStartCoordinatorError.stillQueued(agentId)
        }
        if !starting.contains(agentId) { starting.append(agentId) }
    }

    public func clearStarting(_ agentId: String) {
        lock.lock(); defer { lock.unlock() }
        starting.removeAll { $0 == agentId }
    }

    public func claimStartSlot(_ agentId: String) {
        lock.lock(); defer { lock.unlock() }
        activeStarts += 1
    }

    @discardableResult
    public func releaseStartSlot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeStarts > 0 else { return false }
        activeStarts -= 1
        return true
    }

    public func getPumpState() -> AgentStartPumpState {
        lock.lock(); defer { lock.unlock() }
        if activeStarts >= maxConcurrentStarts { return .blocked(reason: "capacity_full") }
        guard let item = queue.first else { return .empty }
        return .ready(item: item)
    }

    public func cancelQueued(_ agentId: String) -> AgentStartQueueItem? {
        lock.lock(); defer { lock.unlock() }
        guard let item = queuedIndex[agentId] else { return nil }
        queue.removeAll { $0.agentId == agentId }
        queuedIndex[agentId] = nil
        return item
    }

    /// Cancel every queued item; the callback observes the pre-clear queue state.
    public func cancelAllQueued(_ onPreClear: ((AgentStartQueueItem) -> Void)? = nil) -> [AgentStartQueueItem] {
        lock.lock()
        let items = queue
        lock.unlock()
        // Callbacks may inspect the coordinator; never call them while holding the lock.
        for item in items { onPreClear?(item) }
        lock.lock()
        queue.removeAll()
        queuedIndex.removeAll()
        lock.unlock()
        return items
    }
}
