import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/MachinesAndHostedRuntimeService.swift.

extension EmailLoginDirectory {

    public func setMachineDescriptionForTesting(machineId: String, description: String?) {
        machinesAndComputersStore.storage.withLock { storeState in
            if let index = storeState.machines.firstIndex(where: { $0.id == machineId }) {
                storeState.machines[index].description = description
            }
        }
    }

    public func machineDescriptionForTesting(machineId: String) -> String? {
        return machinesAndComputersStore.storage.withLock { storeState in
            return storeState.machines.first { $0.id == machineId }?.description
        }
    }

    public func setMachineRuntimesForTesting(machineId: String, runtimes: [String]) {
        machinesAndComputersStore.storage.withLock { storeState in
            if let index = storeState.machines.firstIndex(where: { $0.id == machineId }) {
                storeState.machines[index].runtimes = runtimes
            }
        }
    }

    public func setHostedUsageForTesting(agentId: String, json: String) {
        agentsRuntimeStore.withState { storeState in
            storeState.hostedUsage[agentId] = json
        }
    }

    public func setHostedRuntimeForTesting(
        agentId: String,
        provider: String = "openai",
        model: String? = nil,
        state: String = "active",
        retryNeedsModel: Bool = false
    ) {
        agentsRuntimeStore.withState { storeState in
            storeState.hostedRuntimes[agentId] = (provider, model, state, retryNeedsModel, Date())
        }
    }

    public func hostedRuntimeStateForTesting(agentId: String) -> String? {
        return agentsRuntimeStore.withState { storeState in
            return storeState.hostedRuntimes[agentId]?.state
        }
    }

    public func setHostedRuntimeStateForTesting(
        agentId: String,
        state: String,
        retryNeedsModel: Bool = false
    ) {
        agentsRuntimeStore.withState { storeState in
            if let existing = storeState.hostedRuntimes[agentId] {
                storeState.hostedRuntimes[agentId] = (existing.provider, existing.model, state, retryNeedsModel, existing.createdAt)
            } else {
                storeState.hostedRuntimes[agentId] = ("antiproton", nil, state, retryNeedsModel, Date())
            }
        }
    }

    public func setHostedModelForTesting(
        agentId: String,
        models: [(id: String, label: String, provider: String)] = [
            ("deepseek-flash", "DeepSeek Flash", "deepseek"),
            ("gpt-5.6-luna", "GPT-5.6 Luna", "openai"),
        ],
        defaultModel: String? = "deepseek-flash",
        defaultLabel: String? = "DeepSeek Flash",
        model: String? = "deepseek-flash",
        label: String? = "DeepSeek Flash",
        source: String = "default",
        locked: Bool = false
    ) {
        agentsRuntimeStore.withState { storeState in
            storeState.hostedModels[agentId] = HostedModelState(
                models: models,
                defaultModel: defaultModel,
                defaultLabel: defaultLabel,
                model: model,
                label: label,
                source: source,
                locked: locked
            )
        }
    }

    public func setAgentConnectionOriginForTesting(origin: String) {
        agentsRuntimeStore.withState { storeState in
            storeState.agentConnectionOrigin = origin
        }
    }
}
