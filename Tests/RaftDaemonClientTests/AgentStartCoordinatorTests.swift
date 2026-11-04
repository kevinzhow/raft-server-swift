import Testing
import RaftDaemonClient

private func item(_ agentId: String, launchId: String? = nil, enqueuedAtMs: Int = 0) -> AgentStartQueueItem {
    .init(agentId: agentId, enqueuedAtMs: enqueuedAtMs, launchId: launchId ?? "launch-\(agentId)")
}

@Test func queueAndLookupAreOneConformanceBoundary() throws {
    let coordinator = AgentStartCoordinator(maxConcurrentStarts: 1, minStartIntervalMs: 0)
    try coordinator.enqueue(item("agent-1"))
    #expect(coordinator.snapshot() == .init(queuedAgentIds: ["agent-1"], startingAgentIds: [], queueDepth: 1))
    #expect(coordinator.getQueued("agent-1")?.launchId == "launch-agent-1")

    #expect(throws: AgentStartCoordinatorError.alreadyQueued("agent-1")) {
        try coordinator.enqueue(item("agent-1", launchId: "launch-duplicate"))
    }

    let dequeued = coordinator.dequeue()
    #expect(dequeued == .item(item("agent-1")))
    #expect(coordinator.snapshot() == .init(queuedAgentIds: [], startingAgentIds: [], queueDepth: 0))
}

@Test func queueAgeComesFromTheImmutableEnqueueTime() throws {
    let coordinator = AgentStartCoordinator(maxConcurrentStarts: 1, minStartIntervalMs: 0)
    try coordinator.enqueue(item("agent-1", enqueuedAtMs: 1_000))
    #expect(coordinator.queueAgeMs("agent-1", nowMs: 1_250) == 250)
    #expect(coordinator.queueAgeMs("agent-1", nowMs: 2_000) == 1_000)
    #expect(coordinator.getQueued("agent-1")?.enqueuedAtMs == 1_000)
    #expect(coordinator.queueAgeMs("missing", nowMs: 2_000) == 0)
}

@Test func startingNeverQueuedPolicyIsAsserted() throws {
    let coordinator = AgentStartCoordinator(maxConcurrentStarts: 1, minStartIntervalMs: 0)
    try coordinator.markStarting("agent-1")
    #expect(coordinator.snapshot().startingAgentIds == ["agent-1"])
    #expect(throws: AgentStartCoordinatorError.alreadyStarting("agent-1")) {
        try coordinator.enqueue(item("agent-1"))
    }
    coordinator.clearStarting("agent-1")
    try coordinator.enqueue(item("agent-1"))
    #expect(throws: AgentStartCoordinatorError.stillQueued("agent-1")) {
        try coordinator.markStarting("agent-1")
    }
}

@Test func dequeueIsGatedByCapacityAndReopensAfterRelease() throws {
    let coordinator = AgentStartCoordinator(maxConcurrentStarts: 1, minStartIntervalMs: 0)
    coordinator.claimStartSlot("agent-active")
    try coordinator.enqueue(item("agent-2"))
    #expect(coordinator.getPumpState() == .blocked(reason: "capacity_full"))
    #expect(coordinator.releaseStartSlot() == true)
    #expect(coordinator.getPumpState() == .ready(item: item("agent-2")))
}

@Test func cancelOperationsDrainQueueAndLookupPreservingPreClearEvidence() throws {
    let coordinator = AgentStartCoordinator(maxConcurrentStarts: 1, minStartIntervalMs: 0)
    try coordinator.enqueue(item("agent-2"))
    try coordinator.enqueue(item("agent-3"))

    #expect(coordinator.cancelQueued("agent-2") == item("agent-2"))
    #expect(coordinator.snapshot().queuedAgentIds == ["agent-3"])
    #expect(coordinator.snapshot().queueDepth == 1)

    final class Observed: @unchecked Sendable { var depths: [Int] = [] }
    let observed = Observed()
    let all = coordinator.cancelAllQueued { _ in observed.depths.append(coordinator.snapshot().queueDepth) }
    #expect(all == [item("agent-3")])
    #expect(observed.depths == [1], "cancel callbacks observe pre-clear queue state")
    #expect(coordinator.snapshot().queuedAgentIds == [])
    #expect(coordinator.snapshot().queueDepth == 0)
}
