import Foundation
import RaftShared

// MARK: - Injected dependencies

/// Everything the agent private surface needs.
///
/// The agent, machine, server, message and provider-connection rows belong to
/// their stores. The human session lookup, the realtime emitter, the hosted
/// provider flag, the wake-hint projection (it spans the channel, message,
/// joint and suppression ledgers) and the system notice a role change posts into
/// the actor's DM belong to domains that have not migrated and stay behind
/// closures; `live(directory:)` wires them at the composition root.
struct AgentPrivateSurfaceDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var emitRealtime: @Sendable (String, String, String?) -> Void
    var oauth: OAuthLedger
    var agents: AgentsRuntimeStore
    var machines: MachinesAndComputersStore
    var channels: ServersAndChannelsStore
    var messages: MessagesAndThreadsStore
    var cards: ManagedMCPAndCardsStore
    var hostedProviderConfigured: @Sendable () -> Bool
    var pendingWakeHints: @Sendable (
        _ agentId: String,
        _ agent: OAuthLedger.AgentRuntimeInfo,
        _ sinceSeq: Int?,
        _ limit: Int
    ) -> [AgentWakeHintRow]
    var directChannelId: @Sendable (_ serverId: String, _ agentId: String, _ peerId: String) -> String?
    var postAgentRoleNotice: @Sendable (
        _ serverId: String,
        _ actorUserId: String,
        _ agentId: String,
        _ agentName: String,
        _ from: String,
        _ to: String
    ) -> Void

    static func live(directory source: EmailLoginDirectory) -> AgentPrivateSurfaceDependencies {
        AgentPrivateSurfaceDependencies(
            sessionUserId: { source.sessionUserId(authorization: $0) },
            emitRealtime: { room, event, payload in
                source.realtimeRelay.emit(room, event, payload)
            },
            oauth: source.oauth,
            agents: source.agentsRuntimeStore,
            machines: source.machinesAndComputersStore,
            channels: source.serversAndChannelsStore,
            messages: source.messagesAndThreadsStore,
            cards: source.managedMCPAndCardsStore,
            hostedProviderConfigured: { [agents = source.agentsRuntimeStore] in agents.hostedProviderConfigured() },
            pendingWakeHints: { agentId, agent, sinceSeq, limit in
                source.pendingWakeHints(agentId: agentId, agent: agent, sinceSeq: sinceSeq, limit: limit)
            },
            directChannelId: { serverId, agentId, peerId in
                source.actionCardPrepare.dmChannelId(serverId: serverId, agentId: agentId, peerId: peerId)
            },
            postAgentRoleNotice: { [notices = source.agentRoleNotices] serverId, actorUserId, agentId, agentName, from, to in
                notices.post(
                    serverId: serverId,
                    actorUserId: actorUserId,
                    agentId: agentId,
                    agentName: agentName,
                    from: from,
                    to: to
                )
            }
        )
    }
}

// MARK: - Service

/// Agent records and their private surfaces: creation, listing, the profile
/// patch, credentials and status, the wake-hint stream and the assistant-owner
/// inbox.
///
/// The service owns the orchestration and returns the published DTOs; every
/// refusal is an `AgentPrivateSurfaceError`. It builds no HTTP reply, header set
/// or response body. Credential use, the onboarding greeting and the assistant
/// link are single store critical sections. The runtime config document keeps
/// the legacy sorted-key serializer bytes behind `AgentRuntimeConfigDocument`.
public struct AgentPrivateSurfaceService: Sendable {
    let dependencies: AgentPrivateSurfaceDependencies

    /// Production wiring.
    public init(directory: EmailLoginDirectory) {
        self.init(dependencies: .live(directory: directory))
    }

    init(dependencies: AgentPrivateSurfaceDependencies) {
        self.dependencies = dependencies
    }

    private var oauth: OAuthLedger { dependencies.oauth }

