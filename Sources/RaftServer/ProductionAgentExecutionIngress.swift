import Foundation
import RaftHTTP
import RaftPersistence
import RaftMachineSocket

/// The registry consumes only post-COMMIT descriptors from the retained HTTP
/// execution service. It keeps its own connection fence before relaying an ACK.
struct ProductionAgentExecutionIngress: Sendable {
    /// Upstream `MACHINE_DISCONNECT_PROJECTION_GRACE_MS`: a reconnect inside the
    /// window cancels the offline agent activity projection, so a transport
    /// flap does not transiently mark every active agent offline.
    static let disconnectProjectionGraceMilliseconds = 2000

    let execution: AgentExecutionService
    /// The same fenced writer; used only for the best-effort briefing retry
    /// after a ready frame has already committed. A briefing failure can never
    /// fail the machine's return.
    var runtime: BusinessPersistenceRuntime? = nil
    var onboardingBriefing: OnboardingBriefingService? = nil

    var callbacks: MachineDurableIngress {
        MachineDurableIngress(
            onOpened: { context in try await self.execution.connectionOpened(Self.context(context)) },
            onMessage: { context, message in try await self.receive(context, message: message) },
            onClosed: { context in
                let owner = Self.context(context)
                try await self.execution.connectionClosed(owner)
                // The socket loss is committed immediately; the activity
                // projection is scheduled after the grace window and becomes a
                // no-op if this epoch is no longer the machine's connection.
                let execution = self.execution
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(Self.disconnectProjectionGraceMilliseconds))
                    try? await execution.projectMachineDisconnect(owner)
                }
            }
        )
    }

    func receive(_ context: MachineIngressContext, message: MachineIngressMessage) async throws -> MachineIngressCommitResult {
        let owner = Self.context(context)
        if message.type == "ready" {
            let ready = message.ready
            let inventory: MachineRuntimeInventoryReport?
            if ready != nil { inventory = try JSONDecoder().decode(MachineRuntimeInventoryReport.self, from: message.payload) }
            else { inventory = nil }
            try await execution.observeReady(
                owner, daemonInstanceId: ready?.daemonInstanceId, capabilities: ready?.capabilities,
                runtimes: ready?.runtimes, runningAgentIds: ready?.runningAgents,
                detectionComplete: ready != nil && (ready?.runtimeDetection == nil || ready?.runtimeDetection?.status == .complete),
                unreliableAgentIds: ready?.runtimeOutcomeUnreliableAgents ?? [],
                inventory: inventory
            )
            // Even a partial inventory first invalidates prior readiness in the
            // same owner transaction. It is never replaced by invented fields.
            if ready != nil, let runtime, let onboardingBriefing {
                // The machine:online analogue is fire-and-forget AFTER the
                // readiness commit, in its own transaction: owner facts first,
                // then the idempotent opener trigger. Upstream explicitly never
                // lets this listener fail the reconnect. A detached task keeps
                // the registry's ready callback free and cannot inherit a
                // request's transaction task-locals.
                let serverId = context.serverId
                Task.detached {
                    try? await runtime.execute {
                        onboardingBriefing.connectionReady(serverId: serverId)
                    }
                }
            }
            return ready == nil ? .hold(reason: "malformed_ready") : .committed(ack: nil)
        }
        if message.type == "machine:runtime_models:catalog" {
            try await execution.observeRuntimeModelCatalog(owner, payload: message.payload)
            return .committed(ack: nil)
        }
        if ["machine:runtime_models:result", "agent:workspace:file_tree", "agent:workspace:file_content", "machine:workspace:scan_result"].contains(message.type) {
            try execution.validateMachineQueryContext(owner)
            return .committed(ack: nil)
        }
        return Self.map(try await execution.consume(context: owner, type: message.type, payload: message.payload))
    }

    static func context(_ context: MachineIngressContext) -> AgentExecutionMachineContext {
        .init(machineId: context.machineId, serverId: context.serverId, connectionEpochId: context.connectionEpochId)
    }

    static func map(_ result: AgentExecutionIngressResult) -> MachineIngressCommitResult {
        switch result {
        case .hold(let reason): return .hold(reason: reason)
        case .committed(nil): return .committed(ack: nil)
        case .committed(.some(.sequence(let agentId, let daemon, let sequence))):
            return .committed(ack: .sequence(agentId: agentId, daemonInstanceId: daemon, clientSeq: sequence))
        case .committed(.some(.marker(let agentId, let gapId))):
            return .committed(ack: .marker(agentId: agentId, gapId: gapId))
        }
    }
}
