import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

/// Upstream parity for a persistent runtime (`codex app-server`): an idle
/// process that carried a completed turn is still the agent's live runtime, so
/// the next human message is delivered to it without a new launch. These cases
/// drive the retained owner facts directly; they do not claim a PostgreSQL
/// commit, a daemon socket or a model turn.
@Suite(.serialized) struct HumanMessageResidentDeliveryTests {
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
    }

    private func fixture() -> Fixture {
        let agents = AgentsRuntimeStore()
        let machines = MachinesAndComputersStore()
        let oauth = OAuthLedger()
        let channels = ServersAndChannelsStore()
        let messages = MessagesAndThreadsStore()
        let server = "resident-server"
        let machine = "resident-machine"
        oauth.addOwnedServer(id: server, slug: "resident", name: "Resident", ownerId: "owner")
        let agent = oauth.createAgent(serverId: server, name: "Resident Cindy", runtime: "codex")
        agents.agentMachineIds = [agent: machine]
        machines.machines = [MachineRecord(id: machine, serverId: server, userId: "owner", name: "Computer",
                                          description: nil, apiKey: nil)]
        let channel = oauth.createChannel(serverId: server, name: "dm-resident", creatorUserId: "owner")
        channels.addDirectMessage(serverId: server, channelId: channel, participantIds: ["owner", agent], agentId: agent)
        oauth.addChannelAgent(channelId: channel, agentId: agent)
        return Fixture(agents: agents, machines: machines, oauth: oauth, channels: channels, messages: messages,
                       server: server, machine: machine, agent: agent, channel: channel)
    }

    private func makeDomain(_ f: Fixture) -> AgentExecutionDomain {
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

    private func capabilities() -> [String] {
        ["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"]
    }

    private func open(_ domain: AgentExecutionDomain, _ f: Fixture, epoch: String = "connection-1",
                      daemon: String = "daemon-1", running: [String] = []) async throws -> AgentExecutionMachineContext {
        let context = AgentExecutionMachineContext(machineId: f.machine, serverId: f.server, connectionEpochId: epoch)
        try await commit {
            try domain.connectionOpened(context)
            try domain.observeReady(context, daemonInstanceId: daemon, capabilities: capabilities(),
                                    runtimes: ["codex"], runningAgentIds: running, detectionComplete: true,
                                    unreliableAgentIds: [])
        }
        return context
    }

    private func frame(_ type: String, agent: String, launch: String? = nil, seq: Int64,
                       extra: [String: Any] = [:]) throws -> Data {
        var body: [String: Any] = ["type": type, "agentId": agent, "daemonInstanceId": "daemon-1", "clientSeq": seq]
        if let launch { body["launchId"] = launch }
        for (key, value) in extra { body[key] = value }
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    private func startAck(_ domain: AgentExecutionDomain, context: AgentExecutionMachineContext,
                          launchId: String, startDispatchId: String, agent: String,
                          queueState: String = "running", processInstanceId: String? = nil) async throws {
        var body: [String: Any] = [
            "type": "agent:start:ack", "agentId": agent, "launchId": launchId,
            "startDispatchId": startDispatchId, "queueState": queueState,
            "queueDepth": 0, "queueAgeMs": 0,
        ]
        if let processInstanceId { body["processInstanceId"] = processInstanceId }
        let payload = try JSONSerialization.data(withJSONObject: body)
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:start:ack", payload: payload) }
    }

    /// Start, acknowledge and complete one turn. `rebound` models the official
    /// Computer's start onto an already resident `codex app-server` (the ack
    /// carries `queueState: running` and the process identity); `spawned`
    /// models a process the daemon created for this launch.
    private func startAndCompleteTurn(_ domain: AgentExecutionDomain, context: AgentExecutionMachineContext,
                                      _ f: Fixture, processIdentity: String = "ack") async throws -> AgentExecutionAdmission {
        let admission = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        let startDispatchId = try #require(admission.startDispatchId)
        if processIdentity == "ack" {
            try await startAck(domain, context: context, launchId: admission.launchId,
                               startDispatchId: startDispatchId, agent: f.agent,
                               queueState: "running", processInstanceId: "process-1")
        } else {
            try await startAck(domain, context: context, launchId: admission.launchId,
                               startDispatchId: startDispatchId, agent: f.agent, queueState: "starting")
            let spawned = try frame("agent:process_spawned", agent: f.agent, launch: admission.launchId,
                                    seq: 1, extra: ["processInstanceId": "process-1"])
            _ = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: spawned) }
        }
        let completed = try JSONSerialization.data(withJSONObject: [
            "type": "agent:runtime:outcome", "v": 1, "agentId": f.agent, "daemonInstanceId": "daemon-1",
            "clientSeq": 2, "launchId": admission.launchId, "sessionId": "codex-session",
            "outcome": ["kind": "turn_completed"],
        ])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: completed) }
        return admission
    }

    private func addMessage(_ f: Fixture, content: String, seq: Int) -> String {
        let message = f.oauth.createMessageRecord(channelId: f.channel, content: content, senderId: "owner", seq: seq)
        f.messages.withState {
            $0.humanMessageRows.append(StoredHumanMessage(id: message.id, channelId: f.channel, senderId: "owner",
                                                          content: content, seq: seq))
        }
        return message.id
    }

    private func deliveryDisposition(_ domain: AgentExecutionDomain, _ f: Fixture, message: String) async throws
        -> HumanMessageExecutionDisposition {
        try await commit {
            try domain.requestHumanMessageDelivery(.init(serverId: f.server, agentId: f.agent,
                                                         channelId: f.channel, messageId: message))
        }
    }

    private func startCommands(_ domain: AgentExecutionDomain, _ f: Fixture) -> [AgentExecutionCommand] {
        domain.agents.state.execution.commands.values.filter { $0.kind == .start && $0.agentId == f.agent }
    }

    private func deliveryCommands(_ domain: AgentExecutionDomain, _ f: Fixture, message: String) -> [AgentExecutionCommand] {
        domain.agents.state.execution.commands.values.filter {
            $0.kind == .delivery && $0.agentId == f.agent && $0.messageId == message
        }
    }

    @Test func idleResidentProcessAcceptsConsecutiveHumanDeliveriesWithoutANewLaunch() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let first = try await startAndCompleteTurn(domain, context: context, f)
        let launch = try #require(f.agents.state.execution.agents[f.agent]?.launches[first.launchId])
        #expect(launch.completed)
        #expect(launch.processInstanceId == "process-1", "the start ack's rebound identity is the live process")

        let second = addMessage(f, content: "Second DM after the first turn", seq: 43)
        let disposition = try await deliveryDisposition(domain, f, message: second)
        guard case .staged(let admission) = disposition else {
            Issue.record("an idle live runtime must accept the next human message, got \(disposition)")
            return
        }
        #expect(admission.launchId == first.launchId, "the live resident process carries the existing launch")
        #expect(startCommands(domain, f).count == 1, "upstream sends agent:deliver, never a second start")
        #expect(deliveryCommands(domain, f, message: second).count == 1)
        #expect(f.agents.state.execution.agents[f.agent]?.launches.count == 1)

        // A third message in the same idle state behaves the same way.
        let third = addMessage(f, content: "Third DM", seq: 44)
        let again = try await deliveryDisposition(domain, f, message: third)
        guard case .staged = again else {
            Issue.record("consecutive idle messages must keep staging deliveries, got \(again)")
            return
        }
        #expect(startCommands(domain, f).count == 1)
    }

    @Test func humanMessageDuringAnInFlightTurnIsStagedOnTheSameLaunch() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let admission = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        try await startAck(domain, context: context, launchId: admission.launchId,
                           startDispatchId: try #require(admission.startDispatchId), agent: f.agent,
                           queueState: "running", processInstanceId: "process-1")
        let busy = addMessage(f, content: "Sent while the first turn is still running", seq: 43)
        let disposition = try await deliveryDisposition(domain, f, message: busy)
        guard case .staged(let staged) = disposition else {
            Issue.record("a busy agent accepts the delivery; the daemon queues it, got \(disposition)")
            return
        }
        #expect(staged.launchId == admission.launchId)
        #expect(startCommands(domain, f).count == 1, "a busy resident runtime is not started again")
    }

    @Test func completedTurnDoesNotForceAColdStartForLaterMessages() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        // The daemon spawned a process for the launch and reported it separately.
        _ = try await startAndCompleteTurn(domain, context: context, f, processIdentity: "spawned")
        let message = addMessage(f, content: "After a spawned process completed its turn", seq: 43)
        let disposition = try await deliveryDisposition(domain, f, message: message)
        guard case .staged = disposition else {
            Issue.record("a live spawned process is deliverable after its turn, got \(disposition)")
            return
        }
        #expect(startCommands(domain, f).count == 1)
    }

    @Test func liveResidentProcessCarriesTheDeliveryAfterAConfigurationLift() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let first = try await startAndCompleteTurn(domain, context: context, f)
        // A runtime configuration change lifts the current launch but asserts no
        // process exit (upstream `applyTerminalLift`). The daemon still runs the
        // process, so the next human message must not cold-start or wedge.
        try await commit {
            try domain.liftTerminalForConfigChange(serverId: f.server, agentId: f.agent, runtimeValuesChanged: true)
        }
        #expect(f.agents.state.execution.agents[f.agent]?.currentLaunchId == nil)
        let message = addMessage(f, content: "After a config lift", seq: 43)
        let disposition = try await deliveryDisposition(domain, f, message: message)
        guard case .staged(let admitted) = disposition else {
            Issue.record("a lifted configuration keeps the live runtime deliverable, got \(disposition)")
            return
        }
        #expect(admitted.launchId == first.launchId,
                "the live process still carries the launch the daemon reports")
        #expect(startCommands(domain, f).count == 1)
        // The delivery materializes against that older-generation launch: the
        // lift is server bookkeeping, not a new daemon identity.
        let command = try #require(f.agents.state.execution.commands[admitted.commandId.uuidString])
        let materializer = AgentExecutionMaterializationService(
            transactionAgents: f.agents, machines: f.machines, oauth: f.oauth, channels: f.channels,
            messages: f.messages, profiles: AuthProfileStore(), tasks: TasksAndRemindersStore(),
            serverURL: "https://resident.invalid")
        try await commit {
            guard case .delivery = try materializer.materializeInTransaction(command: command) else {
                Issue.record("a delivery after a configuration lift must materialize")
                return
            }
        }
    }

    @Test func queuedWakeIsReleasedOnceWhenTheStartIdentitySettles() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        // A start the daemon accepted but has not yet attributed to a process,
        // whose turn then completed: the launch is settled but the daemon's
        // process identity is still missing, so no automatic wake may be
        // admitted. Upstream keeps the message in the durable inbox.
        let admission = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        try await startAck(domain, context: context, launchId: admission.launchId,
                           startDispatchId: try #require(admission.startDispatchId), agent: f.agent,
                           queueState: "starting")
        let completed = try JSONSerialization.data(withJSONObject: [
            "type": "agent:runtime:outcome", "v": 1, "agentId": f.agent, "daemonInstanceId": "daemon-1",
            "clientSeq": 2, "launchId": admission.launchId, "sessionId": "codex-session",
            "outcome": ["kind": "turn_completed"],
        ])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: completed) }
        let queuedMessage = addMessage(f, content: "Queued while the start is unattributed", seq: 43)
        let disposition = try await deliveryDisposition(domain, f, message: queuedMessage)
        guard case .readableOnly(.launchInProgress) = disposition else {
            Issue.record("expected the launch-in-progress refusal, got \(disposition)")
            return
        }
        #expect(f.agents.state.execution.pendingHumanDeliveries?.count == 1)
        // The daemon reports the process that carries the launch (the same fact
        // a rebound start ack or `agent:process_spawned` supplies).
        let spawned = try frame("agent:process_spawned", agent: f.agent, launch: admission.launchId,
                                seq: 3, extra: ["processInstanceId": "process-1"])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: spawned) }
        try await commit { try domain.releasePendingHumanDeliveries(serverId: f.server, agentId: f.agent) }
        let deliveries = deliveryCommands(domain, f, message: queuedMessage)
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.status == .pending)
        let pending = try #require(f.agents.state.execution.pendingHumanDeliveries?.values.first)
        #expect(pending.releasedCommandId == deliveries.first?.commandId)
        #expect(startCommands(domain, f).count == 1)
        // A second settle signal with the same pending fact stages nothing new.
        try await commit { try domain.releasePendingHumanDeliveries(serverId: f.server, agentId: f.agent) }
        #expect(deliveryCommands(domain, f, message: queuedMessage).count == 1)
    }

    @Test func idleResidentProcessStillAcceptsATransientNotice() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        _ = try await startAndCompleteTurn(domain, context: context, f)
        let receipt = try await commit {
            try domain.requestNotice(.init(serverId: f.server, agentId: f.agent, channelId: f.channel,
                                           channelName: "dm", channelType: "dm", content: "owner facts",
                                           messageId: "owner-facts-1", timestamp: "2026-01-02T03:04:05.678Z"))
        }
        guard case .accepted = receipt else {
            Issue.record("a resident runtime accepts a transient notice between turns, got \(receipt)")
            return
        }
    }

    @Test func repeatedLaunchInProgressRefusalNeverDropsAHumanMessage() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        // A start accepted with `queueState: starting` whose process identity was
        // never reported is real in-flight evidence: no new start may be admitted
        // until it resolves. Upstream keeps the message in the durable inbox
        // instead of dropping the wake.
        let admission = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        try await startAck(domain, context: context, launchId: admission.launchId,
                           startDispatchId: try #require(admission.startDispatchId), agent: f.agent,
                           queueState: "starting")
        let completed = try JSONSerialization.data(withJSONObject: [
            "type": "agent:runtime:outcome", "v": 1, "agentId": f.agent, "daemonInstanceId": "daemon-1",
            "clientSeq": 2, "launchId": admission.launchId, "sessionId": "codex-session",
            "outcome": ["kind": "turn_completed"],
        ])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: completed) }
        let message = addMessage(f, content: "Queued while the launch is unresolved", seq: 43)
        let disposition = try await deliveryDisposition(domain, f, message: message)
        guard case .readableOnly(.launchInProgress) = disposition else {
            Issue.record("expected the launch-in-progress refusal, got \(disposition)")
            return
        }
        let pending = f.agents.state.execution.pendingHumanDeliveries ?? [:]
        #expect(pending.values.contains { $0.agentId == f.agent && $0.messageId == message },
                "a refused wake is durably queued, never silently readable-only")
    }
}
