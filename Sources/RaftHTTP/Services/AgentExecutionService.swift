import Foundation
import RaftShared

public enum AgentExecutionDispatchAdmission: Sendable, Equatable {
    case granted
    case alreadyAccepted
    case uncertain
}

public enum AgentExecutionDispatchResolution: Sendable, Equatable {
    case ready(AgentExecutionCommand)
    case wait(reason: String)
    case obsolete
}

/// Production execution uses the same retained owners and the existing fenced
/// coordinator. No initializer allocates another graph or installs a fake runner.
public struct AgentExecutionService: Sendable {
    private let domain: AgentExecutionDomain
    private let persistence: BusinessPersistenceRuntime?

    init(agents: AgentsRuntimeStore, machines: MachinesAndComputersStore,
         oauth: OAuthLedger, channels: ServersAndChannelsStore, messages: MessagesAndThreadsStore,
         persistence: BusinessPersistenceRuntime) {
        self.domain = AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth, channels: channels, messages: messages)
        self.persistence = persistence
    }

    /// Internal fixture binding: only synchronous producer staging is available.
    /// The caller supplies the real owners and a real Shared transaction. This
    /// mode cannot ingest/authorize ACK, update connections, read committed state,
    /// or resolve dispatch; the production initializer still requires runtime.
    init(producerTransactionAgents agents: AgentsRuntimeStore, machines: MachinesAndComputersStore,
         oauth: OAuthLedger, channels: ServersAndChannelsStore, messages: MessagesAndThreadsStore) {
        self.domain = AgentExecutionDomain(agents: agents, machines: machines, oauth: oauth, channels: channels, messages: messages)
        self.persistence = nil
    }

    private func requirePersistence() throws -> BusinessPersistenceRuntime {
        guard let persistence else { throw AgentExecutionError.durableTransactionRequired }
        return persistence
    }

    public func requestStart(_ request: AgentExecutionStartRequest) throws -> AgentExecutionAdmission {
        do { return try domain.requestStart(request) }
        catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    public func requestAutomaticStartIfReady(_ request: AgentExecutionStartRequest) throws -> AgentExecutionAdmission? {
        do { return try domain.requestAutomaticStartIfReady(request) }
        catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    /// nil means the delivery is durably held behind manual stop. The enclosing
    /// canonical message/task transaction remains valid and may commit.
    public func requestDelivery(_ request: AgentExecutionDeliveryRequest) throws -> AgentExecutionAdmission? {
        do { return try domain.requestDelivery(request) }
        catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    func requestHumanMessageDelivery(_ request: AgentExecutionDeliveryRequest) throws -> HumanMessageExecutionDisposition {
        do { return try domain.requestHumanMessageDelivery(request) }
        catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    public func requestStop(_ request: AgentExecutionStopRequest) throws -> AgentExecutionStopAdmission {
        do { return try domain.requestStop(request) }
        catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    /// Stage only in the enclosing durable transaction, as Start/Stop do.
    /// Production HTTP supplies this facade only through its retained BPR;
    /// producer-only unit bindings cannot read/authorize or send any control.
    public func requestReset(_ request: AgentExecutionResetRequest) throws -> AgentExecutionResetAdmission {
        do { return try domain.requestReset(request) }
        catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    /// The accepted config write and terminal lift share the caller's real BPR
    /// transaction. This stages no ready state, launch or transport command.
    public func liftTerminalForConfigChange(serverId: String, agentId: String, runtimeValuesChanged: Bool) throws {
        do { try domain.liftTerminalForConfigChange(serverId: serverId, agentId: agentId, runtimeValuesChanged: runtimeValuesChanged) }
        catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    /// Accepted canonical writes, config lift and optional settings reset share
    /// the enclosing retained BPR. No transport runs before that commit.
    public func applyRuntimeConfigurationChange(serverId: String, agentId: String,
                                                runtimeValuesChanged: Bool,
                                                restartMode: AgentExecutionResetMode?) throws {
        do {
            try domain.applyRuntimeConfigurationChange(serverId: serverId, agentId: agentId,
                runtimeValuesChanged: runtimeValuesChanged, restartMode: restartMode)
        } catch { DeferredEffects.markRollbackOnly(); throw error }
    }

    public func resolveReset(reference: AgentExecutionResetReference) throws -> AgentExecutionResetResolution {
        try requirePersistence().withCommittedReadView { try self.domain.resolveReset(reference) }
    }

    private func resetTransaction<Value: Sendable>(_ operation: @escaping @Sendable (AgentExecutionDomain) throws -> Value) async throws -> Value {
        try await requirePersistence().execute {
            do { return try operation(self.domain) }
            catch { DeferredEffects.markRollbackOnly(); throw error }
        }
    }

    public func reconcileReset(reference: AgentExecutionResetReference) async throws -> AgentExecutionResetResolution {
        try await resetTransaction { try $0.reconcileReset(reference) }
    }
    public func beginResetPhase(reference: AgentExecutionResetReference, context: AgentExecutionMachineContext) async throws -> AgentExecutionResetDispatchAdmission {
        try await resetTransaction { try $0.beginResetPhase(reference, context: context) }
    }
    public func validateResetWrite(reference: AgentExecutionResetReference, context: AgentExecutionMachineContext) async throws {
        try await resetTransaction { try $0.validateResetWrite(reference, context: context) }
    }
    public func noteResetControlWritten(reference: AgentExecutionResetReference, context: AgentExecutionMachineContext) async throws {
        try await resetTransaction { try $0.noteResetControlWritten(reference, context: context) }
    }
    public func noteResetAmbiguous(reference: AgentExecutionResetReference) async throws -> AgentExecutionResetDispatchAdmission {
        try await resetTransaction { try $0.holdReset(reference, reason: "reset_dispatch_unconfirmed") }
    }
    public func stageResetRestart(reference: AgentExecutionResetReference, context: AgentExecutionMachineContext) async throws -> Bool {
        try await resetTransaction { try $0.stageResetRestart(reference, context: context) }
    }

    private func requireMachineQueryContext(_ context: AgentExecutionMachineContext) throws {
        guard domain.ownsMachine(context), let connection = domain.agents.state.execution.connections[context.machineId],
              connection.online, connection.serverId == context.serverId,
              connection.connectionEpochId == context.connectionEpochId else { throw AgentExecutionError.staleConnection }
    }

    /// Query replies have no durable-outcome ACK contract and mutate no state.
    /// The authorized ingress callback still checks the committed business owner.
    public func validateMachineQueryContext(_ context: AgentExecutionMachineContext) throws {
        try requirePersistence().withCommittedReadView { try self.requireMachineQueryContext(context) }
    }

    public func observeRuntimeModelCatalog(_ context: AgentExecutionMachineContext, payload: Data) async throws {
        struct Catalog: Decodable { let runtime: String; let models: [MachineRuntimeModelSource.Model] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
        guard !catalog.runtime.isEmpty else { throw MachineQueryError.invalidReply }
        try await requirePersistence().execute {
            try self.requireMachineQueryContext(context)
            self.domain.machines.recordRuntimeModelCatalog(machineId: context.machineId, runtime: catalog.runtime,
                models: catalog.models, observedAt: Date())
        }
    }

    public func connectionOpened(_ context: AgentExecutionMachineContext) async throws {
        try await requirePersistence().execute { try self.domain.connectionOpened(context) }
    }

    public func observeReady(_ context: AgentExecutionMachineContext, daemonInstanceId: String?, capabilities: [String]?,
                             runtimes: [String]?, runningAgentIds: [String]?, detectionComplete: Bool,
                             unreliableAgentIds: [String], inventory: MachineRuntimeInventoryReport? = nil) async throws {
        try await requirePersistence().execute {
            try self.domain.observeReady(context, daemonInstanceId: daemonInstanceId, capabilities: capabilities,
                                         runtimes: runtimes, runningAgentIds: runningAgentIds,
                                         detectionComplete: detectionComplete, unreliableAgentIds: unreliableAgentIds)
            if let inventory {
                self.domain.machines.recordReadyInventory(machineId: context.machineId, serverId: context.serverId,
                                                          report: inventory, observedAt: Date())
                if let machine = self.domain.machines.machine(id: context.machineId, serverId: context.serverId) {
                    let relay = RealtimeRelayService(messages: self.domain.messages)
                    let payload = inventory.event(machine: machine)
                    DeferredEffects.emit { relay.emit("server:\(context.serverId)", "machine:capabilities", payload) }
                }
            }
        }
    }

    public func connectionReady(_ context: AgentExecutionMachineContext, daemonInstanceId: String,
                                runtimes: [String], runningAgentIds: [String], detectionComplete: Bool) async throws {
        try await requirePersistence().execute {
            try self.domain.connectionReady(context, daemonInstanceId: daemonInstanceId, runtimes: runtimes,
                                            runningAgentIds: runningAgentIds, detectionComplete: detectionComplete)
        }
    }

    public func connectionClosed(_ context: AgentExecutionMachineContext) async throws {
        try await requirePersistence().execute { try self.domain.connectionClosed(context) }
    }

    /// The pending decision cannot escape this method before the atomic owner /
    /// watermark / receipt commit. Failed SQL/CAS/admission throws and authorizes
    /// no ACK, so the daemon keeps its durable evidence for a later connection.
    public func consume(context: AgentExecutionMachineContext, type: String, payload: Data) async throws -> AgentExecutionIngressResult {
        try await requirePersistence().execute {
            try self.domain.stageIngress(context: context, type: type, payload: payload)
        }
    }

    /// Worker/audit access only. This value contains confidential command input
    /// such as resumePrompt/sessionId; do not publish or log the entire DTO.
    public func command(reference: AgentExecutionIntentReference) throws -> AgentExecutionCommand? {
        try requirePersistence().withCommittedReadView { self.domain.agents.state.execution.commands[reference.commandId.uuidString] }
    }

    /// Resolve after claiming the durable outbox. The transport must fence the
    /// returned epoch again at the actual socket write. A retry reuses all ids.
    public func resolveDispatch(reference: AgentExecutionIntentReference) throws -> AgentExecutionDispatchResolution {
        try requirePersistence().withCommittedReadView { self.domain.resolveDispatch(reference: reference) }
    }

    /// Commits an attempt before the socket write. Reclaiming an unconfirmed
    /// attempt cannot authorize another write, even with the same stable ids.
    public func beginDispatch(reference: AgentExecutionIntentReference, context: AgentExecutionMachineContext,
                              deliverySequence: Int64? = nil) async throws -> AgentExecutionDispatchAdmission {
        try await requirePersistence().execute {
            try self.domain.beginDispatch(reference: reference, context: context, deliverySequence: deliverySequence)
        }
    }

    /// A transport failure after the attempt is ambiguous unless the durable
    /// inbox already contains the matching admission. Never infer completion.
    public func noteAmbiguousDispatch(reference: AgentExecutionIntentReference, context: AgentExecutionMachineContext) async throws -> AgentExecutionDispatchAdmission {
        try await requirePersistence().execute { try self.domain.noteAmbiguousDispatch(reference: reference, context: context) }
    }

    /// A successful socket write is only dispatch, never a runtime receipt.
    public func noteDispatched(reference: AgentExecutionIntentReference, context: AgentExecutionMachineContext) async throws {
        try await requirePersistence().execute {
            try self.domain.requireTransaction()
            try self.domain.mutate { state in
                guard var command = state.commands[reference.commandId.uuidString], command.machineId == context.machineId,
                      command.serverId == context.serverId,
                      let connection = state.connections[context.machineId], connection.online,
                      connection.serverId == context.serverId, connection.connectionEpochId == context.connectionEpochId,
                      command.kind == .stop || command.connectionEpochId == context.connectionEpochId,
                      state.dispatches?[reference.commandId.uuidString]?.connectionEpochId == context.connectionEpochId else {
                    throw AgentExecutionError.staleConnection
                }
                if command.status == .pending { command.status = .dispatched }
                state.commands[reference.commandId.uuidString] = command
                if var dispatches = state.dispatches, var dispatch = dispatches[reference.commandId.uuidString] {
                    if dispatch.phase != .accepted { dispatch.phase = .written }
                    dispatches[reference.commandId.uuidString] = dispatch
                    state.dispatches = dispatches
                }
            }
        }
    }
}

extension AgentExecutionDomain {
    func beginDispatch(reference: AgentExecutionIntentReference, context: AgentExecutionMachineContext,
                       deliverySequence: Int64?) throws -> AgentExecutionDispatchAdmission {
        try requireTransaction()
        guard let command = agents.state.execution.commands[reference.commandId.uuidString],
              command.machineId == context.machineId, command.serverId == context.serverId,
              (try? boundMachine(serverId: command.serverId, agentId: command.agentId)) == context.machineId else {
            throw AgentExecutionError.ownershipMismatch
        }
        if command.kind == .delivery {
            guard let sequence = deliverySequence, sequence >= 0, sequence <= 9_007_199_254_740_991,
                  let channelId = command.channelId, let messageId = command.messageId,
                  deliveryIsAuthorized(serverId: command.serverId, agentId: command.agentId, channelId: channelId, messageId: messageId),
                  messages.deliveryAckMessageSnapshot().rows.first(where: { $0.id == messageId }).map({ Int64($0.seq) }) == sequence else {
                throw AgentExecutionError.invalidRequest
            }
        } else if deliverySequence != nil { throw AgentExecutionError.invalidRequest }
        let stopped = manuallyStopped(serverId: command.serverId, agentId: command.agentId)
        return try mutate { state in
            guard let connection = state.connections[context.machineId], connection.online,
                  connection.serverId == context.serverId, connection.connectionEpochId == context.connectionEpochId,
                  command.kind == .stop || command.connectionEpochId == context.connectionEpochId,
                  var agent = state.agents[command.agentId] else { throw AgentExecutionError.staleConnection }
            guard agent.currentLaunchId == nil && command.kind == .stop || agent.currentLaunchId == command.launchId,
                  agent.generation == command.breakerGeneration, agent.takeoverEpoch == command.takeoverEpoch,
                  command.status != .superseded else { throw AgentExecutionError.conflictingCommand }
            if command.status == .accepted || command.kind == .stop && command.status == .dispatched { return .alreadyAccepted }
            if let previous = state.dispatches?[reference.commandId.uuidString] {
                if previous.phase == .accepted { return .alreadyAccepted }
                agent.needsManual = "dispatch_outcome_unknown"
                state.agents[command.agentId] = agent
                return .uncertain
            }
            if command.kind != .stop {
                guard !stopped else { throw AgentExecutionError.manuallyStopped }
                guard connection.ready, connection.runtimes.contains("codex"), agent.needsManual == nil,
                      let launch = agent.launches[command.launchId], !launch.stopRequested,
                      !launch.notSpawned, command.kind != .start || !launch.completed,
                      command.kind != .delivery || launch.startAccepted || launch.processInstanceId != nil else {
                    throw AgentExecutionError.manualRecoveryRequired
                }
            }
            var dispatches = state.dispatches ?? [:]
            dispatches[reference.commandId.uuidString] = AgentExecutionDispatch(connectionEpochId: context.connectionEpochId,
                                                                                deliverySequence: deliverySequence, phase: .attempting)
            state.dispatches = dispatches
            return .granted
        }
    }

    func noteAmbiguousDispatch(reference: AgentExecutionIntentReference, context: AgentExecutionMachineContext) throws -> AgentExecutionDispatchAdmission {
        try requireTransaction()
        return try mutate { state in
            guard let command = state.commands[reference.commandId.uuidString], command.machineId == context.machineId,
                  command.serverId == context.serverId, var dispatches = state.dispatches,
                  var dispatch = dispatches[reference.commandId.uuidString], dispatch.connectionEpochId == context.connectionEpochId else {
                throw AgentExecutionError.staleConnection
            }
            if command.status == .accepted || command.kind == .stop && command.status == .dispatched || dispatch.phase == .accepted { return .alreadyAccepted }
            dispatch.phase = .ambiguous
            dispatches[reference.commandId.uuidString] = dispatch
            state.dispatches = dispatches
            if state.agents[command.agentId]?.currentLaunchId == command.launchId,
               state.agents[command.agentId]?.generation == command.breakerGeneration {
                state.agents[command.agentId]?.needsManual = "dispatch_outcome_unknown"
            }
            return .uncertain
        }
    }
}
