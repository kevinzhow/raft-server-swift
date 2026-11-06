import Foundation

// MARK: - Injected dependencies

/// Every dependency the runtime-form surface reads.
///
/// The machine, notification, onboarding and agent rows belong to their stores.
/// The human session lookup, the realtime emitter and the machine registration
/// (which the Computer lifecycle and the hosted-migration domains also use)
/// belong to domains that have not migrated, so they enter as closures wired by
/// `live(directory:)`.
struct RuntimeFormsAndProbesDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var emitRealtime: @Sendable (String, String, String?) -> Void
    /// `registerMachine` of the unmigrated hosted-migration domain.
    var registerMachine: @Sendable (_ serverId: String, _ userId: String, _ name: String) -> String
    /// `machineAPIKey` of the unmigrated hosted-runtime domain.
    var machineAPIKey: @Sendable (_ machineId: String) -> String?
    var oauth: OAuthLedger
    var machines: MachinesAndComputersStore
    var servers: ServersAndChannelsStore
    var notifications: NotificationsStore
    var agents: AgentsRuntimeStore
    var now: @Sendable () -> Date

    static func live(directory source: EmailLoginDirectory) -> RuntimeFormsAndProbesDependencies {
        RuntimeFormsAndProbesDependencies(
            sessionUserId: { source.sessionUserId(authorization: $0) },
            emitRealtime: { room, event, payload in
                source.emitRealtime(room, event, payload)
            },
            registerMachine: { serverId, userId, name in
                source.registerMachine(serverId: serverId, userId: userId, name: name)
            },
            machineAPIKey: { source.machineAPIKey(machineId: $0) },
            oauth: source.oauth,
            machines: source.machinesAndComputersStore,
            servers: source.serversAndChannelsStore,
            notifications: source.notificationsStore,
            agents: source.agentsRuntimeStore,
            now: { Date() }
        )
    }
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

    /// Production wiring.
    public init(directory: EmailLoginDirectory) {
        self.init(dependencies: .live(directory: directory))
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
    static let runtimeFormV1Runtimes: Set<String> = ["builtin", "claude", "cursor", "kimi-sdk"]

    /// Runtimes whose released form only exists at protocol v2; v1 clients must
    /// see them as having no form at all.
    static let runtimeFormV2Only: Set<String> = [
        "pi", "opencode", "gemini", "codex", "grok", "antigravity", "kimi",
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
        var writeOnly: [String] = []
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

    // MARK: - Runtime form option sources

    /// `GET .../runtime-form-definitions/:runtimeId/option-sources/:sourceId`
    /// (v1) and `GET .../runtime-forms/v2/:runtimeId/option-sources/:sourceId`
    /// (v2). Static sources never probe the Computer; the model sources of
    /// probed runtimes do.
    public func runtimeFormOptionSource(
        authorization: String?,
        serverId: String,
        machineId: String,
        runtimeId: String,
        sourceId: String,
        protocolVersion: Int,
        schemaVersion: String?,
        language: String?,
        refresh: Bool = false
    ) throws -> RuntimeOptionSourceResponse {
        _ = try authorizedMachine(
            authorization: authorization,
            serverId: serverId,
            machineId: machineId,
            purpose: "inspect runtime form option sources"
        )
        let expected = try expectedSchema(
            runtimeId: runtimeId,
            protocolVersion: protocolVersion,
            schemaVersion: schemaVersion,
            unknown: .runtimeFormOptionSourceNotFound
        )
        let chinese = Self.prefersChinese(language)

        if protocolVersion == 2 {
            if let source = try v2OptionSource(
                machineId: machineId,
                runtimeId: runtimeId,
                sourceId: sourceId,
                expected: expected,
                refresh: refresh
            ) {
                return source
            }
        }

        if sourceId == "model", runtimeId == "kimi-sdk" {
            return try kimiSDKSource(
                resolution: probeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh),
                protocolVersion: 1,
                expected: expected
            )
        }
        if sourceId == "model", runtimeId == "builtin" {
            return try builtinModelSource(protocolVersion: 1, expected: expected)
        }
        switch sourceId {
        case "provider" where runtimeId == "builtin":
            return .builtinProvider(schemaVersion: expected, chinese: chinese)
        case "model":
            let cached = dependencies.machines.runtimeModels(machineId: machineId, runtime: runtimeId)
            return .cachedModels(
                schemaVersion: expected,
                models: cached.map { RuntimeModelChoice(value: $0.id, label: $0.label) }
            )
        default:
            throw RuntimeFormsAndProbesError.unknownOptionSource
        }
    }

    /// The v2 sources that answer without falling through to the shared
    /// legacy tail; `nil` leaves the request to that tail.
    private func v2OptionSource(
        machineId: String,
        runtimeId: String,
        sourceId: String,
        expected: String,
        refresh: Bool
    ) throws -> RuntimeOptionSourceResponse? {
        if runtimeId == "antigravity" {
            throw RuntimeFormsAndProbesError.unknownOptionSource
        }
        if sourceId == "provider", runtimeId == "pi" {
            return .catalog(RuntimeFormCatalog.optionSources["pi/provider"] ?? "")
        }
        if sourceId == "providerModel", runtimeId == "pi" {
            return .catalog(RuntimeFormCatalog.optionSources["pi/providerModel"] ?? "")
        }
        if sourceId == "model", runtimeId == "kimi" || runtimeId == "gemini" {
            return .catalog(RuntimeFormCatalog.optionSources["\(runtimeId)/model"] ?? "")
        }
        if sourceId == "model", runtimeId == "kimi-sdk" {
            return try kimiSDKSource(
                resolution: probeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh),
                protocolVersion: 2,
                expected: expected
            )
        }
        if sourceId == "model", runtimeId == "builtin" {
            return try builtinModelSource(protocolVersion: 2, expected: expected)
        }
        if sourceId == "provider", runtimeId == "claude" {
            return .catalog(RuntimeFormCatalog.optionSources["claude/provider"] ?? "")
        }
        if sourceId == "model", runtimeId == "claude" || runtimeId == "cursor" {
            switch probeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh) {
            case .live(let models, let defaultModel):
                return .model(RuntimeModelSourceBody(
                    runtimeId: runtimeId,
                    schemaVersion: expected,
                    options: models.map { RuntimeProbeOption($0, reasoning: runtimeId == "claude") },
                    defaultValue: defaultModel ?? models.first?.id ?? "",
                    customValueAllowed: true,
                    status: "live"
                ))
            case .notLive(let reason):
                return .catalog(Self.catalogWithReason(
                    RuntimeFormCatalog.optionSources["\(runtimeId)/model"] ?? "",
                    reason: reason
                ))
            }
        }
        if sourceId == "model", ["opencode", "codex", "grok", "pi"].contains(runtimeId) {
            switch probeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh) {
            case .live(let models, let defaultModel):
                let reasoning = runtimeId == "codex" || runtimeId == "grok" || runtimeId == "pi"
                return .model(RuntimeModelSourceBody(
                    runtimeId: runtimeId,
                    schemaVersion: expected,
                    options: models.map { RuntimeProbeOption($0, reasoning: reasoning) },
                    defaultValue: defaultModel ?? models.first?.id ?? "",
                    customValueAllowed: runtimeId == "codex" || runtimeId == "pi" ? true : nil,
                    status: runtimeId == "opencode" ? nil : "live"
                ))
            case .notLive(let reason):
                switch runtimeId {
                case "opencode":
                    return .catalog(RuntimeFormCatalog.optionSources["opencode/model"] ?? "")
                case "grok":
                    return .model(RuntimeModelSourceBody(
                        runtimeId: "grok",
                        schemaVersion: expected,
                        options: Self.grokBundledModels.map { RuntimeProbeOption($0, reasoning: true) },
                        defaultValue: "grok-4.5",
                        status: "fallback",
                        reason: reason,
                        retryable: Self.runtimeReasonRetryable(reason)
                    ))
                default:
                    let raw = RuntimeFormCatalog.optionSources["\(runtimeId)/model"] ?? ""
                    if reason == "missing_config" { return .catalog(raw) }
                    return .catalog(Self.catalogWithReason(raw, reason: reason))
                }
            }
        }
        return nil
    }

    /// The shipped `missing_config` source with the probe's reason and
    /// retryability substituted into the rendered catalog text.
    private static func catalogWithReason(_ raw: String, reason: String) -> String {
        raw
            .replacingOccurrences(of: "\"reason\": \"missing_config\"", with: "\"reason\": \"\(reason)\"")
            .replacingOccurrences(of: "\"retryable\": false", with: "\"retryable\": \(runtimeReasonRetryable(reason))")
    }

    // MARK: - Probe resolution

    /// How a machine's model probe resolved for one runtime.
    enum ProbeResolution {
        case live(models: [RuntimeModelProbeModel], default: String?)
        case notLive(reason: String)
    }

    private func probeResolution(machineId: String, runtimeId: String, refresh: Bool) -> ProbeResolution {
        guard dependencies.machines.machineRoutedLocally?(machineId) ?? true else {
            return .notLive(reason: "machine_offline")
        }
        let outcome: RuntimeModelProbeOutcome
        if let probe = dependencies.machines.machineRuntimeModelProbe {
            outcome = probe(machineId, runtimeId, refresh)
        } else {
            let models = dependencies.machines.runtimeModels(machineId: machineId, runtime: runtimeId)
            outcome = models.isEmpty
                ? .missingConfig
                : .live(
                    models: models.map { RuntimeModelProbeModel(id: $0.id, label: $0.label) },
                    default: models.first?.id
                )
        }
        switch outcome {
        case .live(let models, let defaultModel), .models(let models, let defaultModel):
            return models.isEmpty ? .notLive(reason: "no_models") : .live(models: models, default: defaultModel)
        case .missingConfig:
            return .notLive(reason: "missing_config")
        case .noModels:
            return .notLive(reason: "no_models")
        case .unsupported:
            return .notLive(reason: "unsupported")
        case .error(let code, _):
            if code == "detect_timeout" { return .notLive(reason: "probe_timeout") }
            if code == "computer_offline" { return .notLive(reason: "machine_offline") }
            return .notLive(reason: "probe_failed")
        case .failed:
            return .notLive(reason: "probe_failed")
        }
    }

    private static func runtimeReasonRetryable(_ reason: String) -> Bool {
        ["probe_timeout", "probe_failed", "machine_offline", "no_models"].contains(reason)
    }

    private func kimiSDKSource(
        resolution: ProbeResolution,
        protocolVersion: Int,
        expected: String
    ) throws -> RuntimeOptionSourceResponse {
        let managed = RuntimeModelProbeModel(id: "kimi-code/kimi-for-coding", label: "Kimi for Coding (default)")
        func body(
            options: [RuntimeProbeOption],
            defaultValue: String,
            status: String? = nil,
            reason: String? = nil,
            retryable: Bool? = nil
        ) -> RuntimeOptionSourceResponse {
            .model(RuntimeModelSourceBody(
                runtimeId: "kimi-sdk",
                schemaVersion: expected,
                options: options,
                defaultValue: defaultValue,
                status: status,
                reason: reason,
                retryable: retryable
            ))
        }
        switch resolution {
        case .live(let models, let defaultModel):
            return body(
                options: models.map { RuntimeProbeOption($0, reasoning: true) },
                defaultValue: defaultModel ?? models.first?.id ?? "",
                status: protocolVersion == 2 ? "live" : nil
            )
        case .notLive(let reason):
            let retryable = Self.runtimeReasonRetryable(reason)
            let fallbackReason = reason == "missing_config" || reason == "machine_offline"
            if protocolVersion == 2 {
                if fallbackReason {
                    return body(
                        options: [RuntimeProbeOption(managed, reasoning: true)],
                        defaultValue: "kimi-code/kimi-for-coding",
                        status: "fallback",
                        reason: reason,
                        retryable: retryable
                    )
                }
                return body(
                    options: [],
                    defaultValue: "",
                    status: "unavailable",
                    reason: reason,
                    retryable: retryable
                )
            }
            if fallbackReason {
                return body(
                    options: [RuntimeProbeOption(managed, reasoning: true)],
                    defaultValue: "kimi-code/kimi-for-coding"
                )
            }
            switch reason {
            case "no_models":
                throw RuntimeFormsAndProbesError.kimiSDKSource(code: "runtime_model_source_no_models")
            case "unsupported":
                throw RuntimeFormsAndProbesError.kimiSDKSource(code: "runtime_model_source_unsupported")
            default:
                throw RuntimeFormsAndProbesError.kimiSDKSource(code: "runtime_model_source_error")
            }
        }
    }

    private func builtinModelSource(
        protocolVersion: Int,
        expected: String
    ) throws -> RuntimeOptionSourceResponse {
        let mode = dependencies.machines.builtinCatalogMode
        if mode == "legacy" {
            throw RuntimeFormsAndProbesError.builtinCatalogCapabilityRequired
        }
        let bundled = BuiltinModelSourceBody.bundledGroups()
        if protocolVersion == 1 {
            if mode == "timeout" {
                throw RuntimeFormsAndProbesError.builtinCatalogUnavailable
            }
            let groups = mode == "offline" ? bundled : liveBuiltinGroups(bundled: bundled)
            return .builtinModel(BuiltinModelSourceBody(schemaVersion: expected, groups: groups))
        }
        switch mode {
        case "timeout":
            return .builtinModel(BuiltinModelSourceBody(
                schemaVersion: expected,
                groups: [],
                status: "unavailable",
                reason: "probe_timeout",
                retryable: true
            ))
        case "offline":
            return .builtinModel(BuiltinModelSourceBody(
                schemaVersion: expected,
                groups: bundled,
                status: "fallback",
                reason: "machine_offline",
                retryable: true
            ))
        default:
            return .builtinModel(BuiltinModelSourceBody(
                schemaVersion: expected,
                groups: liveBuiltinGroups(bundled: bundled),
                status: "live"
            ))
        }
    }

    private func liveBuiltinGroups(
        bundled: [BuiltinModelSourceBody.Group]
    ) -> [BuiltinModelSourceBody.Group] {
        let models = dependencies.machines.builtinRuntimeModels()
        guard !models.isEmpty else { return bundled }
        return [BuiltinModelSourceBody.Group(
            provider: "deepseek",
            models: models.map { RuntimeModelChoice(value: $0.id, label: $0.label) }
        )]
    }

    // MARK: - Shared guards

    /// The session, membership and machine-authority checks every runtime-form
    /// route runs in the same order: `401`, server `404`, Computer `404`, `403`.
    private func authorizedMachine(
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
    private func expectedSchema(
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
        let installed = Set(machine.runtimes)
        let grokEnabled = dependencies.agents.isGrokRuntimeEnabled(serverId: serverId)
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            throw RuntimeFormsAndProbesError.editMachinesRequired(purpose: "inspect runtime options")
        }
        let catalog: [(id: String, binary: String)] = [
            ("claude", "claude"),
            ("codex", "codex"),
            ("builtin", ""),
            ("kimi-sdk", ""),
            ("cursor", "cursor-agent"),
            ("opencode", "opencode"),
            ("pi", "pi"),
            ("grok", "grok"),
        ]
        let options = catalog.filter { $0.id != "grok" || grokEnabled }.map { runtime in
            let capability = installed.contains(runtime.id)
                ? "available"
                : (runtime.binary.isEmpty ? "update_required" : "not_installed")
            return MachineRuntimeOptionsResponse.Option(
                runtimeId: runtime.id,
                capabilityStatus: capability,
                canSelectInThisContext: capability == "available",
                runtimeFormV2: includeRuntimeFormV2 && RuntimeFormCatalog.v2Forms[runtime.id] != nil,
                formDefinitionSchemaVersion: !includeRuntimeFormV2 && Self.runtimeFormV1Runtimes.contains(runtime.id)
                    ? (Self.runtimeFormSchemas[runtime.id] ?? "")
                    : nil
            )
        }
        return MachineRuntimeOptionsResponse(machineId: machine.id, options: options)
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

    /// The agent workspaces one Computer hosts for one Server.
    public func machineWorkspaces(
        authorization: String?,
        serverId: String,
        machineId: String
    ) throws -> MachineWorkspacesResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw RuntimeFormsAndProbesError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw RuntimeFormsAndProbesError.notAMember
        }
        guard let machine = dependencies.machines.machine(id: machineId, serverId: serverId) else {
            throw RuntimeFormsAndProbesError.machineNotFound
        }
        let canManage = role == "owner" || role == "admin" || machine.userId == userId
        let agentIds = dependencies.agents.agentIds(boundToMachine: machineId)
        let deleted = dependencies.machines.deletedWorkspaceKeys()
        guard canManage else {
            throw RuntimeFormsAndProbesError.workspacesForbidden
        }
        let epoch = RuntimeUsageISO.string(Date(timeIntervalSince1970: 0))
        let rows = agentIds.compactMap { agentId -> MachineWorkspacesResponse.Row? in
            guard let agent = dependencies.oauth.agentRuntimeInfo(id: agentId),
                  agent.serverId == serverId
            else { return nil }
            if deleted.contains("\(machineId)\n\(agentId)") { return nil }
            let agentStatus = dependencies.agents.agentStatus(agentId: agentId) ?? "inactive"
            let status = agent.deleted ? "deleted" : (agentStatus == "inactive" ? "stopped" : "active")
            return MachineWorkspacesResponse.Row(
                directoryName: agent.id,
                lastModified: epoch,
                status: status,
                agentName: agent.displayName.isEmpty ? agent.name : agent.displayName,
                agentStatus: agentStatus
            )
        }
        return MachineWorkspacesResponse(rows: rows)
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
            ))?.staleAfter.flatMap(EmailLoginDirectory.isoDate) ?? now.addingTimeInterval(1800)
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
