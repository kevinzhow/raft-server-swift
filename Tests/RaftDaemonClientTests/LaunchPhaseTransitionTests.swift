import RaftDaemonClient
import Testing

private func identity(_ overrides: LaunchIdentity? = nil) -> LaunchTransition.Identity {
    LaunchTransition.Identity(
        agentLaunchId: overrides?.agentLaunchId ?? "launch-1",
        agentId: "agent-1", serverId: "server-1", machineId: "machine-1",
        runtime: "codex", driver: "codex", launchSource: "wake_message"
    )
}

private struct LaunchIdentity {
    var agentLaunchId: String?
}

private func readiness(_ overrides: LaunchTransition.ReadinessState? = nil) -> LaunchTransition.ReadinessState {
    LaunchTransition.ReadinessState(
        stateInstanceId: overrides?.stateInstanceId ?? "state-1",
        enterSeq: overrides?.enterSeq ?? 0,
        identity: overrides?.identity ?? identity(),
        fenceKind: overrides?.fenceKind ?? "runtime_startup_timeout",
        deadlineUnixMs: overrides?.deadlineUnixMs ?? 1_000
    )
}

private func readinessRows(closeResult: String = "advanced") -> [LaunchTransition.Row] {
    let state = readiness()
    return [
        .init(name: LaunchTransition.readinessSpan, attrs: LaunchTransition.buildReadinessEnterAttrs(state)),
        .init(name: LaunchTransition.readinessSpan, attrs: LaunchTransition.buildReadinessCloseAttrs(state, closeResult: closeResult, closeSeq: state.enterSeq + 1)),
    ]
}

@Test func readinessEnterCarriesIdentitySpineAndWaitStateFence() {
    let attrs = LaunchTransition.buildReadinessEnterAttrs(readiness())
    #expect(attrs["span_name"] as? String == LaunchTransition.readinessSpan)
    #expect(attrs["phase"] as? String == "runtime_readiness")
    #expect(attrs["transition_kind"] as? String == "enter")
    #expect(attrs["phase_result"] as? String == "entered")
    #expect(attrs["state"] as? String == "awaiting_runtime_ready")
    #expect(attrs["state_instance_id"] as? String == "state-1")
    #expect(attrs["transition_seq"] as? Int == 0)
    #expect(attrs["is_wait_state"] as? Bool == true)
    #expect(attrs["fence_kind"] as? String == "runtime_startup_timeout")
    #expect(attrs["deadline_unix_ms"] as? Int == 1_000)
    #expect(attrs["agent_launch_id"] as? String == "launch-1")
    #expect(attrs["agent_id"] as? String == "agent-1")
    #expect(attrs["server_id"] as? String == "server-1")
    #expect(attrs["machine_id"] as? String == "machine-1")
    #expect(attrs["runtime"] as? String == "codex")
    #expect(attrs["driver"] as? String == "codex")
    #expect(attrs["launch_source"] as? String == "wake_message")
    #expect(attrs["negative_evidence_bucket"] == nil)
}

@Test func readinessCloseKeepsPairingKeyAndClosedCloseResult() throws {
    let state = readiness()
    let attrs = LaunchTransition.buildReadinessCloseAttrs(state, closeResult: "advanced", closeSeq: 1)
    #expect(attrs["transition_kind"] as? String == "close")
    #expect(attrs["close_result"] as? String == "advanced")
    #expect(attrs["state_instance_id"] as? String == "state-1")
    #expect(attrs["transition_seq"] as? Int == 1)
    #expect(attrs["is_wait_state"] == nil)
    try LaunchTransition.assertReadinessPairing(context: "valid", rows: readinessRows())
    #expect(reads(throws: { try LaunchTransition.assertReadinessPairing(context: "open", rows: [readinessRows()[0]]) }) != nil)
    let closesOnly = LaunchTransition.Row(name: LaunchTransition.readinessSpan, attrs: LaunchTransition.buildReadinessCloseAttrs(state, closeResult: "terminal", closeSeq: 2))
    #expect(reads(throws: { try LaunchTransition.assertReadinessPairing(context: "orphan", rows: [closesOnly]) })?.contains("close without enter") == true)
    let duplicated = readinessRows() + [LaunchTransition.Row(name: LaunchTransition.readinessSpan, attrs: LaunchTransition.buildReadinessEnterAttrs(LaunchTransition.ReadinessState(
        stateInstanceId: "state-1", enterSeq: 0, identity: identity(), fenceKind: "none", deadlineUnixMs: nil
    )))]
    #expect(reads(throws: { try LaunchTransition.assertReadinessPairing(context: "dup", rows: duplicated) })?.contains("reused") == true)
}

