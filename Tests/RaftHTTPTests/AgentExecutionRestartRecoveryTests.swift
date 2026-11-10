import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

/// A live idle process is not an unsettled turn. These cases drive the owner's
/// reconnect/restore projections with real retained execution facts; they do
/// not claim a PostgreSQL commit, daemon socket or model execution.
@Suite(.serialized) struct AgentExecutionRestartRecoveryTests {
    private struct Fixture: Sendable {
        let agents: AgentsRuntimeStore
        let machines: MachinesAndComputersStore
        let oauth: OAuthLedger
        let channels: ServersAndChannelsStore
        let messages: MessagesAndThreadsStore
        let server: String
        let machine: String
        let agent: String
    }

    private func fixture() -> Fixture {
        let agents = AgentsRuntimeStore()
        let machines = MachinesAndComputersStore()
        let oauth = OAuthLedger()
        let server = "restart-server"
        let machine = "restart-machine"
        oauth.addOwnedServer(id: server, slug: "restart", name: "Restart", ownerId: "owner")
        let agent = oauth.createAgent(serverId: server, name: "Restart Idle", runtime: "codex")
        agents.agentMachineIds = [agent: machine]
        machines.machines = [MachineRecord(id: machine, serverId: server, userId: "owner", name: "Computer",
                                          description: nil, apiKey: nil)]
        return Fixture(agents: agents, machines: machines, oauth: oauth, channels: ServersAndChannelsStore(),
                       messages: MessagesAndThreadsStore(), server: server, machine: machine, agent: agent)
    }

