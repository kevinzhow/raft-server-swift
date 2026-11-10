import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

/// The transient agent notice: an agent-only system wake that is never a
/// `messages` row, admitted only to an agent that can receive NOW, with a
/// typed accepted/dropped receipt and a `seq: 0` wire identity.
@Suite(.serialized) struct AgentExecutionNoticeTests {
    private struct Fixture {
        let domain: AgentExecutionDomain
        let service: AgentExecutionService
        let agents: AgentsRuntimeStore
        let machines: MachinesAndComputersStore
        let oauth: OAuthLedger
        let channels: ServersAndChannelsStore
        let messages: MessagesAndThreadsStore
        let serverId: String
        let machineId: String
        let agentId: String
        let context: AgentExecutionMachineContext
        let materializer: AgentExecutionMaterializationService

        init(runtime: String = "codex") {
            let agents = AgentsRuntimeStore()
            let machines = MachinesAndComputersStore()
            let oauth = OAuthLedger()
            let channels = ServersAndChannelsStore()
            let messages = MessagesAndThreadsStore()
            let auditProfiles = AuthProfileStore()
            let tasks = TasksAndRemindersStore()
            let serverId = "11111111-1111-4111-8111-111111111801"
            let machineId = "notice-machine"
            oauth.addOwnedServer(id: serverId, slug: "notice-server", name: "Notice", ownerId: "owner")
            let agentId = oauth.createAgent(serverId: serverId, name: "Cindy", displayName: "Cindy",
                                            runtime: runtime)
            oauth.setAgentStatus(id: agentId, status: "active")
            agents.agentMachineIds = [agentId: machineId]
            machines.machines = [MachineRecord(id: machineId, serverId: serverId, userId: "owner",
                                              name: "Computer", description: nil, apiKey: nil)]
            self.domain = AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth,
                                               channels: channels, messages: messages)
            self.service = AgentExecutionService(producerTransactionAgents: agents, machines: machines,
                                                 oauth: oauth, channels: channels, messages: messages)
            self.agents = agents
            self.machines = machines
            self.oauth = oauth
            self.channels = channels
            self.messages = messages
            self.serverId = serverId
            self.machineId = machineId
            self.agentId = agentId
            self.context = AgentExecutionMachineContext(machineId: machineId, serverId: serverId,
                                                        connectionEpochId: "notice-epoch")
            self.materializer = AgentExecutionMaterializationService(
                transactionAgents: agents, machines: machines, oauth: oauth, channels: channels,
                messages: messages, profiles: auditProfiles, tasks: tasks,
                serverURL: "https://notice.invalid"
            )
        }
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

    private func connect(_ fixture: Fixture) async throws {
        try await commit {
            try fixture.domain.connectionOpened(fixture.context)
            try fixture.domain.connectionReady(fixture.context, daemonInstanceId: "notice-daemon",
                                               runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
        }
    }

    /// Drive a real human start through the domain and ack it from the
    /// controlled daemon frame so the launch is genuinely live.
    @discardableResult
    private func startAgent(_ fixture: Fixture) async throws -> AgentExecutionAdmission {
        let admission = try await commit {
            try fixture.service.requestStart(.init(serverId: fixture.serverId, agentId: fixture.agentId,
                                                   control: .humanStart))
        }
        let frame = try JSONSerialization.data(withJSONObject: [
            "type": "agent:start:ack", "agentId": fixture.agentId,
            "launchId": admission.launchId, "startDispatchId": admission.startDispatchId ?? "",
            "queueState": "starting", "queueDepth": 0, "queueAgeMs": 0,
        ], options: .sortedKeys)
        try await commit {
            _ = try fixture.domain.stageIngress(context: fixture.context, type: "agent:start:ack", payload: frame)
        }
        return admission
    }

    private func request(_ fixture: Fixture, messageId: String = "onboarding-owner-facts-111",
                         channelId: String = "onboarding-context", content: String = "owner facts")
        -> AgentExecutionNoticeRequest {
        AgentExecutionNoticeRequest(
            serverId: fixture.serverId, agentId: fixture.agentId, channelId: channelId,
            channelName: channelId, channelType: "channel", content: content,
            messageId: messageId, timestamp: "2026-01-02T03:04:05.678Z"
        )
    }

    // MARK: - Admission

    @Test func noticeNeedsADurableTransactionAndNeverColdStartsADeadAgent() async throws {
        let fixture = Fixture()
        #expect(try fixture.service.requestNotice(request(fixture)) == .dropped(.transactionRequired))
        #expect(fixture.agents.state.execution.commands.isEmpty)

        try await connect(fixture)
        let dropped = try await commit { try fixture.service.requestNotice(self.request(fixture)) }
        #expect(dropped == .dropped(.agentNotRunning))
        // No automatic start command and no notice command were written.
        #expect(fixture.agents.state.execution.commands.isEmpty)
        #expect(fixture.agents.state.execution.agents[fixture.agentId]?.currentLaunchId == nil)
    }

    @Test func noticeIsAcceptedOnlyForALiveLaunchAndAReadyMachine() async throws {
        let fixture = Fixture()
        try await connect(fixture)
        let admission = try await startAgent(fixture)
        let accepted = try await commit { try fixture.service.requestNotice(self.request(fixture)) }
        guard case .accepted(let commandId) = accepted else {
            Issue.record("expected accepted, got \(accepted)")
            return
        }
        let state = fixture.agents.state.execution
        let command = try #require(state.commands[commandId.uuidString])
        #expect(command.kind == .notice)
        #expect(command.launchId == admission.launchId)
        #expect(command.serverId == fixture.serverId)
        #expect(command.machineId == fixture.machineId)
        #expect(command.channelId == "onboarding-context")
        #expect(command.messageId == "onboarding-owner-facts-111")
        #expect(command.notice == AgentExecutionNotice(channelName: "onboarding-context",
                                                      channelType: "channel", content: "owner facts",
                                                      timestamp: "2026-01-02T03:04:05.678Z"))
        #expect(command.deliveryId?.isEmpty == false)
        // The only start command is the explicit human start; the notice never
        // creates a launch.
        #expect(state.commands.values.filter { $0.kind == .start }.count == 1)
        #expect(state.agents[fixture.agentId]?.currentLaunchId == admission.launchId)

