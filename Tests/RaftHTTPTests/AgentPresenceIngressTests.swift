import Foundation
import RaftShared
import Synchronization
import Testing
@testable import RaftHTTP

/// The daemon `agent:status` / `agent:activity` contract: retained facts, the
/// manual-stop guard, the canonical detailKind projection and the realtime
/// push. The fixture uses the same owner stores as the production ingress.
@Suite(.serialized) struct AgentPresenceIngressTests {
    private struct Fixture: Sendable {
        let domain: AgentExecutionDomain
        let agents: AgentsRuntimeStore
        let machines: MachinesAndComputersStore
        let oauth: OAuthLedger
        let messages: MessagesAndThreadsStore
        let server: String
        let machine: String
        let agent: String
        let context: AgentExecutionMachineContext
    }

    private func fixture() -> Fixture {
        let server = "presence-server"
        let machine = "presence-machine"
        let agents = AgentsRuntimeStore()
        let machines = MachinesAndComputersStore()
        let oauth = OAuthLedger()
        oauth.addOwnedServer(id: server, slug: "presence", name: "Presence", ownerId: "owner")
        let agent = oauth.createAgent(serverId: server, name: "Cindy", runtime: "codex")
        agents.agentMachineIds = [agent: machine]
        machines.machines = [MachineRecord(
            id: machine, serverId: server, userId: "owner", name: "Computer", description: nil, apiKey: nil
        )]
        machines.setMachineOnline(machineId: machine, online: true)
        let messages = MessagesAndThreadsStore()
        let domain = AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth,
                                          channels: ServersAndChannelsStore(), messages: messages)
        return Fixture(domain: domain, agents: agents, machines: machines, oauth: oauth, messages: messages,
                       server: server, machine: machine, agent: agent,
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

    private func ready(_ fixture: Fixture) async throws {
        try await commit {
            try fixture.domain.connectionOpened(fixture.context)
            try fixture.domain.connectionReady(fixture.context, daemonInstanceId: "daemon-1",
                                               runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
        }
    }

    private func frame(_ type: String, agent: String, body: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["type": type, "agentId": agent, "daemonInstanceId": "daemon-1", "clientSeq": 1]
        value.merge(body) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }

    private func status(_ fixture: Fixture, _ status: String, launch: String? = nil) async throws -> AgentExecutionIngressResult {
        var body: [String: Any] = ["status": status]
        if let launch { body["launchId"] = launch }
        let payload = try frame("agent:status", agent: fixture.agent, body: body)
        return try await commit {
            try fixture.domain.stageIngress(context: fixture.context, type: "agent:status", payload: payload)
        }
    }

    private func activity(_ fixture: Fixture, detailKind: String?, detail: String,
                          activity: String? = nil, launch: String? = nil) async throws -> AgentExecutionIngressResult {
        var body: [String: Any] = ["detail": detail]
        if let detailKind { body["detailKind"] = detailKind }
        if let activity { body["activity"] = activity }
        if let launch { body["launchId"] = launch }
        let payload = try frame("agent:activity", agent: fixture.agent, body: body)
        return try await commit {
            try fixture.domain.stageIngress(context: fixture.context, type: "agent:activity", payload: payload)
        }
    }

    @Test func daemonStatusPersistsActiveInactiveAndSleeping() async throws {
        let fixture = fixture()
        try await ready(fixture)
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")

        #expect(try await status(fixture, "active") == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")

        #expect(try await status(fixture, "inactive") == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")

        // RFC 069: a sleeping runtime is still a live process.
        #expect(try await status(fixture, "sleeping") == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")

        let unknown = try await status(fixture, "busy")
        guard case .hold = unknown else { Issue.record("unknown status must be held"); return }
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
    }

    @Test func manualStopIntentIsNotOverwrittenByDaemonStatus() async throws {
        let fixture = fixture()
        try await ready(fixture)
        fixture.oauth.setAgentStatus(id: fixture.agent, status: "stopped")

        #expect(try await status(fixture, "active") == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "stopped")
        #expect(try await status(fixture, "inactive") == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "stopped")
    }

    @Test func staleLaunchStatusIsIgnored() async throws {
        let fixture = fixture()
        try await ready(fixture)
        fixture.agents.withState { state in
            state.execution.agents[fixture.agent] = AgentExecutionAgent(
                serverId: fixture.server, machineId: fixture.machine, currentLaunchId: "launch-current")
        }
        #expect(try await status(fixture, "active", launch: "launch-old") == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")
        #expect(try await status(fixture, "active", launch: "launch-current") == .committed(ack: nil))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "active")
    }

    @Test func activityDerivesFromCanonicalDetailKindAndPushesRealtime() async throws {
        let fixture = fixture()
        try await ready(fixture)
        let events = Mutex<[(room: String, event: String, payload: String?)]>([])
        fixture.messages.realtimeEmitterStorage = { room, event, payload in
            events.withLock { $0.append((room, event, payload)) }
        }

        #expect(try await activity(fixture, detailKind: "thinking_started", detail: "Planning") == .committed(ack: nil))
        #expect(fixture.agents.state.agentActivities[fixture.agent]?.activity == "thinking")
        #expect(fixture.agents.state.agentActivities[fixture.agent]?.detail == "Planning")
        let captured = events.withLock { $0 }
        #expect(captured.count == 1)
        #expect(captured.first?.room == "server:presence-server")
        #expect(captured.first?.event == "agent:activity")
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: Data((captured.first?.payload ?? "").utf8))
        #expect(payload["agentId"] == .string(fixture.agent))
        #expect(payload["activity"] == .string("thinking"))
        #expect(payload["activityKind"] == .string("thinking"))
        #expect(payload["detail"] == .string("Planning"))
        #expect(payload["detailKind"] == .string("thinking_started"))
        guard case .integer(let firstSequence)? = payload["serverSeq"] else {
            Issue.record("socket push must carry serverSeq"); return
        }

        // idle maps to online, and the server sequence advances monotonically.
        #expect(try await activity(fixture, detailKind: "idle", detail: "") == .committed(ack: nil))
        #expect(fixture.agents.state.agentActivities[fixture.agent]?.activity == "online")
        let next = try JSONDecoder().decode([String: JSONValue].self,
                                            from: Data((events.withLock { $0 }.last?.payload ?? "").utf8))
        guard case .integer(let secondSequence)? = next["serverSeq"] else {
            Issue.record("second socket push must carry serverSeq"); return
        }
        #expect(secondSequence > firstSequence)
        #expect(next["activity"] == .string("online"))
    }

    @Test func legacyActivityWithoutDetailKindKeepsItsOwnKind() async throws {
        let fixture = fixture()
        try await ready(fixture)
        #expect(try await activity(fixture, detailKind: nil, detail: "Running", activity: "working") == .committed(ack: nil))
        #expect(fixture.agents.state.agentActivities[fixture.agent]?.activity == "working")
    }

    @Test func explicitWeakOrUnknownActivityKindsAreHeld() async throws {
        let fixture = fixture()
        try await ready(fixture)
        try await activity(fixture, detailKind: "thinking_started", detail: "Planning")
        for kind in ["other", "daemon_activity", "external_activity", "slock_action", "none", "bogus"] {
            let result = try await activity(fixture, detailKind: kind, detail: "ignored")
            guard case .hold = result else { Issue.record("\(kind) must be held"); continue }
        }
        #expect(fixture.agents.state.agentActivities[fixture.agent]?.activity == "thinking")
    }

    @Test func manualStopSuppressesDaemonActivity() async throws {
        let fixture = fixture()
        try await ready(fixture)
        fixture.oauth.setAgentStatus(id: fixture.agent, status: "stopped")
        #expect(try await activity(fixture, detailKind: "thinking_started", detail: "Planning") == .committed(ack: nil))
        #expect(fixture.agents.state.agentActivities[fixture.agent] == nil)
    }

    @Test func foreignMachineAndStaleConnectionNeverWritePresence() async throws {
        let fixture = fixture()
        try await ready(fixture)
        let foreign = AgentExecutionMachineContext(machineId: fixture.machine, serverId: "foreign-server",
                                                   connectionEpochId: "connection-1")
        let foreignStatusPayload = try frame("agent:status", agent: fixture.agent, body: ["status": "active"])
        let foreignStatus = try await commit {
            try fixture.domain.stageIngress(context: foreign, type: "agent:status", payload: foreignStatusPayload)
        }
        guard case .hold = foreignStatus else { Issue.record("foreign server must be held"); return }
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")
        let foreignActivityPayload = try frame("agent:activity", agent: fixture.agent,
                                               body: ["detail": "x", "detailKind": "idle"])
        let foreignActivity = try await commit {
            try fixture.domain.stageIngress(context: foreign, type: "agent:activity", payload: foreignActivityPayload)
        }
        guard case .hold = foreignActivity else { Issue.record("foreign activity must be held"); return }
        #expect(fixture.agents.state.agentActivities[fixture.agent] == nil)

        let next = AgentExecutionMachineContext(machineId: fixture.machine, serverId: fixture.server,
                                                connectionEpochId: "connection-2")
        try await commit { try fixture.domain.connectionOpened(next) }
        let staleStatusPayload = try frame("agent:status", agent: fixture.agent, body: ["status": "active"])
        let staleStatus = try await commit {
            try fixture.domain.stageIngress(context: fixture.context, type: "agent:status", payload: staleStatusPayload)
        }
        #expect(staleStatus == .hold(reason: "stale_connection"))
        let staleActivityPayload = try frame("agent:activity", agent: fixture.agent,
                                             body: ["detail": "x", "detailKind": "idle"])
        let staleActivity = try await commit {
            try fixture.domain.stageIngress(context: fixture.context, type: "agent:activity", payload: staleActivityPayload)
        }
        #expect(staleActivity == .hold(reason: "stale_connection"))
        #expect(fixture.oauth.agentRuntimeInfo(id: fixture.agent)?.status == "inactive")
        #expect(fixture.agents.state.agentActivities[fixture.agent] == nil)
    }
}
