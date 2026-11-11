import Foundation

/// One refusal of the authenticated-machine gate that fronts every legacy
/// `/internal/agent/:id/*` route.
///
/// Upstream mounts `requireMachineAuth` on `/internal` and
/// `requireAgentScope(scope)` on the route. Their published order is:
///
///   missing key                                   401 "Missing machine API key"
///   unknown machine key                           401 "Invalid machine API key"
///   non-machine principal                         401 "Invalid authentication: machine API key required"
///   adopted machine key                           401 legacy_machine_key_migrated
///   deleted server                                401 "Server no longer exists"
///   unknown / other-server agent                  404 "Agent not found"
///   agent bound to another machine                403 "This agent is not assigned to your machine"
///   keyed grant set without the route scope       403 missing required scope
///
/// The bodies and statuses live here, once, so every legacy agent route shares
/// the same gate instead of repeating the checks.
public enum LegacyAgentMachineGateError: DomainError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case invalidAuthentication
    case legacyKeyMigrated
    case serverNotFound
    case agentNotFound
    case notAssignedToMachine
    case missingScope(scope: String)

    public var status: UInt {
        switch self {
        case .missingAPIKey, .invalidAPIKey, .invalidAuthentication, .legacyKeyMigrated,
             .serverNotFound:
            401
        case .agentNotFound:
            404
        case .notAssignedToMachine, .missingScope:
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
        case .legacyKeyMigrated:
            "Legacy machine key has been migrated to a Computer attachment"
        case .serverNotFound:
            "Server no longer exists"
        case .agentNotFound:
            "Agent not found"
        case .notAssignedToMachine:
            "This agent is not assigned to your machine"
        case .missingScope:
            "missing required scope"
        }
    }

    public var errorCode: String? {
        switch self {
        case .legacyKeyMigrated:
            "legacy_machine_key_migrated"
        default:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .missingScope(let scope):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("requiredScope", scope)
            body.append("reason", "missing_scope")
            return body.json
        default:
            return nil
        }
    }
}

/// The authenticated machine principal of one legacy agent request. `nil`
/// machine means the legacy `sk_daemon_*` key row, which is bound to one agent
/// instead of a machine.
public struct LegacyAgentMachinePrincipal: Sendable, Equatable {
    public let machineId: String?
    public let legacyAgentId: String?
    public let serverId: String

    public init(machineId: String?, legacyAgentId: String?, serverId: String) {
        self.machineId = machineId
        self.legacyAgentId = legacyAgentId
        self.serverId = serverId
    }
}

/// The agent a machine-authenticated legacy request acts for.
public struct LegacyAgentMachineActor: Sendable {
    public let agent: OAuthLedger.AgentRuntimeInfo
    public let machineId: String?
    public let serverId: String

    public init(agent: OAuthLedger.AgentRuntimeInfo, machineId: String?, serverId: String) {
        self.agent = agent
        self.machineId = machineId
        self.serverId = serverId
    }
}

/// `requireMachineAuth` + `requireAgentScope(scope)` as one reusable gate.
///
/// `machinePrincipal` owns the 401 half (and the server-liveness check);
/// `actor` owns the agent/server/ownership/grant half. The split exists only
/// so the legacy send route can keep its published body-validation step
/// between the two, exactly as upstream registers
/// `validateLegacyAgentSendBody` before `requireAgentScope`.
public struct LegacyAgentMachineGate: Sendable {
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let oauth: OAuthLedger
    private let cards: ManagedMCPAndCardsStore

    init(
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        oauth: OAuthLedger,
        cards: ManagedMCPAndCardsStore
    ) {
        self.agents = agents
        self.machines = machines
        self.oauth = oauth
        self.cards = cards
    }

    /// `requireMachineAuth` for the legacy `/internal/agent/:id/*` surface.
    public func machinePrincipal(authorization: String?) throws -> LegacyAgentMachinePrincipal {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw LegacyAgentMachineGateError.missingAPIKey
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token.hasPrefix("sk_machine_") || token.hasPrefix("sk_daemon_") else {
            // `sk_agent_*`, `sk_computer_*`, JWTs and unknown shapes all reach
            // the machine surface with the wrong principal class.
            throw LegacyAgentMachineGateError.invalidAuthentication
        }
        let credential = machines.machineCredential(apiKey: token, agentId: nil)
        if let machine = credential.machine {
            if machine.legacyKeyMigratedAt != nil {
                throw LegacyAgentMachineGateError.legacyKeyMigrated
            }
            guard oauth.serverProfile(id: machine.serverId) != nil else {
                throw LegacyAgentMachineGateError.serverNotFound
            }
            return LegacyAgentMachinePrincipal(
                machineId: machine.id,
                legacyAgentId: nil,
                serverId: machine.serverId
            )
        }
        if let legacy = credential.legacy {
            guard oauth.serverProfile(id: legacy.serverId) != nil else {
                throw LegacyAgentMachineGateError.serverNotFound
            }
            return LegacyAgentMachinePrincipal(
                machineId: nil,
                legacyAgentId: legacy.agentId,
                serverId: legacy.serverId
            )
        }
        throw LegacyAgentMachineGateError.invalidAPIKey
    }

    /// `requireAgentScope(scope)` for an already-authenticated machine.
    public func actor(
        principal: LegacyAgentMachinePrincipal,
        agentId: String,
        requiredScope: String?
    ) throws -> LegacyAgentMachineActor {
        guard let agent = oauth.agentRuntimeInfo(id: agentId),
              !agent.deleted,
              agent.serverId == principal.serverId
        else {
            throw LegacyAgentMachineGateError.agentNotFound
        }
        if let machineId = principal.machineId {
            guard agents.agentMachineIds[agentId] == machineId else {
                throw LegacyAgentMachineGateError.notAssignedToMachine
            }
        } else if let legacyAgentId = principal.legacyAgentId {
            guard legacyAgentId == agentId else {
                throw LegacyAgentMachineGateError.notAssignedToMachine
            }
        } else {
            throw LegacyAgentMachineGateError.notAssignedToMachine
        }
        if let requiredScope,
           let grants = cards.agentGrantSets[agentId],
           !grants.contains(requiredScope) {
            throw LegacyAgentMachineGateError.missingScope(scope: requiredScope)
        }
        return LegacyAgentMachineActor(
            agent: agent,
            machineId: principal.machineId,
            serverId: principal.serverId
        )
    }

    /// The combined gate. Route middleware and every direct caller use this
    /// entry point; `machinePrincipal`/`actor` are only the send route's
    /// published two-phase order.
    public func actor(
        authorization: String?,
        agentId: String,
        requiredScope: String?
    ) throws -> LegacyAgentMachineActor {
        try actor(
            principal: machinePrincipal(authorization: authorization),
            agentId: agentId,
            requiredScope: requiredScope
        )
    }
}
