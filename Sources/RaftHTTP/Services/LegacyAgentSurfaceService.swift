import Foundation

/// The machine-principal refusals of the legacy `/internal/agent/:id/*` surface.
///
/// These are the upstream `requireMachineAuth` and `requireAgentScope` bodies:
/// a missing/invalid `sk_machine_*`/`sk_daemon_*` key is a 401 with its own
/// message, an unknown or cross-server agent is 404 `Agent not found`, and an
/// agent that is not assigned to the authenticated machine is 403.
public enum LegacyAgentMachineError: DomainError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case invalidAuthentication
    case agentNotFound
    case notAssignedToMachine

    public var status: UInt {
        switch self {
        case .missingAPIKey, .invalidAPIKey, .invalidAuthentication:
            401
        case .agentNotFound:
            404
        case .notAssignedToMachine:
            403
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAPIKey:
            "Missing machine API key"
        case .invalidAPIKey:
            "Invalid machine API key"
        case .invalidAuthentication:
            "Invalid authentication: machine API key required"
        case .agentNotFound:
            "Agent not found"
        case .notAssignedToMachine:
            "This agent is not assigned to your machine"
        }
    }
}

/// The legacy machine-key surface: knowledge, message resolve, receive, the
/// task list and the server avatar upload.
///
/// Upstream `/internal/agent/:id/*` routes run `requireMachineAuth` and
/// `requireAgentScope(scope)` before their handler. This service owns both gates
/// (the machine row or daemon-compat key row, the agent/server match, the exact
/// machine ownership and the keyed grant set) and then delegates the domain
/// work to the service that already owns it. It never reads or writes beyond
/// the gates itself; `receive` is the one projection the port owns directly,
/// because the pinned server's queued inbox belongs to an agent orchestrator the
/// port does not have.
public struct LegacyAgentSurfaceService: Sendable {
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let oauth: OAuthLedger
    private let cards: ManagedMCPAndCardsStore
    private let tasksAndLabs: TasksAndLabsService
    private let messageLookup: AgentMessageLookupService
    private let agentChannels: AgentChannelsService

    init(
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        oauth: OAuthLedger,
        cards: ManagedMCPAndCardsStore,
        tasksAndLabs: TasksAndLabsService,
        messageLookup: AgentMessageLookupService,
        agentChannels: AgentChannelsService
    ) {
        self.agents = agents
        self.machines = machines
        self.oauth = oauth
        self.cards = cards
        self.tasksAndLabs = tasksAndLabs
        self.messageLookup = messageLookup
        self.agentChannels = agentChannels
    }

    // MARK: - Machine authentication and grant

    /// `requireMachineAuth` + `requireAgentScope(scope)` for one path agent.
    ///
    /// A `Bearer` value resolves as a machine key (including the daemon-compat
    /// key row) to its server; the path agent must exist on that server and be
    /// assigned to the machine (or be the daemon key's own agent). The keyed
    /// grant set then gates the operation exactly like `requireAgentScope`.
    public func actor(
        authorization: String?,
        agentId: String,
        requiredScope: String
    ) throws -> OAuthLedger.AgentRuntimeInfo {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw LegacyAgentMachineError.missingAPIKey
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let credential = machines.machineCredential(apiKey: token, agentId: nil)
        guard let serverId = credential.machine?.serverId ?? credential.legacy?.serverId else {
            throw token.hasPrefix("sk_") ? LegacyAgentMachineError.invalidAPIKey : LegacyAgentMachineError.invalidAuthentication
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
            throw LegacyAgentMachineError.agentNotFound
        }
        let ownsAgent: Bool
        if let machine = credential.machine {
            ownsAgent = agents.agentMachineIds[agentId] == machine.id
        } else if let legacy = credential.legacy {
            ownsAgent = legacy.agentId == agentId
        } else {
            ownsAgent = false
        }
        guard ownsAgent else { throw LegacyAgentMachineError.notAssignedToMachine }
        if let grants = cards.agentGrantSets[agentId], !grants.contains(requiredScope) {
            throw FeedbackLocatorError.missingScope(scope: requiredScope)
        }
        return agent
    }

    // MARK: - GET /internal/agent/:id/knowledge

    /// The knowledge routes render their own body; the service exposes only the
    /// authenticated agent identity and the `knowledge:read` gate.
    public func knowledgeAgent(authorization: String?, agentId: String) throws -> OAuthLedger.AgentRuntimeInfo {
        try actor(authorization: authorization, agentId: agentId, requiredScope: "knowledge:read")
    }

    // MARK: - GET /internal/agent/:id/messages/:messageId/resolve

    public func messageResolve(
        authorization: String?,
        agentId: String,
        messageRef: String
    ) throws -> AgentMessageResolveResponse {
        let agent = try actor(authorization: authorization, agentId: agentId, requiredScope: "message:read")
        return try messageLookup.messageResolve(agent: agent, messageRef: messageRef)
    }

    // MARK: - GET /internal/agent/:id/receive

    /// The legacy daemon long poll.
    ///
    /// The pinned route drains the machine inbox held by `agentOrchestrator`.
    /// This port has no in-process inbox, so a receive is an empty delivery:
    /// `{"messages":[]}`. `block` and `timeout` are validated by the route and
    /// then ignored; they cannot make a queued message appear. The endpoint
    /// still authenticates and gates the call before answering, so it is not an
    /// unauthenticated empty probe.
    public func receive(
        authorization: String?,
        agentId: String
    ) throws -> AgentReceiveMessagesResponse {
        _ = try actor(authorization: authorization, agentId: agentId, requiredScope: "message:read")
        return AgentReceiveMessagesResponse()
    }

    // MARK: - GET /internal/agent/:id/tasks

    public func tasks(
        authorization: String?,
        agentId: String,
        channelRef: String,
        rawQuery: String?
    ) throws -> LegacyAgentTaskListResponse {
        let agent = try actor(authorization: authorization, agentId: agentId, requiredScope: "task:read")
        guard !channelRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskApiError.channelQueryRequired
        }
        return try tasksAndLabs.legacyAgentTasks(
            agent: agent, channelRef: channelRef, rawQuery: rawQuery
        )
    }

    // MARK: - POST /internal/agent/:id/server/avatar

    public func uploadServerAvatar(
        authorization: String?,
        agentId: String,
        byteCount: Int
    ) throws -> ServerProfilePatchResponse {
        let agent = try actor(authorization: authorization, agentId: agentId, requiredScope: "server:update")
        return try agentChannels.uploadServerAvatar(agent: agent, byteCount: byteCount)
    }
}
