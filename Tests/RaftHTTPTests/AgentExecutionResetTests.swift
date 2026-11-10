import Foundation
import RaftShared
import Testing
import TestSupport
@testable import RaftHTTP

/// Real retained-owner/UoW invariants only; no fake PG, transport or executor.
/// The public refusal and actual NIO frame tests are separate acceptance paths.
@Suite(.serialized) struct AgentExecutionResetTests {
    private func fixture(machine: Bool = true) -> (AgentExecutionDomain, String, String, String) {
        let agents = AgentsRuntimeStore(), machines = MachinesAndComputersStore(), oauth = OAuthLedger()
        let server = "reset-server", computer = "reset-machine"
        oauth.addOwnedServer(id: server, slug: "reset", name: "Reset", ownerId: "owner")
        let agent = oauth.createAgent(serverId: server, name: "Reset", runtime: "codex")
        agents.serverAgents = [agent: ServerAgent(id: agent, serverId: server, name: "Reset", status: "active")]
        if machine {
            agents.agentMachineIds = [agent: computer]
            machines.machines = [MachineRecord(id: computer, serverId: server, userId: "owner", name: "Computer", description: nil, apiKey: nil)]
        }
        return (.init(agents: agents, machines: machines, oauth: oauth, channels: ServersAndChannelsStore(), messages: MessagesAndThreadsStore()), server, computer, agent)
    }
    private func publish<T: Sendable>(_ body: @Sendable () throws -> T) async throws -> T {
        let context = TransactionContext()
        return try await withTransactionContext(context) {
            let result = try body()
            try context.prepareCommit()
            context.publishCommitted()
            context.flushDeferredEffects()
            return result
        }
    }
    private func ready(_ domain: AgentExecutionDomain, _ server: String, _ machine: String) async throws -> AgentExecutionMachineContext {
        let context = AgentExecutionMachineContext(machineId: machine, serverId: server, connectionEpochId: "reset-epoch")
        try await publish {
            try domain.connectionOpened(context)
            try domain.observeReady(context, daemonInstanceId: "reset-daemon",
                capabilities: ["agent:start", "agent:stop", "agent:deliver", "agent:runtime-outcome-v1"],
                runtimes: ["codex"], runningAgentIds: [], detectionComplete: true, unreliableAgentIds: [])
        }
        return context
    }

