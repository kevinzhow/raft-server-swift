import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

@Suite(.serialized) struct AgentExecutionTransactionTests {
    private func fixture() -> (AgentExecutionDomain, AgentsRuntimeStore, String, String, String) {
        let agents = AgentsRuntimeStore()
        let machines = MachinesAndComputersStore()
        let oauth = OAuthLedger()
        let server = "execution-server"
        let machine = "execution-machine"
        oauth.addOwnedServer(id: server, slug: "execution", name: "Execution", ownerId: "owner")
        let agent = oauth.createAgent(serverId: server, name: "Executor", runtime: "codex")
        agents.agentMachineIds = [agent: machine]
        machines.machines = [MachineRecord(id: machine, serverId: server, userId: "owner", name: "Computer", description: nil, apiKey: nil)]
        return (AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth,
                                     channels: ServersAndChannelsStore(), messages: MessagesAndThreadsStore()), agents, server, machine, agent)
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

    private func prepare(_ domain: AgentExecutionDomain, server: String, machine: String) async throws -> AgentExecutionMachineContext {
        let context = AgentExecutionMachineContext(machineId: machine, serverId: server, connectionEpochId: "connection-1")
        try await commit {
            try domain.connectionOpened(context)
            try domain.connectionReady(context, daemonInstanceId: "daemon-1", runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
        }
        return context
    }

    /// A resident process is what carries agent:deliver. A message to an agent
    /// without one is the start's wake input (upstream attempt-wake).
    private func residentStart(_ domain: AgentExecutionDomain, context: AgentExecutionMachineContext,
                               server: String, agent: String) async throws -> AgentExecutionAdmission {
        let admission = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        let ack = try JSONSerialization.data(withJSONObject: [
            "type": "agent:start:ack", "agentId": agent, "launchId": admission.launchId,
            "startDispatchId": try #require(admission.startDispatchId), "queueState": "running",
            "queueDepth": 0, "queueAgeMs": 0, "processInstanceId": "resident-process",
        ])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:start:ack", payload: ack) }
        return admission
    }

    private func frame(_ type: String, agent: String, launch: String? = nil, seq: Int64 = 0, extra: [String: String] = [:]) throws -> Data {
        var body: [String: Any] = ["type": type, "agentId": agent, "daemonInstanceId": "daemon-1", "clientSeq": seq]
        if let launch { body["launchId"] = launch }
        for (key, value) in extra { body[key] = value }
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    @Test func executionRequiresDurableTransactionAndReadiness() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        #expect(throws: (any Error).self) { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        #expect(agents.state.execution.commands.isEmpty)
        let context = AgentExecutionMachineContext(machineId: machine, serverId: server, connectionEpochId: "connection-1")
        try await commit { try domain.connectionOpened(context) }
        await #expect(throws: AgentExecutionError.machineNotReady) {
            try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        }
    }

    @Test func commandStateAndOutboxReferenceShareTheCommitAndRollback() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        _ = try await prepare(domain, server: server, machine: machine)
        let request = AgentExecutionStartRequest(serverId: server, agentId: agent)
        let context = TransactionContext()
        try await withTransactionContext(context) {
            let admitted = try domain.requestStart(request)
            #expect(admitted.commandId == request.commandId)
            try context.prepareCommit()
            let intents = try context.preparedDurableEffects()
            #expect(intents.count == 1)
            #expect(intents.first?.kind == "agent.execution")
            let reference = try JSONDecoder().decode(AgentExecutionIntentReference.self, from: #require(intents.first?.payload))
            #expect(reference.commandId == request.commandId)
            context.discard()
        }
        #expect(agents.state.execution.commands.isEmpty)
        let first = try await commit { try domain.requestStart(request) }
        let replay = try await commit { try domain.requestStart(request) }
        #expect(first == replay)
        #expect(agents.state.execution.commands.count == 1)
    }