        // A duplicate command id is an idempotent replay, not a second wake.
        let replay = try await commit {
            try fixture.service.requestNotice(AgentExecutionNoticeRequest(
                commandId: commandId, serverId: fixture.serverId, agentId: fixture.agentId,
                channelId: "onboarding-context", channelName: "onboarding-context", channelType: "channel",
                content: "owner facts", messageId: "onboarding-owner-facts-111",
                timestamp: "2026-01-02T03:04:05.678Z"
            ))
        }
        #expect(replay == .accepted(commandId: commandId))
    }

    @Test func noticeDropReasonsFollowTheRetainedState() async throws {
        let fixture = Fixture()
        try await connect(fixture)
        try await startAgent(fixture)

        // Manual stop refuses the wake and never starts the agent.
        try await commit {
            try fixture.service.requestStop(.init(serverId: fixture.serverId, agentId: fixture.agentId))
        }
        let stopped = try await commit { try fixture.service.requestNotice(self.request(fixture)) }
        #expect(stopped == .dropped(.manuallyStopped))

        let other = Fixture()
        try await connect(other)
        try await startAgent(other)
        other.agents.withState { $0.execution.agents[other.agentId]?.needsManual = "runtime_probe" }
        let recovery = try await commit { try other.service.requestNotice(self.request(other)) }
        #expect(recovery == .dropped(.manualRecovery))

        let offline = Fixture()
        try await connect(offline)
        try await startAgent(offline)
        offline.agents.withState { $0.execution.connections[offline.machineId]?.ready = false }
        let notReady = try await commit { try offline.service.requestNotice(self.request(offline)) }
        #expect(notReady == .dropped(.machineNotReady))
    }

    // MARK: - Materialization and receipt

    @Test func noticeMaterializesTheExactUpstreamSystemBodyWithoutASeqMember() async throws {
        let fixture = Fixture()
        try await connect(fixture)
        try await startAgent(fixture)
        let receipt = try await commit { try fixture.service.requestNotice(self.request(fixture)) }
        guard case .accepted(let commandId) = receipt else {
            Issue.record("expected accepted")
            return
        }
        let command = try #require(fixture.agents.state.execution.commands[commandId.uuidString])
        let payload = try await commit { try fixture.materializer.materializeInTransaction(command: command) }
        guard case .notice(let bodyData) = payload else {
            Issue.record("expected notice payload")
            return
        }
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["channel_id"] as? String == "onboarding-context")
        #expect(body["channel_name"] as? String == "onboarding-context")
        #expect(body["channel_type"] as? String == "channel")
        #expect(body["message_id"] as? String == "onboarding-owner-facts-111")
        #expect(body["sender_id"] as? String == "system")
        #expect(body["sender_name"] as? String == "system")
        #expect(body["sender_type"] as? String == "system")
        #expect(body["content"] as? String == "owner facts")
        #expect(body["timestamp"] as? String == "2026-01-02T03:04:05.678Z")
        // The synthetic notice has no stored seq: the envelope owns seq 0.
        #expect(body["seq"] == nil)
        // Nothing was written to chat history, and no chat publication exists.
        #expect(fixture.messages.humanMessageRows.isEmpty)
        let context = TransactionContext()
        try await withTransactionContext(context) {
            _ = try fixture.materializer.materializeInTransaction(command: command)
            try context.prepareCommit()
            let intents = try context.preparedDurableEffects()
            #expect(intents.filter { $0.kind == "realtime.publish" }.isEmpty)
            context.discard()
        }
    }

    @Test func seqZeroAcknowledgementSettlesTheNoticeAndNeverPoisonsTheAgent() async throws {
        let fixture = Fixture()
        try await connect(fixture)
        try await startAgent(fixture)
        let receipt = try await commit { try fixture.service.requestNotice(self.request(fixture)) }
        guard case .accepted(let commandId) = receipt else {
            Issue.record("expected accepted")
            return
        }
        let command = try #require(fixture.agents.state.execution.commands[commandId.uuidString])
        let deliveryId = try #require(command.deliveryId)
        // The production worker commits its fenced attempt before the socket
        // write; the daemon ack can only settle that committed attempt.
        let reference = AgentExecutionIntentReference(commandId: commandId)
        let admitted = try await commit {
            try fixture.domain.beginDispatch(reference: reference, context: fixture.context, deliverySequence: 0)
        }
        #expect(admitted == .granted)

        // A wrong seq is a conflicting receipt: hold, and the command stays
        // pending. The agent is not marked manual for an onboarding notice.
        let wrong = try JSONSerialization.data(withJSONObject: [
            "type": "agent:deliver:ack", "agentId": fixture.agentId, "deliveryId": deliveryId, "seq": 1,
        ], options: .sortedKeys)
        let held = try await commit {
            try fixture.domain.stageIngress(context: fixture.context, type: "agent:deliver:ack", payload: wrong)
        }
        if case .hold(let reason) = held { #expect(reason == "conflicting_delivery_ack") } else {
            Issue.record("expected hold, got \(held)")
        }
        #expect(fixture.agents.state.execution.commands[commandId.uuidString]?.status == .pending)
        #expect(fixture.agents.state.execution.agents[fixture.agentId]?.needsManual == nil)

        // The official daemon acks a synthetic notice at seq 0.
        let ack = try JSONSerialization.data(withJSONObject: [
            "type": "agent:deliver:ack", "agentId": fixture.agentId, "deliveryId": deliveryId, "seq": 0,
        ], options: .sortedKeys)
        let result = try await commit {
            try fixture.domain.stageIngress(context: fixture.context, type: "agent:deliver:ack", payload: ack)
        }
        #expect(result == .committed(ack: nil))
        let settled = fixture.agents.state.execution
        #expect(settled.commands[commandId.uuidString]?.status == .accepted)
        #expect(settled.dispatches?[commandId.uuidString]?.phase == .accepted)
        #expect(settled.dispatches?[commandId.uuidString]?.deliverySequence == 0)
        #expect(settled.agents[fixture.agentId]?.needsManual == nil)
    }

    /// The persisted snapshot must validate with a notice and its seq-0
    /// dispatch. A rejected snapshot would fail every later business commit (the
    /// runtime encodes the whole Agents owner on commit), so this pins the
    /// validation rule that the real-PostgreSQL acceptance exposed.
    @Test func noticeDispatchSnapshotRoundTripsAndValidates() async throws {
        let fixture = Fixture()
        try await connect(fixture)
        try await startAgent(fixture)
        let receipt = try await commit { try fixture.service.requestNotice(self.request(fixture)) }
        guard case .accepted(let commandId) = receipt else {
            Issue.record("expected accepted")
            return
        }
        let reference = AgentExecutionIntentReference(commandId: commandId)
        _ = try await commit {
            try fixture.domain.beginDispatch(reference: reference, context: fixture.context, deliverySequence: 0)
        }
        let exported = try fixture.agents.exportPersistenceData()
        let restored = AgentsRuntimeStore()
        try restored.restorePersistenceData(exported)
        let command = try #require(restored.state.execution.commands[commandId.uuidString])
        #expect(command.kind == .notice)
        #expect(command.notice?.content == "owner facts")
        #expect(restored.state.execution.dispatches?[commandId.uuidString]?.deliverySequence == 0)
        // Re-encoding exercises validate() on the restored snapshot too.
        _ = try restored.exportPersistenceData()
    }

    @Test func lostNoticeDispatchDoesNotRequireManualAgentRecovery() async throws {
        let fixture = Fixture()
        try await connect(fixture)
        try await startAgent(fixture)
        let receipt = try await commit { try fixture.service.requestNotice(self.request(fixture)) }
        guard case .accepted(let commandId) = receipt else {
            Issue.record("expected accepted")
            return
        }
        let reference = AgentExecutionIntentReference(commandId: commandId)
        let ambiguous = try await commit {
            try fixture.domain.beginDispatch(reference: reference, context: fixture.context, deliverySequence: 0)
        }
        #expect(ambiguous == .granted)
        let result = try await commit {
            try fixture.domain.noteAmbiguousDispatch(reference: reference, context: fixture.context)
        }
        #expect(result == .uncertain)
        // A transient notice is lost, not a reason to require manual recovery of
        // the whole agent; upstream's dropped wake has no such side effect.
        #expect(fixture.agents.state.execution.agents[fixture.agentId]?.needsManual == nil)
    }
}
