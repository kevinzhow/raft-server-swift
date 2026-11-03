import Testing
import RaftDaemonClient

private func message(_ content: String, _ id: String? = nil) -> PendingDeliveryMessage {
    PendingDeliveryMessage(messageId: id ?? content, content: content)
}

@Test func transitionTablePreservesPendingWakeExactlyOnce() throws {
    let buffer = AgentStartPendingDeliveryBuffer()
    #expect(buffer.bufferDuringStart("agent-1", message("during-start")) == 1)
    #expect(buffer.bufferDuringStart("agent-1", message("during-cooldown")) == 2)
    try buffer.assertInvariants("queued/start/cooldown", snapshot: .init(
        queuedAgentIds: ["agent-1"], cooldownAgentIds: ["agent-1"]
    ))
    buffer.rebindWake("agent-1", previousWake: message("old-wake"), nextWake: message("new-wake"), sameWake: { $0.messageId == $1.messageId })
    #expect(buffer.values("agent-1").map(\.content) == ["during-start", "during-cooldown", "old-wake"], "rebindWake merges the old wake instead of overwriting")
    let drained = buffer.drainOnSpawn("agent-1")
    #expect(drained.map(\.content) == ["during-start", "during-cooldown", "old-wake"], "drainOnSpawn returns each pending wake once")
    #expect(!buffer.has("agent-1"), "drainOnSpawn clears the owner buffer")
    buffer.cancelStart("agent-1")
    #expect(!buffer.has("agent-1"), "cancelStart is idempotent after drain")
}

@Test func dropIsBlockedByRebindWakeMerge() {
    let buffer = AgentStartPendingDeliveryBuffer()
    buffer.bufferDuringStart("agent-1", message("already-pending"))
    buffer.rebindWake("agent-1", previousWake: message("old-wake"), nextWake: message("new-wake"), sameWake: { _, _ in false })
    #expect(buffer.values("agent-1").map(\.content) == ["already-pending", "old-wake"], "regression catch: rebindWake must append the old wake")
}

@Test func duplicateIsBlockedByDrainOnSpawnTransfer() {
    let buffer = AgentStartPendingDeliveryBuffer()
    buffer.bufferDuringStart("agent-1", message("wake"))
    #expect(buffer.drainOnSpawn("agent-1").map(\.content) == ["wake"])
    buffer.bufferDuringStart("agent-1", message("later-wake"))
    #expect(buffer.drainOnSpawn("agent-1").map(\.content) == ["later-wake"], "a second drain only delivers newly-buffered work")
}

@Test func orphanIsBlockedByCancelStartCleanup() throws {
    let buffer = AgentStartPendingDeliveryBuffer()
    buffer.bufferDuringStart("agent-1", message("wake"))
    buffer.cancelStart("agent-1")
    #expect(!buffer.has("agent-1"))
    try buffer.assertInvariants("cancelled start", snapshot: .init())
}

@Test func valuesReturnsASnapshotNotMutableOwnerState() {
    let buffer = AgentStartPendingDeliveryBuffer()
    buffer.bufferDuringStart("agent-1", message("wake"))
    var snapshot = buffer.values("agent-1")
    snapshot.append(message("external-mutation"))
    #expect(buffer.count("agent-1") == 1)
    #expect(buffer.values("agent-1").map(\.content) == ["wake"])
}

@Test func nonStartingPendingOwnerIsRejected() {
    let buffer = AgentStartPendingDeliveryBuffer()
    buffer.bufferDuringStart("agent-1", message("wake"))
    var threw = false
    do {
        try buffer.assertInvariants("non-starting pending", snapshot: .init())
    } catch let error as PendingDeliveryInvariantViolation {
        threw = error.message.contains("pending messages for non-starting agent agent-1")
    } catch {
        threw = false
    }
    #expect(threw)
}

@Test func suppressConsumedRemovesMatchingPendingMessagesWithoutRawAccess() {
    let buffer = AgentStartPendingDeliveryBuffer()
    buffer.bufferDuringStart("agent-1", message("seen", "seen-id"))
    buffer.bufferDuringStart("agent-1", message("unseen", "unseen-id"))
    let removed = buffer.suppressConsumed("agent-1") { $0.messageId == "seen-id" }
    #expect(removed == 1)
    #expect(buffer.values("agent-1").map(\.content) == ["unseen"])
}
