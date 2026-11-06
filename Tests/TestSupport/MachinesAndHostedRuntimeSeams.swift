import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/MachinesAndHostedRuntimeService.swift.

extension EmailLoginDirectory {

    public func setMachineDescriptionForTesting(machineId: String, description: String?) {
        lock.lock()
        if let index = machines.firstIndex(where: { $0.id == machineId }) {
            machines[index].description = description
        }
        lock.unlock()
    }

    public func machineDescriptionForTesting(machineId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return machines.first { $0.id == machineId }?.description
    }

    public func setMachineRuntimesForTesting(machineId: String, runtimes: [String]) {
        lock.lock()
        if let index = machines.firstIndex(where: { $0.id == machineId }) {
            machines[index].runtimes = runtimes
        }
        lock.unlock()
    }

    public func setHostedUsageForTesting(agentId: String, json: String) {
        lock.lock()
        hostedUsage[agentId] = json
        lock.unlock()
    }

    public func setHostedRuntimeForTesting(
        agentId: String,
        provider: String = "openai",
        model: String? = nil,
        state: String = "active",
        retryNeedsModel: Bool = false
    ) {
        lock.lock()
        hostedRuntimes[agentId] = (provider, model, state, retryNeedsModel, Date())
        lock.unlock()
    }

    public func hostedRuntimeStateForTesting(agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return hostedRuntimes[agentId]?.state
    }

    public func setHostedRuntimeStateForTesting(
        agentId: String,
        state: String,
        retryNeedsModel: Bool = false
    ) {
        lock.lock()
        if let existing = hostedRuntimes[agentId] {
            hostedRuntimes[agentId] = (existing.provider, existing.model, state, retryNeedsModel, existing.createdAt)
        } else {
            hostedRuntimes[agentId] = ("antiproton", nil, state, retryNeedsModel, Date())
        }
        lock.unlock()
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
        lock.lock()
        hostedModels[agentId] = HostedModelState(
            models: models,
            defaultModel: defaultModel,
            defaultLabel: defaultLabel,
            model: model,
            label: label,
            source: source,
            locked: locked
        )
        lock.unlock()
    }

    public func setAgentConnectionOriginForTesting(origin: String) {
        lock.lock()
        agentConnectionOrigin = origin
        lock.unlock()
    }
}
