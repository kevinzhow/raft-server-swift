import Foundation
import RaftDaemonClient
import Testing

@Test func replacedProcessRecordsOneRejectionPerWindowWithTheSuppressedCount() {
    final class State: @unchecked Sendable {
        var now = 1_000
        var records: [[String: Any]] = []
    }
    let state = State()
    let staleToken = RuntimeProcessBindingFence.RuntimeToken()
    let currentToken = RuntimeProcessBindingFence.RuntimeToken()
    let stale = RuntimeProcessBindingFence.Process(
        runtime: staleToken, driverId: "codex", launchId: "launch", sessionId: "session", processInstanceId: "old"
    )
    let current = RuntimeProcessBindingFence.Process(
        runtime: currentToken, driverId: "codex", launchId: "launch", sessionId: "session", processInstanceId: "new"
    )
    let fence = RuntimeProcessBindingFence(
        getCurrentProcess: { _ in current },
        recordTrace: { name, attrs in
            if name == "daemon.agent.runtime_binding.rejected" { state.records.append(attrs) }
        },
        now: { state.now }
    )
    func binding(_ process: RuntimeProcessBindingFence.Process) -> RuntimeProcessBindingFence.Binding {
        .init(
            agentId: "a", serverId: "s", machineId: "m", configuredRuntimeId: "codex",
            driverId: "codex", initialLaunchId: "launch", activeLaunchId: "launch",
            startSessionId: "session", activeSessionId: "session", processInstanceId: process.processInstanceId
        )
    }
    fence.bind(token: staleToken, binding: binding(stale))
    fence.bind(token: currentToken, binding: binding(current))

    for _ in 0..<5_000 {
        #expect(fence.acceptOutput(agentId: "a", process: stale, source: "stdout") == false)
    }
    #expect(fence.acceptOutput(agentId: "a", process: stale, source: "stderr") == false)
    #expect(state.records[0]["agent_id"] as? String == "a")
    #expect(state.records[0]["process_instance_id"] as? String == "old")
    #expect(state.records.map { "\($0["source"] as? String ?? ""):\($0["reason"] as? String ?? ""):\($0["suppressed_count"] as? Int ?? -1)" }
        == ["stdout:inactive_process_generation:0", "stderr:inactive_process_generation:0"])

    state.now += RuntimeProcessBindingFence.outputRejectionTraceWindowMs
    _ = fence.acceptOutput(agentId: "a", process: stale, source: "stdout")
    #expect(state.records.last?["suppressed_count"] as? Int == 4_999)
    #expect(state.records.count == 3)

    _ = fence.send(agentId: "a", process: stale, input: ["sessionId": "session"], source: "stdin_idle_delivery")
    _ = fence.send(agentId: "a", process: stale, input: ["sessionId": "session"], source: "stdin_idle_delivery")
    #expect(state.records.filter { $0["direction"] as? String == "input" }.count == 2)
}