    @Test func versionedResetReferenceCanNeverBecomeANormalExecutionReference() throws {
        let ref = AgentExecutionResetReference(resetOperationId: UUID(), phase: .stop, phaseId: UUID())
        let data = try JSONEncoder().encode(ref)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentExecutionIntentReference.self, from: data) }
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var mixed = object
        mixed["commandId"] = UUID().uuidString
        let mixedData = try JSONSerialization.data(withJSONObject: mixed)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentExecutionIntentReference.self, from: mixedData) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentExecutionResetReference.self, from: mixedData) }
    }

    @Test func fullResetRequiresWrittenPredecessorsAndSettlesOldPhasesWithoutAnotherSend() async throws {
        let (domain, server, machine, agent) = fixture()
        let context = try await ready(domain, server, machine)
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .full)
        _ = try await publish { try domain.requestReset(request) }
        let first = try #require(domain.agents.state.execution.resetIntents?[request.operationId.uuidString])
        #expect(domain.agents.state.execution.commands[first.startCommandId.uuidString] == nil)
        let stop = first.reference(.stop), workspace = first.reference(.workspace), restart = first.reference(.restart)
        #expect(try domain.resolveReset(workspace) == .wait(reason: "predecessor_not_written"))
        #expect(try await publish { try domain.beginResetPhase(stop, context: context) } == .granted)
        try await publish { try domain.noteResetControlWritten(stop, context: context) }
        #expect(try domain.resolveReset(stop) == .settled)
        #expect(domain.agents.state.execution.agents[agent]?.sessionId == nil)
        #expect(domain.agents.state.execution.commands[first.startCommandId.uuidString] == nil)
        #expect(try await publish { try domain.beginResetPhase(workspace, context: context) } == .granted)
        try await publish { try domain.noteResetControlWritten(workspace, context: context) }
        // A failed outbox ACK can revisit either old ref after the advance.
        try await publish { try domain.noteResetControlWritten(stop, context: context) }
        #expect(try domain.resolveReset(workspace) == .settled)
        #expect(try await publish { try domain.stageResetRestart(restart, context: context) })
        let command = try #require(domain.agents.state.execution.commands[first.startCommandId.uuidString])
        #expect(command.kind == .start && command.humanStart && command.sessionId == nil)
        #expect(try domain.resolveReset(restart) == .settled)
        #expect(domain.agents.state.execution.resetIntents?[request.operationId.uuidString]?.workspaceAttempt == .written)
        try domain.agents.state.execution.validate()
    }

    @Test func attemptedWorkspaceResetBecomesHoldOnRestoreAndCannotDeleteANewWorkspace() async throws {
        let (domain, server, machine, agent) = fixture()
        let context = try await ready(domain, server, machine)
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .full)
        _ = try await publish { try domain.requestReset(request) }
        let intent = try #require(domain.agents.state.execution.resetIntents?[request.operationId.uuidString])
        _ = try await publish { try domain.beginResetPhase(intent.reference(.stop), context: context) }
        try await publish { try domain.noteResetControlWritten(intent.reference(.stop), context: context) }
        _ = try await publish { try domain.beginResetPhase(intent.reference(.workspace), context: context) }
        var restored = try JSONDecoder().decode(AgentExecutionState.self, from: JSONEncoder().encode(domain.agents.state.execution))
        restored.fenceAfterRestore()
        #expect(restored.resetIntents?[request.operationId.uuidString]?.phase == .held)
        #expect(restored.resetIntents?[request.operationId.uuidString]?.workspaceAttempt == .ambiguous)
        #expect(restored.agents[agent]?.needsManual != nil)
        #expect(restored.commands[intent.startCommandId.uuidString] == nil)
    }

    @Test func noMachineSessionResetHasOnlyLocalFactsAndNoFabricatedLaunchOrWire() async throws {
        let (domain, server, _, agent) = fixture(machine: false)
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .session)
        let admission = try await publish { try domain.requestReset(request) }
        #expect(!admission.requiresMachineDispatch)
        #expect(domain.agents.state.execution.commands.isEmpty)
        #expect(domain.agents.state.execution.agents.isEmpty)
        #expect(domain.agents.state.execution.resetIntents?[request.operationId.uuidString]?.phase == .localOnly)
        #expect(domain.agents.state.execution.stopIntents == nil)
    }

    @Test func resetWithoutRestartPreservesUnknownAttemptAndManualRecoveryFacts() async throws {
        let (domain, server, machine, agent) = fixture()
        let context = try await ready(domain, server, machine)
        let start = try await publish { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        let startRef = AgentExecutionIntentReference(commandId: start.commandId)
        _ = try await publish { try domain.beginDispatch(reference: startRef, context: context, deliverySequence: nil) }
        _ = try await publish { try domain.noteAmbiguousDispatch(reference: startRef, context: context) }
        let reason = try #require(domain.agents.state.execution.agents[agent]?.needsManual)
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .session, restart: false)
        _ = try await publish { try domain.requestReset(request) }
        let intent = try #require(domain.agents.state.execution.resetIntents?[request.operationId.uuidString])
        _ = try await publish { try domain.beginResetPhase(intent.reference(.stop), context: context) }
        try await publish { try domain.noteResetControlWritten(intent.reference(.stop), context: context) }
        #expect(domain.agents.state.execution.agents[agent]?.needsManual == reason)
        #expect(domain.agents.state.execution.dispatches?[start.commandId.uuidString]?.phase == .ambiguous)
        #expect(domain.agents.state.execution.agents[agent]?.launches[start.launchId]?.completed == false)
        #expect(domain.agents.state.execution.commands[intent.startCommandId.uuidString] == nil)
        #expect(domain.agents.state.execution.resetIntents?[request.operationId.uuidString]?.phase == .dispatched)
    }

    @Test(arguments: [0, 1, 2])
    func laterManualStopCancelsUnsentResetRemainderAndAllowsFreshHumanStart(writtenPhases: Int) async throws {
        let (domain, server, machine, agent) = fixture()
        let context = try await ready(domain, server, machine)
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .full)
        _ = try await publish { try domain.requestReset(request) }
        let intent = try #require(domain.agents.state.execution.resetIntents?[request.operationId.uuidString])
        if writtenPhases > 0 {
            _ = try await publish { try domain.beginResetPhase(intent.reference(.stop), context: context) }
            try await publish { try domain.noteResetControlWritten(intent.reference(.stop), context: context) }
        }
        if writtenPhases > 1 {
            _ = try await publish { try domain.beginResetPhase(intent.reference(.workspace), context: context) }
            try await publish { try domain.noteResetControlWritten(intent.reference(.workspace), context: context) }
        }
        let manualStop = try await publish { try domain.requestStop(.init(serverId: server, agentId: agent)) }
        let remaining = intent.reference(writtenPhases == 0 ? .stop : writtenPhases == 1 ? .workspace : .restart)
        if writtenPhases < 2 {
            #expect(try await publish { try domain.beginResetPhase(remaining, context: context) } == .cancelled)
        } else {
            #expect(try await publish { try domain.stageResetRestart(remaining, context: context) } == false)
        }
        #expect(try await publish { try domain.reconcileReset(remaining) } == .cancelled)
        #expect(try await publish { try domain.holdReset(remaining, reason: "reset_dispatch_unconfirmed") } == .cancelled)
        let cancelled = try #require(domain.agents.state.execution.resetIntents?[request.operationId.uuidString])
        #expect(cancelled.phase == .cancelled && cancelled.cancelledByStopId == manualStop.commandId)
        #expect(cancelled.stopAttempt == (writtenPhases > 0 ? .written : .notAttempted))
        #expect(cancelled.workspaceAttempt == (writtenPhases > 1 ? .written : .notAttempted))
        #expect(cancelled.holdReason == nil)
        #expect(domain.agents.state.execution.agents[agent]?.needsManual == nil)
        #expect(!domain.hasActiveReset(serverId: server, agentId: agent))
        let fresh = try await publish { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        #expect(fresh.commandId != intent.startCommandId && fresh.commandId != manualStop.commandId)
        #expect(domain.agents.state.execution.commands[intent.startCommandId.uuidString] == nil)
        #expect(domain.agents.state.execution.stopIntents?[manualStop.commandId.uuidString]?.clearedByHumanStart == fresh.commandId)
        #expect(try domain.resolveReset(remaining) == .cancelled)
        if writtenPhases > 0 { #expect(try domain.resolveReset(intent.reference(.stop)) == .settled) }
        if writtenPhases > 1 { #expect(try domain.resolveReset(intent.reference(.workspace)) == .settled) }
        let next = try await publish { try domain.requestReset(.init(serverId: server, agentId: agent, mode: .session)) }
        #expect(next.operationId != intent.operationId)
        try domain.agents.state.execution.validate()
    }

    @Test func laterStopCannotCancelAnAttemptedWorkspaceOrReleaseItsRecoveryGate() async throws {
        let (domain, server, machine, agent) = fixture()
        let context = try await ready(domain, server, machine)
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .full)
        _ = try await publish { try domain.requestReset(request) }
        let intent = try #require(domain.agents.state.execution.resetIntents?[request.operationId.uuidString])
        _ = try await publish { try domain.beginResetPhase(intent.reference(.stop), context: context) }
        try await publish { try domain.noteResetControlWritten(intent.reference(.stop), context: context) }
        _ = try await publish { try domain.beginResetPhase(intent.reference(.workspace), context: context) }
        _ = try await publish { try domain.requestStop(.init(serverId: server, agentId: agent)) }
        if case .hold = try await publish({ try domain.reconcileReset(intent.reference(.workspace)) }) {} else { Issue.record("Attempted workspace must remain HOLD") }
        #expect(try await publish { try domain.holdReset(intent.reference(.workspace), reason: "reset_dispatch_unconfirmed") } == .uncertain)
        #expect(domain.agents.state.execution.resetIntents?[request.operationId.uuidString]?.workspaceAttempt == .ambiguous)
        #expect(domain.agents.state.execution.resetIntents?[request.operationId.uuidString]?.cancelledByStopId == nil)
        await #expect(throws: AgentExecutionError.manualRecoveryRequired) {
            try await publish { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        }
    }

    @Test func resetStartReleasesHeldWorkUsingNewAttemptsAndKeepsTheOriginalReceipt() async throws {
        let (domain, server, machine, agent) = fixture()
        let context = try await ready(domain, server, machine)
        let first = try await publish { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        let stopped = try await publish { try domain.requestStop(.init(serverId: server, agentId: agent)) }
        let channel = domain.oauth.createChannel(serverId: server, name: "reset-messages", creatorUserId: "owner")
        domain.channels.addPostableChannel(serverId: server, channelId: channel, memberId: agent)
        let message = domain.oauth.createMessageRecord(channelId: channel, content: "Keep the original work", senderId: "owner")
        domain.messages.withState { $0.humanMessageRows.append(.init(id: message.id, channelId: channel,
            senderId: "owner", content: "Keep the original work", seq: $0.humanMessageRows.count + 1)) }
        let delivery = AgentExecutionDeliveryRequest(serverId: server, agentId: agent, channelId: channel, messageId: message.id)
        #expect(try await publish { try domain.requestDelivery(delivery) } == nil)
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .session)
        _ = try await publish { try domain.requestReset(request) }
        let intent = try #require(domain.agents.state.execution.resetIntents?[request.operationId.uuidString])
        _ = try await publish { try domain.beginResetPhase(intent.reference(.stop), context: context) }
        try await publish { try domain.noteResetControlWritten(intent.reference(.stop), context: context) }
        #expect(try await publish { try domain.stageResetRestart(intent.reference(.restart), context: context) })
        let held = try #require(domain.agents.state.execution.heldDeliveries?[delivery.commandId.uuidString])
        #expect(held.commandId == delivery.commandId && held.messageId == message.id)
        #expect(held.releasedCommandId != nil && held.releasedCommandId != held.commandId)
        #expect(domain.agents.state.execution.stopIntents?[stopped.commandId.uuidString]?.clearedByHumanStart == intent.startCommandId)
        #expect(domain.agents.state.execution.commands[first.commandId.uuidString] != nil)
        try domain.agents.state.execution.validate()
    }

    @Test func pendingResetBlocksTask84SafeAssignmentWithoutRetiringStopHistory() async throws {
        let (domain, server, machine, agent) = fixture()
        let stop = try await publish { try domain.requestStop(.init(serverId: server, agentId: agent)) }
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .full)
        _ = try await publish { try domain.requestReset(request) }
        let target = "reset-new-machine"
        domain.machines.machines.append(MachineRecord(id: target, serverId: server, userId: "owner", name: "New Computer", description: nil, apiKey: nil))
        let result = try await publish {
            domain.agents.assignMachineWithExecutionFence(serverId: server, agentId: agent, machineId: target, targetServerId: server)
        }
        #expect(result == .executionRequiresRecovery)
        let legacy = try await publish { domain.agents.assignMachine(agentId: agent, machineId: target) }
        #expect(!legacy)
        #expect(domain.agents.agentMachineIds[agent] == machine)
        #expect(domain.agents.state.execution.agents[agent]?.machineId == machine)
        #expect(domain.agents.state.execution.stopIntents?[stop.commandId.uuidString]?.retiredByAssignmentEpoch == nil)
    }

    @Test func lateOldLaunchSessionCannotUndoTheDurableSessionClear() async throws {
        let (domain, server, machine, agent) = fixture()
        let context = try await ready(domain, server, machine)
        let first = try await publish { try domain.requestStart(.init(serverId: server, agentId: agent, control: .humanStart)) }
        let initial = try JSONSerialization.data(withJSONObject: ["type": "agent:session", "agentId": agent,
            "launchId": first.launchId, "sessionId": "old-session"])
        #expect(try await publish { try domain.stageIngress(context: context, type: "agent:session", payload: initial) } == .committed(ack: nil))
        let request = AgentExecutionResetRequest(serverId: server, agentId: agent, mode: .session)
        _ = try await publish { try domain.requestReset(request) }
        let intent = try #require(domain.agents.state.execution.resetIntents?[request.operationId.uuidString])
        let late = try JSONSerialization.data(withJSONObject: ["type": "agent:session", "agentId": agent,
            "launchId": first.launchId, "sessionId": "late-session"])
        #expect(try await publish { try domain.stageIngress(context: context, type: "agent:session", payload: late) } == .hold(reason: "reset_session_fenced"))
        _ = try await publish { try domain.beginResetPhase(intent.reference(.stop), context: context) }
        try await publish { try domain.noteResetControlWritten(intent.reference(.stop), context: context) }
        _ = try await publish { try domain.stageIngress(context: context, type: "agent:session", payload: late) }
        #expect(domain.agents.state.execution.agents[agent]?.sessionId == nil)
    }

    private struct PublicFixture: Sendable {
        let accounts: EmailLoginDirectory
        let domain: AgentExecutionDomain
        let controls: AgentMachineMigrationControlService
        let server: String
        let agent: String
        let source: String
        let target: String
        let authorization: String
    }

    private func publicFixture() throws -> PublicFixture {
        let accounts = EmailLoginDirectory()
        let owner = UUID().uuidString.lowercased(), server = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased(), target = UUID().uuidString.lowercased()
        accounts.addAccount(id: owner, email: "reset-migration@slock.test", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "reset-migration", name: "Reset Migration", ownerId: owner)
        let agent = accounts.oauth.createAgent(serverId: server, name: "Reset executor", creatorUserId: owner, runtime: "codex")
        accounts.machinesAndComputersStore.machines = [source, target].map {
            MachineRecord(id: $0, serverId: server, userId: owner, name: "Computer", description: nil, apiKey: nil, runtimes: ["codex"])
        }
        accounts.machinesAndComputersStore.machineOnline = [source: true, target: true]
        accounts.enableHostedMigrationForTesting(serverId: server)
        accounts.enableHostedRuntimeForTesting(serverId: server)
        let authorization = "Bearer \(accounts.mintAccessTokenForTesting(userId: owner))"
        _ = try accounts.agentHostedMigration.assignAgentMachine(authorization: authorization, agentId: agent, request: .init(machineId: .machine(source)))
        let domain = AgentExecutionDomain(agents: accounts.agentsRuntimeStore, machines: accounts.machinesAndComputersStore,
            oauth: accounts.oauth, channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        let execution = AgentExecutionService(producerTransactionAgents: accounts.agentsRuntimeStore,
            machines: accounts.machinesAndComputersStore, oauth: accounts.oauth,
            channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        return .init(accounts: accounts, domain: domain, controls: accounts.agentMachineMigrationControl.bindingExecution(execution),
            server: server, agent: agent, source: source, target: target, authorization: authorization)
    }

    @Test(arguments: [false, true])
    func publicResetRefusesMachineAndHostedMigrationWithoutPublishingALease(hosted: Bool) async throws {
        for permitAlreadyIssued in [false, true] {
            let f = try publicFixture()
            _ = try await publish { try f.controls.resetAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server, request: .init(mode: "full")) }
            let intent = try #require(f.domain.agents.state.execution.resetIntents?.values.first)
            if permitAlreadyIssued {
                let context = try await ready(f.domain, f.server, f.source)
                _ = try await publish { try f.domain.beginResetPhase(intent.reference(.stop), context: context) }
                try await publish { try f.domain.noteResetControlWritten(intent.reference(.stop), context: context) }
                _ = try await publish { try f.domain.beginResetPhase(intent.reference(.workspace), context: context) }
                try await publish { try f.domain.validateResetWrite(intent.reference(.workspace), context: context) }
            }
            let migrate = AgentMigrateRequest(hostedTarget: hosted ? .init() : nil, targetComputer: hosted ? nil : f.target)
            await #expect(throws: AgentMigrationControlError.resetInProgress) {
                try await publish { try f.controls.migrateAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server, request: migrate) }
            }
            #expect(AgentMigrationControlError.resetInProgress.status == 409)
            #expect(AgentMigrationControlError.resetInProgress.publishedErrorBody.render().contains("agent_reset_in_progress"))
            #expect(f.domain.agents.agentMachineIds[f.agent] == f.source)
            #expect(f.domain.agents.state.machineMigrations.isEmpty && f.domain.agents.state.hostedMigrations.isEmpty)
            #expect(f.domain.agents.state.execution.resetIntents?[intent.operationId.uuidString]?.phase == (permitAlreadyIssued ? .workspace : .stop))
            let machineRow = MachineMigrationRecord(agentId: f.agent, serverId: f.server, supportRef: "blocked-machine", revision: 1,
                state: "provisioning", sourceMachineId: f.source, targetMachineId: f.target, transportGeneration: "blocked-generation")
            #expect(try await publish { f.domain.agents.insertMachineMigrationIfIdle(machineRow) } == false)
            #expect(try await publish { f.domain.agents.insertHostedMigrationIfIdle(.init(agentId: f.agent, serverId: f.server,
                supportRef: "blocked-hosted", revision: 1, state: "preparing", sourceMachineId: f.source)) } == false)
            #expect(f.domain.agents.state.machineMigrations.isEmpty && f.domain.agents.state.hostedMigrations.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func publicMachineAndHostedMigrationRefuseLaterResetWithoutChangingTheirRecord(hosted: Bool) async throws {
        let f = try publicFixture()
        let migrate = AgentMigrateRequest(hostedTarget: hosted ? .init() : nil, targetComputer: hosted ? nil : f.target)
        let started = try await publish { try f.controls.migrateAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server, request: migrate) }
        switch started {
        case .hosted: #expect(f.domain.agents.state.hostedMigrations[f.agent]?.state == "preparing")
        case .computer: #expect(f.domain.agents.state.machineMigrations.values.first?.state == "provisioning")
        case .accepted: Issue.record("A concrete migration target must create its actual record")
        }
        let machineRefs = Set(f.domain.agents.state.machineMigrations.keys)
        let hostedRef = f.domain.agents.state.hostedMigrations[f.agent]?.supportRef
        await #expect(throws: AgentMigrationControlError.resetMigrationInProgress) {
            try await publish { try f.controls.resetAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server, request: .init(mode: "full")) }
        }
        #expect(AgentMigrationControlError.resetMigrationInProgress.status == 409)
        #expect(Set(f.domain.agents.state.machineMigrations.keys) == machineRefs)
        #expect(f.domain.agents.state.hostedMigrations[f.agent]?.supportRef == hostedRef)
        #expect(f.domain.agents.agentMachineIds[f.agent] == f.source)
        #expect(f.domain.agents.state.execution.resetIntents?.isEmpty ?? true)
    }

    @Test func publicManualStopRevokesPendingResetAndFreshPublicStartResumes() async throws {
        let f = try publicFixture()
        _ = try await ready(f.domain, f.server, f.source)
        _ = try await publish { try f.controls.resetAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server, request: .init(mode: "full")) }
        let intent = try #require(f.domain.agents.state.execution.resetIntents?.values.first)
        _ = try await publish { try f.controls.stopAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server) }
        let stop = try #require(f.domain.agents.state.execution.stopIntents?.values.first)
        #expect(try await publish { try f.domain.reconcileReset(intent.reference(.stop)) } == .cancelled)
        _ = try await publish { try f.accounts.agentHostedMigration.assignAgentMachine(authorization: f.authorization, agentId: f.agent,
            request: .init(machineId: .machine(f.source))) }
        _ = try await publish { try f.controls.startAgent(authorization: f.authorization, agentId: f.agent, serverId: f.server) }
        let fresh = try #require(f.domain.agents.state.execution.commands.values.first { $0.kind == .start })
        #expect(fresh.commandId != intent.startCommandId && fresh.commandId != stop.commandId)
        #expect(f.domain.agents.state.execution.stopIntents?[stop.commandId.uuidString]?.clearedByHumanStart == fresh.commandId)
        #expect(try f.domain.resolveReset(intent.reference(.stop)) == .cancelled)
        #expect(f.domain.agents.state.execution.agents[f.agent]?.needsManual == nil)
    }

    @Test func preResetSnapshotsDoNotNeedTheNewOptionalDictionary() throws {
        let old = Data(#"{"connections":{},"agents":{},"commands":{},"receipts":{},"watermarks":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentExecutionState.self, from: old)
        #expect(decoded.resetIntents == nil)
        try decoded.validate()
    }
}

