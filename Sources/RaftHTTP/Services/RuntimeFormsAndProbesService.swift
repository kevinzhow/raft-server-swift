import Foundation

// MARK: - Injected dependencies

/// The runtime-form surface's owners and operations, assembled by its explicit
/// constructor. Registration and API-key lookup use the machine owner directly.
struct RuntimeFormsAndProbesDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var emitRealtime: @Sendable (String, String, String?) -> Void
    /// `MachinesAndComputersStore.registerMachine`, the machine row insert.
    var registerMachine: @Sendable (_ serverId: String, _ userId: String, _ name: String) -> String
    /// The machine owner's current API-key read.
    var machineAPIKey: @Sendable (_ machineId: String) -> String?
    var oauth: OAuthLedger
    var machines: MachinesAndComputersStore
    var servers: ServersAndChannelsStore
    var notifications: NotificationsStore
    var agents: AgentsRuntimeStore
    var now: @Sendable () -> Date
}

// MARK: - Service

/// Runtime form definitions, option sources and probes, machine runtime account
/// usage, and the server settings/notification projections the runtime routes
/// read.
///
/// The service owns the orchestration and returns the published
/// `JSONBodyConvertible` DTOs; every refusal is a `RuntimeFormsAndProbesError`.
/// It builds no HTTP reply, header set or body text. The usage-refresh claim,
/// the notification patch and the onboarding patch are each one store critical
/// section.
public struct RuntimeFormsAndProbesService: Sendable {
    let dependencies: RuntimeFormsAndProbesDependencies

    init(
        auth: AuthCoreService,
        oauth: OAuthLedger,
        machines: MachinesAndComputersStore,
        servers: ServersAndChannelsStore,
        notifications: NotificationsStore,
        agents: AgentsRuntimeStore,
        realtime: RealtimeRelayService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(dependencies: RuntimeFormsAndProbesDependencies(
            sessionUserId: { try? auth.authenticate($0) },
            emitRealtime: { room, event, payload in realtime.emit(room, event, payload) },
            registerMachine: { serverId, userId, name in
                machines.registerMachine(serverId: serverId, userId: userId, name: name)
            },
            machineAPIKey: { machines.machineAPIKey(machineId: $0) },
            oauth: oauth,
            machines: machines,
            servers: servers,
            notifications: notifications,
            agents: agents,
            now: now
        ))
    }

    init(dependencies: RuntimeFormsAndProbesDependencies) {
        self.dependencies = dependencies
    }

    // MARK: Constants

    static let onboardingSteps: Set<String> = [
        "add-computer", "create-agent", "invite-teammates", "join-community", "notifications",
    ]

    static let runtimeFormSchemas: [String: String] = [
        "builtin": "builtin-pi.create.v3",
        "claude": "claude.create.v1",
        "codex": "codex.create.v1",
        "kimi-sdk": "kimi-sdk.create.v1",
        "cursor": "cursor.create.v1",
        "opencode": "opencode.create.v1",
        "pi": "pi.create.v1",
        "gemini": "gemini.create.v1",
        "kimi": "kimi.create.v1",
        "antigravity": "antigravity.create.v1",
        "grok": "grok.create.v1",
    ]

    /// Runtimes that still publish a v1 form definition.
    static let runtimeFormV1Runtimes: Set<String> = ["builtin", "kimi-sdk"]

    /// Runtimes whose released form only exists at protocol v2; v1 clients must
    /// see them as having no form at all.
    static let runtimeFormV2Only: Set<String> = [
        "claude", "cursor", "pi", "opencode", "gemini", "codex", "grok", "antigravity", "kimi",
    ]

    static let grokBundledModels: [RuntimeModelProbeModel] = [
        RuntimeModelProbeModel(
            id: "grok-4.5",
            label: "Grok 4.5",
            supportedReasoningEfforts: ["high", "medium", "low"],
            defaultReasoningEffort: "high"
        ),
        RuntimeModelProbeModel(id: "grok-4.6", label: "Grok 4.6"),
        RuntimeModelProbeModel(id: "grok-composer-2.5-fast", label: "Composer 2.5"),
    ]

