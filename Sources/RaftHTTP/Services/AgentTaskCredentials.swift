import Foundation

/// The agent task credential and channel-reference policy shared by every
/// service that serves the agent task routes (`ActionCardExecuteService`,
/// `ActionCardMarketplaceService`) and, through the directory forwarders, the
/// services that have not migrated yet. One copy of the legacy
/// `agentTaskAuth` / `agentTaskWriter` / `agentTaskChannel` decisions.
struct AgentTaskCredentials: Sendable {
    enum AuthOutcome: Sendable, Equatable {
        case missingAuthorization
        case invalidCredential
        case ok(agentId: String, serverId: String)
    }

    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let channels: ServersAndChannelsStore
    private let oauth: OAuthLedger

    init(
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        oauth: OAuthLedger
    ) {
        self.agents = agents
        self.machines = machines
        self.channels = channels
        self.oauth = oauth
    }

    /// The legacy `agentTaskAuth` reading order: credential path first (a live
    /// credential without `tasks` is the published invalid-token 401), then the
    /// machine key plus the path agent id.
    func auth(authorization: String?, legacyAgentId: String?) -> AuthOutcome {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missingAuthorization }
        let token = String(authorization.dropFirst("Bearer ".count))
        let credential = agents.agentCredential(token: token)
        let machine = machines.machine(apiKey: token)
        if let credential, credential.revokedAt == nil {
            guard credential.scopes.contains("tasks") else { return .invalidCredential }
            guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
                return .invalidCredential
            }
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        return .invalidCredential
    }

    /// The legacy `agentTaskWriter`: write routes accept both an `sk_agent_*`
    /// credential and the legacy machine key plus path agent id.
    func writer(authorization: String?, legacyAgentId: String?) -> (agentId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        let credential = agents.agentCredential(token: token)
        let machine = machines.machine(apiKey: token)
        if let credential, credential.revokedAt == nil,
           let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted {
            return (agent.id, agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return (agent.id, agent.serverId)
        }
        return nil
    }

    /// The legacy `agentTaskChannel` reference resolution (`#name` or a raw id).
    func channel(serverId: String, agentId: String, reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let channelRows = channels.postableChannels
        if trimmed.hasPrefix("#") {
            let name = String(trimmed.dropFirst())
            for (id, channel) in channelRows {
                guard channel.serverId == serverId, channel.name == name, channel.deletedAt == nil else { continue }
                guard channel.kind == "channel"
                    || channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
                else { continue }
                return id
            }
            return nil
        }
        guard channelRows[trimmed]?.serverId == serverId else { return nil }
        return trimmed
    }
}
