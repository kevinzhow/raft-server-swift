import Foundation

extension AgentsRuntimeStore {
    // MARK: - Join-link and agent-profile checks

    /// Whether one server already has an agent row. The setup reset refuses
    /// after this is true.
    func hasServerAgent(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.serverAgents.values.contains { $0.serverId == serverId }
    }

    func isHostedAgent(_ agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.hostedAgents.contains(agentId)
    }

    /// Hosted-agent membership written by the profile route and read by the
    /// join-link policy.
    func markHosted(agentId: String) {
        lock.lock()
        storage.hostedAgents.insert(agentId)
        lock.unlock()
    }

    // MARK: - Runtime options and workspaces

    /// Whether the `grok` runtime is offered to one Server.
    func isGrokRuntimeEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.grokRuntimeServers.contains(serverId)
    }

    /// The agents bound to one machine, in the store's own iteration order.
    func agentIds(boundToMachine machineId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentMachineIds.filter { $0.value == machineId }.map(\.key)
    }

    /// The directory status of one agent, if the agent is registered.
    func agentStatus(agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.serverAgents[agentId]?.status
    }
}

extension AgentsRuntimeStore {
    /// Whether the agent has a stored channel membership row.
    func isChannelAgentMember(channelId: String, agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.channelAgentMembers[channelId]?.contains(agentId) == true
    }

    /// The machine and the last reported activity of one agent, from one
    /// critical section.
    func runtimeFacts(agentId: String) -> (machineId: String?, activity: String, detail: String) {
        lock.lock()
        defer { lock.unlock() }
        let activity = storage.agentActivities[agentId] ?? (activity: "offline", detail: "")
        return (storage.agentMachineIds[agentId], activity.activity, activity.detail)
    }
}
