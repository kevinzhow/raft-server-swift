import Foundation

// MARK: - Injected dependencies

/// Everything the machine, hosted runtime and provider connection surface needs.
///
/// The hosted rows, the machine rows, the server rows and the account rows
/// belong to their stores. The human session lookup, the realtime emitter and
/// the provider relay belong to domains that have not migrated and stay behind
/// closures; `live(directory:)` wires them at the composition root.
struct MachinesAndHostedRuntimeDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var emitRealtime: @Sendable (String, String, String?) -> Void
    var oauth: OAuthLedger
    var agents: AgentsRuntimeStore
    var machines: MachinesAndComputersStore
    var channels: ServersAndChannelsStore
    var profiles: AuthProfileStore
    /// The provider relay; `.unavailable` when none is configured.
    var callProvider: @Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult
    var connectionOrigin: @Sendable () -> String

    static func live(directory source: EmailLoginDirectory) -> MachinesAndHostedRuntimeDependencies {
        MachinesAndHostedRuntimeDependencies(
            sessionUserId: { source.sessionUserId(authorization: $0) },
            emitRealtime: { room, event, payload in
                source.emitRealtime(room, event, payload)
            },
            oauth: source.oauth,
            agents: source.agentsRuntimeStore,
            machines: source.machinesAndComputersStore,
            channels: source.serversAndChannelsStore,
            profiles: source.authProfileStore,
            callProvider: { request in
                guard let relay = source.agentConnectionProvider else { return .unavailable }
                return relay(request)
            },
            connectionOrigin: { source.agentConnectionOrigin }
        )
    }
}

// MARK: - Service

/// Machine credential lookups, the onboarding identity adoption, the hosted
/// runtime reads and writes, and the provider account connections.
///
/// The service owns the orchestration and returns the published DTOs; every
/// refusal is a `MachinesAndHostedRuntimeError`. It builds no HTTP reply, header
/// set or response body. The provisioning retry and the hosted model change are
/// one `AgentsRuntimeStore` critical section each.
public struct MachinesAndHostedRuntimeService: Sendable {
    private let dependencies: MachinesAndHostedRuntimeDependencies

    private static let connectionProviders: Set<String> = ["github"]

    /// Production wiring.
    public init(directory: EmailLoginDirectory) {
        self.init(dependencies: .live(directory: directory))
    }

    init(dependencies: MachinesAndHostedRuntimeDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Machine credential lookups

    /// The Machine a bearer token authenticates (a Machine key, else a live
    /// Computer key's Machine).
    public func machineIdForCredential(authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return dependencies.machines.machineId(forToken: String(authorization.dropFirst("Bearer ".count)))
    }

    func canMachineServeAgent(machineId: String, agent: OAuthLedger.AgentRuntimeInfo) -> Bool {
        let bound = dependencies.agents.agentMachineIds[agent.id]
        let machineServer = dependencies.machines.machineServerId(machineId: machineId)
        guard machineServer == agent.serverId else { return false }
        if let bound { return bound == machineId }
        return true
    }

    public func machineAPIKey(machineId: String) -> String? {
        dependencies.machines.machineAPIKey(machineId: machineId)
    }

    public func bumpMachineStatusVersion(machineId: String) -> Int {
        dependencies.machines.bumpMachineStatusVersion(machineId: machineId)
    }

    public func setMachineOnline(machineId: String, online: Bool) {
        dependencies.machines.setMachineOnline(machineId: machineId, online: online)
    }

    public func enableHostedModelPicker(serverId: String) {
        dependencies.agents.enableHostedModelPicker(serverId: serverId)
    }

    // MARK: - Onboarding identity adoption

    private struct AdoptionState {
        var agent: OAuthLedger.AgentRuntimeInfo
        var role: String
        var changes: [OnboardingAdoptionChangeDTO]
    }

    private func adoptionState(serverId: String, agentId: String) -> AdoptionState? {
        guard let agent = dependencies.oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else { return nil }
        let role = dependencies.oauth.agentRole(serverId: serverId, agentId: agentId) ?? "member"
        var changes: [OnboardingAdoptionChangeDTO] = []
        if agent.name != "Cindy" {
            changes.append(OnboardingAdoptionChangeDTO(field: "name", before: agent.name, after: "Cindy"))
        }
        if agent.displayName != "Cindy" {
            changes.append(OnboardingAdoptionChangeDTO(field: "displayName", before: agent.displayName, after: "Cindy"))
        }
        if agent.description != "Onboarding Assistant" {
            changes.append(OnboardingAdoptionChangeDTO(field: "role", before: agent.description, after: "Onboarding Assistant"))
        }
        if role != "admin" {
            changes.append(OnboardingAdoptionChangeDTO(field: "serverRole", before: role, after: "admin"))
        }
        if agent.avatarUrl != "pixel:mug" {
            changes.append(OnboardingAdoptionChangeDTO(field: "avatarUrl", before: agent.avatarUrl, after: "pixel:mug"))
        }
        return AdoptionState(agent: agent, role: role, changes: changes)
    }

    /// The caller must be an owner/admin or the agent's creator, and the agent
    /// must be this server's onboarding agent.
    private func adoptionActor(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> AdoptionState {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw MachinesAndHostedRuntimeError.unauthorized
        }
        guard let state = adoptionState(serverId: serverId, agentId: agentId) else {
            throw MachinesAndHostedRuntimeError.agentNotFound
        }
        let memberRole = dependencies.oauth.memberRole(serverId: serverId, userId: userId)
        guard memberRole == "owner" || memberRole == "admin" || state.agent.creatorUserId == userId else {
            throw MachinesAndHostedRuntimeError.authorityRequired(
                "The `editAgents` capability or human creator authority is required to edit agents"
            )
        }
        guard dependencies.channels.serverOnboardingSettings[serverId]?.agentId == agentId else {
            throw MachinesAndHostedRuntimeError.notOnboardingAgent
        }
        return state
    }

    public func onboardingIdentityAdoption(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> OnboardingAdoptionResponse {
        let state = try adoptionActor(authorization: authorization, serverId: serverId, agentId: agentId)
        return OnboardingAdoptionResponse(canAdopt: !state.changes.isEmpty, changes: state.changes)
    }

    public func adoptOnboardingIdentity(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> OnboardingAdoptionResponse {
        let state = try adoptionActor(authorization: authorization, serverId: serverId, agentId: agentId)
        func summary(_ agent: OAuthLedger.AgentRuntimeInfo, role: String) -> OnboardingAdoptionResponse.AgentSummary {
            OnboardingAdoptionResponse.AgentSummary(
                id: agent.id,
                name: agent.name,
                displayName: agent.displayName,
                description: agent.description,
                avatarUrl: agent.avatarUrl,
                serverRole: role
            )
        }
        let changes = state.changes
        guard !changes.isEmpty else {
            return OnboardingAdoptionResponse(
                canAdopt: false,
                changes: [],
                appliedChanges: [],
                agent: summary(state.agent, role: state.role)
            )
        }
        if dependencies.oauth.serverAgents(serverId: serverId).contains(where: {
            $0.id != agentId && $0.name == "Cindy"
        }) {
            throw MachinesAndHostedRuntimeError.nameTaken
        }
        dependencies.oauth.adoptAgentIdentity(
            serverId: serverId,
            agentId: agentId,
            name: "Cindy",
            displayName: "Cindy",
            description: "Onboarding Assistant",
            avatarUrl: "pixel:mug",
            role: "admin"
        )
        dependencies.emitRealtime(
            "server:\(serverId)",
            "agent:updated",
            OrderedJSON.object([OrderedJSONField("agentId", agentId)]).render()
        )
        let updated = dependencies.oauth.agentRuntimeInfo(id: agentId) ?? state.agent
        return OnboardingAdoptionResponse(
            canAdopt: false,
            changes: [],
            appliedChanges: changes,
            agent: summary(updated, role: "admin")
        )
    }

    // MARK: - Hosted runtime

    /// The agent of this server the caller may manage: an owner, an admin or the
    /// agent's human creator. `denial` names the action in the 403.
    private func managedAgent(
        authorization: String?,
        serverId: String,
        agentId: String,
        denial: String
    ) throws -> OAuthLedger.AgentRuntimeInfo {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw MachinesAndHostedRuntimeError.unauthorized
        }
        guard let agent = dependencies.oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            throw MachinesAndHostedRuntimeError.agentNotFound
        }
        let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            throw MachinesAndHostedRuntimeError.authorityRequired(
                "The `editAgents` capability or human creator authority is required to \(denial)"
            )
        }
        return agent
    }