    private func makeDomain(_ f: Fixture, agents: AgentsRuntimeStore? = nil) -> AgentExecutionDomain {
        AgentExecutionDomain(agents: agents ?? f.agents, machines: f.machines, oauth: f.oauth,
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

    private func frame(_ type: String, agent: String, launch: String? = nil, seq: Int64 = 0,
                       extra: [String: Any] = [:]) throws -> Data {
        var body: [String: Any] = ["type": type, "agentId": agent, "daemonInstanceId": "daemon-1", "clientSeq": seq]
        if let launch { body["launchId"] = launch }
        for (key, value) in extra { body[key] = value }
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    private func startAck(_ domain: AgentExecutionDomain, context: AgentExecutionMachineContext,
                          launchId: String, startDispatchId: String, agent: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "agent:start:ack", "agentId": agent, "launchId": launchId,
            "startDispatchId": startDispatchId, "queueState": "starting",
            "queueDepth": 0, "queueAgeMs": 0,
        ])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:start:ack", payload: payload) }
    }

    /// Start, acknowledge, spawn a long-lived process and complete one turn.
    /// The process intentionally stays alive, which is the upstream daemon's
    /// idle Codex app-server state.
    private func startAndCompleteTurn(_ domain: AgentExecutionDomain, context: AgentExecutionMachineContext,
                                      _ f: Fixture) async throws -> AgentExecutionAdmission {
        let admission = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        try await startAck(domain, context: context, launchId: admission.launchId,
                           startDispatchId: try #require(admission.startDispatchId), agent: f.agent)
        let spawned = try frame("agent:process_spawned", agent: f.agent, launch: admission.launchId,
                                extra: ["processInstanceId": "process-1"])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: spawned) }
        let completed = try JSONSerialization.data(withJSONObject: [
            "type": "agent:runtime:outcome", "v": 1, "agentId": f.agent, "daemonInstanceId": "daemon-1",
            "clientSeq": 1, "launchId": admission.launchId, "sessionId": "codex-session",
            "outcome": ["kind": "turn_completed"],
        ])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: completed) }
        return admission
    }

    private func conversation(_ domain: AgentExecutionDomain, _ f: Fixture, content: String) -> (String, String) {
        let channel = domain.oauth.createChannel(serverId: f.server, name: "dm-\(UUID().uuidString)",
                                                creatorUserId: "owner")
        domain.channels.addDirectMessage(serverId: f.server, channelId: channel,
                                         participantIds: ["owner", f.agent], agentId: f.agent)
        domain.oauth.addChannelAgent(channelId: channel, agentId: f.agent)
        let message = domain.oauth.createMessageRecord(channelId: channel, content: content, senderId: "owner",
                                                       seq: 42)
        domain.messages.withState {
            $0.humanMessageRows.append(StoredHumanMessage(id: message.id, channelId: channel, senderId: "owner",
                                                          content: content, seq: 42))
        }
        return (channel, message.id)
    }

    /// Deliver one human message and let the daemon acknowledge it without a
    /// turn outcome: an in-flight turn whose result the server cannot observe.
    private func startInFlightTurn(_ domain: AgentExecutionDomain, context: AgentExecutionMachineContext,
                                   _ f: Fixture) async throws {
        let (channel, message) = conversation(domain, f, content: "In flight at disconnect")
        let admitted = try #require(try await commit {
            try domain.requestDelivery(.init(serverId: f.server, agentId: f.agent, channelId: channel, messageId: message))
        })
        let launch = try #require(f.agents.state.execution.agents[f.agent]?.launches[admitted.launchId])
        try await startAck(domain, context: context, launchId: launch.launchId,
                           startDispatchId: launch.startDispatchId, agent: f.agent)
        try await commit {
            let grant = try domain.beginDispatch(reference: .init(commandId: admitted.commandId),
                                                 context: context, deliverySequence: 42)
            #expect(grant == .granted)
        }
        let deliveryId = try #require(admitted.deliveryId)
        let ack = try JSONSerialization.data(withJSONObject: [
            "type": "agent:deliver:ack", "agentId": f.agent, "deliveryId": deliveryId, "seq": 42,
        ])
        let result = try await commit {
            try domain.stageIngress(context: context, type: "agent:deliver:ack", payload: ack)
        }
        #expect(result == .committed(ack: nil))
        #expect(f.agents.state.execution.agents[f.agent]?.launches[launch.launchId]?.completed == false)
    }

    @Test func idleLiveProcessWithCompletedTurnIsSettledWhenTheConnectionCloses() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let admission = try await startAndCompleteTurn(domain, context: context, f)
        #expect(f.agents.state.execution.agents[f.agent]?.launches[admission.launchId]?.completed == true)
        #expect(f.agents.state.execution.agents[f.agent]?.processes["process-1"]?.exited == false)

        try await commit { try domain.connectionClosed(context) }

        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == nil,
                "a live process between turns is not an unsettled execution")
        #expect(f.agents.state.execution.connections[f.machine]?.online == false)
    }

    @Test func inFlightTurnAtDisconnectStillRequiresRecovery() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        _ = try await startAndCompleteTurn(domain, context: context, f)
        // A second launch accepts a delivery but never reports turn_completed.
        try await startInFlightTurn(domain, context: context, f)

        try await commit { try domain.connectionClosed(context) }
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")

        // Reconnecting with the same daemon does not erase genuine ambiguity.
        let reconnected = try await open(domain, f, epoch: "connection-2", running: [f.agent])
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")
        let (channel, message) = conversation(domain, f, content: "Must stay readable only")
        let disposition = try await commit {
            try domain.requestHumanMessageDelivery(.init(serverId: f.server, agentId: f.agent,
                                                         channelId: channel, messageId: message))
        }
        if case .readableOnly(.recoveryRequired) = disposition {} else {
            Issue.record("an in-flight turn must keep the recovery gate, got \(disposition)")
        }
        #expect(f.agents.state.execution.connections[f.machine]?.connectionEpochId == reconnected.connectionEpochId)
    }

    @Test func alreadyPersistedConnectionLostFlagIsReconciledOnReady() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        _ = try await startAndCompleteTurn(domain, context: context, f)
        // The deployed production row: the flag is persisted while the completed
        // turn, the live process and the daemon identity remain real facts.
        f.agents.withState { $0.execution.agents[f.agent]?.needsManual = "connection_lost_with_unsettled_execution" }
        let restoredAgents = AgentsRuntimeStore()
        try restoredAgents.restorePersistenceData(f.agents.exportPersistenceData())
        #expect(restoredAgents.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")
        let restored = makeDomain(f, agents: restoredAgents)

        _ = try await open(restored, f, epoch: "connection-2", running: [f.agent])

        #expect(restoredAgents.state.execution.agents[f.agent]?.needsManual == nil,
                "ready with the same live process and no unsettled delivery/turn clears a connection-derived flag")
        #expect(restoredAgents.state.execution.connections[f.machine]?.ready == true)
        let (channel, message) = conversation(restored, f, content: "Deliverable after reconnect")
        let disposition = try await commit {
            try restored.requestHumanMessageDelivery(.init(serverId: f.server, agentId: f.agent,
                                                           channelId: channel, messageId: message))
        }
        if case .staged = disposition {} else {
            Issue.record("a reconciled running agent must accept a new delivery, got \(disposition)")
        }
    }

    @Test func preFlaggedIdleProcessWithoutAnyTurnIsReconciledAndPendingDeliveryIsRearmed() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        // A process exists and its start was admitted, but no turn ever started.
        let admission = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        try await startAck(domain, context: context, launchId: admission.launchId,
                           startDispatchId: try #require(admission.startDispatchId), agent: f.agent)
        let spawned = try frame("agent:process_spawned", agent: f.agent, launch: admission.launchId,
                                extra: ["processInstanceId": "process-1"])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: spawned) }
        // A message staged while connected, with no dispatch attempt. The
        // producer never wrote it, so upstream retries it after reconnect.
        let (channel, message) = conversation(domain, f, content: "Pending before reconnect")
        let pending = try #require(try await commit {
            try domain.requestDelivery(.init(serverId: f.server, agentId: f.agent, channelId: channel, messageId: message))
        })
        f.agents.withState { $0.execution.agents[f.agent]?.needsManual = "connection_lost_with_unsettled_execution" }

        let restoredAgents = AgentsRuntimeStore()
        try restoredAgents.restorePersistenceData(f.agents.exportPersistenceData())
        let restored = makeDomain(f, agents: restoredAgents)
        _ = try await open(restored, f, epoch: "connection-2", running: [f.agent])

        #expect(restoredAgents.state.execution.agents[f.agent]?.needsManual == nil)
        #expect(restoredAgents.state.execution.commands[pending.commandId.uuidString]?.connectionEpochId == "connection-2")
        let resolution = restored.resolveDispatch(reference: .init(commandId: pending.commandId))
        if case .ready = resolution {} else {
            Issue.record("a provably unsent pending delivery must become dispatchable on the new epoch, got \(resolution)")
        }
    }

    @Test func readyReconcileDoesNotClearUnrelatedRecoveryReasons() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let admission = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        try await startAck(domain, context: context, launchId: admission.launchId,
                           startDispatchId: try #require(admission.startDispatchId), agent: f.agent)
        let spawned = try frame("agent:process_spawned", agent: f.agent, launch: admission.launchId,
                                extra: ["processInstanceId": "process-1"])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: spawned) }
        f.agents.withState {
            $0.execution.agents[f.agent]?.launches[admission.launchId]?.completed = true
            $0.execution.agents[f.agent]?.needsManual = "daemon_outcome_storage_unreliable"
        }
        _ = try await open(domain, f, epoch: "connection-2", running: [f.agent])
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == "daemon_outcome_storage_unreliable",
                "only connection-derived recovery reasons are reconciled")
    }

    @Test func restoringAnIdleLiveProcessDoesNotFenceServerRestart() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        _ = try await startAndCompleteTurn(domain, context: context, f)

        let restored = AgentsRuntimeStore()
        try restored.restorePersistenceData(f.agents.exportPersistenceData())

        #expect(restored.state.execution.connections[f.machine]?.online == false)
        #expect(restored.state.execution.connections[f.machine]?.ready == false)
        #expect(restored.state.execution.agents[f.agent]?.needsManual == nil,
                "a completed turn with a live process is not an unsettled server-restart fence")
    }

    @Test func restoringAFlaggedInFlightTurnKeepsServerRestartRecovery() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        _ = try await startAndCompleteTurn(domain, context: context, f)
        try await startInFlightTurn(domain, context: context, f)
        f.agents.withState { $0.execution.agents[f.agent]?.needsManual = nil }

        let restored = AgentsRuntimeStore()
        try restored.restorePersistenceData(f.agents.exportPersistenceData())

        #expect(restored.state.execution.agents[f.agent]?.needsManual == "server_restarted_with_unsettled_execution")
        let restoredDomain = makeDomain(f, agents: restored)
        _ = try await open(restoredDomain, f, epoch: "connection-2", running: [f.agent])
        #expect(restored.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution",
                "an accepted delivery without turn_completed stays ambiguous after ready")
    }
}
