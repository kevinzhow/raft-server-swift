import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

/// D7: a keep-session restart and a session reset with queued messages.
///
/// Upstream carries the message that causes a start inside `agent:start` as its
/// `wakeMessage` (no separate `agent:deliver`), and a delivery write the daemon
/// has not acknowledged is in-flight evidence — never a manual-recovery gate.
/// One message gets exactly one live attempt across every release trigger.
@Suite(.serialized) struct QueuedRestartDeliveryTests {
    private struct Fixture: Sendable {
        let agents: AgentsRuntimeStore
        let machines: MachinesAndComputersStore
        let oauth: OAuthLedger
        let channels: ServersAndChannelsStore
        let messages: MessagesAndThreadsStore
        let server: String
        let machine: String
        let agent: String
        let channel: String
        let context: AgentExecutionMachineContext
    }

    private func fixture() -> Fixture {
        let agents = AgentsRuntimeStore()
        let machines = MachinesAndComputersStore()
        let channels = ServersAndChannelsStore()
        let oauth = OAuthLedger()
        let server = "d7-server", machine = "d7-machine"
        oauth.addOwnedServer(id: server, slug: "d7", name: "D7", ownerId: "owner")
        let agent = oauth.createAgent(serverId: server, name: "Cindy", creatorUserId: "owner", runtime: "codex")
        agents.serverAgents = [agent: ServerAgent(id: agent, serverId: server, name: "Cindy", status: "active")]
        agents.agentMachineIds = [agent: machine]
        machines.machines = [MachineRecord(id: machine, serverId: server, userId: "owner", name: "Computer",
                                           description: nil, apiKey: nil)]
        let channel = oauth.createChannel(serverId: server, name: "d7-dm", creatorUserId: "owner")
        channels.addDirectMessage(serverId: server, channelId: channel, participantIds: ["owner", agent], agentId: agent)
        oauth.addChannelAgent(channelId: channel, agentId: agent)
        return Fixture(agents: agents, machines: machines, oauth: oauth, channels: channels,
                       messages: MessagesAndThreadsStore(), server: server, machine: machine, agent: agent,
                       channel: channel,
                       context: AgentExecutionMachineContext(machineId: machine, serverId: server,
                                                             connectionEpochId: "d7-epoch"))
    }