    public func agentHostedUsage(
        authorization: String?,
        serverId: String,
        agentId: String,
        query: String?
    ) throws -> HostedUsageResponse {
        _ = try managedAgent(
            authorization: authorization, serverId: serverId, agentId: agentId,
            denial: "view cloud agent usage"
        )
        let snapshot = dependencies.agents.hostedSnapshot(agentId: agentId)
        guard snapshot.runtime != nil else { throw MachinesAndHostedRuntimeError.hostedRuntimeMissing }
        var params: [String: String] = [:]
        for pair in (query ?? "").split(separator: "&") {
            let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(item[0]).removingPercentEncoding ?? String(item[0])
            let value = item.count == 2 ? (String(item[1]).removingPercentEncoding ?? String(item[1])) : ""
            params[name] = value
        }
        let bucket = params["bucket"] ?? "1d"
        guard ["1h", "1d"].contains(bucket) else { throw MachinesAndHostedRuntimeError.usageInvalidQuery }
        let now = Date()
        func parse(_ name: String) -> Date? {
            guard let raw = params[name], !raw.isEmpty else { return nil }
            return EmailLoginDirectory.isoDate(raw)
        }
        if params["from"] != nil, parse("from") == nil { throw MachinesAndHostedRuntimeError.usageInvalidQuery }
        if params["to"] != nil, parse("to") == nil { throw MachinesAndHostedRuntimeError.usageInvalidQuery }
        let from = parse("from") ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        let to = parse("to") ?? now
        guard to >= from, to.timeIntervalSince(from) <= 31 * 24 * 60 * 60 else {
            throw MachinesAndHostedRuntimeError.usageInvalidQuery
        }
        guard let body = snapshot.usage else { throw MachinesAndHostedRuntimeError.usageNotReady }
        return HostedUsageResponse(rawJSON: body)
    }

    private func statusResponse(
        agentId: String,
        row: HostedRuntimeRow,
        includesOnboardingSetup: Bool
    ) -> HostedRuntimeStatusResponse {
        HostedRuntimeStatusResponse(
            agentId: agentId,
            provider: row.provider,
            model: row.model,
            state: row.state,
            retryNeedsModel: row.retryNeedsModel,
            createdAt: EmailLoginDirectory.isoString(row.createdAt),
            includesOnboardingSetup: includesOnboardingSetup
        )
    }