    static let runtimeAccountUsageProviders: Set<String> = ["claude", "codex", "kimi", "grok"]

    /// A usage refresh within this many seconds of the last one is refused.
    static let usageRefreshCooldown: TimeInterval = 60

    // MARK: - GET /api/agents/:id/runtime-form

    /// The stored runtime values of one agent, without any secret.
    public func agentRuntimeForm(
        authorization: String?,
        serverId: String,
        agentId: String,
        language: String?
    ) throws -> AgentRuntimeFormResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard let agent = dependencies.oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            throw RuntimeFormsAndProbesError.agentNotFound
        }
        let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            throw RuntimeFormsAndProbesError.editAgentsRequired
        }
        guard agent.runtime != "external",
              let schemaVersion = Self.runtimeFormSchemas[agent.runtime]
        else {
            throw RuntimeFormsAndProbesError.noRuntimeForm
        }
        let config = AgentRuntimeConfigProjection.parse(agent.runtimeConfigJSON)
        var values = AgentRuntimeFormValues(envVars: config.envVars ?? [:])
        if agent.runtime != "antigravity", let model = config.model {
            values.model = model.id ?? model.name
        }
        if agent.runtime == "builtin" {
            guard let provider = config.provider, provider.kind == "preset" || provider.kind == "gateway" else {
                throw RuntimeFormsAndProbesError.noRuntimeForm
            }
            values.providerId = provider.providerId ?? ""
            values.model = config.model?.id ?? config.model?.name ?? ""
            values.loadLocalPlugins = config.loadLocalPlugins == true
            if provider.kind == "gateway" {
                values.baseUrl = provider.baseUrl ?? ""
                values.supportsImageInput = provider.supportsImageInput == true
            }
        }
        var writeOnly: [String] = agent.runtime == "builtin" ? ["/apiKey"] : []
        if agent.runtime == "claude" {
            values.provider = config.provider?.kind ?? "default"
            values.apiUrl = config.provider?.apiUrl
            values.reasoningEffort = config.reasoningEffort
            values.fastMode = config.fastMode ?? false
            values.command = config.command
            writeOnly = ["/apiKey"]
        }
        return AgentRuntimeFormResponse(
            runtimeId: agent.runtime,
            schemaVersion: schemaVersion,
            modelLabel: Self.prefersChinese(language) ? "模型" : "Model",
            values: values,
            writeOnlyPointers: writeOnly
        )
    }

    // MARK: - Credential lookups

    /// Whether the presented bearer is a live Computer credential (used before
    /// parsing an oversized control-manifest body so secrets never reach a parser).
    public func machineCredentialIsLive(authorization: String?) -> Bool {
        guard let token = Self.bearerToken(authorization) else { return false }
        return dependencies.machines.machineCredentialIsLive(token: token)
    }

    public func computerCredentialIsLive(authorization: String?) -> Bool {
        guard let token = Self.bearerToken(authorization) else { return false }
        return dependencies.machines.computerCredentialIsLive(token: token)
    }

    /// Keyed lookup the `/daemon/connect` handshake uses by machine id.
    public func machineCredential(id: String) -> MachineCredentialIdentity? {
        dependencies.machines.machineCredentialIdentity(id: id)
    }

    /// Keyed lookup shared by `/daemon/connect` and the legacy machine surface.
    /// A row that was adopted into a Computer attachment carries its migration
    /// stamp so the connect handshake refuses the legacy key immediately, with
    /// no TTL window.
    public func machineCredential(apiKey: String) -> MachineCredentialIdentity? {
        dependencies.machines.machine(apiKey: apiKey).map {
            MachineCredentialIdentity(
                machineId: $0.id, serverId: $0.serverId, legacyKeyMigratedAt: $0.legacyKeyMigratedAt
            )
        }
    }

    public func serverExists(id: String) -> Bool {
        dependencies.oauth.serverDetailsValue(id: id) != nil
    }

    private static func bearerToken(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    // MARK: - Server settings

    /// `GET /api/servers/:id/settings`: an owner or admin reads the onboarding
    /// block under `settings`.
    public func serverSettings(authorization: String?, serverId: String) throws -> ServerSettingsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeFormsAndProbesError.serverNotFound
        }
        guard role == "owner" || role == "admin" else {
            throw RuntimeFormsAndProbesError.forbidden
        }
        return ServerSettingsResponse(onboarding: onboardingResponse(serverId: serverId, userId: userId))
    }

    /// `GET /api/servers/:id/onboarding-settings`.
    public func serverOnboardingSettings(
        authorization: String?,
        serverId: String
    ) throws -> OnboardingSettingsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard dependencies.oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw RuntimeFormsAndProbesError.serverNotFound
        }
        return onboardingResponse(serverId: serverId, userId: userId)
    }

    /// `PATCH /api/servers/:id/onboarding-settings`.
    ///
    /// Only an owner or admin may name the onboarding agent or toggle the
    /// greeting; every member writes their own wizard progress. The server and
    /// member rows are patched in one store critical section.
    public func patchServerOnboardingSettings(
        authorization: String?,
        serverId: String,
        body: ServerOnboardingPatchRequest?
    ) throws -> OnboardingSettingsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeFormsAndProbesError.notAMember
        }
        guard let body else {
            throw RuntimeFormsAndProbesError.invalidOnboardingSettings
        }
        let isAdmin = role == "owner" || role == "admin"
        if body["onboardingAgentId"] != nil || body["agentAllChannelGreetingEnabled"] != nil {
            guard isAdmin else {
                throw RuntimeFormsAndProbesError.onboardingAdminOnly
            }
        }
        if let greeting = body["agentAllChannelGreetingEnabled"] {
            guard greeting.legacyBool != nil else {
                throw RuntimeFormsAndProbesError.greetingNotBoolean
            }
        }
        if let rawStep = body["onboardingWizardCurrentStep"], !rawStep.isJSONNull {
            guard let step = rawStep.legacyString, Self.onboardingSteps.contains(step) else {
                throw RuntimeFormsAndProbesError.invalidOnboardingStep
            }
        }
        var patch = ServersAndChannelsStore.OnboardingPatch(isAdmin: isAdmin)
        if let rawAgent = body["onboardingAgentId"] {
            if rawAgent.isJSONNull {
                patch.agentId = .clear
            } else if let agentId = rawAgent.legacyString {
                patch.agentId = .set(agentId)
            }
        }
        patch.greeting = body["agentAllChannelGreetingEnabled"]?.legacyBool
        patch.reminderOptOut = body["setupModalReminderOptOut"]?.legacyBool
        if let rawStep = body["onboardingWizardCurrentStep"] {
            if rawStep.isJSONNull {
                patch.currentStep = .clear
            } else if let step = rawStep.legacyString {
                patch.currentStep = .set(step)
            }
        }
        let dismissKeys: [(String, String)] = [
            ("dismissedAddComputerStep", "add-computer"),
            ("dismissedCreateAgentStep", "create-agent"),
            ("dismissedInviteStep", "invite-teammates"),
            ("dismissedCommunityStep", "join-community"),
            ("dismissedNotificationStep", "notifications"),
        ]
        patch.dismissedSteps = dismissKeys.compactMap { field, step in
            body[field]?.legacyBool == true ? step : nil
        }
        let snapshot = dependencies.servers.applyOnboardingPatch(
            serverId: serverId,
            userId: userId,
            patch: patch,
            now: dependencies.now()
        )
        return onboardingResponse(serverId: serverId, snapshot: snapshot)
    }

    private func onboardingResponse(serverId: String, userId: String) -> OnboardingSettingsResponse {
        onboardingResponse(
            serverId: serverId,
            snapshot: dependencies.servers.onboardingSnapshot(serverId: serverId, userId: userId)
        )
    }

    private func onboardingResponse(
        serverId: String,
        snapshot: ServersAndChannelsStore.OnboardingSnapshot
    ) -> OnboardingSettingsResponse {
        let slug = dependencies.oauth.serverDetailsValue(id: serverId)?.slug ?? ""
        func dismissed(_ key: String) -> String? {
            snapshot.user.dismissed[key].map(RuntimeUsageISO.string)
        }
        return OnboardingSettingsResponse(
            onboardingAgentId: snapshot.agentId,
            agentAllChannelGreetingEnabled: snapshot.greeting,
            onboardingWizardEnabled: !(slug == "community" || slug == "community-cn"),
            setupModalReminderOptOut: snapshot.user.reminderOptOut,
            dismissedAddComputerStepAt: dismissed("add-computer"),
            dismissedCreateAgentStepAt: dismissed("create-agent"),
            dismissedInviteStepAt: dismissed("invite-teammates"),
            dismissedCommunityStepAt: dismissed("join-community"),
            dismissedNotificationStepAt: dismissed("notifications"),
            onboardingWizardCurrentStep: snapshot.user.currentStep
        )
    }

    // MARK: - Server notification settings

    /// `GET /api/servers/:id/notification-settings`.
    public func memberNotificationSettings(
        authorization: String?,
        serverId: String
    ) throws -> ServerNotificationSettingsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard dependencies.oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw RuntimeFormsAndProbesError.serverNotFound
        }
        return Self.notificationResponse(
            dependencies.notifications.serverNotificationPref(key: "\(serverId)\n\(userId)")
        )
    }

    /// `PATCH /api/servers/:id/notification-settings`.
    ///
    /// A changed row bumps `prefsVersion` and publishes
    /// `notification_prefs:updated` to the member's own room; the read, the
    /// decision and the write are one store critical section.
    public func patchServerNotificationSettings(
        authorization: String?,
        serverId: String,
        body: ServerNotificationPatchRequest?
    ) throws -> ServerNotificationSettingsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard dependencies.oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw RuntimeFormsAndProbesError.serverNotFound
        }
        guard let body else {
            throw RuntimeFormsAndProbesError.invalidNotificationSettings
        }
        if let muted = body["serverPushMuted"], muted.legacyBool == nil {
            throw RuntimeFormsAndProbesError.pushMutedNotBoolean
        }
        if let rawMode = body["serverPushMode"] {
            guard let mode = rawMode.legacyString, ["all", "mentions", "none"].contains(mode) else {
                throw RuntimeFormsAndProbesError.invalidPushMode
            }
        }
        let result = dependencies.notifications.patchServerNotificationPref(
            key: "\(serverId)\n\(userId)",
            mode: body["serverPushMode"]?.legacyString,
            muted: body["serverPushMuted"]?.legacyBool
        )
        let response = Self.notificationResponse(result.prefs)
        if result.changed {
            dependencies.emitRealtime(
                "user:\(userId)",
                "notification_prefs:updated",
                response.updatedEventPayload(serverId: serverId)
            )
        }
        return response
    }

    private static func notificationResponse(
        _ prefs: NotificationsStore.ServerNotificationPref
    ) -> ServerNotificationSettingsResponse {
        ServerNotificationSettingsResponse(
            serverPushMuted: prefs.muted,
            serverPushMentionsOnly: prefs.mentionsOnly,
            serverPushMode: prefs.mode,
            prefsVersion: prefs.version
        )
    }

    // MARK: - POST /api/servers/:id/machines

    /// Registers a machine (owner or admin) and publishes `machine:updated`.
    public func registerServerMachine(
        authorization: String?,
        serverId: String,
        body: ServerMachineRegistrationRequest?
    ) throws -> ServerMachineRegistrationResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeFormsAndProbesError.serverNotFound
        }
        guard role == "owner" || role == "admin" else {
            throw RuntimeFormsAndProbesError.registerMachinesRequired
        }
        guard let name = body?["name"]?.legacyString,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RuntimeFormsAndProbesError.nameRequired
        }
        let machineId = dependencies.registerMachine(serverId, userId, name)
        let response = ServerMachineRegistrationResponse(
            id: machineId,
            serverId: serverId,
            name: name,
            userId: userId,
            apiKey: dependencies.machineAPIKey(machineId) ?? ""
        )
        dependencies.emitRealtime("server:\(serverId)", "machine:updated", response.updatedEventPayload())
        return response
    }

    // MARK: - Runtime form definitions

    /// `GET .../runtime-form-definitions/:runtimeId` (v1) and
    /// `GET .../runtime-forms/v2/:runtimeId` (v2).
    public func runtimeFormDefinition(
        authorization: String?,
        serverId: String,
        machineId: String,
        runtimeId: String,
        protocolVersion: Int,
        schemaVersion: String?,
        language: String?
    ) throws -> RuntimeFormDefinitionResponse {
        _ = try authorizedMachine(
            authorization: authorization,
            serverId: serverId,
            machineId: machineId,
            purpose: "inspect runtime forms"
        )
        let expected = try expectedSchema(
            runtimeId: runtimeId,
            protocolVersion: protocolVersion,
            schemaVersion: schemaVersion,
            unknown: .runtimeFormNotFound
        )
        let chinese = Self.prefersChinese(language)
        if protocolVersion == 2 {
            if runtimeId == "builtin" {
                return .builtinV2(schemaVersion: expected, chinese: chinese)
            }
            if let form = RuntimeFormCatalog.v2Forms[runtimeId] {
                return .catalog(form)
            }
            return .selectV2(runtimeId: runtimeId, schemaVersion: expected, chinese: chinese)
        }
        if runtimeId == "builtin" {
            return .catalog(RuntimeFormCatalog.builtinV1Definition)
        }
        if runtimeId == "kimi-sdk", let definition = RuntimeFormCatalog.optionSources["kimi-sdk/edit"] {
            return .catalog(definition)
        }
        return .selectV1(runtimeId: runtimeId, schemaVersion: expected)
    }

    // MARK: - Shared guards

    /// The session, membership and machine-authority checks every runtime-form
    /// route runs in the same order: `401`, server `404`, Computer `404`, `403`.
    func authorizedMachine(
        authorization: String?,
        serverId: String,
        machineId: String,
        purpose: String
    ) throws -> MachineRecord {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeFormsAndProbesError.serverNotFound
        }
        guard let machine = dependencies.machines.machine(id: machineId, serverId: serverId) else {
            throw RuntimeFormsAndProbesError.computerNotFound
        }
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            throw RuntimeFormsAndProbesError.editMachinesRequired(purpose: purpose)
        }
        return machine
    }

    /// The schema version a runtime form publishes, refusing an unknown runtime,
    /// a v2-only runtime asked at v1 and a stale v1 schema version.
    func expectedSchema(
        runtimeId: String,
        protocolVersion: Int,
        schemaVersion: String?,
        unknown: RuntimeFormsAndProbesError
    ) throws -> String {
        guard let expected = Self.runtimeFormSchemas[runtimeId] else {
            throw unknown
        }
        if protocolVersion == 1, Self.runtimeFormV2Only.contains(runtimeId) {
            throw unknown
        }
        if protocolVersion == 1, let schemaVersion, schemaVersion != expected {
            throw RuntimeFormsAndProbesError.staleFormSchema
        }
        return expected
    }

    static func prefersChinese(_ language: String?) -> Bool {
        guard let language else { return false }
        return language.lowercased().hasPrefix("zh")
    }

    // MARK: - GET .../runtime-options

    /// The runtimes a Computer can offer a new agent and whether each is
    /// installed.
    public func machineRuntimeOptions(
        authorization: String?,
        serverId: String,
        machineId: String,
        includeRuntimeFormV2: Bool = false
    ) throws -> MachineRuntimeOptionsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeFormsAndProbesError.serverNotFound
        }
        guard let machine = dependencies.machines.machine(id: machineId, serverId: serverId) else {
            throw RuntimeFormsAndProbesError.computerNotFound
        }
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            throw RuntimeFormsAndProbesError.editMachinesRequired(purpose: "inspect runtime options")
        }
        return MachineRuntimeOptionsResponse(machineId: machine.id, options: Self.admissionOptions(
            installedRuntimeIds: machine.runtimes, currentRuntime: nil,
            grokEnabled: dependencies.agents.evaluateFeatureFlag(
                key: "grok_runtime_v0", userId: userId, serverId: serverId, platform: nil,
                client: .init(os: nil, buildNumber: nil, buildType: nil)
            ).enabled,
            includeRuntimeFormV2: includeRuntimeFormV2
        ))
    }

    /// Registered local v2 definitions comprise the static JSON entries and
    /// the independently built builtin form. A v1 reference is not a v2 gate.
    static func hasRegisteredRuntimeFormV2(_ runtimeId: String) -> Bool {
        runtimeId == "builtin" || RuntimeFormCatalog.v2Forms[runtimeId] != nil
    }

    /// Pinned runtimeCatalog/runtimeAdmissionService projection. No capability is
    /// inferred from a version string or a connection; inventory remains factual.
    static func admissionOptions(installedRuntimeIds: [String], currentRuntime: String?,
                                 grokEnabled: Bool, includeRuntimeFormV2: Bool) -> [MachineRuntimeOptionsResponse.Option] {
        let catalog: [(id: String, binary: String, deprecated: Bool)] = [
            ("claude", "claude", false), ("codex", "codex", false), ("grok", "grok", false),
            ("builtin", "", false), ("antigravity", "agy", true), ("kimi-sdk", "", false),
            ("kimi", "kimi", true), ("copilot", "copilot", true), ("cursor", "cursor-agent", false),
            ("gemini", "gemini", true), ("opencode", "opencode", false), ("pi", "pi", false),
        ]
        let installed = Set(installedRuntimeIds)
        return catalog.filter { !$0.deprecated || $0.id == currentRuntime }
            .filter { $0.id != "grok" || grokEnabled || $0.id == currentRuntime }
            .map { runtime in
                let current = runtime.id == currentRuntime
                let reason: String? = current && runtime.deprecated ? "deprecated"
                    : (current && runtime.id == "grok" && !grokEnabled ? "feature_flag_off" : nil)
                let capability = installed.contains(runtime.id) ? "available"
                    : (runtime.binary.isEmpty ? "update_required" : "not_installed")
                // v1 refs and opt-in v2 markers are independent. In particular,
                // onboarding asks for the marker but deliberately stays on v1.
                return .init(runtimeId: runtime.id, capabilityStatus: capability,
                    canSelectInThisContext: capability == "available",
                    runtimeFormV2: includeRuntimeFormV2 && Self.hasRegisteredRuntimeFormV2(runtime.id),
                    formDefinitionSchemaVersion: runtimeFormV1Runtimes.contains(runtime.id) ? runtimeFormSchemas[runtime.id] : nil,
                    current: current, admissionReason: reason)
            }
    }

    // MARK: - GET .../runtime-models/:runtime

    /// The models one runtime offers on a Computer, probed on request.
    public func machineRuntimeModels(
        authorization: String?,
        serverId: String,
        machineId: String,
        runtime: String
    ) throws -> MachineRuntimeModelsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeFormsAndProbesError.serverNotFound
        }
        guard let machine = dependencies.machines.machine(id: machineId, serverId: serverId) else {
            throw RuntimeFormsAndProbesError.machineNotFound
        }
        let cached = dependencies.machines.runtimeModels(machineId: machineId, runtime: runtime)
        let probe = dependencies.machines.machineRuntimeModelProbe
        let routed = dependencies.machines.machineRoutedLocally?(machineId) ?? true
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            throw RuntimeFormsAndProbesError.editMachinesRequired(purpose: "inspect runtime models")
        }
        func choices(_ models: [RuntimeModelProbeModel]) -> [RuntimeModelChoice] {
            models.map { RuntimeModelChoice(value: $0.id, label: $0.label) }
        }
        guard routed else {
            return .computerOffline
        }
        guard let probe else {
            return .live(
                models: cached.map { RuntimeModelChoice(value: $0.id, label: $0.label) },
                defaultModel: cached.first?.id
            )
        }
        switch probe(machineId, runtime, true) {
        case .live(let models, let defaultModel):
            return .live(models: choices(models), defaultModel: defaultModel)
        case .models(let models, let defaultModel):
            return .plainModels(models: choices(models), defaultModel: defaultModel)
        case .missingConfig:
            return .missingConfig
        case .noModels:
            return .noModels
        case .unsupported:
            return .unsupported
        case .error(let code, _):
            return .error(code: code)
        case .failed:
            return .error(code: "")
        }
    }

    // MARK: - GET .../workspaces

    /// Scan the actual Computer filesystem; there is no agent-derived fallback.
    /// Only short committed reads surround the RPC wait, including its failure.
    public func machineWorkspaces(
        authorization: String?,
        serverId: String,
        machineId: String,
        persistence: BusinessPersistenceRuntime? = nil
    ) async throws -> MachineWorkspacesResponse {
        func authorize() throws {
            guard let userId = dependencies.sessionUserId(authorization) else {
                throw RuntimeFormsAndProbesError.unauthorized
            }
            guard dependencies.oauth.activeRegularServerMember(serverId: serverId, userId: userId),
                  let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
                throw RuntimeFormsAndProbesError.notAMember
            }
            guard let machine = dependencies.machines.machine(id: machineId, serverId: serverId) else {
                throw RuntimeFormsAndProbesError.machineNotFound
            }
            guard role == "owner" || role == "admin" || machine.userId == userId else {
                throw RuntimeFormsAndProbesError.workspacesForbidden
            }
        }
        let binding: (MachineQueryAuthority, any MachineQuerying)
        do {
            binding = try machineQueryRead(persistence: persistence) {
                try authorize()
                guard dependencies.machines.machineRoutedLocally?(machineId) ?? true,
                      let port = dependencies.machines.machineQueries else { throw MachineQueryError.offline }
                return (try machineQueryAuthority(agents: dependencies.agents, machineId: machineId, serverId: serverId), port)
            }
        } catch is MachineQueryError { throw MachineWorkspaceScanFailure() }
        let directories: [MachineWorkspaceDirectory]
        do { directories = try await binding.1.machineWorkspaces(authority: binding.0) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try machineQueryRead(persistence: persistence) {
                try authorize()
                guard dependencies.machines.machineRoutedLocally?(machineId) ?? true,
                      (try? machineQueryAuthority(agents: dependencies.agents, machineId: machineId, serverId: serverId)) == binding.0 else {
                    throw MachineWorkspaceScanFailure()
                }
            }
            throw MachineWorkspaceScanFailure()
        }
        return try machineQueryRead(persistence: persistence) {
            try authorize()
            guard dependencies.machines.machineRoutedLocally?(machineId) ?? true,
                  (try? machineQueryAuthority(agents: dependencies.agents, machineId: machineId, serverId: serverId)) == binding.0 else {
                throw MachineWorkspaceScanFailure()
            }
            let rows = directories.compactMap { workspaceEntry -> MachineWorkspacesResponse.Row? in
                // Own live OR soft-deleted identity is the only ownership proof.
                // Current machine bindings and cached deletion marks prove no FS fact.
                guard let agent = dependencies.oauth.agentRuntimeInfo(id: workspaceEntry.directoryName),
                      agent.serverId == serverId else { return nil }
                let status = agent.deleted ? "deleted" : (agent.status == "inactive" ? "stopped" : "active")
                let name = !agent.displayName.isEmpty ? agent.displayName : (agent.name.isEmpty ? nil : agent.name)
                return .init(directoryName: workspaceEntry.directoryName, totalSizeBytes: workspaceEntry.totalSizeBytes,
                    lastModified: workspaceEntry.lastModified, fileCount: workspaceEntry.fileCount, displayPath: workspaceEntry.displayPath,
                    status: status, agentName: name, agentStatus: agent.status)
            }
            return MachineWorkspacesResponse(rows: rows)
        }
    }

    // MARK: - Runtime account usage

    /// `GET .../runtime-account-usage/:provider`.
    public func machineRuntimeAccountUsage(
        authorization: String?,
        serverId: String,
        machineId: String,
        provider: String
    ) throws -> RuntimeAccountUsageResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard Self.runtimeAccountUsageProviders.contains(provider) else {
            throw RuntimeFormsAndProbesError.usageProviderNotFound
        }
        guard let context = dependencies.machines.runtimeAccountUsageContext(
            machineId: machineId,
            serverId: serverId,
            provider: provider
        ) else {
            throw RuntimeFormsAndProbesError.computerNotFound
        }
        guard canInspectUsage(serverId: serverId, userId: userId, attacher: context.attacher) else {
            throw RuntimeFormsAndProbesError.attachingHumanRequired(purpose: "inspect runtime account usage")
        }
        guard let snapshot = context.snapshot else {
            return RuntimeAccountUsageResponse(state: "missing", snapshotJSON: nil)
        }
        return RuntimeAccountUsageResponse(
            state: snapshot.staleAfter <= dependencies.now() ? "stale" : "fresh",
            snapshotJSON: snapshot.json
        )
    }

    /// `POST .../runtime-account-usage/:provider/refresh`.
    ///
    /// A requested (non-manual) refresh claims the cooldown slot in one store
    /// decision and answers `202`. A manual refresh asks the Computer for a
    /// snapshot and answers `200` with it (or `timeout`); every refresh that
    /// did not complete synchronously throws `RuntimeAccountUsageRefreshDeferral`.
    public func refreshMachineRuntimeAccountUsage(
        authorization: String?,
        serverId: String,
        machineId: String,
        provider: String,
        body: RuntimeAccountUsageRefreshRequest?
    ) throws -> RuntimeAccountUsageRefreshResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard Self.runtimeAccountUsageProviders.contains(provider) else {
            throw RuntimeFormsAndProbesError.usageProviderNotFound
        }
        guard let context = dependencies.machines.runtimeAccountUsageContext(
            machineId: machineId,
            serverId: serverId,
            provider: provider
        ) else {
            throw RuntimeFormsAndProbesError.computerNotFound
        }
        guard canInspectUsage(serverId: serverId, userId: userId, attacher: context.attacher) else {
            throw RuntimeFormsAndProbesError.attachingHumanRequired(purpose: "refresh runtime account usage")
        }
        let manual = body?["reason"]?.legacyString == "manual"
        let key = "\(machineId)\n\(provider)"
        let now = dependencies.now()
        guard manual else {
            guard dependencies.machines.claimRuntimeAccountUsageRefresh(
                key: key,
                now: now,
                cooldown: Self.usageRefreshCooldown
            ) else {
                throw RuntimeAccountUsageRefreshDeferral.cooldown
            }
            throw RuntimeAccountUsageRefreshDeferral.requested
        }
        if dependencies.machines.runtimeAccountUsageRefreshInCooldown(
            key: key,
            now: now,
            cooldown: Self.usageRefreshCooldown
        ) {
            throw RuntimeAccountUsageRefreshDeferral.cooldown
        }
        guard context.online else {
            throw RuntimeAccountUsageRefreshDeferral.computerOffline
        }
        let result = dependencies.machines.runtimeAccountUsageManualRefresh?(machineId, provider) ?? .timeout
        switch result {
        case .snapshot(let json):
            let staleAfter = (try? JSONDecoder().decode(
                RuntimeUsageSnapshotFreshness.self,
                from: Data(json.utf8)
            ))?.staleAfter.flatMap(DateText.isoDate) ?? now.addingTimeInterval(1800)
            dependencies.machines.recordRuntimeAccountUsage(
                key: key,
                json: json,
                staleAfter: staleAfter,
                refreshedAt: now
            )
            return RuntimeAccountUsageRefreshResponse(state: "fresh", snapshotJSON: json)
        case .timeout:
            dependencies.machines.recordRuntimeAccountUsageRefreshAttempt(key: key, at: now)
            return RuntimeAccountUsageRefreshResponse(state: "timeout")
        case .offline:
            throw RuntimeAccountUsageRefreshDeferral.computerOffline
        }
    }

    private func canInspectUsage(serverId: String, userId: String, attacher: String?) -> Bool {
        if attacher == userId { return true }
        let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId)
        return role == "owner" || role == "admin"
    }
}
