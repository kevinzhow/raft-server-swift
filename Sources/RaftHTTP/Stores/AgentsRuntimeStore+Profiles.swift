import Foundation

extension AgentsRuntimeStore {
    // MARK: - Join-link and agent-profile checks

    /// Whether one server already has an agent row. The setup reset refuses
    /// after this is true.
    func hasServerAgent(serverId: String) -> Bool {
        return withState { state in
            return state.serverAgents.values.contains { $0.serverId == serverId }
        }
    }

    func isHostedAgent(_ agentId: String) -> Bool {
        return withState { state in
            return state.hostedAgents.contains(agentId)
        }
    }

    /// Hosted-agent membership written by the profile route and read by the
    /// join-link policy.
    func markHosted(agentId: String) {
        withState { _ = $0.hostedAgents.insert(agentId) }
    }

    // MARK: - Runtime options and workspaces

    /// Whether the `grok` runtime is offered to one Server.
    func isGrokRuntimeEnabled(serverId: String) -> Bool {
        return withState { state in
            return state.grokRuntimeServers.contains(serverId)
        }
    }

    /// The agents bound to one machine, in the store's own iteration order.
    func agentIds(boundToMachine machineId: String) -> [String] {
        return withState { state in
            return state.agentMachineIds.filter { $0.value == machineId }.map(\.key)
        }
    }

    /// The directory status of one agent, if the agent is registered.
    func agentStatus(agentId: String) -> String? {
        return withState { state in
            return state.serverAgents[agentId]?.status
        }
    }
}

extension AgentsRuntimeStore {
    /// Whether the agent has a stored channel membership row.
    func isChannelAgentMember(channelId: String, agentId: String) -> Bool {
        return withState { state in
            return state.channelAgentMembers[channelId]?.contains(agentId) == true
        }
    }

    /// The machine and the last reported activity of one agent, from one
    /// critical section.
    func runtimeFacts(agentId: String) -> (machineId: String?, activity: String, detail: String) {
        return withState { state in
            let activity = state.agentActivities[agentId] ?? (activity: "offline", detail: "")
            return (state.agentMachineIds[agentId], activity.activity, activity.detail)
        }
    }

    /// The machine binding and the retained live-activity observation, when one
    /// exists. Distinguishes a real daemon/HTTP report from the projection's
    /// offline default in one critical section.
    func presenceFacts(agentId: String) -> (machineId: String?, activity: (activity: String, detail: String)?) {
        return withState { state in
            (machineId: state.agentMachineIds[agentId], activity: state.agentActivities[agentId])
        }
    }
}