    public func agentHostedRuntime(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> HostedRuntimeStatusResponse {
        _ = try managedAgent(
            authorization: authorization, serverId: serverId, agentId: agentId,
            denial: "view cloud agent status"
        )
        guard let hosted = dependencies.agents.hostedRuntimeRow(agentId: agentId) else {
            throw MachinesAndHostedRuntimeError.hostedRuntimeMissing
        }
        return statusResponse(agentId: agentId, row: hosted, includesOnboardingSetup: true)
    }

    /// A `model` body member: a model id, or `null` for the default. Anything
    /// else (an empty or oversized id, a non-string) is refused.
    private enum ModelRequest {
        case absent
        case value(String?)
        case invalid
    }

    private func modelRequest(_ body: LegacyJSONObjectBody?) -> ModelRequest {
        guard let raw = body?["model"] else { return .absent }
        if raw.isNull { return .value(nil) }
        if let value = raw.legacyString,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           value.count <= 200 {
            return .value(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .invalid
    }

    public func retryAgentProvisioning(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: LegacyJSONObjectBody?
    ) throws -> HostedRuntimeStatusResponse {
        _ = try managedAgent(
            authorization: authorization, serverId: serverId, agentId: agentId,
            denial: "retry provisioning"
        )
        guard dependencies.agents.hostedRuntimeRow(agentId: agentId) != nil else {
            throw MachinesAndHostedRuntimeError.hostedRuntimeMissing
        }
        var modelProvided = false
        var providedModel: String?
        switch modelRequest(body) {
        case .absent:
            break
        case .value(let model):
            modelProvided = true
            providedModel = model
        case .invalid:
            throw MachinesAndHostedRuntimeError.modelInvalid
        }
        let outcome = dependencies.agents.retryHostedProvisioning(
            agentId: agentId,
            serverId: serverId,
            modelProvided: modelProvided,
            providedModel: providedModel,
            defaultModel: EmailLoginDirectory.hostedDefaultModel
        )
        switch outcome {
        case .missing:
            throw MachinesAndHostedRuntimeError.hostedRuntimeMissing
        case .pickerDisabled:
            throw MachinesAndHostedRuntimeError.modelPickerDisabled
        case .modelLocked:
            throw MachinesAndHostedRuntimeError.modelLocked
        case .modelNotOffered:
            throw MachinesAndHostedRuntimeError.modelNotOffered
        case .modelRequired:
            throw MachinesAndHostedRuntimeError.modelRequired
        case .nothingToRetry:
            throw MachinesAndHostedRuntimeError.nothingToRetry
        case .retried(let row):
            return statusResponse(agentId: agentId, row: row, includesOnboardingSetup: false)
        }
    }

    /// Shared guard for the hosted model read and write: authority, an existing
    /// hosted runtime, and an active provision with a model state.
    private func hostedModelAgent(
        authorization: String?,
        serverId: String,
        agentId: String,
        action: String
    ) throws {
        _ = try managedAgent(
            authorization: authorization, serverId: serverId, agentId: agentId,
            denial: "\(action) a cloud agent's model"
        )
        let snapshot = dependencies.agents.hostedSnapshot(agentId: agentId)
        guard let hosted = snapshot.runtime else { throw MachinesAndHostedRuntimeError.hostedRuntimeMissing }
        guard hosted.state == "active", snapshot.models != nil else {
            throw MachinesAndHostedRuntimeError.modelNotReady
        }
    }

    private func modelView(_ state: HostedModelState, picker: Bool) -> HostedModelViewResponse {
        HostedModelViewResponse(
            models: state.models.map {
                HostedModelViewResponse.Option(id: $0.id, label: $0.label, provider: $0.provider)
            },
            defaultModel: state.defaultModel,
            defaultLabel: state.defaultLabel,
            model: state.model,
            label: state.label,
            source: state.source,
            locked: state.locked,
            picker: picker
        )
    }

    public func agentHostedModel(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> HostedModelViewResponse {
        try hostedModelAgent(authorization: authorization, serverId: serverId, agentId: agentId, action: "view")
        guard let state = dependencies.agents.hostedSnapshot(agentId: agentId).models else {
            throw MachinesAndHostedRuntimeError.modelNotReady
        }
        return modelView(state, picker: dependencies.agents.hostedModelPickerEnabled(serverId: serverId))
    }

    public func setAgentHostedModel(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: LegacyJSONObjectBody?
    ) throws -> HostedModelViewResponse {
        try hostedModelAgent(authorization: authorization, serverId: serverId, agentId: agentId, action: "change")
        let requested: String?
        switch modelRequest(body) {
        case .absent, .invalid:
            throw MachinesAndHostedRuntimeError.modelInvalid
        case .value(let model):
            requested = model
        }
        let outcome = dependencies.agents.changeHostedModel(
            agentId: agentId,
            serverId: serverId,
            requested: requested,
            defaultModel: EmailLoginDirectory.hostedDefaultModel
        )
        switch outcome {
        case .notReady:
            throw MachinesAndHostedRuntimeError.modelNotReady
        case .pickerDisabled:
            throw MachinesAndHostedRuntimeError.modelPickerDisabled
        case .modelLocked:
            throw MachinesAndHostedRuntimeError.modelLocked
        case .modelNotOffered:
            throw MachinesAndHostedRuntimeError.modelNotOffered
        case .changed(let state, let picker):
            return modelView(state, picker: picker)
        }
    }

    // MARK: - Provider account connections

    private struct ConnectionActor {
        var userId: String
        var role: String
    }

    private func loadConnectionActor(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) throws -> ConnectionActor {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw MachinesAndHostedRuntimeError.unauthorized
        }
        guard Self.connectionProviders.contains(provider) else {
            throw MachinesAndHostedRuntimeError.connectionProviderUnknown
        }
        guard let agent = dependencies.oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            throw MachinesAndHostedRuntimeError.agentNotFound
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId),
              role != "guest",
              role == "owner" || role == "admin" || agent.creatorUserId == userId
        else {
            throw MachinesAndHostedRuntimeError.connectionForbidden
        }
        guard let hosted = dependencies.agents.hostedRuntimeRow(agentId: agentId) else {
            throw MachinesAndHostedRuntimeError.connectionNotProviderBacked
        }
        guard hosted.state == "active" else {
            throw MachinesAndHostedRuntimeError.connectionAgentNotActive(state: hosted.state)
        }
        return ConnectionActor(userId: userId, role: role)
    }

    private func providerCall(
        method: String,
        action: String,
        provider: String,
        agentId: String,
        body: String? = nil
    ) -> AgentConnectionProviderResult {
        dependencies.callProvider(AgentConnectionProviderRequest(
            method: method,
            action: action,
            provider: provider,
            agentId: agentId,
            body: body
        ))
    }

    private func memberIdentity(serverId: String, userId: String) -> String? {
        guard dependencies.oauth.memberRole(serverId: serverId, userId: userId) != nil else { return nil }
        return dependencies.profiles.accounts.values.first { $0.id == userId }?.name
    }

    private func redactProviderMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        var value = message
        for pattern in [
            "(ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9]+",
            "Bearer [A-Za-z0-9._~+/=-]+",
            "sk-[A-Za-z0-9_-]+",
        ] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return value
    }

    private func statusResponse(
        _ parsed: HostedConnectionStatusRecord,
        provider: String,
        serverId: String,
        actor: ConnectionActor
    ) -> ProviderConnectionStatusResponse {
        var connectedBy: ProviderConnectionStatusResponse.Person?
        if parsed.connected, let id = parsed.connectedBy {
            connectedBy = .init(id: id, name: memberIdentity(serverId: serverId, userId: id))
        }
        let connectors = parsed.connectors.map { connector -> ProviderConnectionStatusResponse.Connector in
            var creator: ProviderConnectionStatusResponse.Person?
            if let creatorId = connector.creatorRaftUserId {
                let name = memberIdentity(serverId: serverId, userId: creatorId)
                creator = .init(id: creatorId, name: name, displayName: name, includesDisplayName: true)
            }
            let canManage = actor.role == "owner" || actor.role == "admin"
                || connector.creatorRaftUserId == actor.userId
            return .init(
                id: connector.id,
                account: connector.account,
                createdAt: connector.createdAt,
                creator: creator,
                current: connector.current,
                canManage: canManage
            )
        }
        return ProviderConnectionStatusResponse(
            provider: provider,
            connected: parsed.connected,
            account: parsed.connected ? parsed.account : nil,
            connectedAt: parsed.connected ? parsed.connectedAt : nil,
            connectedBy: connectedBy,
            scopes: parsed.scopes,
            connectorId: parsed.connectorId,
            connectors: connectors
        )
    }

    private func isSuccess(_ status: Int) -> Bool { (200..<300).contains(status) }

    private func providerFailure(_ result: AgentConnectionProviderResult) -> MachinesAndHostedRuntimeError {
        switch result {
        case .unavailable:
            return .connectionProviderError(providerCode: nil, providerMessage: nil, providerStatus: nil)
        case .empty(let status):
            return .connectionProviderError(providerCode: nil, providerMessage: nil, providerStatus: status)
        case .response(let status, let body):
            let parts = AgentConnectionProviderPayload.providerErrorParts(body)
            let message = redactProviderMessage(parts.message)
            if (400..<500).contains(status) {
                return .connectionProviderRefused(
                    message: message ?? "The provider refused the request",
                    providerCode: parts.code,
                    providerMessage: message,
                    providerStatus: status
                )
            }
            return .connectionProviderError(providerCode: parts.code, providerMessage: message, providerStatus: status)
        }
    }

    private func missingAtProvider(_ message: String?) -> MachinesAndHostedRuntimeError {
        .connectionAgentMissingAtProvider(providerMessage: redactProviderMessage(message))
    }

    /// A 404 from the provider may mean the connections route is missing
    /// (unsupported) or that the provider no longer knows the agent. Only the
    /// agent lookup can tell them apart.
    private func notFoundFailure(
        provider: String,
        agentId: String,
        body: String,
        connectorScoped: Bool = false
    ) -> MachinesAndHostedRuntimeError {
        let lookup = providerCall(method: "GET", action: "agentLookup", provider: provider, agentId: agentId)
        switch lookup {
        case .response(let status, _) where isSuccess(status):
            return connectorScoped ? .connectionConnectorNotFound : .connectionUnsupported
        case .response(let status, let lookupBody) where status == 404:
            return missingAtProvider(
                AgentConnectionProviderPayload.providerErrorParts(lookupBody).message
                    ?? AgentConnectionProviderPayload.providerErrorParts(body).message
            )
        default:
            return providerFailure(lookup)
        }
    }

    private func statusReply(
        _ result: AgentConnectionProviderResult,
        provider: String,
        agentId: String,
        serverId: String,
        actor: ConnectionActor
    ) throws -> ProviderConnectionStatusReply {
        switch result {
        case .response(let status, let body) where isSuccess(status):
            guard let parsed = AgentConnectionProviderPayload.parseConnectionStatus(body) else {
                throw MachinesAndHostedRuntimeError.connectionProviderError(
                    providerCode: "invalid_response", providerMessage: nil, providerStatus: status
                )
            }
            return .status(statusResponse(parsed, provider: provider, serverId: serverId, actor: actor))
        case .response(let status, _) where status == 404:
            let lookup = providerCall(method: "GET", action: "agentLookup", provider: provider, agentId: agentId)
            switch lookup {
            case .response(let lookupStatus, _) where isSuccess(lookupStatus):
                return .unsupported(provider: provider)
            case .response(let lookupStatus, let lookupBody) where lookupStatus == 404:
                throw missingAtProvider(AgentConnectionProviderPayload.providerErrorParts(lookupBody).message)
            default:
                throw providerFailure(lookup)
            }
        default:
            throw providerFailure(result)
        }
    }

    public func agentConnectionStatus(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) throws -> ProviderConnectionStatusReply {
        let actor = try loadConnectionActor(
            authorization: authorization, serverId: serverId, agentId: agentId, provider: provider
        )
        let result = providerCall(method: "GET", action: "status", provider: provider, agentId: agentId)
        return try statusReply(result, provider: provider, agentId: agentId, serverId: serverId, actor: actor)
    }

    public func startAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: LegacyJSONObjectBody?
    ) throws -> ProviderConnectionStartResponse {
        let actor = try loadConnectionActor(
            authorization: authorization, serverId: serverId, agentId: agentId, provider: provider
        )
        var access: String?
        if let rawAccess = body?["access"], !rawAccess.isNull {
            guard rawAccess.legacyString == "private" else {
                throw MachinesAndHostedRuntimeError.connectionAccessInvalid
            }
            access = "private"
        }
        let origin = dependencies.connectionOrigin()
        var members = [
            OrderedJSONField("returnUrl", "\(origin)/api/connections/callback/\(serverId)/\(agentId)"),
            OrderedJSONField("initiatedBy", .object([OrderedJSONField("raftUserId", actor.userId)])),
        ]
        if let access { members.append(OrderedJSONField("access", access)) }
        let result = providerCall(
            method: "POST", action: "start", provider: provider, agentId: agentId,
            body: OrderedJSON.object(members).render()
        )
        switch result {
        case .response(let status, let responseBody) where isSuccess(status):
            guard let start = AgentConnectionProviderPayload.parseConnectionStart(responseBody) else {
                throw MachinesAndHostedRuntimeError.connectionProviderError(
                    providerCode: "invalid_connection_url", providerMessage: nil, providerStatus: status
                )
            }
            return ProviderConnectionStartResponse(
                url: start.url,
                expiresAt: start.expiresAt ?? "",
                scopes: start.scopes
            )
        case .response(let status, let responseBody) where status == 404:
            throw notFoundFailure(provider: provider, agentId: agentId, body: responseBody)
        default:
            throw providerFailure(result)
        }
    }

