import Foundation
import RaftShared
import Synchronization
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
                          launchId: String, startDispatchId: String, agent: String,
                          queueState: String = "starting", processInstanceId: String? = nil) async throws {
        var body: [String: Any] = [
            "type": "agent:start:ack", "agentId": agent, "launchId": launchId,
            "startDispatchId": startDispatchId, "queueState": queueState,
            "queueDepth": 0, "queueAgeMs": 0,
        ]
        if let processInstanceId { body["processInstanceId"] = processInstanceId }
        let payload = try JSONSerialization.data(withJSONObject: body)
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

    /// Deliver one human message to the resident launch and let the daemon
    /// acknowledge it without a turn outcome: an in-flight turn whose result the
    /// server cannot observe. Upstream sends no second start for a running
    /// process, so the acknowledged delivery itself is the in-flight fact.
    private func startInFlightTurn(_ domain: AgentExecutionDomain, context: AgentExecutionMachineContext,
                                   _ f: Fixture) async throws {
        let (channel, message) = conversation(domain, f, content: "In flight at disconnect")
        let admitted = try #require(try await commit {
            try domain.requestDelivery(.init(serverId: f.server, agentId: f.agent, channelId: channel, messageId: message))
        })
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
        let launch = try #require(f.agents.state.execution.agents[f.agent]?.launches[admitted.launchId])
        #expect(launch.inFlightDeliveryCommandIds?.contains(admitted.commandId) == true)
        #expect(f.agents.state.execution.agents[f.agent]?.hasUnsettledExecution == true)
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

    /// The deployed production shape: a completed turn whose process stays
    /// resident, then a later start staged on that same connection that never
    /// reached the daemon (the outbox consumer stopped before dispatch). Main
    /// restarts. The same daemon instance reconnects, reports the agent running
    /// and carries the earlier admitted launch, while the current launch is the
    /// never-admitted start. Recovery must adopt the launch the process carries
    /// and retire the unsent start; otherwise the agent stays in manual recovery
    /// and every transient notice (owner facts and the opener ledger) is dropped
    /// even though the runtime is demonstrably alive.
    @Test func staleUnadmittedStartAfterMainRestartAdoptsTheResidentLaunchForNotices() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let first = try await startAndCompleteTurn(domain, context: context, f)
        // Staged after the turn completed, but no beginDispatch/wire write ever
        // happened: the production start command that stayed pending.
        let staged = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        #expect(staged.launchId != first.launchId)
        #expect(f.agents.state.execution.agents[f.agent]?.currentLaunchId == staged.launchId)
        #expect(f.agents.state.execution.dispatches?[staged.commandId.uuidString] == nil)

        try await commit { try domain.connectionClosed(context) }
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")

        let restoredAgents = AgentsRuntimeStore()
        try restoredAgents.restorePersistenceData(f.agents.exportPersistenceData())
        let restored = makeDomain(f, agents: restoredAgents)
        _ = try await open(restored, f, epoch: "connection-2", running: [f.agent])

        let agent = try #require(restoredAgents.state.execution.agents[f.agent])
        #expect(agent.needsManual == nil,
                "a ready-reported resident process clears the connection-loss fence")
        #expect(agent.currentLaunchId == first.launchId,
                "the launch the live process carries becomes current again")
        #expect(agent.launches[staged.launchId]?.notSpawned == true,
                "a start that never reached the daemon is retired, not a live launch")
        #expect(restoredAgents.state.execution.commands[staged.commandId.uuidString]?.status == .superseded)

        let receipt = try await commit {
            try restored.requestNotice(.init(
                serverId: f.server, agentId: f.agent,
                channelId: "onboarding-context", channelName: "onboarding-context", channelType: "channel",
                content: "owner facts", messageId: "onboarding-owner-facts-\(f.server)",
                timestamp: "2026-11-11T00:46:48Z"))
        }
        guard case .accepted(let commandId) = receipt else {
            Issue.record("a ready-reported resident process must admit the owner notice, got \(receipt)")
            return
        }
        let command = try #require(restoredAgents.state.execution.commands[commandId.uuidString])
        #expect(command.kind == .notice)
        #expect(command.launchId == first.launchId,
                "the notice names the daemon-admitted launch, not the retired start")
    }

    /// A human takeover (the operator's Start) increments the agent's takeover
    /// epoch and thereby acknowledges every older launch, the same rule
    /// `hasBlockingUnexitedExecution` already applies. An accepted delivery left
    /// on the previous epoch can never complete after the takeover, so it must
    /// not keep the agent in recovery or block the owner notices.
    @Test func humanTakeoverRetiresPriorEpochInFlightEvidence() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        _ = try await startAndCompleteTurn(domain, context: context, f)
        try await startInFlightTurn(domain, context: context, f)
        #expect(f.agents.state.execution.agents[f.agent]?.hasUnsettledExecution == true)

        let takeover = try await commit {
            try domain.requestStart(.init(serverId: f.server, agentId: f.agent, control: .humanStart))
        }
        try await startAck(domain, context: context, launchId: takeover.launchId,
                           startDispatchId: try #require(takeover.startDispatchId), agent: f.agent)
        let spawned = try frame("agent:process_spawned", agent: f.agent, launch: takeover.launchId, seq: 2,
                                extra: ["processInstanceId": "process-2"])
        _ = try await commit {
            try domain.stageIngress(context: context, type: "agent:process_spawned", payload: spawned)
        }
        let completed = try frame("agent:runtime:outcome", agent: f.agent, launch: takeover.launchId, seq: 3,
                                  extra: ["v": 1, "sessionId": "codex-session-2",
                                          "outcome": ["kind": "turn_completed"]])
        _ = try await commit {
            try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: completed)
        }
        #expect(f.agents.state.execution.agents[f.agent]?.takeoverEpoch == 1)
        #expect(f.agents.state.execution.agents[f.agent]?.hasUnsettledExecution == false,
                "the previous epoch's in-flight delivery is acknowledged by the takeover")

        try await commit { try domain.connectionClosed(context) }
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == nil,
                "an acknowledged older epoch is not an unsettled execution")
        let restoredAgents = AgentsRuntimeStore()
        try restoredAgents.restorePersistenceData(f.agents.exportPersistenceData())
        #expect(restoredAgents.state.execution.agents[f.agent]?.needsManual == nil)
        let restored = makeDomain(f, agents: restoredAgents)
        _ = try await open(restored, f, epoch: "connection-2", running: [f.agent])

        let receipt = try await commit {
            try restored.requestNotice(.init(
                serverId: f.server, agentId: f.agent,
                channelId: "onboarding-context", channelName: "onboarding-context", channelType: "channel",
                content: "owner facts", messageId: "onboarding-owner-facts-\(f.server)",
                timestamp: "2026-11-11T00:46:48Z"))
        }
        guard case .accepted(let commandId) = receipt else {
            Issue.record("a human-takeover agent must admit the owner notice, got \(receipt)")
            return
        }
        #expect(restoredAgents.state.execution.commands[commandId.uuidString]?.launchId == takeover.launchId)
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

    /// Three completed turns on one long-lived resident process, then the old
    /// bug's refused start left current: the daemon never acknowledged it and
    /// never reported a process for it. This is the deployed production shape.
    private func residentProcessWithCompletedLaunches(
        _ domain: AgentExecutionDomain, context: AgentExecutionMachineContext, _ f: Fixture
    ) async throws -> [AgentExecutionAdmission] {
        var admissions: [AgentExecutionAdmission] = []
        for index in 0..<3 {
            let admission = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
            try await startAck(domain, context: context, launchId: admission.launchId,
                               startDispatchId: try #require(admission.startDispatchId), agent: f.agent,
                               queueState: "running", processInstanceId: "process-1")
            let completed = try JSONSerialization.data(withJSONObject: [
                "type": "agent:runtime:outcome", "v": 1, "agentId": f.agent, "daemonInstanceId": "daemon-1",
                "clientSeq": index + 1, "launchId": admission.launchId, "sessionId": "codex-session",
                "outcome": ["kind": "turn_completed"],
            ])
            _ = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: completed) }
            admissions.append(admission)
        }
        return admissions
    }

    @Test func abandonedStartOnALiveResidentProcessIsRetiredOnReadyAndReleasesTheQueuedDm() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let completed = try await residentProcessWithCompletedLaunches(domain, context: context, f)
        let resident = try #require(completed.last)
        #expect(f.agents.state.execution.agents[f.agent]?.processes["process-1"]?.launchIds.count == 3)

        // The old bug: an automatic start is staged and becomes current, but the
        // daemon neither admits it nor reports a process for it.
        let abandoned = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        let abandonedLaunch = try #require(f.agents.state.execution.agents[f.agent]?.launches[abandoned.launchId])
        #expect(!abandonedLaunch.startAccepted)
        #expect(abandonedLaunch.processInstanceId == nil)
        #expect(f.agents.state.execution.agents[f.agent]?.currentLaunchId == abandoned.launchId)
        // The old start was written once and never acknowledged: the dispatch
        // row is real history, so the repair must not pretend it never happened.
        let grant = try await commit {
            try domain.beginDispatch(reference: .init(commandId: abandoned.commandId),
                                     context: context, deliverySequence: nil)
        }
        #expect(grant == .granted)
        let startsBefore = f.agents.state.execution.commands.values.filter {
            $0.kind == .start && $0.agentId == f.agent
        }.count

        // The socket drops. The never-admitted launch counts as unsettled, so
        // the connection history blocks every send. A DM is queued, not lost.
        try await commit { try domain.connectionClosed(context) }
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")
        let (channel, message) = conversation(domain, f, content: "Queued while the stale flag held the send")
        let queued = try await commit {
            try domain.requestHumanMessageDelivery(.init(serverId: f.server, agentId: f.agent,
                                                         channelId: channel, messageId: message))
        }
        if case .readableOnly = queued {} else {
            Issue.record("the stale flag must keep the DM readable-only, got \(queued)")
        }
        #expect(f.agents.state.execution.pendingHumanDeliveries?.count == 1)

        // The same daemon returns ready reporting the agent running on its
        // tracked process: the abandoned start is provably not that process.
        let reconnected = try await open(domain, f, epoch: "connection-2", running: [f.agent])
        try await commit { try domain.releasePendingHumanDeliveries(reconnected) }

        let agent = try #require(f.agents.state.execution.agents[f.agent])
        #expect(agent.needsManual == nil,
                "a complete ready on the live process clears the connection-derived flag")
        #expect(agent.currentLaunchId == resident.launchId,
                "the resident process's latest launch is adopted as current")
        #expect(agent.launches[abandoned.launchId]?.notSpawned == true,
                "the never-admitted start is retired instead of waiting for an ACK that will never come")
        #expect(agent.launches[abandoned.launchId]?.processInstanceId == nil)
        let deliveries = f.agents.state.execution.commands.values.filter {
            $0.kind == .delivery && $0.agentId == f.agent && $0.messageId == message
        }
        #expect(deliveries.count == 1, "the pending DM is released exactly once")
        #expect(deliveries.first?.launchId == resident.launchId)
        #expect(f.agents.state.execution.commands.values.filter {
            $0.kind == .start && $0.agentId == f.agent
        }.count == startsBefore, "the resident process receives agent:deliver; no new agent:start")
        #expect(f.agents.state.execution.dispatches?[abandoned.commandId.uuidString] != nil,
                "the unacknowledged start's dispatch history is preserved, not erased")
        if case .obsolete = domain.resolveDispatch(reference: .init(commandId: abandoned.commandId)) {} else {
            Issue.record("a start whose launch was retired can never be redispatched")
        }

        // A replay of the same ready/release stages nothing new.
        try await commit { try domain.releasePendingHumanDeliveries(reconnected) }
        #expect(f.agents.state.execution.commands.values.filter {
            $0.kind == .delivery && $0.agentId == f.agent && $0.messageId == message
        }.count == 1)
    }

    @Test func agentSessionRepairsTheAbandonedStartWhenReadyDidNotReportRunning() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let completed = try await residentProcessWithCompletedLaunches(domain, context: context, f)
        let resident = try #require(completed.last)
        let abandoned = try await commit { try domain.requestStart(.init(serverId: f.server, agentId: f.agent)) }
        try await commit { try domain.connectionClosed(context) }
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")
        let (channel, message) = conversation(domain, f, content: "Queued behind the abandoned start")
        _ = try await commit {
            try domain.requestHumanMessageDelivery(.init(serverId: f.server, agentId: f.agent,
                                                         channelId: channel, messageId: message))
        }

        // The ready frame itself did not list the agent as running, so the
        // ready reconcile has no report to act on. The daemon's session for the
        // launch its resident process carries is that same fact.
        let reconnected = try await open(domain, f, epoch: "connection-2", running: [])
        #expect(f.agents.state.execution.agents[f.agent]?.needsManual == "connection_lost_with_unsettled_execution")
        #expect(f.agents.state.execution.agents[f.agent]?.currentLaunchId == abandoned.launchId)
        let session = try JSONSerialization.data(withJSONObject: [
            "type": "agent:session", "agentId": f.agent, "launchId": resident.launchId,
            "sessionId": "codex-session-2",
        ])
        let result = try await commit {
            try domain.stageIngress(context: reconnected, type: "agent:session", payload: session)
        }
        #expect(result == .committed(ack: nil))

        let agent = try #require(f.agents.state.execution.agents[f.agent])
        #expect(agent.needsManual == nil)
        #expect(agent.currentLaunchId == resident.launchId)
        #expect(agent.sessionId == "codex-session-2")
        #expect(agent.launches[abandoned.launchId]?.notSpawned == true)

        // The service releases the queued DM in the committed step after the
        // session; it is delivered on the resident launch without a new start.
        let startsBefore = f.agents.state.execution.commands.values.filter {
            $0.kind == .start && $0.agentId == f.agent
        }.count
        try await commit { try domain.releasePendingHumanDeliveries(serverId: f.server, agentId: f.agent) }
        let deliveries = f.agents.state.execution.commands.values.filter {
            $0.kind == .delivery && $0.agentId == f.agent && $0.messageId == message
        }
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.launchId == resident.launchId)
        #expect(f.agents.state.execution.commands.values.filter {
            $0.kind == .start && $0.agentId == f.agent
        }.count == startsBefore)
    }

    @Test func terminalBreakerReasonSurvivesReadyAndKeepsTheQueuedDmPending() async throws {
        let f = fixture()
        let domain = makeDomain(f)
        let context = try await open(domain, f)
        let completed = try await residentProcessWithCompletedLaunches(domain, context: context, f)
        let resident = try #require(completed.last)
        // A critical lost marker: a terminal-breaker/manual reason, never a
        // connection-derived one.
        f.agents.withState { $0.execution.agents[f.agent]?.needsManual = "outcome_evidence_lost" }
        let (channel, message) = conversation(domain, f, content: "Manual recovery must keep this queued")
        let frames = Mutex<[(room: String, event: String, payload: String)]>([])
        RealtimeRelayService(messages: f.messages).install { room, event, payload in
            frames.withLock { $0.append((room, event, payload ?? "")) }
        }
        let queued = try await commit {
            try domain.requestHumanMessageDelivery(.init(serverId: f.server, agentId: f.agent,
                                                         channelId: channel, messageId: message))
        }
        if case .readableOnly(.recoveryRequired) = queued {} else {
            Issue.record("a terminal reason must refuse the wake, got \(queued)")
        }
        let shown = frames.withLock { $0 }
        #expect(shown.contains {
            $0.room == "server:\(f.server)" && $0.event == "agent:activity"
                && $0.payload.contains("\"detailKind\":\"terminal_failure_paused\"")
                && $0.payload.contains("Automatic wake stopped")
        }, "the refused wake publishes the upstream typed offline activity frame")

        let reconnected = try await open(domain, f, epoch: "connection-2", running: [f.agent])
        try await commit { try domain.releasePendingHumanDeliveries(reconnected) }

        let agent = try #require(f.agents.state.execution.agents[f.agent])
        #expect(agent.needsManual == "outcome_evidence_lost", "ready never clears a breaker/terminal reason")
        #expect(agent.currentLaunchId == resident.launchId)
        #expect(f.agents.state.execution.pendingHumanDeliveries?.count == 1)
        #expect(f.agents.state.execution.commands.values.contains {
            $0.kind == .delivery && $0.agentId == f.agent && $0.messageId == message
        } == false)
    }
}
