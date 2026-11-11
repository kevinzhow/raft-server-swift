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
    private let cards: ManagedMCPAndCardsStore
    private let oauth: OAuthLedger
    private let accounts: AuthProfileStore

    init(
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        cards: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        accounts: AuthProfileStore
    ) {
        self.agents = agents
        self.machines = machines
        self.channels = channels
        self.cards = cards
        self.oauth = oauth
        self.accounts = accounts
    }

    private var machineGate: LegacyAgentMachineGate {
        LegacyAgentMachineGate(agents: agents, machines: machines, oauth: oauth, cards: cards)
    }

    /// The legacy `agentTaskAuth` reading order: the path-agent machine route
    /// runs `requireMachineAuth` + `requireAgentScope`, while the id-less
    /// `/internal/agent-api/*` twin reads a live `sk_agent_*` credential (a
    /// credential without `tasks` is the published capability 403 in the
    /// caller; here it is the same invalid-token outcome as before).
    func auth(authorization: String?, legacyAgentId: String?) -> AuthOutcome {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missingAuthorization }
        if let legacyAgentId {
            guard let actor = try? machineGate.actor(
                authorization: authorization,
                agentId: legacyAgentId,
                requiredScope: nil
            ) else {
                return .invalidCredential
            }
            return .ok(agentId: actor.agent.id, serverId: actor.serverId)
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredential(token: token), credential.revokedAt == nil else {
            return .invalidCredential
        }
        guard credential.scopes.contains("tasks") else { return .invalidCredential }
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return .invalidCredential
        }
        return .ok(agentId: agent.id, serverId: agent.serverId)
    }

    /// The legacy `agentTaskWriter`: write routes on the legacy path agent surface
    /// accept the machine key that owns the agent; their `/internal/agent-api/*`
    /// twin accepts the bound `sk_agent_*` credential.
    func writer(authorization: String?, legacyAgentId: String?) -> (agentId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        if let legacyAgentId {
            guard let actor = try? machineGate.actor(
                authorization: authorization,
                agentId: legacyAgentId,
                requiredScope: nil
            ) else {
                return nil
            }
            return (actor.agent.id, actor.serverId)
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredential(token: token), credential.revokedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return nil
        }
        return (agent.id, agent.serverId)
    }

    /// The legacy `agentTaskChannel` reference resolution.
    ///
    /// Upstream resolves every task-channel reference through
    /// `channelService.resolveChannelByName`, which accepts `#name`, `dm:@peer`
    /// and a raw channel id. The DM arm is load-bearing for the claim-before-work
    /// prompt: an agent that receives an actionable top-level DM message claims
    /// it by `--target dm:@<peer> --message-id <id>` before running any tool. A
    /// resolver that only knew `#name` and raw ids answered that claim with
    /// `400 Invalid task claim request`, and the prompt then forbids the agent
    /// from starting the work at all.
    func channel(serverId: String, agentId: String, reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let channelRows = channels.postableChannels
        if trimmed.lowercased().hasPrefix("dm:@") {
            return dmPeerChannel(serverId: serverId, agentId: agentId, reference: trimmed)
        }
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

    /// Resolves one `dm:@name[~kind]` task reference to its DM channel.
    ///
    /// The peer rules mirror `ActionCardPrepareService.resolveDMPeer` and the
    /// pinned `channelService.resolveDMByPeerName`: a bare name that names both
    /// a human and an agent is ambiguous, `~human`/`~agent` picks the kind, and
    /// a migration-receipt DM resolves only for the migrated agent that owns it.
    /// A DM with no existing channel is not found here; unlike a send, a task
    /// claim never creates the conversation.
    private func dmPeerChannel(serverId: String, agentId: String, reference: String) -> String? {
        var rawPeer = String(reference.dropFirst(4))
        var kind: String?
        if let tilde = rawPeer.lastIndex(of: "~") {
            kind = String(rawPeer[rawPeer.index(after: tilde)...]).lowercased()
            rawPeer = String(rawPeer[..<tilde])
        }
        let peerName = rawPeer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerName.isEmpty else { return nil }
        if let kind, kind != "agent", kind != "human" { return nil }
        // `dm:@reminders` is the agent's private reminder surface, not a peer
        // conversation; it is not a task channel.
        if kind == nil, peerName.lowercased() == "reminders" { return nil }
        if kind == nil, peerName.hasPrefix("migration-receipt-") {
            guard let receipt = channels.postableChannels.first(where: { id, channel in
                channel.serverId == serverId && channel.deletedAt == nil
                    && channel.kind == "dm" && channel.name == peerName
                    && channel.memberIds == [agentId]
                    && oauth.channelAgentIds(channelId: id) == [agentId]
                    && oauth.channelHumanIds(channelId: id).isEmpty
            }) else { return nil }
            return receipt.key
        }
        let humans = accounts.accounts.values.filter { account in
            (account.name.caseInsensitiveCompare(peerName) == .orderedSame
                || (account.displayName ?? "").caseInsensitiveCompare(peerName) == .orderedSame)
                && oauth.memberRole(serverId: serverId, userId: account.id) != nil
        }.map(\.id)
        let agentPeers = oauth.serverAgents(serverId: serverId)
            .filter {
                $0.id != agentId
                    && $0.name.caseInsensitiveCompare(peerName) == .orderedSame
            }
            .map(\.id)
        let peerId: String
        let peerKind: String
        switch kind {
        case "human":
            guard let id = humans.first else { return nil }
            peerId = id
            peerKind = "human"
        case "agent":
            guard let id = agentPeers.first else { return nil }
            peerId = id
            peerKind = "agent"
        default:
            // A bare name held by both kinds is ambiguous regardless of which
            // DM exists today; resolving it would let the same target name two
            // different conversations over time.
            if !humans.isEmpty, !agentPeers.isEmpty { return nil }
            if let id = humans.first {
                peerId = id
                peerKind = "human"
            } else if let id = agentPeers.first {
                peerId = id
                peerKind = "agent"
            } else {
                return nil
            }
        }
        guard peerId != agentId else { return nil }
        guard let channelId = oauth.directChannelId(
            serverId: serverId,
            firstUserId: agentId,
            secondUserId: peerId,
            firstKind: .agent,
            secondKind: peerKind == "agent" ? .agent : .human
        ), let channel = channels.postableChannel(id: channelId),
            channel.serverId == serverId, channel.kind == "dm", channel.deletedAt == nil,
            channel.memberIds.contains(agentId), channel.memberIds.contains(peerId)
        else { return nil }
        return channelId
    }
}