    public func confirmAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: LegacyJSONObjectBody?
    ) throws -> ProviderConnectionStatusResponse {
        let actor = try loadConnectionActor(
            authorization: authorization, serverId: serverId, agentId: agentId, provider: provider
        )
        guard let pending = body?.string("pending"), !pending.isEmpty else {
            throw MachinesAndHostedRuntimeError.connectionInvalid("pending is required")
        }
        guard AgentConnectionProviderPayload.isIdentifier(pending) else {
            throw MachinesAndHostedRuntimeError.connectionPendingInvalid(providerCode: nil, providerMessage: nil)
        }
        let requestBody = OrderedJSON.object([
            OrderedJSONField("pending", pending),
            OrderedJSONField("raftUserId", actor.userId),
        ]).render()
        let result = providerCall(
            method: "POST", action: "confirm", provider: provider, agentId: agentId, body: requestBody
        )
        switch result {
        case .response(let status, let responseBody) where isSuccess(status):
            guard let parsed = AgentConnectionProviderPayload.parseConnectionStatus(responseBody) else {
                throw MachinesAndHostedRuntimeError.connectionProviderError(
                    providerCode: "invalid_response", providerMessage: nil, providerStatus: status
                )
            }
            return statusResponse(parsed, provider: provider, serverId: serverId, actor: actor)
        case .response(let status, let responseBody) where status == 404:
            let parts = AgentConnectionProviderPayload.providerErrorParts(responseBody)
            throw MachinesAndHostedRuntimeError.connectionPendingInvalid(
                providerCode: parts.code,
                providerMessage: redactProviderMessage(parts.message)
            )
        default:
            throw providerFailure(result)
        }
    }

    public func assignAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: LegacyJSONObjectBody?
    ) throws -> ProviderConnectionStatusReply {
        let actor = try loadConnectionActor(
            authorization: authorization, serverId: serverId, agentId: agentId, provider: provider
        )
        guard let connectorId = body?.string("connectorId"),
              AgentConnectionProviderPayload.isIdentifier(connectorId)
        else {
            throw MachinesAndHostedRuntimeError.connectionInvalid("connectorId is required")
        }
        let connector = try connectorForAction(
            provider: provider, agentId: agentId, connectorId: connectorId, actor: actor
        )
        let actingRole = connector.creatorRaftUserId == actor.userId ? "creator" : "admin"
        let requestBody = OrderedJSON.object([
            OrderedJSONField("connectorId", connectorId),
            OrderedJSONField("actingRaftUserId", actor.userId),
            OrderedJSONField("actingRole", actingRole),
        ]).render()
        let result = providerCall(
            method: "PUT", action: "assign", provider: provider, agentId: agentId, body: requestBody
        )
        switch result {
        case .response(let status, _) where isSuccess(status):
            let refreshed = providerCall(method: "GET", action: "status", provider: provider, agentId: agentId)
            return try statusReply(refreshed, provider: provider, agentId: agentId, serverId: serverId, actor: actor)
        case .response(let status, let responseBody) where status == 404:
            throw notFoundFailure(provider: provider, agentId: agentId, body: responseBody, connectorScoped: true)
        default:
            throw providerFailure(result)
        }
    }

    /// Reads the provider status, finds `connectorId` and checks the caller may
    /// act on it.
    private func connectorForAction(
        provider: String,
        agentId: String,
        connectorId: String,
        actor: ConnectionActor
    ) throws -> HostedConnectionConnectorRecord {
        let statusResult = providerCall(method: "GET", action: "status", provider: provider, agentId: agentId)
        guard case .response(let statusCode, let statusBody) = statusResult, isSuccess(statusCode) else {
            if case .response(404, let body) = statusResult {
                throw notFoundFailure(provider: provider, agentId: agentId, body: body)
            }
            throw providerFailure(statusResult)
        }
        guard let parsed = AgentConnectionProviderPayload.parseConnectionStatus(statusBody),
              let connector = parsed.connectors.first(where: { $0.id == connectorId })
        else {
            throw MachinesAndHostedRuntimeError.connectionConnectorNotFound
        }
        let isManager = actor.role == "owner" || actor.role == "admin"
        guard isManager || connector.creatorRaftUserId == actor.userId else {
            throw MachinesAndHostedRuntimeError.connectionConnectorForbidden
        }
        return connector
    }

    public func disconnectAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) throws -> NoContentResponse {
        _ = try loadConnectionActor(
            authorization: authorization, serverId: serverId, agentId: agentId, provider: provider
        )
        let result = providerCall(method: "DELETE", action: "disconnect", provider: provider, agentId: agentId)
        switch result {
        case .response(let status, let responseBody) where status == 404:
            throw notFoundFailure(provider: provider, agentId: agentId, body: responseBody)
        case .response(let status, _) where isSuccess(status):
            return NoContentResponse()
        case .empty(let status) where isSuccess(status):
            return NoContentResponse()
        default:
            throw providerFailure(result)
        }
    }

    public func disconnectAgentConnector(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        connectorId: String
    ) throws -> NoContentResponse {
        let actor = try loadConnectionActor(
            authorization: authorization, serverId: serverId, agentId: agentId, provider: provider
        )
        guard AgentConnectionProviderPayload.isIdentifier(connectorId) else {
            throw MachinesAndHostedRuntimeError.connectionInvalid("connectorId is required")
        }
        let connector = try connectorForAction(
            provider: provider, agentId: agentId, connectorId: connectorId, actor: actor
        )
        let actingRole = connector.creatorRaftUserId == actor.userId ? "creator" : "admin"
        let requestBody = OrderedJSON.object([
            OrderedJSONField("actingRaftUserId", actor.userId),
            OrderedJSONField("actingRole", actingRole),
        ]).render()
        let result = providerCall(
            method: "DELETE", action: "disconnectConnector", provider: provider, agentId: agentId,
            body: requestBody
        )
        switch result {
        case .response(let status, let responseBody) where status == 502:
            throw MachinesAndHostedRuntimeError.connectionConnectorDisconnectPartial(
                failedCount: AgentConnectionProviderPayload.failedConnectorCount(responseBody)
            )
        case .response(let status, let responseBody) where status == 404:
            throw notFoundFailure(provider: provider, agentId: agentId, body: responseBody, connectorScoped: true)
        case .response(let status, _) where isSuccess(status):
            return NoContentResponse()
        case .empty(let status) where isSuccess(status):
            return NoContentResponse()
        default:
            throw providerFailure(result)
        }
    }
}
