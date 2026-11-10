import Foundation
import RaftShared
import Synchronization
import Testing
@testable import RaftHTTP

/// The daemon `ready`/disconnect presence reconciliation and the sequenced
/// `agent:status` channel, driven through the same owner stores as the
/// production machine ingress.
@Suite(.serialized) struct AgentPresenceReconcileTests {
    private final class Recorder: Sendable {
        let events = Mutex<[(room: String, event: String, payload: String?)]>([])
        let sequence = Mutex<Int64>(0)
    }

    private struct Fixture: Sendable {
        let recorder: Recorder
        let domain: AgentExecutionDomain
        let agents: AgentsRuntimeStore
        let machines: MachinesAndComputersStore
        let oauth: OAuthLedger
        let messages: MessagesAndThreadsStore
        let server: String
        let machine: String
        let agent: String
        let other: String
        let context: AgentExecutionMachineContext
    }

    private func fixture() -> Fixture {
        let server = "reconcile-server"
        let machine = "reconcile-machine"
        let agents = AgentsRuntimeStore()
        let machines = MachinesAndComputersStore()
        let oauth = OAuthLedger()
        oauth.addOwnedServer(id: server, slug: "reconcile", name: "Reconcile", ownerId: "owner")
        let agent = oauth.createAgent(serverId: server, name: "Cindy", runtime: "codex")
        let other = oauth.createAgent(serverId: server, name: "Bob", runtime: "codex")
        agents.agentMachineIds = [agent: machine, other: machine]
        machines.machines = [MachineRecord(
            id: machine, serverId: server, userId: "owner", name: "Computer", description: nil, apiKey: nil
        )]
        machines.setMachineOnline(machineId: machine, online: true)
        let messages = MessagesAndThreadsStore()
        let recorder = Recorder()
        messages.realtimeEmitterStorage = { room, event, payload in
            recorder.events.withLock { $0.append((room, event, payload)) }
        }
        let domain = AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth,
                                          channels: ServersAndChannelsStore(), messages: messages)
        return Fixture(recorder: recorder, domain: domain, agents: agents, machines: machines, oauth: oauth, messages: messages,
                       server: server, machine: machine, agent: agent, other: other,
                       context: AgentExecutionMachineContext(machineId: machine, serverId: server,
                                                             connectionEpochId: "connection-1"))
    }

    private func commit<Value: Sendable>(_ operation: @Sendable () throws -> Value) async throws -> Value {
        let context = TransactionContext()
        return try await withTransactionContext(context) {
            let value = try operation()
            try context.prepareCommit()
            context.publishCommitted()
            context.flushDeferredEffects()
            return value
        }
    }

    private func capabilities() -> [String] {
        ["agent:start", "agent:deliver", "agent:stop", "agent:status-sequenced", "agent:runtime-outcome-v1"]
    }

    private func ready(_ fixture: Fixture, running: [String], daemon: String = "daemon-1") async throws {
        try await commit {
            try fixture.domain.connectionOpened(fixture.context)
            try fixture.domain.observeReady(
                fixture.context, daemonInstanceId: daemon, capabilities: capabilities(), runtimes: ["codex"],
                runningAgentIds: running, detectionComplete: true, unreliableAgentIds: [])
        }
    }

    private func status(_ fixture: Fixture, _ status: String, daemon: String? = "daemon-1",
                        clientSeq: Int64? = nil, launch: String? = nil) async throws -> AgentExecutionIngressResult {
        var body: [String: Any] = ["type": "agent:status", "agentId": fixture.agent, "status": status]
        if let daemon { body["daemonInstanceId"] = daemon }
        let seq: Int64? = clientSeq ?? fixture.recorder.sequence.withLock { $0 += 1; return $0 }
        if let seq { body["clientSeq"] = seq }
        if let launch { body["launchId"] = launch }
        let payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return try await commit {
            try fixture.domain.stageIngress(context: fixture.context, type: "agent:status", payload: payload)
        }
    }

    private func activityEvents(_ fixture: Fixture, agent: String) -> [[String: JSONValue]] {
        return fixture.recorder.events.withLock { $0 }
            .filter { $0.room == "server:\(fixture.server)" && $0.event == "agent:activity" }
            .compactMap { entry -> [String: JSONValue]? in
                guard let raw = entry.payload, let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8)) else { return nil }
                guard object["agentId"] == .string(agent) else { return nil }
                return object
            }
    }

    private func storedActivity(_ fixture: Fixture, agent: String) -> (activity: String, detail: String)? {
        fixture.agents.state.agentActivities[agent]
    }

    @Test func runningAgentReadyReconcilesActiveAndOnline() async throws {
        let fixture = fixture()
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")
        try await ready(fixture, running: [fixture.agent])

        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
        #expect(storedActivity(fixture, agent: fixture.agent)?.activity == "online")
        #expect(storedActivity(fixture, agent: fixture.agent)?.detail == "")
        let pushed = activityEvents(fixture, agent: fixture.agent)
        #expect(pushed.count == 1)
        let payload = try #require(pushed.first)
        #expect(payload["activity"] == .string("online"))
        #expect(payload["activityKind"] == .string("online"))
        #expect(payload["detail"] == .string(""))
        #expect(payload["detailKind"] == .string("none"))
        guard case .integer(let sequence)? = payload["serverSeq"] else {
            Issue.record("ready reconcile push must carry serverSeq"); return
        }
        #expect(sequence > 0)
    }

    @Test func activeAgentAbsentFromReadyStaysWakeableAndOnline() async throws {
        let fixture = fixture()
        fixture.oauth.setAgentStatus(id: fixture.agent, status: "active")
        try await ready(fixture, running: [])

        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
        #expect(storedActivity(fixture, agent: fixture.agent)?.activity == "online")
        #expect(activityEvents(fixture, agent: fixture.agent).count == 1)
    }

    @Test func inactiveAgentAbsentFromReadyIsOfflineRuntimeInterrupted() async throws {
        let fixture = fixture()
        try await ready(fixture, running: [])

        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")
        #expect(storedActivity(fixture, agent: fixture.agent)?.activity == "offline")
        #expect(storedActivity(fixture, agent: fixture.agent)?.detail == "Runtime interrupted")
        let payload = try #require(activityEvents(fixture, agent: fixture.agent).first)
        #expect(payload["activity"] == .string("offline"))
        #expect(payload["detailKind"] == .string("runtime_interrupted"))
    }

    @Test func stoppedAgentReportedRunningIsForcedOfflineWithoutReopeningStatus() async throws {
        let fixture = fixture()
        fixture.oauth.setAgentStatus(id: fixture.agent, status: "stopped")
        try await ready(fixture, running: [fixture.agent])

        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "stopped")
        #expect(storedActivity(fixture, agent: fixture.agent)?.activity == "offline")
        #expect(storedActivity(fixture, agent: fixture.agent)?.detail == "Stopped")
        let pushed = activityEvents(fixture, agent: fixture.agent)
        #expect(pushed.count == 1)
        #expect(pushed.first?["detailKind"] == .string("stopped"))
        #expect(!pushed.contains { $0["activity"] == .string("online") })
    }

    @Test func freshBusyActivitySurvivesReadyOnlineButStillPersistsActive() async throws {
        let fixture = fixture()
        fixture.agents.withState { state in
            state.agentActivities[fixture.agent] = (activity: "working", detail: "Running tests")
        }
        try await ready(fixture, running: [fixture.agent])

        // The dbStatus projection is independent of the suppressed online
        // broadcast: the running agent is still active.
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
        #expect(storedActivity(fixture, agent: fixture.agent)?.activity == "working")
        #expect(storedActivity(fixture, agent: fixture.agent)?.detail == "Running tests")
        #expect(activityEvents(fixture, agent: fixture.agent).isEmpty)
    }

    @Test func readyOnlineIsDedupedWithinOneSecond() async throws {
        let fixture = fixture()
        try await ready(fixture, running: [fixture.agent])
        #expect(activityEvents(fixture, agent: fixture.agent).count == 1)

        try await ready(fixture, running: [fixture.agent])
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
        #expect(activityEvents(fixture, agent: fixture.agent).count == 1)
    }

    @Test func statusClientSeqIsOrderedWithinOneDaemonInstance() async throws {
        let fixture = fixture()
        try await ready(fixture, running: [])

        #expect(try await status(fixture, "active", clientSeq: 2) == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")

        // An older sequence from the same daemon process is a replay.
        #expect(try await status(fixture, "inactive", clientSeq: 1) == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")

        #expect(try await status(fixture, "inactive", clientSeq: 3) == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")
    }

    @Test func statusFromForeignDaemonInstanceIsIgnored() async throws {
        let fixture = fixture()
        try await ready(fixture, running: [])

        #expect(try await status(fixture, "active", daemon: "daemon-stale", clientSeq: 9) == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")
    }

    @Test func unsequencedStatusKeepsTheLegacyAcceptPath() async throws {
        let fixture = fixture()
        try await ready(fixture, running: [])

        var body: [String: Any] = ["type": "agent:status", "agentId": fixture.agent, "status": "active"]
        body["launchId"] = nil
        let payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        _ = try await commit {
            try fixture.domain.stageIngress(context: fixture.context, type: "agent:status", payload: payload)
        }
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
    }

    @Test func aStaleLaunchFrameDoesNotAdvanceTheStatusWatermark() async throws {
        let fixture = fixture()
        try await ready(fixture, running: [])
        fixture.agents.withState { state in
            state.execution.agents[fixture.agent] = AgentExecutionAgent(
                serverId: fixture.server, machineId: fixture.machine, currentLaunchId: "launch-current")
        }

        // The launched frame is dropped by the launch guard; it must not consume
        // sequence 4 for the subsequent unlaunched frame.
        #expect(try await status(fixture, "active", clientSeq: 4, launch: "launch-old") == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")
        #expect(try await status(fixture, "active", clientSeq: 4) == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
    }

    @Test func machineDisconnectProjectsOfflineOnlyForActiveAgentsAndPreservesStatus() async throws {
        let fixture = fixture()
        fixture.oauth.setAgentStatus(id: fixture.agent, status: "active")
        try await ready(fixture, running: [])

        // Ready kept the active agent wakeable/online; the inactive agent is
        // offline/runtime_interrupted. Nothing is projected until the upstream
        // two-second grace window has elapsed, so closing alone writes nothing.
        let readyCount = activityEvents(fixture, agent: fixture.agent).count
        let otherReadyCount = activityEvents(fixture, agent: fixture.other).count
        try await commit { try fixture.domain.connectionClosed(fixture.context) }
        #expect(activityEvents(fixture, agent: fixture.agent).count == readyCount)
        #expect(activityEvents(fixture, agent: fixture.other).count == otherReadyCount)

        try await commit { try fixture.domain.projectMachineDisconnect(fixture.context) }
        let projected = activityEvents(fixture, agent: fixture.agent)
        #expect(projected.count == readyCount + 1)
        let payload = try #require(projected.last)
        #expect(payload["activity"] == .string("offline"))
        #expect(payload["detail"] == .string("Machine disconnected"))
        #expect(payload["detailKind"] == .string("machine_disconnected"))
        // The persisted status is preserved by the disconnect projection.
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.other)?.status == "inactive")
        // An inactive agent is not part of the disconnect projection at all.
        #expect(activityEvents(fixture, agent: fixture.other).count == otherReadyCount)
        #expect(storedActivity(fixture, agent: fixture.other)?.detail == "Runtime interrupted")

        // One projection per connection epoch.
        try await commit { try fixture.domain.projectMachineDisconnect(fixture.context) }
        #expect(activityEvents(fixture, agent: fixture.agent).count == readyCount + 1)
    }

    @Test func reconnectedEpochCancelsTheDisconnectProjection() async throws {
        let fixture = fixture()
        fixture.oauth.setAgentStatus(id: fixture.agent, status: "active")
        try await ready(fixture, running: [])
        try await commit { try fixture.domain.connectionClosed(fixture.context) }
        let before = activityEvents(fixture, agent: fixture.agent).count
        let next = AgentExecutionMachineContext(machineId: fixture.machine, serverId: fixture.server,
                                                connectionEpochId: "connection-2")
        try await commit { try fixture.domain.connectionOpened(next) }
        try await commit { try fixture.domain.projectMachineDisconnect(fixture.context) }
        #expect(activityEvents(fixture, agent: fixture.agent).count == before)
        #expect(storedActivity(fixture, agent: fixture.agent)?.activity == "online")

        // Closing the new epoch projects its own disconnect once.
        try await commit { try fixture.domain.connectionClosed(next) }
        try await commit { try fixture.domain.projectMachineDisconnect(next) }
        let after = activityEvents(fixture, agent: fixture.agent)
        #expect(after.count == before + 1)
        #expect(after.last?["detailKind"] == .string("machine_disconnected"))
    }

    @Test func visiblePresenceDerivesTheUpstreamFallback() {
        #expect(AgentPresenceSignal.visiblePresence(recorded: nil, status: "active", machineReachable: true)
            == (activity: "online", detail: ""))
        #expect(AgentPresenceSignal.visiblePresence(recorded: nil, status: "active", machineReachable: false)
            == (activity: "offline", detail: ""))
        #expect(AgentPresenceSignal.visiblePresence(recorded: nil, status: "inactive", machineReachable: true)
            == (activity: "offline", detail: ""))
        #expect(AgentPresenceSignal.visiblePresence(recorded: (activity: "thinking", detail: "Planning"),
                                                    status: "active", machineReachable: true)
            == (activity: "thinking", detail: "Planning"))
        #expect(AgentPresenceSignal.visiblePresence(recorded: (activity: "thinking", detail: "Planning"),
                                                    status: "stopped", machineReachable: true)
            == (activity: "offline", detail: "Stopped"))
    }
}
