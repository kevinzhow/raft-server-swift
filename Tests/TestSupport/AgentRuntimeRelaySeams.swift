// Agent and machine relay installations used by the HTTP fixtures.
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func installAgentStartDispatchForTesting(_ handler: (@Sendable (_ agentId: String, _ resumePrompt: String?) async throws -> AgentStartDispatchOutcome)?) {
        agentsRuntimeStore.agentStartDispatch = handler
    }

    public func installAgentSkillsProviderForTesting(_ handler: (@Sendable (_ agentId: String) -> AgentSurfaceResult)?) {
        agentsRuntimeStore.agentSkillsProvider = handler
    }

    public func installAgentHasMachineLocallyForTesting(_ handler: (@Sendable (_ agentId: String) -> Bool)?) {
        agentsRuntimeStore.agentHasMachineLocally = handler
    }

    public func installAgentActivityLogProviderForTesting(_ handler: (@Sendable (_ agentId: String, _ limit: Int?) -> AgentSurfaceResult)?) {
        agentsRuntimeStore.agentActivityLogProvider = handler
    }

    public func installAgentActivitySummariesProviderForTesting(_ handler: (@Sendable (_ agentId: String, _ limit: Int, _ beforeEndedAt: Int?, _ beforeId: String?) -> AgentSurfaceResult)?) {
        agentsRuntimeStore.agentActivitySummariesProvider = handler
    }

    public func installAgentWorkspaceTreeProviderForTesting(_ handler: (@Sendable (_ agentId: String, _ dirPath: String?, _ includeHidden: Bool) -> AgentSurfaceResult)?) {
        agentsRuntimeStore.agentWorkspaceTreeProvider = handler
    }

    public func installAgentWorkspaceReadProviderForTesting(_ handler: (@Sendable (_ agentId: String, _ path: String?) -> AgentSurfaceResult)?) {
        agentsRuntimeStore.agentWorkspaceReadProvider = handler
    }

    public func installAgentStartControlDispatchForTesting(_ handler: (@Sendable (_ agentId: String, _ control: String) -> Void)?) {
        agentsRuntimeStore.agentStartControlDispatch = handler
    }

    public func installAgentResetDispatchForTesting(_ handler: (@Sendable (_ agentId: String, _ mode: String, _ terminalControl: String) -> Void)?) {
        agentsRuntimeStore.agentResetDispatch = handler
    }

    public func installAgentConfigLiftDispatchForTesting(_ handler: (@Sendable (_ agentId: String, _ runtimeValuesChanged: Bool) -> Void)?) {
        agentsRuntimeStore.agentConfigLiftDispatch = handler
    }

    public func installMachineMigrationArchiveSourceWorkspaceForTesting(_ handler: (@Sendable (_ machineId: String, _ migrationRef: String, _ agentId: String) async throws -> Void)?) {
        machinesAndComputersStore.machineMigrationArchiveSourceWorkspace = handler
    }

    public func installMachineMigrationStartAgentForTesting(_ handler: (@Sendable (_ agentId: String) async throws -> MachineMigrationAgentStartOutcome)?) {
        machinesAndComputersStore.machineMigrationStartAgent = handler
    }

    public func installBuiltinModelCatalogCheckForTesting(_ handler: (@Sendable (_ machineId: String, _ modelId: String) -> BuiltinModelCatalogResult)?) {
        machinesAndComputersStore.builtinModelCatalogCheck = handler
    }

    public func installMachineMigrationProvisionerForTesting(_ handler: (@Sendable (_ sourceMachineId: String, _ targetMachineId: String) -> String?)?) {
        machinesAndComputersStore.machineMigrationProvisioner = handler
    }

    public func installAgentRuntimeModelsForMachineForTesting(_ handler: (@Sendable (_ machineId: String, _ runtime: String) -> [String]?)?) {
        machinesAndComputersStore.agentRuntimeModelsForMachine = handler
    }

    public func installMachineMigrationLeaseDispatchForTesting(_ handler: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String) -> Void)?) {
        machinesAndComputersStore.machineMigrationLeaseDispatch = handler
    }

    public func installMachineRoutedLocallyForTesting(_ handler: (@Sendable (_ machineId: String) -> Bool)?) {
        machinesAndComputersStore.machineRoutedLocally = handler
    }

    public func setMachineRuntimeDetectionForTesting(machineId: String, status: String?) {
        if let status {
            machinesAndComputersStore.machineRuntimeDetections[machineId] = (status: status, unfinished: [])
        } else {
            machinesAndComputersStore.machineRuntimeDetections.removeValue(forKey: machineId)
        }
    }

    public func setMigrationServerPlanForTesting(serverId: String, plan: String?) {
        serversAndChannelsStore.serverPlans[serverId] = plan
    }
}
