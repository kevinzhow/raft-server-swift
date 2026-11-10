import RaftHTTP
import RaftMachineSocket

/// Provider execution belongs to raft-computer. Production activation requires
/// the durable domain, real materializer, kind-filtered worker and typed registry
/// together. A registry alone cannot satisfy the production startup gate.
enum ProductionDaemonIntegration {
    /// Retired registry-only bootstrap. Callers must connect the complete graph
    /// after the fenced runtime is active; a bare registry cannot execute work.
    static func makeRegistry(
        execution: AgentExecutionService, runtime: BusinessPersistenceRuntime
    ) throws -> MachineCommandRegistry {
        throw ProductionStartupError.agentExecutionNotConnected
    }

    /// Explicit complete-graph construction for the composition owner. There is
    /// no optional/noop materializer, Directory bridge or environment bypass.
    static func connect(
        execution: AgentExecutionService, runtime: BusinessPersistenceRuntime,
        materializer: AgentExecutionMaterializationService
    ) throws -> ProductionAgentExecutionConnection {
        guard runtime.readinessSnapshot.isReady else { throw ProductionStartupError.unavailable }
        let ingress = ProductionAgentExecutionIngress(execution: execution)
        let registry = MachineCommandRegistry(durableIngress: ingress.callbacks)
        let worker = try ProductionAgentExecutionWorker(runtime: runtime, execution: execution,
                                                       materializer: materializer, registry: registry)
        return ProductionAgentExecutionConnection(registry: registry, worker: worker)
    }
}

struct ProductionAgentExecutionConnection: Sendable {
    let registry: MachineCommandRegistry
    let worker: ProductionAgentExecutionWorker

    func stop() async {
        await worker.stop()
        await registry.close()
    }
}
