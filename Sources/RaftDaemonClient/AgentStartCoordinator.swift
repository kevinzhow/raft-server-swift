import Foundation
import Synchronization

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

public final class AgentStartCoordinator: Sendable {
    private let maxConcurrentStarts: Int
    private let minStartIntervalMs: Int
    private struct State: Sendable {
        var queue: [AgentStartQueueItem] = []
        var queuedIndex: [String: AgentStartQueueItem] = [:]
        var starting: [String] = []
        var activeStarts = 0
    }
    private let state = Mutex(State())

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
        return state.withLock { state in
            return Snapshot(
                queuedAgentIds: state.queue.map(\.agentId),
                startingAgentIds: state.starting,
                queueDepth: state.queue.count
            )
        }
    }

    public func getQueued(_ agentId: String) -> AgentStartQueueItem? {
        return state.withLock { state in
            return state.queuedIndex[agentId]
        }
    }

    public func enqueue(_ item: AgentStartQueueItem) throws {
        try state.withLock { state in
            if state.queuedIndex[item.agentId] != nil {
                throw AgentStartCoordinatorError.alreadyQueued(item.agentId)
            }
            if state.starting.contains(item.agentId) {
                throw AgentStartCoordinatorError.alreadyStarting(item.agentId)
            }
            state.queue.append(item)
            state.queuedIndex[item.agentId] = item
        }
    }

    public func dequeue() -> AgentStartDequeueResult {
        return state.withLock { state in
            guard !state.queue.isEmpty else { return .empty }
            let item = state.queue.removeFirst()
            state.queuedIndex[item.agentId] = nil
            return .item(item)
        }
    }

    public func queueAgeMs(_ agentId: String, nowMs: Int) -> Int {
        return state.withLock { state in
            guard let item = state.queuedIndex[agentId] else { return 0 }
            return nowMs - item.enqueuedAtMs
        }
    }

    public func markStarting(_ agentId: String) throws {
        try state.withLock { state in
            if state.queuedIndex[agentId] != nil {
                throw AgentStartCoordinatorError.stillQueued(agentId)
            }
            if !state.starting.contains(agentId) { state.starting.append(agentId) }
        }
    }

    public func clearStarting(_ agentId: String) {
        state.withLock { state in
            state.starting.removeAll { $0 == agentId }
        }
    }

    public func claimStartSlot(_ agentId: String) {
        state.withLock { state in
            state.activeStarts += 1
        }
    }

    @discardableResult
    public func releaseStartSlot() -> Bool {
        return state.withLock { state in
            guard state.activeStarts > 0 else { return false }
            state.activeStarts -= 1
            return true
        }
    }

    public func getPumpState() -> AgentStartPumpState {
        return state.withLock { state in
            if state.activeStarts >= maxConcurrentStarts { return .blocked(reason: "capacity_full") }
            guard let item = state.queue.first else { return .empty }
            return .ready(item: item)
        }
    }

    public func cancelQueued(_ agentId: String) -> AgentStartQueueItem? {
        return state.withLock { state in
            guard let item = state.queuedIndex[agentId] else { return nil }
            state.queue.removeAll { $0.agentId == agentId }
            state.queuedIndex[agentId] = nil
            return item
        }
    }

    /// Cancel every queued item; the callback observes the pre-clear queue state.
    public func cancelAllQueued(_ onPreClear: ((AgentStartQueueItem) -> Void)? = nil) -> [AgentStartQueueItem] {
        let items = state.withLock { state in
            return state.queue
        }
        // Callbacks may inspect the coordinator; never call them while holding the lock.
        for item in items { onPreClear?(item) }
        state.withLock { state in
            state.queue.removeAll()
            state.queuedIndex.removeAll()
        }
        return items
    }
}