    private static let reservedHandles: Set<String> = [
        "all", "human", "humans", "agent", "agents", "here",
        "idle", "busy", "system", "reminders",
    ]

    private static func fractionalISO(_ date: Date) -> String {
        DateText.isoString(date)
    }

    // MARK: - POST /api/agents

    public func createAgent(
        authorization: String?,
        serverId: String,
        body: LegacyJSONObjectBody?
    ) throws -> CreatedAgentResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw AgentPrivateSurfaceError.notAMember
        }
        guard role != "guest" else { throw AgentPrivateSurfaceError.forbidden }
        guard let fields = body?.members,
              let name = fields["name"]?.legacyString,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AgentPrivateSurfaceError.invalidAgent
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.reservedHandles.contains(trimmedName.lowercased()) else {
            throw AgentPrivateSurfaceError.reservedName
        }
        let onboardingRequest = fields["onboarding"]?.castBool == true
        if onboardingRequest {
            guard role == "owner" || role == "admin" else {
                throw AgentPrivateSurfaceError.onboardingRequiresAdmin
            }
            if let existing = dependencies.channels.serverOnboardingSettings[serverId]?.agentId {
                throw AgentPrivateSurfaceError.onboardingAgentExists(agentId: existing)
            }
            if oauth.serverAgents(serverId: serverId).contains(where: {
                !$0.deleted && $0.name.caseInsensitiveCompare("Cindy") == .orderedSame
            }) {
                throw AgentPrivateSurfaceError.cindyExists
            }
        }
        let duplicate = oauth.serverAgents(serverId: serverId).contains {
            !$0.deleted && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        guard !duplicate else { throw AgentPrivateSurfaceError.nameTaken }
        let external = fields["external"]?.castBool ?? false
        if external, fields["machineId"] != nil {
            throw AgentPrivateSurfaceError.externalWithMachine
        }
        let hostedProvider = try validatedHostedProvider(fields["provider"], serverId: serverId, external: external)
        let rawConfig = AgentRuntimeConfigDocument(request: fields["runtimeConfig"]) ?? AgentRuntimeConfigDocument()
        try validateFormValues(fields, serverId: serverId)
        if let legacyRuntime = fields["runtime"]?.legacyString,
           MachineMigrationPolicy.deprecatedAgentRuntimes.contains(legacyRuntime) {
            throw AgentPrivateSurfaceError.deprecatedRuntime(legacyRuntime)
        }
        if let configRuntime = rawConfig.runtime,
           MachineMigrationPolicy.deprecatedAgentRuntimes.contains(configRuntime) {
            throw AgentPrivateSurfaceError.deprecatedRuntime(configRuntime)
        }
        try Self.checkStructure(rawConfig)
        var config = rawConfig.normalized()
        var envVars: [String: String] = [:]
        if external {
            config = .external
        } else if fields["envVars"] != nil {
            let validation = AgentRuntimeConfigDocument.validatedEnvVars(fields["envVars"])
            if let error = validation.error { throw AgentPrivateSurfaceError.invalidEnvVars(error) }
            if let env = validation.env { config.setEnv(env) }
        }
        if !external {
            if let unsupported = config.unsupportedCommandRuntime {
                throw AgentPrivateSurfaceError.commandNotSupported(runtime: unsupported)
            }
            envVars = config.derivedEnvVars(userEnv: config.userEnv)
        }
        if onboardingRequest {
            var onboardingEnv = config.userEnv
            onboardingEnv["SLOCK_ONBOARDING_MEMORY_SEED"] = "first-cindy"
            config.setEnv(onboardingEnv)
            envVars = config.derivedEnvVars(userEnv: onboardingEnv)
        }
        let effectiveName = onboardingRequest ? "Cindy" : name
        let runtime = external ? "external" : (config.runtime ?? "managed")
        let machineId = fields["machineId"]?.legacyString
        try checkBuiltinCatalog(machineId: machineId, config: config)
        let configJSON = config.serialized()
        let envJSON = external ? "null" : AgentRuntimeConfigDocument.serializedEnv(envVars)
        let agentId = oauth.createAgent(
            serverId: serverId,
            name: effectiveName,
            displayName: onboardingRequest ? "Cindy" : nil,
            avatarUrl: onboardingRequest ? "pixel:mug" : nil,
            description: onboardingRequest ? "Onboarding Assistant" : nil,
            creatorUserId: userId,
            runtime: runtime,
            runtimeConfigJSON: configJSON,
            envVarsJSON: envJSON
        )
        if onboardingRequest {
            oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "admin")
            dependencies.channels.bindOnboardingAgent(serverId: serverId, agentId: agentId)
            dependencies.emitRealtime(
                "server:\(serverId)", "agent:updated",
                OrderedJSON.object([OrderedJSONField("agentId", agentId)]).render()
            )
        }
        if let machineId, !machineId.isEmpty {
            dependencies.agents.bindMachine(agentId: agentId, machineId: machineId)
        }
        if let hostedProvider {
            dependencies.agents.beginHostedProvisioning(agentId: agentId, provider: hostedProvider, now: Date())
        }
        let creatorDm = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: agentId)
        oauth.addChannelAgent(channelId: creatorDm, agentId: agentId)
        let dmPayload = OrderedJSON.object([OrderedJSONField("channelId", creatorDm)]).render()
        dependencies.emitRealtime("channel:\(creatorDm)", "dm:new", dmPayload)
        dependencies.emitRealtime("user:\(userId)", "dm:new", dmPayload)
        let responseConfigJSON = AgentRuntimeConfigDocument.redactedConfigJSON(configJSON) ?? configJSON
        let model = AgentRuntimeConfigDocument.agentModel(from: responseConfigJSON, external: external)
        let projection = AgentRuntimeProjection(
            id: agentId,
            name: effectiveName,
            runtime: runtime,
            model: model,
            external: external,
            envVarsJSON: envJSON,
            runtimeConfigJSON: responseConfigJSON
        )
        var broadcast = projection
        broadcast.name = name
        dependencies.emitRealtime(
            "server:\(serverId)", "agent:created",
            OrderedJSON.object([OrderedJSONField("agent", .raw(broadcast.broadcastJSON))]).render()
        )
        let created = oauth.agentRuntimeInfo(id: agentId)
        return CreatedAgentResponse(
            agent: projection,
            creatorId: userId,
            displayName: created?.displayName ?? effectiveName,
            description: created?.description,
            avatarUrl: created?.avatarUrl,
            serverRole: oauth.agentRole(serverId: serverId, agentId: agentId) ?? "member",
            hostedProvider: hostedProvider
        )
    }

    /// The hosted runtime provider an external agent may select: only
    /// `antiproton`, only for external agents, only on a flagged server with a
    /// configured deployment.
    private func validatedHostedProvider(
        _ value: JSONValue?,
        serverId: String,
        external: Bool
    ) throws -> String? {
        guard let provider = value?.legacyString, !provider.isEmpty else { return nil }
        guard provider == "antiproton" else { throw AgentPrivateSurfaceError.unknownRuntimeProvider }
        guard external else { throw AgentPrivateSurfaceError.providerOnlyForExternal }
        guard dependencies.agents.hostedRuntimeEnabled(serverId: serverId) else {
            throw AgentPrivateSurfaceError.runtimeProviderDisabled
        }
        guard dependencies.hostedProviderConfigured() else {
            throw AgentPrivateSurfaceError.runtimeProviderNotConfigured
        }
        return provider
    }

    /// The version-2 form checks: a `connection:` provider must be a live
    /// connection of this server, and a picked model must be available on the
    /// chosen Computer's runtime.
    private func validateFormValues(
        _ fields: [String: JSONValue],
        serverId: String
    ) throws {
        guard let formRef = fields["formDefinitionRef"]?.legacyObject,
              formRef["protocolVersion"]?.castInt == 2,
              let formValues = fields["formValues"]?.legacyObject
        else { return }
        if let providerId = formValues["providerId"]?.legacyString, providerId.hasPrefix("connection:") {
            let connectionId = String(providerId.dropFirst("connection:".count))
            guard ServerScope.isUUID(connectionId) else {
                throw AgentPrivateSurfaceError.invalidProviderConnectionId
            }
            let exists = dependencies.cards.providerConnections.contains {
                $0.id == connectionId && $0.serverId == serverId
            }
            guard exists else { throw AgentPrivateSurfaceError.providerConnectionUnavailable }
        }
        if let machineId = fields["machineId"]?.legacyString,
           let runtimeId = formRef["runtimeId"]?.legacyString,
           let model = formValues["model"]?.legacyString,
           !model.isEmpty,
           let models = dependencies.machines.agentRuntimeModelsForMachine?(machineId, runtimeId),
           !models.contains(model) {
            throw AgentPrivateSurfaceError.modelNotAvailable
        }
    }

    static func checkStructure(_ config: AgentRuntimeConfigDocument) throws {
        switch config.structureError {
        case .modelNameRequired:
            throw AgentPrivateSurfaceError.runtimeConfigModelNameRequired
        case .providerNotSupportedForCursor:
            throw AgentPrivateSurfaceError.runtimeConfigProviderNotSupportedForCursor
        case .providerAPIKeyRequired:
            throw AgentPrivateSurfaceError.runtimeConfigProviderAPIKeyRequired
        case nil:
            return
        }
    }

    /// `409` when the target Computer cannot answer for its Built-in catalog.
    func checkBuiltinCatalog(machineId: String?, config: AgentRuntimeConfigDocument) throws {
        guard let machineId,
              let modelId = config.builtinModelId,
              let check = dependencies.machines.builtinModelCatalogCheck,
              check(machineId, modelId) == .catalogUnavailable
        else { return }
        throw AgentPrivateSurfaceError.builtinCatalogUnavailable
    }

    // MARK: - Reads

    private func summary(
        _ agent: OAuthLedger.AgentRuntimeInfo,
        role: String,
        userId: String,
        lastSeen: [String: Date]?
    ) -> AgentSummary {
        let canSeeConfig = role == "owner" || role == "admin" || agent.creatorUserId == userId
        let external = agent.runtime == "external"
        var includesLastSeen = false
        var lastSeenAt: String?
        if let lastSeen, external {
            includesLastSeen = true
            lastSeenAt = lastSeen[agent.id].map(Self.fractionalISO)
        }
        return AgentSummary(
            id: agent.id,
            name: agent.name,
            displayName: agent.displayName,
            runtime: agent.runtime,
            model: AgentRuntimeConfigDocument.agentModel(from: agent.runtimeConfigJSON, external: external),
            external: external,
            serverRole: oauth.agentRole(serverId: agent.serverId, agentId: agent.id) ?? "member",
            creatorId: agent.creatorUserId,
            description: agent.description,
            includesLastSeen: includesLastSeen,
            lastSeenAt: lastSeenAt,
            config: canSeeConfig
                ? AgentSummary.Config(
                    runtimeConfigJSON: AgentRuntimeConfigDocument.redactedConfigJSON(agent.runtimeConfigJSON) ?? "null",
                    envVarsJSON: agent.envVarsJSON ?? "null"
                )
                : nil
        )
    }

    public func listServerAgents(authorization: String?, serverId: String) throws -> AgentListResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw AgentPrivateSurfaceError.notAMember
        }
        let seen = dependencies.agents.lastSeenSnapshot()
        return AgentListResponse(agents: oauth.serverAgents(serverId: serverId).map {
            summary($0, role: role, userId: userId, lastSeen: seen)
        })
    }

    public func listArchivedAgents(authorization: String?, serverId: String) throws -> ArchivedAgentsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw AgentPrivateSurfaceError.notAMember
        }
        guard role != "guest" else { throw AgentPrivateSurfaceError.forbidden }
        let rows = dependencies.agents.archivedAgents(serverId: serverId).map {
            ArchivedAgentsResponse.Row(
                agentId: $0.agentId,
                machineName: $0.machineName.isEmpty ? nil : $0.machineName,
                workspaceState: $0.workspaceState
            )
        }
        // The published order is the lexicographic order of the rendered rows.
        return ArchivedAgentsResponse(rows: rows.sorted { $0.json.render() < $1.json.render() })
    }

    public func agentRuntimeOptions(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> AgentRuntimeOptionsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            throw AgentPrivateSurfaceError.agentMissing
        }
        return AgentRuntimeOptionsResponse(agentId: agentId)
    }

    public func getAgent(
        authorization: String?,
        agentId: String,
        serverId: String
    ) throws -> AgentDetailResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard agentId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            throw AgentPrivateSurfaceError.agentNotFound
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted,
              serverId.isEmpty || agent.serverId == serverId
        else {
            throw AgentPrivateSurfaceError.agentNotFound
        }
        guard let role = oauth.memberRole(serverId: agent.serverId, userId: userId) else {
            throw AgentPrivateSurfaceError.notAMember
        }
        if role == "guest" {
            return .guest(id: agent.id, name: agent.name, displayName: agent.displayName, description: agent.description)
        }
        return .full(summary(agent, role: role, userId: userId, lastSeen: nil))
    }

    public func externalAgentStatus(
        authorization: String?,
        agentId: String
    ) throws -> ExternalAgentStatusResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard let info = oauth.agentRuntimeInfo(id: agentId), !info.deleted else {
            throw AgentPrivateSurfaceError.agentNotFound
        }
        guard oauth.memberRole(serverId: info.serverId, userId: userId) != nil else {
            throw AgentPrivateSurfaceError.notAMember
        }
        guard info.runtime == "external" else { throw AgentPrivateSurfaceError.agentNotExternal }
        let usage = dependencies.agents.credentialUsage(agentId: agentId)
        let setupState: String
        if usage.lastUsedAt != nil {
            setupState = "connected"
        } else if usage.minted {
            setupState = "credential_minted"
        } else {
            setupState = "waiting_for_login"
        }
        return ExternalAgentStatusResponse(
            setupState: setupState,
            credentialLastUsedAt: usage.lastUsedAt.map { ISO8601DateFormatter().string(from: $0) }
        )
    }

    public func manageableAgentList(authorization: String?) throws -> ManageableAgentsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        let result = oauth.manageableAgents(userId: userId)
        let reason: String
        if !result.agents.isEmpty {
            reason = "ok"
        } else if result.serverCount > 0 {
            reason = "no_agents_on_manageable_servers"
        } else {
            reason = "no_manageable_server"
        }
        return ManageableAgentsResponse(
            agents: result.agents.map {
                ManageableAgentsResponse.Row(id: $0.id, name: $0.name, serverId: $0.serverId, serverName: $0.serverName)
            },
            reason: reason,
            manageableServerCount: result.serverCount
        )
    }

    // MARK: - Login, bootstrap token, creator, avatar

    /// `POST /api/agent/login`: the runner bootstrap is never available, so every
    /// request ends in a refusal.
    public func agentLogin(body: LegacyJSONObjectBody?) throws -> AgentLoginResponse {
        let enabled = (ProcessInfo.processInfo.environment["SLOCK_SELF_HOSTED_RUNNER_BOOTSTRAP_ENABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        guard enabled else { throw AgentPrivateSurfaceError.bootstrapDisabled }
        let token = body?.string("bootstrapToken")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw AgentPrivateSurfaceError.bootstrapTokenRequired }
        throw AgentPrivateSurfaceError.tokenInvalid
    }

    public func createAgentBootstrapToken(
        authorization: String?,
        serverId: String,
        agentId: String
    ) throws -> AgentBootstrapTokenResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            throw AgentPrivateSurfaceError.agentMissing
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            throw AgentPrivateSurfaceError.insufficientCredentialRole
        }
        guard info.runtime == "external" else { throw AgentPrivateSurfaceError.agentNotExternalCoded }
        return AgentBootstrapTokenResponse()
    }

    public func patchAgentCreator(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: LegacyJSONObjectBody?
    ) throws -> AgentCreatorResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            throw AgentPrivateSurfaceError.agentMissing
        }
        guard role == "owner" || role == "admin" else { throw AgentPrivateSurfaceError.agentMissing }
        guard let body, body.string("creatorType") == "user",
              let creatorId = body.string("creatorId"),
              oauth.memberRole(serverId: serverId, userId: creatorId) != nil
        else {
            throw AgentPrivateSurfaceError.invalidCreator
        }
        _ = oauth.setAgentCreator(id: agentId, creatorUserId: creatorId)
        return AgentCreatorResponse(creatorId: creatorId)
    }

    /// The caller must be an owner, an admin or the agent's creator.
    struct AgentActor {
        var userId: String
        var role: String
        var info: OAuthLedger.AgentManagementInfo
    }

    func authorizedActor(authorization: String?, agentId: String) throws -> AgentActor {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted else {
            throw AgentPrivateSurfaceError.agentNotFound
        }
        guard let role = oauth.memberRole(serverId: info.serverId, userId: userId) else {
            throw AgentPrivateSurfaceError.notAMember
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            throw AgentPrivateSurfaceError.forbidden
        }
        return AgentActor(userId: userId, role: role, info: info)
    }

    public func uploadAgentAvatar(
        authorization: String?,
        agentId: String,
        byteCount: Int
    ) throws -> AgentAvatarResponse {
        _ = try authorizedActor(authorization: authorization, agentId: agentId)
        let maxBytes = 5 * 1024 * 1024
        guard byteCount <= maxBytes else { throw AgentPrivateSurfaceError.avatarTooLarge(maxBytes: maxBytes) }
        let key = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let avatarUrl = "/api/avatars/users/\(key).webp"
        oauth.updateAgentAvatar(id: agentId, avatarUrl: avatarUrl)
        return AgentAvatarResponse(avatarUrl: avatarUrl)
    }

    // MARK: - Credential use and the push webhook

    /// Records one use of an agent credential and tells the server room when an
    /// external agent was seen.
    public func recordAgentCredentialUse(token: String) {
        guard let agentId = dependencies.agents.recordCredentialUse(
            token: token,
            now: Date(),
            defaultThrottleMs: AuthTokenCodec.agentCredentialUseDefaultThrottleMs
        ) else { return }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.runtime == "external" else { return }
        dependencies.emitRealtime(
            "server:\(agent.serverId)",
            "agent:seen",
            OrderedJSON.object([
                OrderedJSONField("agentId", agent.id),
                OrderedJSONField("lastSeenAt", Self.fractionalISO(Date())),
            ]).render()
        )
    }

    public func putAgentPushWebhook(
        authorization: String?,
        body: LegacyJSONObjectBody?
    ) throws -> OkResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentPrivateSurfaceError.missingAuthorizationHeader
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = dependencies.agents.agentCredential(token: token), credential.revokedAt == nil else {
            throw AgentPrivateSurfaceError.invalidToken
        }
        guard let rawURL = body?.string("url"),
              let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let secret = body?.string("secret"), !secret.isEmpty
        else {
            throw AgentPrivateSurfaceError.webhookFieldsRequired
        }
        dependencies.agents.setPushWebhook(agentId: credential.agentId, url: rawURL, secret: secret)
        return OkResponse()
    }
}