private func reads(throws body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch let error as LaunchTransition.PairingViolation {
        return error.message
    } catch {
        return "\(error)"
    }
}

@Test func missingLaunchIdIsNegativeEvidenceOnEnterAndClose() {
    let state = readiness(LaunchTransition.ReadinessState(
        stateInstanceId: "s", enterSeq: 0,
        identity: LaunchTransition.Identity(agentLaunchId: nil, agentId: "a", serverId: nil, machineId: nil, runtime: "r", driver: "d", launchSource: "l"),
        fenceKind: "runtime_startup_timeout", deadlineUnixMs: 5
    ))
    #expect(LaunchTransition.readinessNegativeEvidence(state.identity) == "missing_launch_id")
    #expect(LaunchTransition.buildReadinessEnterAttrs(state)["negative_evidence_bucket"] as? String == "missing_launch_id")
    #expect(LaunchTransition.buildReadinessCloseAttrs(state, closeResult: "timeout", closeSeq: 1)["negative_evidence_bucket"] as? String == "missing_launch_id")
}

@Test func activationEnterAndCloseCarryDeliveredViaAndFenceNone() throws {
    let state = LaunchTransition.ActivationState(stateInstanceId: "act-1", enterSeq: 3, identity: identity())
    let enter = LaunchTransition.buildActivationEnterAttrs(state)
    #expect(enter["phase"] as? String == "activation_delivery")
    #expect(enter["span_name"] as? String == LaunchTransition.activationSpan)
    #expect(enter["state"] as? String == "awaiting_activation_delivery")
    #expect(enter["fence_kind"] as? String == "none")
    #expect(enter["deadline_unix_ms"] == nil)
    let close = LaunchTransition.buildActivationCloseAttrs(state, closeResult: "advanced", closeSeq: 4, deliveredVia: "stdin")
    #expect(close["delivered_via"] as? String == "stdin")
    #expect(close["close_result"] as? String == "advanced")
    let rows = [
        LaunchTransition.Row(name: LaunchTransition.activationSpan, attrs: enter),
        LaunchTransition.Row(name: LaunchTransition.activationSpan, attrs: close),
    ]
    try LaunchTransition.assertActivationPairing(context: "activation", rows: rows)
}

@Test func multipleLaunchesPairIndependentlyAndQ8ScrubRejectsRawKeys() throws {
    var rows: [LaunchTransition.Row] = []
    for launch in ["launch-1", "launch-2"] {
        let state = LaunchTransition.ReadinessState(
            stateInstanceId: "state-\(launch)", enterSeq: launch == "launch-1" ? 0 : 2,
            identity: LaunchTransition.Identity(agentLaunchId: launch, agentId: "a", serverId: "s", machineId: "m", runtime: "r", driver: "d", launchSource: "wake_message"),
            fenceKind: "none", deadlineUnixMs: nil
        )
        rows.append(.init(name: LaunchTransition.readinessSpan, attrs: LaunchTransition.buildReadinessEnterAttrs(state)))
        rows.append(.init(name: LaunchTransition.readinessSpan, attrs: LaunchTransition.buildReadinessCloseAttrs(state, closeResult: "advanced", closeSeq: state.enterSeq + 1)))
    }
    try LaunchTransition.assertReadinessPairing(context: "two launches", rows: rows)
    var leaky = rows
    leaky.append(.init(name: LaunchTransition.readinessSpan, attrs: ["agent_launch_id": "launch-1", "state_instance_id": "x", "transition_kind": "enter", "transition_seq": 9, "prompt_text": "secret"]))
    #expect(reads(throws: { try LaunchTransition.assertReadinessPairing(context: "q8", rows: leaky) })?.contains("forbidden attr key") == true)
}
