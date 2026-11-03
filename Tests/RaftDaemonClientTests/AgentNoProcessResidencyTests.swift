import Testing
import RaftDaemonClient

private func snapshot(
    running: [String] = [], queued: [String] = [], starting: [String] = [], idle: [String] = [],
    terminal: [String] = [], cooldown: [String] = [], fence: [String] = [], pending: [String] = []
) -> AgentNoProcessResidencySnapshot {
    .init(
        runningAgentIds: running, queuedAgentIds: queued, startingAgentIds: starting, idleAgentIds: idle,
        terminalFailureAgentIds: terminal, activeCooldownAgentIds: cooldown,
        fingerprintFenceAgentIds: fence, pendingDeliveryAgentIds: pending
    )
}

private func violation(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as AgentResidencyInvariantViolation { return error.message } catch { return "\(error)" }
}

@Test func allowsPendingDeliveryForQueuedStartingTerminalAndCooldownWithIdle() throws {
    let state = snapshot(
        queued: ["queued"], starting: ["starting"], idle: ["cooldown"], terminal: ["terminal"],
        cooldown: ["cooldown"], pending: ["queued", "starting", "terminal", "cooldown"]
    )
    try AgentNoProcessResidency.assertInvariants("green", state)
    #expect(AgentNoProcessResidency.allowedStartPendingSnapshot(state) == .init(
        queuedAgentIds: ["queued"], startingAgentIds: ["starting"],
        terminalRecoveryAgentIds: ["terminal"], cooldownAgentIds: ["cooldown"]
    ))
}

@Test func rejectsCooldownWithoutRestartConfig() {
    #expect(violation { try AgentNoProcessResidency.assertInvariants("red", snapshot(cooldown: ["agent-1"])) }?.contains("active cooldown without restart config") == true)
}

@Test func rejectsTerminalFailureThatIsAlsoAutoRestartable() {
    #expect(violation { try AgentNoProcessResidency.assertInvariants("red", snapshot(idle: ["agent-1"], terminal: ["agent-1"])) }?.contains("terminal failure and idle restart config both present") == true)
}

@Test func rejectsTerminalFailureWhileStillRunning() {
    #expect(violation { try AgentNoProcessResidency.assertInvariants("red", snapshot(running: ["agent-1"], terminal: ["agent-1"])) }?.contains("terminal failure while process is still registered") == true)
}

@Test func rejectsPendingDeliveryWithoutResidency() {
    #expect(violation { try AgentNoProcessResidency.assertInvariants("red", snapshot(pending: ["agent-1"])) }?.contains("pending delivery without queued/starting/terminal/cooldown residency") == true)
}

@Test func allowsFingerprintFenceTiedToWakeableIdleRetryEvidenceAndRejectsFenceAlone() throws {
    try AgentNoProcessResidency.assertInvariants("green", snapshot(idle: ["agent-1"], fence: ["agent-1"]))
    #expect(violation { try AgentNoProcessResidency.assertInvariants("red", snapshot(fence: ["agent-1"])) }?.contains("fingerprint fence without running process, idle retry config, or terminal failure") == true)
}

private let identity = ResidencyTransitionIdentity(
    agentId: "agent-1", agentLaunchId: "launch-1", agentLaunchIdPresent: true,
    serverId: "server-1", machineId: "machine-1", runtime: "codex", driver: "codex", launchSource: "wake_message"
)

@Test func emitsStableEnterClosePairingRows() {
    let transitions = AgentNoProcessResidencyTransitions()
    let queuedRows = transitions.enter(.init(identity: identity, state: "queued_start", isWaitState: true, fenceKind: "start_scheduler", deadlineUnixMs: 100))
    let queuedEnter = queuedRows[0]
    #expect(queuedEnter.transitionKind == "enter")
    #expect(queuedEnter.spanName == "launch_residency_transition")
    #expect(queuedEnter.phase == "process_residency")
    #expect(queuedEnter.stateInstanceId == queuedEnter.residencyStateInstanceId)
    #expect(queuedEnter.isWaitState == true)
    #expect(queuedEnter.deadlineUnixMs == 100)
    #expect(transitions.enter(.init(identity: identity, state: "queued_start", isWaitState: true, fenceKind: "start_scheduler", deadlineUnixMs: 100)).isEmpty)

    let switchRows = transitions.enter(.init(identity: identity, state: "starting_process", isWaitState: true, fenceKind: "runtime_start_timeout", deadlineUnixMs: 200))
    let queuedClose = switchRows[0]
    let startingEnter = switchRows[1]
    #expect(queuedClose.transitionKind == "close")
    #expect(queuedClose.closeResult == "advanced")
    #expect(queuedClose.stateInstanceId == queuedEnter.stateInstanceId)
    #expect(startingEnter.transitionKind == "enter")
    #expect(startingEnter.stateInstanceId != queuedEnter.stateInstanceId)

    let startingClose = transitions.close(agentId: "agent-1", .init(closeResult: "advanced"))[0]
    #expect(startingClose.transitionKind == "close")
    #expect(startingClose.stateInstanceId == startingEnter.stateInstanceId)
    #expect(startingClose.residencyStateInstanceId == startingEnter.residencyStateInstanceId)
    #expect([queuedEnter, queuedClose, startingEnter, startingClose].map(\.transitionSeq) == [1, 2, 3, 4])
}

@Test func emitsClosedNegativeEvidenceForMissingLaunchId() {
    let transitions = AgentNoProcessResidencyTransitions()
    let enter = transitions.enter(.init(
        identity: .init(
            agentId: "agent-1", agentLaunchId: "missing_launch_id", agentLaunchIdPresent: false,
            serverId: "server-1", machineId: "machine-1", runtime: "codex", driver: "codex", launchSource: "wake_message"
        ),
        state: "starting_process", isWaitState: true, fenceKind: "runtime_start_timeout", deadlineUnixMs: 100,
        failureKind: "missing_launch_id", negativeEvidenceBucket: "missing_launch_id"
    ))[0]
    #expect(enter.agentLaunchId == "missing_launch_id")
    #expect(enter.agentLaunchIdPresent == false)
    #expect(enter.failureKind == "missing_launch_id")
    #expect(enter.negativeEvidenceBucket == "missing_launch_id")
}