    @Test func outcomeReplayAndConflictingIdentity() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        let launch = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        let data = try frame("agent:process_spawned", agent: agent, launch: launch.launchId, extra: ["processInstanceId": "process-1"])
        let first = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: data) }
        let replay = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: data) }
        #expect(first == replay)
        #expect(agents.state.execution.agents[agent]?.processes.count == 1)
        let conflict = try frame("agent:process_spawned", agent: agent, launch: launch.launchId, extra: ["processInstanceId": "process-2"])
        let held = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: conflict) }
        #expect(held == .hold(reason: "conflicting_identity"))
        #expect(agents.state.execution.agents[agent]?.processes.count == 1)
        #expect(agents.state.execution.agents[agent]?.needsManual == "conflicting_identity")
    }

    @Test func validMalformedEvidenceCommitsRecoveryButInvalidIdentityHolds() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        let payload = try frame("agent:runtime:outcome", agent: agent)
        let result = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: payload) }
        #expect(result == .committed(ack: .sequence(agentId: agent, daemonInstanceId: "daemon-1", clientSeq: 0)))
        #expect(agents.state.execution.agents[agent]?.needsManual == "unknown_version")
        let invalid = Data("{\"type\":\"agent:runtime:outcome\",\"agentId\":\"\(agent)\",\"daemonInstanceId\":\"daemon-1\",\"clientSeq\":true}".utf8)
        let held = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: invalid) }
        #expect(held == .hold(reason: "malformed_identity"))
        #expect(agents.state.execution.receipts.count == 1)
    }

    @Test func ownershipAndOldConnectionNeverAuthorizeAck() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        let data = try frame("agent:process_spawned", agent: agent)
        let foreign = AgentExecutionMachineContext(machineId: machine, serverId: "foreign", connectionEpochId: "connection-1")
        let denied = try await commit { try domain.stageIngress(context: foreign, type: "agent:process_spawned", payload: data) }
        #expect(denied == .hold(reason: "ownership_mismatch"))
        let next = AgentExecutionMachineContext(machineId: machine, serverId: server, connectionEpochId: "connection-2")
        try await commit { try domain.connectionOpened(next) }
        let stale = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: data) }
        #expect(stale == .hold(reason: "stale_connection"))
        #expect(agents.state.execution.receipts.isEmpty)
    }

    @Test func markersCommitRecoveryAndTakeoverPreservesDedupe() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        let marker = try JSONSerialization.data(withJSONObject: ["type": "agent:runtime:outcome_gap", "agentId": agent, "gapId": "gap-1", "takeoverEpoch": 0])
        let first = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome_gap", payload: marker) }
        #expect(first == .committed(ack: .marker(agentId: agent, gapId: "gap-1")))
        await #expect(throws: AgentExecutionError.manualRecoveryRequired) {
            try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        }
        _ = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        #expect(agents.state.execution.agents[agent]?.takeoverEpoch == 1)
        #expect(agents.state.execution.agents[agent]?.needsManual == nil)
        let replay = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome_gap", payload: marker) }
        #expect(replay == first)
        #expect(agents.state.execution.agents[agent]?.needsManual == nil)
        let invalid = Data("{\"type\":\"agent:runtime:outcome_cross_instance_unknown\",\"agentId\":\"\(agent)\"}".utf8)
        let held = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome_cross_instance_unknown", payload: invalid) }
        #expect(held == .hold(reason: "malformed_identity"))
        let cross = try JSONSerialization.data(withJSONObject: ["type": "agent:runtime:outcome_cross_instance_unknown", "agentId": agent, "gapId": "cross-1"])
        let decision = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome_cross_instance_unknown", payload: cross) }
        #expect(decision == .committed(ack: .marker(agentId: agent, gapId: "cross-1")))
        #expect(agents.state.execution.agents[agent]?.needsManual == "outcome_evidence_lost")
    }

    @Test func startAcceptanceSessionProcessAndTurnAreDifferentFacts() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        let admitted = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        let ack = try JSONSerialization.data(withJSONObject: ["type": "agent:start:ack", "agentId": agent, "launchId": admitted.launchId, "startDispatchId": try #require(admitted.startDispatchId), "queueState": "queued", "queueDepth": 0, "queueAgeMs": 0])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:start:ack", payload: ack) }
        #expect(agents.state.execution.agents[agent]?.launches[admitted.launchId]?.startAccepted == true)
        #expect(agents.state.execution.agents[agent]?.processes.isEmpty == true)
        #expect(agents.state.execution.agents[agent]?.launches[admitted.launchId]?.completed == false)
        let session = try JSONSerialization.data(withJSONObject: ["type": "agent:session", "agentId": agent, "launchId": admitted.launchId, "sessionId": "codex-session"])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:session", payload: session) }
        #expect(agents.state.execution.agents[agent]?.sessionId == "codex-session")
        let spawned = try frame("agent:process_spawned", agent: agent, launch: admitted.launchId, extra: ["processInstanceId": "process-1"])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:process_spawned", payload: spawned) }
        let completed = try JSONSerialization.data(withJSONObject: ["type": "agent:runtime:outcome", "v": 1, "agentId": agent, "daemonInstanceId": "daemon-1", "clientSeq": 1, "launchId": admitted.launchId, "sessionId": "codex-session", "outcome": ["kind": "turn_completed"]])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: completed) }
        #expect(agents.state.execution.agents[agent]?.launches[admitted.launchId]?.completed == true)
        #expect(agents.state.execution.agents[agent]?.processes["process-1"]?.exited == false)
        let exited = try frame("agent:process_exited", agent: agent, launch: admitted.launchId, seq: 2, extra: ["processInstanceId": "process-1", "spawnLaunchId": admitted.launchId])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:process_exited", payload: exited) }
        #expect(agents.state.execution.agents[agent]?.processes["process-1"]?.exited == true)
        let next = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        #expect(agents.state.execution.commands[next.commandId.uuidString]?.sessionId == "codex-session")
        let rejected = try JSONSerialization.data(withJSONObject: ["type": "agent:start:outcome", "agentId": agent, "daemonInstanceId": "daemon-1", "clientSeq": 3, "launchId": next.launchId, "result": ["kind": "not_spawned", "reason": "cancelled"]])
        _ = try await commit { try domain.stageIngress(context: context, type: "agent:start:outcome", payload: rejected) }
        #expect(agents.state.execution.agents[agent]?.launches[next.launchId]?.notSpawned == true)
    }

    @Test func terminalBreakerStopsAutomaticRetriesButHumanControlCanTakeOver() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        for sequence in 0..<2 {
            let admission = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
            let failed = try JSONSerialization.data(withJSONObject: ["type": "agent:runtime:outcome", "v": 1, "agentId": agent, "daemonInstanceId": "daemon-1", "clientSeq": sequence, "launchId": admission.launchId, "outcome": ["kind": "terminal_failure", "fingerprint": "same-failure", "failureKind": "runtime_error"]])
            _ = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: failed) }
        }
        #expect(agents.state.execution.agents[agent]?.failureCount == 2)
        await #expect(throws: AgentExecutionError.breakerPaused) {
            try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        }
        _ = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        #expect(agents.state.execution.agents[agent]?.failureCount == 0)
        #expect(agents.state.execution.agents[agent]?.takeoverEpoch == 1)
    }

    @Test func freshCreateAutostartCanDeclineBeforeStaging() async throws {
        let (domain, agents, server, _, agent) = fixture()
        let context = TransactionContext()
        try await withTransactionContext(context) {
            let declined = try domain.requestAutomaticStartIfReady(.init(serverId: server, agentId: agent))
            #expect(declined == nil)
            try context.prepareCommit()
            #expect(try context.preparedDurableEffects().isEmpty)
            context.publishCommitted()
            context.flushDeferredEffects()
        }
        #expect(agents.state.execution.commands.isEmpty)
    }

    @Test func deliveryUsesAuthorizedLocalJointProjectionOfCanonicalMessage() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        domain.oauth.addOwnedServer(id: "host-server", slug: "host", name: "Host", ownerId: "host-owner")
        let canonical = domain.oauth.createChannel(serverId: "host-server", name: "canonical", creatorUserId: "host-owner")
        let local = domain.oauth.createChannel(serverId: server, name: "local", creatorUserId: "owner")
        domain.channels.addPostableChannel(serverId: server, channelId: local, memberId: agent)
        domain.channels.addJointChannelProjection(localChannelId: local, canonicalChannelId: canonical, serverId: server)
        let message = domain.oauth.createMessageRecord(channelId: canonical, content: "Real message", senderId: "host-owner")
        let context = try await prepare(domain, server: server, machine: machine)
        _ = try await residentStart(domain, context: context, server: server, agent: agent)
        let admitted = try #require(try await commit {
            try domain.requestDelivery(.init(serverId: server, agentId: agent, channelId: local, messageId: message.id))
        })
        #expect(agents.state.execution.commands[admitted.commandId.uuidString]?.channelId == local)
        #expect(admitted.deliveryId?.isEmpty == false)
        await #expect(throws: AgentExecutionError.invalidRequest) {
            try await commit { try domain.requestDelivery(.init(serverId: server, agentId: agent, channelId: canonical, messageId: message.id)) }
        }
        domain.channels.mutex.withLock { $0.postableChannels[local]?.memberIds.remove(agent) }
        #expect(!domain.deliveryIsAuthorized(serverId: server, agentId: agent, channelId: local, messageId: message.id))
    }

    @Test func producerTransactionBindingCannotPretendToCommitOrAcknowledge() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let service = AgentExecutionService(producerTransactionAgents: agents, machines: domain.machines,
                                            oauth: domain.oauth, channels: domain.channels, messages: domain.messages)
        let context = AgentExecutionMachineContext(machineId: machine, serverId: server, connectionEpochId: "connection-1")
        let reference = AgentExecutionIntentReference(commandId: UUID())
        #expect(throws: AgentExecutionError.durableTransactionRequired) { try service.command(reference: reference) }
        #expect(throws: AgentExecutionError.durableTransactionRequired) { try service.resolveDispatch(reference: reference) }
        await #expect(throws: AgentExecutionError.durableTransactionRequired) { try await service.connectionOpened(context) }
        await #expect(throws: AgentExecutionError.durableTransactionRequired) {
            try await service.connectionReady(context, daemonInstanceId: "daemon-1", runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
        }
        await #expect(throws: AgentExecutionError.durableTransactionRequired) { try await service.connectionClosed(context) }
        let payload = try frame("agent:runtime:outcome", agent: agent)
        await #expect(throws: AgentExecutionError.durableTransactionRequired) {
            try await service.consume(context: context, type: "agent:runtime:outcome", payload: payload)
        }
        await #expect(throws: AgentExecutionError.durableTransactionRequired) { try await service.noteDispatched(reference: reference, context: context) }
        await #expect(throws: AgentExecutionError.durableTransactionRequired) { try await service.beginDispatch(reference: reference, context: context) }
        await #expect(throws: AgentExecutionError.durableTransactionRequired) { try await service.noteAmbiguousDispatch(reference: reference, context: context) }
        await #expect(throws: AgentExecutionError.durableTransactionRequired) {
            try await service.observeReady(context, daemonInstanceId: nil, capabilities: nil, runtimes: nil,
                                           runningAgentIds: nil, detectionComplete: false, unreliableAgentIds: [])
        }
        let transaction = TransactionContext()
        try await withTransactionContext(transaction) {
            let admission = try service.requestStop(.init(serverId: server, agentId: agent))
            #expect(agents.state.execution.commands[admission.commandId.uuidString]?.kind == .stop)
            try transaction.prepareCommit()
            let effects = try transaction.preparedDurableEffects()
            #expect(effects.count == 1)
            #expect(effects.first?.effectID == admission.commandId)
            transaction.discard()
        }
        #expect(agents.state.execution.connections.isEmpty)
        #expect(agents.state.execution.receipts.isEmpty)
        #expect(agents.state.execution.commands.isEmpty)
    }

    @Test func partialReadyInvalidatesPriorInventoryAndUnreliableAgentsCanRecoverByHumanControl() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        try await commit {
            try domain.observeReady(context, daemonInstanceId: nil, capabilities: nil, runtimes: nil,
                                    runningAgentIds: nil, detectionComplete: false, unreliableAgentIds: [])
        }
        #expect(agents.state.execution.connections[machine]?.ready == false)
        #expect(agents.state.execution.connections[machine]?.daemonInstanceId == "daemon-1")
        let capabilities = ["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"]
        try await commit {
            try domain.observeReady(context, daemonInstanceId: "daemon-1", capabilities: capabilities, runtimes: ["codex"],
                                    runningAgentIds: [], detectionComplete: true, unreliableAgentIds: [agent])
        }
        #expect(agents.state.execution.connections[machine]?.ready == true)
        #expect(agents.state.execution.agents[agent]?.needsManual == "daemon_outcome_storage_unreliable")
        await #expect(throws: AgentExecutionError.manualRecoveryRequired) {
            try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        }
        _ = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        #expect(agents.state.execution.agents[agent]?.needsManual == nil)
    }

    @Test func aReclaimedUnconfirmedDispatchRequiresRecoveryAndDoesNotGrantAnotherWrite() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        let admission = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        let reference = AgentExecutionIntentReference(commandId: admission.commandId)
        let first = try await commit { try domain.beginDispatch(reference: reference, context: context, deliverySequence: nil) }
        #expect(first == .granted)
        let second = try await commit { try domain.beginDispatch(reference: reference, context: context, deliverySequence: nil) }
        #expect(second == .uncertain)
        #expect(agents.state.execution.agents[agent]?.needsManual == "dispatch_outcome_unknown")
        #expect(agents.state.execution.agents[agent]?.launches[admission.launchId]?.startAccepted == false)
        #expect(agents.state.execution.agents[agent]?.processes.isEmpty == true)
        let restored = AgentsRuntimeStore()
        try restored.restorePersistenceData(agents.exportPersistenceData())
        #expect(restored.state.execution.dispatches?[admission.commandId.uuidString]?.phase == .attempting)
        #expect(restored.state.execution.agents[agent]?.needsManual == "server_restarted_with_unsettled_dispatch")
    }

    @Test func deliveryAckRequiresThePersistedAttemptSequenceAndEpoch() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let channel = domain.oauth.createChannel(serverId: server, name: "delivery", creatorUserId: "owner")
        domain.channels.addPostableChannel(serverId: server, channelId: channel, memberId: agent)
        let message = domain.oauth.createMessageRecord(channelId: channel, content: "Stored", senderId: "owner")
        domain.messages.withState { $0.humanMessageRows.append(StoredHumanMessage(id: message.id, channelId: channel, senderId: "owner", content: "Stored", seq: 42)) }
        let context = try await prepare(domain, server: server, machine: machine)
        _ = try await residentStart(domain, context: context, server: server, agent: agent)
        let admission = try #require(try await commit { try domain.requestDelivery(.init(serverId: server, agentId: agent, channelId: channel, messageId: message.id)) })
        #expect(agents.state.execution.commands[admission.commandId.uuidString]?.kind == .delivery)
        let reference = AgentExecutionIntentReference(commandId: admission.commandId)
        let deliveryId = try #require(admission.deliveryId)
        let data = try JSONSerialization.data(withJSONObject: ["type": "agent:deliver:ack", "agentId": agent, "deliveryId": deliveryId, "seq": 42])
        let unowned = try await commit { try domain.stageIngress(context: context, type: "agent:deliver:ack", payload: data) }
        #expect(unowned == .hold(reason: "unowned_delivery_ack"))
        let permission = try await commit { try domain.beginDispatch(reference: reference, context: context, deliverySequence: 42) }
        #expect(permission == .granted)
        let accepted = try await commit { try domain.stageIngress(context: context, type: "agent:deliver:ack", payload: data) }
        #expect(accepted == .committed(ack: nil))
        #expect(agents.state.execution.commands[admission.commandId.uuidString]?.status == .accepted)
        let replay = try await commit { try domain.stageIngress(context: context, type: "agent:deliver:ack", payload: data) }
        #expect(replay == accepted)
        let conflict = try JSONSerialization.data(withJSONObject: ["type": "agent:deliver:ack", "agentId": agent, "deliveryId": deliveryId, "seq": 43])
        let held = try await commit { try domain.stageIngress(context: context, type: "agent:deliver:ack", payload: conflict) }
        #expect(held == .hold(reason: "conflicting_delivery_ack"))
        #expect(agents.state.execution.agents[agent]?.needsManual == "conflicting_delivery_ack")
    }

    @Test func typedOutcomeFingerprintsKeepSupportedLegacyBytesAndUnknownFields() throws {
        let cases: [(String, String)] = [
            ("agent:runtime:outcome", "\"v\":1,\"launchId\":\"launch\",\"outcome\":{\"kind\":\"turn_completed\"}"),
            ("agent:process_spawned", "\"launchId\":\"launch\",\"processInstanceId\":\"process\""),
            ("agent:process_exited", "\"launchId\":\"launch\",\"processInstanceId\":\"process\",\"spawnLaunchId\":null"),
            ("agent:start:outcome", "\"launchId\":\"launch\",\"result\":{\"kind\":\"not_spawned\",\"reason\":\"cancelled\"}"),
            ("agent:runtime:outcome_gap", "\"gapId\":\"gap\",\"takeoverEpoch\":0,\"counts\":{\"e1\":0,\"spawned\":0,\"exited\":0,\"startOutcome\":0,\"turnCompleted\":1}"),
            ("agent:runtime:outcome_cross_instance_unknown", "\"gapId\":\"gap\",\"takeoverEpoch\":0")
        ]
        let numbers = ["0", "1", "-1", "0.5", "1.5", "-2.25", "1e-7", "1e+21", "9007199254740991", "9223372036854775807", "-9223372036854775808"]
        for (type, details) in cases {
            for number in numbers {
                let text = "{\"type\":\"\(type)\",\"agentId\":\"agent\",\"daemonInstanceId\":\"daemon\",\"clientSeq\":1,\(details),\"extension\":{\"2\":2,\"10\":10,\"a\":true,\"B\":null,\"text\":\"é😀 a/b\\n\\u0001\",\"number\":\(number)}}"
                let payload = Data(text.utf8)
                let legacy = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: payload), options: .sortedKeys)
                let parsed = try #require(AgentExecutionOutcomeFrame.parse(type: type, payload: payload))
                #expect(parsed.fingerprint == AgentExecutionOutcomeFrame.digest(legacy))
            }
        }
        let first = Data("{\"type\":\"agent:runtime:outcome\",\"agentId\":\"agent\",\"daemonInstanceId\":\"daemon\",\"clientSeq\":1,\"v\":2,\"unknown\":\"first\"}".utf8)
        let second = Data("{\"unknown\":\"second\",\"v\":2,\"clientSeq\":1,\"daemonInstanceId\":\"daemon\",\"agentId\":\"agent\",\"type\":\"agent:runtime:outcome\"}".utf8)
        #expect(AgentExecutionOutcomeFrame.parse(type: "agent:runtime:outcome", payload: first)?.fingerprint != AgentExecutionOutcomeFrame.parse(type: "agent:runtime:outcome", payload: second)?.fingerprint)
        let booleanIdentity = Data("{\"type\":\"agent:runtime:outcome\",\"agentId\":\"agent\",\"daemonInstanceId\":\"daemon\",\"clientSeq\":true,\"v\":2}".utf8)
        #expect(AgentExecutionOutcomeFrame.parse(type: "agent:runtime:outcome", payload: booleanIdentity) == nil)
    }

    @Test func unsupportedNumericRepresentationsHoldWithoutAssigningANewReceipt() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        let context = try await prepare(domain, server: server, machine: machine)
        for number in ["18446744073709551615", "0.123456789012345678901", "-0.0", "1e-400"] {
            let payload = Data("{\"type\":\"agent:runtime:outcome\",\"agentId\":\"\(agent)\",\"daemonInstanceId\":\"daemon-1\",\"clientSeq\":0,\"v\":2,\"unknown\":\(number)}".utf8)
            #expect(!AgentExecutionJSONNumberPolicy.accepts(payload))
            #expect(AgentExecutionOutcomeFrame.parse(type: "agent:runtime:outcome", payload: payload) == nil)
            let result = try await commit { try domain.stageIngress(context: context, type: "agent:runtime:outcome", payload: payload) }
            #expect(result == .hold(reason: "unsupported_numeric_representation"))
        }
        #expect(agents.state.execution.receipts.isEmpty)
        #expect(agents.state.execution.watermarks.isEmpty)
        #expect(AgentExecutionJSONNumberPolicy.accepts(Data("{\"text\":\"18446744073709551615 -0.0\"}".utf8)))
    }

    @Test func restoringSnapshotsPreservesIntentButNeverRestoresReadyPresence() async throws {
        let (domain, agents, server, machine, agent) = fixture()
        _ = try await prepare(domain, server: server, machine: machine)
        let admitted = try await commit { try domain.requestStart(.init(serverId: server, agentId: agent)) }
        let snapshot = try agents.exportPersistenceData()
        let restored = AgentsRuntimeStore()
        try restored.restorePersistenceData(snapshot)
        #expect(restored.state.execution.commands[admitted.commandId.uuidString]?.launchId == admitted.launchId)
        #expect(restored.state.execution.connections[machine]?.online == false)
        #expect(restored.state.execution.connections[machine]?.ready == false)
        #expect(restored.state.execution.agents[agent]?.needsManual == "server_restarted_with_unsettled_execution")
    }
}