    private func domain(_ f: Fixture) -> AgentExecutionDomain {
        AgentExecutionDomain(agents: f.agents, machines: f.machines, oauth: f.oauth,
                             channels: f.channels, messages: f.messages)
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

    private func ready(_ domain: AgentExecutionDomain, _ f: Fixture,
                       running: [String] = []) async throws {
        try await commit {
            try domain.connectionOpened(f.context)
            try domain.observeReady(f.context, daemonInstanceId: "d7-daemon",
                                    capabilities: ["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"],
                                    runtimes: ["codex"], runningAgentIds: running, detectionComplete: true,
                                    unreliableAgentIds: [])
        }
    }

    /// One canonical human message row the delivery domain may authorize.
    private func message(_ f: Fixture, content: String, seq: Int) -> String {
        let message = f.oauth.createMessageRecord(channelId: f.channel, content: content, senderId: "owner", seq: seq)
        f.messages.withState {
            $0.humanMessageRows.append(StoredHumanMessage(id: message.id, channelId: f.channel,
                                                          senderId: "owner", content: content, seq: seq))
        }
        return message.id
    }

    private func startAck(_ domain: AgentExecutionDomain, _ f: Fixture, launchId: String,
                          startDispatchId: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "agent:start:ack", "agentId": f.agent, "launchId": launchId,
            "startDispatchId": startDispatchId, "queueState": "starting",
            "queueDepth": 0, "queueAgeMs": 0,
        ])
        _ = try await commit { try domain.stageIngress(context: f.context, type: "agent:start:ack", payload: payload) }
    }

    private func processSpawned(_ domain: AgentExecutionDomain, _ f: Fixture, launchId: String,
                                processId: String = "process-1") async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "agent:process_spawned", "agentId": f.agent, "daemonInstanceId": "d7-daemon",
            "clientSeq": 1, "launchId": launchId, "processInstanceId": processId,
        ])
        _ = try await commit { try domain.stageIngress(context: f.context, type: "agent:process_spawned", payload: payload) }
    }

    private func session(_ domain: AgentExecutionDomain, _ f: Fixture, launchId: String,
                         sessionId: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "agent:session", "agentId": f.agent, "launchId": launchId, "sessionId": sessionId,
        ])
        _ = try await commit { try domain.stageIngress(context: f.context, type: "agent:session", payload: payload) }
    }

    /// Queue one human message while the only launch is starting but has not
    /// reported a process: the daemon cannot acknowledge a delivery then (it
    /// buffers it for the start), so the send is durably queued.
    private func queueDuringStart(_ domain: AgentExecutionDomain, _ f: Fixture,
                                  admission: AgentExecutionAdmission, content: String, seq: Int) async throws -> String {
        try await startAck(domain, f, launchId: admission.launchId,
                           startDispatchId: try #require(admission.startDispatchId))
        let id = message(f, content: content, seq: seq)
        let disposition = try await commit {
            try domain.requestHumanMessageDelivery(.init(serverId: f.server, agentId: f.agent,
                                                          channelId: f.channel, messageId: id))
        }
        if case .readableOnly(.launchInProgress) = disposition {} else {
            Issue.record("a launch without a process must keep the send queued, got \(disposition)")
        }
        return id
    }

    private func deliveryCommands(_ f: Fixture, messageId: String) -> [AgentExecutionCommand] {
        f.agents.state.execution.commands.values.filter {
            $0.kind == .delivery && $0.agentId == f.agent && $0.messageId == messageId
        }
    }

    private func starts(_ f: Fixture) -> [AgentExecutionCommand] {
        f.agents.state.execution.commands.values.filter { $0.kind == .start && $0.agentId == f.agent }
    }

    private func writeWrittenStop(_ domain: AgentExecutionDomain, _ f: Fixture,
                                  intent: AgentExecutionResetIntent) async throws {
        _ = try await commit { try domain.beginResetPhase(intent.reference(.stop), context: f.context) }
        try await commit { try domain.noteResetControlWritten(intent.reference(.stop), context: f.context) }
    }

    @Test func keepSessionRestartCarriesTheQueuedMessageAsTheStartWake() async throws {
        let f = fixture()
        let domain = self.domain(f)
        try await ready(domain, f)
        let first = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        let queued = try await queueDuringStart(domain, f, admission: first, content: "Queued across the restart", seq: 43)

        let reset = AgentExecutionResetRequest(serverId: f.server, agentId: f.agent, mode: .restart)
        _ = try await commit { try domain.requestReset(reset) }
        let intent = try #require(f.agents.state.execution.resetIntents?[reset.operationId.uuidString])
        try await writeWrittenStop(domain, f, intent: intent)
        #expect(try await commit { try domain.stageResetRestart(intent.reference(.restart), context: f.context) })

        let restart = try #require(f.agents.state.execution.commands[intent.startCommandId.uuidString])
        #expect(restart.wakeMessage == AgentExecutionWakeMessage(channelId: f.channel, messageId: queued),
                "upstream attempt-wake carries the queued message inside agent:start")
        #expect(deliveryCommands(f, messageId: queued).isEmpty,
                "the carried message is not also sent as a separate agent:deliver")
        let pending = try #require(f.agents.state.execution.pendingHumanDeliveries?.values.first)
        #expect(pending.releasedCommandId == restart.commandId)
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == nil)

        // The daemon acknowledges the restart start: the queued fact is settled
        // by that same frame and the message row stays readable.
        try await startAck(domain, f, launchId: restart.launchId,
                           startDispatchId: try #require(restart.startDispatchId))
        #expect(f.agents.state.execution.pendingHumanDeliveries?.isEmpty ?? true)
        #expect(f.messages.state.humanMessageRows.contains { $0.id == queued },
                "the canonical message row keeps its history after the wake settles")
        try f.agents.state.execution.validate()
    }

    @Test func sessionResetReleasesEachQueuedMessageExactlyOnceAcrossTriggers() async throws {
        let f = fixture()
        let domain = self.domain(f)
        try await ready(domain, f)
        let first = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        let m1 = try await queueDuringStart(domain, f, admission: first, content: "Queued one", seq: 43)
        let m2 = try await queueDuringStart(domain, f, admission: first, content: "Queued two", seq: 44)
        let m3 = try await queueDuringStart(domain, f, admission: first, content: "Queued three", seq: 45)

        let reset = AgentExecutionResetRequest(serverId: f.server, agentId: f.agent, mode: .session)
        _ = try await commit { try domain.requestReset(reset) }
        let intent = try #require(f.agents.state.execution.resetIntents?[reset.operationId.uuidString])
        try await writeWrittenStop(domain, f, intent: intent)
        #expect(f.agents.state.execution.agents[f.agent]?.sessionId == nil,
                "a session reset clears the native session before the restart")
        #expect(try await commit { try domain.stageResetRestart(intent.reference(.restart), context: f.context) })

        let restart = try #require(f.agents.state.execution.commands[intent.startCommandId.uuidString])
        #expect(restart.wakeMessage == AgentExecutionWakeMessage(channelId: f.channel, messageId: m1),
                "the oldest queued message is the start's wake input")
        #expect(f.agents.state.execution.pendingHumanDeliveries?.count == 3)

        // A start ACK for an in-flight launch without a process must not emit a
        // delivery: the official daemon answers such a frame only after the
        // start, and a second copy would be duplicated when both drain.
        try await startAck(domain, f, launchId: restart.launchId,
                           startDispatchId: try #require(restart.startDispatchId))
        for messageId in [m1, m2, m3] { #expect(deliveryCommands(f, messageId: messageId).isEmpty) }

        // The process identity is the delivery-capable fact. Each remaining
        // message is released exactly once.
        try await processSpawned(domain, f, launchId: restart.launchId)
        try await commit { try domain.releasePendingHumanDeliveries(serverId: f.server, agentId: f.agent) }
        for messageId in [m2, m3] {
            let deliveries = deliveryCommands(f, messageId: messageId)
            #expect(deliveries.count == 1)
            #expect(deliveries.first?.launchId == restart.launchId)
        }
        #expect(deliveryCommands(f, messageId: m1).isEmpty)

        // Every later trigger (a replayed process report, the session, a ready
        // release, another explicit reconciliation) stages nothing new.
        try await session(domain, f, launchId: restart.launchId, sessionId: "codex-session-2")
        try await commit { try domain.releasePendingHumanDeliveries(f.context) }
        try await commit { try domain.releasePendingHumanDeliveries(serverId: f.server, agentId: f.agent) }
        for messageId in [m1, m2, m3] {
            #expect(deliveryCommands(f, messageId: messageId).count == (messageId == m1 ? 0 : 1))
        }
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == nil)
        try f.agents.state.execution.validate()
    }

    @Test func unacknowledgedDeliveryWriteIsNotAManualRecoveryGate() async throws {
        let f = fixture()
        let domain = self.domain(f)
        try await ready(domain, f)
        let start = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        try await startAck(domain, f, launchId: start.launchId,
                           startDispatchId: try #require(start.startDispatchId))
        try await processSpawned(domain, f, launchId: start.launchId)
        let messageId = message(f, content: "Delivered to a resident process", seq: 43)
        let admission = try #require(try await commit {
            try domain.requestDelivery(.init(serverId: f.server, agentId: f.agent,
                                             channelId: f.channel, messageId: messageId))
        })
        let grant = try await commit {
            try domain.beginDispatch(reference: .init(commandId: admission.commandId),
                                     context: f.context, deliverySequence: 43)
        }
        #expect(grant == .granted)
        let ambiguous = try await commit {
            try domain.noteAmbiguousDispatch(reference: .init(commandId: admission.commandId), context: f.context)
        }
        #expect(ambiguous == .uncertain)
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == nil,
                "upstream never turns an unacknowledged delivery into manual recovery")
        // A later daemon ACK settles the same attempt; the queued fact clears.
        let ack = try JSONSerialization.data(withJSONObject: [
            "type": "agent:deliver:ack", "agentId": f.agent,
            "deliveryId": try #require(admission.deliveryId), "seq": 43,
        ])
        let result = try await commit { try domain.stageIngress(context: f.context, type: "agent:deliver:ack", payload: ack) }
        #expect(result == .committed(ack: nil))
        #expect(f.agents.state.execution.commands[admission.commandId.uuidString]?.status == .accepted)
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == nil)
    }

    @Test func startDispatchAmbiguityStillRequiresManualRecovery() async throws {
        let f = fixture()
        let domain = self.domain(f)
        try await ready(domain, f)
        let start = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        _ = try await commit {
            try domain.beginDispatch(reference: .init(commandId: start.commandId),
                                     context: f.context, deliverySequence: nil)
        }
        let ambiguous = try await commit {
            try domain.noteAmbiguousDispatch(reference: .init(commandId: start.commandId), context: f.context)
        }
        #expect(ambiguous == .uncertain)
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == "dispatch_outcome_unknown",
                "the launch, not the message, is what became unknown")
    }
}
