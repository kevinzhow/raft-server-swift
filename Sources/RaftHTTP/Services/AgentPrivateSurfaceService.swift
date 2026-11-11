import Foundation
import RaftShared

// MARK: - Injected dependencies

/// The private surface's owners and operations, assembled from explicit
/// session, relay, credential-use and existing domain service capabilities.
struct AgentPrivateSurfaceDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var emitRealtime: @Sendable (String, String, String?) -> Void
    var execution: AgentExecutionService?
    var oauth: OAuthLedger
    var agents: AgentsRuntimeStore
    var credentialUse: AgentCredentialUseService
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

    init(
        auth: AuthCoreService,
        oauth: OAuthLedger,
        agents: AgentsRuntimeStore,
        credentialUse: AgentCredentialUseService,
        machines: MachinesAndComputersStore,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        cards: ManagedMCPAndCardsStore,
        realtime: RealtimeRelayService,
        prepare: ActionCardPrepareService,
        reactions: ReactionsRealtimeService,
        notices: AgentRoleNoticeService,
        execution: AgentExecutionService? = nil
    ) {
        self.init(dependencies: AgentPrivateSurfaceDependencies(
            sessionUserId: { try? auth.authenticate($0) },
            emitRealtime: { room, event, payload in realtime.emit(room, event, payload) },
            execution: execution,
            oauth: oauth,
            agents: agents,
            credentialUse: credentialUse,
            machines: machines,
            channels: channels,
            messages: messages,
            cards: cards,
            hostedProviderConfigured: { agents.hostedProviderConfigured() },
            pendingWakeHints: { agentId, agent, sinceSeq, limit in
                reactions.pendingWakeHints(agentId: agentId, agent: agent, sinceSeq: sinceSeq, limit: limit)
                    .hints.compactMap { hint in
                        hint.seq.map { AgentWakeHintRow(seq: $0, json: hint.jsonBody.render()) }
                    }
            },
            directChannelId: { serverId, agentId, peerId in
                prepare.dmChannelId(serverId: serverId, agentId: agentId, peerId: peerId, peerKind: "human")
            },
            postAgentRoleNotice: { serverId, actorUserId, agentId, agentName, from, to in
                notices.post(
                    serverId: serverId, actorUserId: actorUserId, agentId: agentId,
                    agentName: agentName, from: from, to: to
                )
            }
        ))
    }

    init(dependencies: AgentPrivateSurfaceDependencies) {
        self.dependencies = dependencies
    }

    public func bindingExecution(_ execution: AgentExecutionService?) -> Self {
        var bound = dependencies
        bound.execution = execution
        return Self(dependencies: bound)
    }

    private var oauth: OAuthLedger { dependencies.oauth }

    private static let reservedHandles: Set<String> = [
        "all", "human", "humans", "agent", "agents", "here",
        "idle", "busy", "system", "reminders",
    ]

    private static func fractionalISO(_ date: Date) -> String {
        DateText.isoString(date)
    }

    /// The body UUID boundary mirrors Node's truthy optional machine field. The
    /// returned key is canonical; authority still comes from the actual row.
    private static func createMachineId(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        switch value {
        case .null, .bool(false), .integer(0), .number(0): return nil
        case .string(let raw):
            if raw.isEmpty { return nil }
            guard ServerScope.isUUID(raw), let uuid = UUID(uuidString: raw) else {
                throw AgentPrivateSurfaceError.invalidMachineId
            }
            return uuid.uuidString.lowercased()
        default: throw AgentPrivateSurfaceError.invalidMachineId
        }
    }

    /// Structured config takes precedence. Legacy request columns hydrate only
    /// when it is absent/null; these are metadata defaults from the pinned Node
    /// registry, not detected model availability or provider acceptance.
    static func requestRuntimeConfig(
        _ fields: [String: JSONValue], env: [String: String]?, stored: AgentRuntimeConfigDocument? = nil,
        coercionFailureMessage: String = "Failed to create agent"
    ) throws -> AgentRuntimeConfigDocument {
        var structured = fields["runtimeConfig"] == nil ? stored : nil
        if let value = fields["runtimeConfig"], value != .null {
            guard let supplied = AgentRuntimeConfigDocument(request: value) else {
                throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig must be an object")
            }
            structured = supplied
        }
        if var config = structured {
            guard let rawRuntime = config.runtime else {
                throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig.runtime is required")
            }
            let runtime = rawRuntime.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !runtime.isEmpty else {
                throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig.runtime is required")
            }
            config.setRuntime(runtime)
            return config
        }
        let rawRuntime = fields["runtime"]?.legacyString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let runtime = rawRuntime.isEmpty ? "claude" : rawRuntime
        if runtime == "builtin" {
            throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig.provider is required for runtime: builtin")
        }
        let defaults = [
            "claude": "opus", "codex": "gpt-6.1-sol", "grok": "grok-4.5",
            "cursor": "composer-2-fast", "opencode": "default", "pi": "default",
            "kimi-sdk": "kimi-code/kimi-for-coding", "external": "external",
        ]
        let rawModel = fields["model"]?.legacyString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = rawModel.isEmpty ? (defaults[runtime] ?? "sonnet") : rawModel
        let presets: [String: Set<String>] = [
            "claude": ["opus", "fable", "sonnet", "haiku", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5-5", "claude-haiku-4-5"],
            "codex": ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "gpt-5.3-codex-spark", "gpt-5.2-codex", "gpt-5.2", "gpt-5.1-codex-max", "gpt-5.1-codex", "gpt-5-codex", "gpt-5"],
            "grok": Set(RuntimeFormsAndProbesService.grokBundledModels.map(\.id)),
            "cursor": ["composer-2-fast", "composer-2", "auto"],
            "opencode": ["default", "deepseek/deepseek-v4-pro", "openrouter/anthropic/claude-opus-4.5", "fusecode/opus[1m]"],
            "pi": ["default"], "kimi-sdk": ["kimi-code/kimi-for-coding"], "external": ["external"],
        ]
        let modelValue: JSONValue = presets[runtime]?.contains(model) == true
            ? .object(["kind": .string("preset"), "id": .string(model)])
            : .object(["kind": .string("custom"), "name": .string(model)])
        var config: [String: JSONValue] = [
            "version": .integer(1), "runtime": .string(runtime), "model": modelValue,
            "mode": .object(["kind": .string("default")]),
            "reasoningEffort": fields["reasoningEffort"] ?? .null,
            "envVars": .object((env ?? [:]).mapValues(JSONValue.string)),
        ]
        if runtime == "claude" {
            if let url = env?["ANTHROPIC_BASE_URL"], !url.isEmpty,
               let key = env?["ANTHROPIC_API_KEY"], !key.isEmpty {
                try Self.validateLegacyProvider(url: url, key: key)
                config["provider"] = .object(["kind": .string("custom"), "apiUrl": .string(url), "apiKey": .string(key)])
            } else { config["provider"] = .object(["kind": .string("default")]) }
        }
        try Self.validateLegacyReasoningEffort(runtime: runtime, value: fields["reasoningEffort"],
            coercionFailureMessage: coercionFailureMessage)
        // The known object constructor cannot fail its sole object-shape check.
        return AgentRuntimeConfigDocument(request: .object(config))!
    }

    private static let knownReasoningEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max", "ultra"]

    /// PATCH validates raw hints before restart/role/config resolution. A supplied
    /// structured config does not suppress an invalid shadowed top-level hint.
    static func validatePatchRuntimeHints(_ fields: [String: JSONValue], currentRuntime: String) throws {
        let supported: Set<String> = ["claude", "codex", "grok", "builtin", "antigravity", "kimi-sdk", "kimi", "copilot", "cursor", "gemini", "opencode", "pi"]
        var targetRuntime = currentRuntime
        if let value = fields["runtime"] {
            guard case .string(let runtime) = value else {
                throw AgentPrivateSurfaceError.invalidRuntimeConfig("Runtime must be a string")
            }
            guard supported.contains(runtime) else {
                throw AgentPrivateSurfaceError.invalidRuntimeConfig("Invalid runtime: \(runtime)")
            }
            targetRuntime = runtime
        }
        if let value = fields["reasoningEffort"], value != .null, targetRuntime != "kimi-sdk" {
            guard case .string(let effort) = value, knownReasoningEfforts.contains(effort) else {
                throw AgentPrivateSurfaceError.invalidRuntimeConfig("Invalid reasoning effort: \(try Self.nodeValueDescription(value, failureMessage: "Failed to update agent"))")
            }
        }
    }

    /// Only the newly hydrated legacy branch uses this strict value check.
    private static func validateLegacyReasoningEffort(
        runtime: String, value: JSONValue?, coercionFailureMessage: String
    ) throws {
        guard let value, value != .null else { return }
        let supported: Set<String> = ["builtin", "claude", "codex", "grok", "copilot", "pi", "kimi-sdk"]
        guard supported.contains(runtime) else {
            throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig.reasoningEffort is not supported for runtime: \(runtime)")
        }
        guard case .string(let effort) = value, !effort.isEmpty,
              effort.trimmingCharacters(in: .whitespacesAndNewlines) == effort,
              !effort.contains("\u{0}"), runtime == "kimi-sdk" || knownReasoningEfforts.contains(effort) else {
            throw AgentPrivateSurfaceError.invalidRuntimeConfig("Invalid reasoning effort: \(try Self.nodeValueDescription(value, failureMessage: coercionFailureMessage))")
        }
    }

    private static func validateLegacyProvider(url: String, key: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig.provider.apiUrl is required")
        }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig.provider.apiKey is required")
        }
        // URL's special schemes treat backslashes as slashes and accept the
        // scheme:host form. Normalize that syntax before the Foundation parse so
        // credentials cannot hide in a path that Node parses as an authority.
        let c0 = CharacterSet(charactersIn: "\u{0}\u{1}\u{2}\u{3}\u{4}\u{5}\u{6}\u{7}\u{8}\u{9}\u{a}\u{b}\u{c}\u{d}\u{e}\u{f}\u{10}\u{11}\u{12}\u{13}\u{14}\u{15}\u{16}\u{17}\u{18}\u{19}\u{1a}\u{1b}\u{1c}\u{1d}\u{1e}\u{1f}\u{20}")
        var source = url.trimmingCharacters(in: c0).replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let networkSchemes: Set<String> = ["ftp", "http", "https", "ws", "wss"]
        if let colon = source.firstIndex(of: ":"), networkSchemes.contains(String(source[..<colon]).lowercased()) {
            let scheme = String(source[..<colon])
            let tail = source[source.index(after: colon)...].replacingOccurrences(of: "\\", with: "/").drop(while: { $0 == "/" })
            source = scheme + "://" + String(tail)
        }
        guard let parsed = URLComponents(string: source), let scheme = parsed.scheme, !scheme.isEmpty,
              parsed.url != nil,
              !networkSchemes.contains(scheme.lowercased()) || !(parsed.host ?? "").isEmpty,
              parsed.port.map({ (0...65535).contains($0) }) ?? true,
              scheme.lowercased() != "file" || ((parsed.user ?? "").isEmpty && (parsed.password ?? "").isEmpty) else {
            throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig.provider.apiUrl must be a valid URL")
        }
        guard (parsed.user ?? "").isEmpty, (parsed.password ?? "").isEmpty else {
            throw AgentPrivateSurfaceError.invalidRuntimeConfig("runtimeConfig.provider.apiUrl must not contain credentials")
        }
    }

    /// JavaScript interpolation used by the pinned raw-value error bodies.
    static func nodeValueDescription(_ value: JSONValue, failureMessage: String) throws -> String {
        switch value {
        case .string(let text): return text
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .integer(let number): return Self.nodeNumberDescription(Double(number))
        case .number(let number): return Self.nodeNumberDescription(number)
        case .object(let members):
            // JSON cannot carry callable properties. An own toString shadows
            // Object.prototype.toString; valueOf cannot produce a primitive.
            guard members["toString"] == nil else {
                throw AgentValueCoercionFailure(errorMessage: failureMessage)
            }
            return "[object Object]"
        case .array(let values):
            return try values.map { value in
                if value == .null { return "" }
                return try Self.nodeValueDescription(value, failureMessage: failureMessage)
            }.joined(separator: ",")
        }
    }

    /// JSON numbers enter Node as Doubles. Reuse Swift's shortest-roundtrip
    /// digits, adapting only JavaScript's decimal/exponent presentation.
    private static func nodeNumberDescription(_ number: Double) -> String {
        guard number.isFinite else { return String(number) }
        if number == 0 { return "0" }
        let sign = number < 0 ? "-" : ""
        let parts = String(abs(number)).lowercased().split(separator: "e")
        let coefficient = parts[0]
        let integerDigits = coefficient.firstIndex(of: ".").map {
            coefficient.distance(from: coefficient.startIndex, to: $0)
        } ?? coefficient.count
        let exponent = parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
        var digits = Array(coefficient.filter { $0 != "." })
        var decimalPosition = integerDigits + exponent
        while digits.first == "0" {
            digits.removeFirst()
            decimalPosition -= 1
        }
        while digits.last == "0" {
            digits.removeLast()
        }
        let scientificExponent = decimalPosition - 1
        if scientificExponent >= -6 && scientificExponent < 21 {
            if decimalPosition <= 0 {
                return sign + "0." + String(repeating: "0", count: -decimalPosition) + String(digits)
            }
            if decimalPosition >= digits.count {
                return sign + String(digits) + String(repeating: "0", count: decimalPosition - digits.count)
            }
            return sign + String(digits.prefix(decimalPosition)) + "." + String(digits.dropFirst(decimalPosition))
        }
        let mantissa = String(digits.prefix(1)) + (digits.count > 1 ? "." + String(digits.dropFirst()) : "")
        return sign + mantissa + "e" + (scientificExponent >= 0 ? "+" : "") + String(scientificExponent)
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
        }
        let external = fields["external"]?.castBool ?? false
        if external, let supplied = fields["machineId"], supplied != .null, supplied != .string("") {
            throw AgentPrivateSurfaceError.externalWithMachine
        }
        let hostedProvider = try validatedHostedProvider(fields["provider"], serverId: serverId, external: external)
        let envValidation = external ? (env: nil as [String: String]?, error: nil as String?)
            : AgentRuntimeConfigDocument.validatedEnvVars(fields["envVars"])
        if let error = envValidation.error { throw AgentPrivateSurfaceError.invalidEnvVars(error) }
        // Supplied machine authority precedes config normalization and Grok policy.
        let suppliedMachineId = try Self.createMachineId(external ? nil : fields["machineId"])
        let assignedMachine = suppliedMachineId.flatMap { dependencies.machines.machine(id: $0, serverId: serverId) }
        if suppliedMachineId != nil, assignedMachine == nil {
            throw AgentPrivateSurfaceError.machineNotInServer
        }
        let machineId = assignedMachine?.id
        if onboardingRequest {
            if let existing = dependencies.channels.serverOnboardingSettings[serverId]?.agentId {
                throw AgentPrivateSurfaceError.onboardingAgentExists(agentId: existing)
            }
            if oauth.serverAgents(serverId: serverId).contains(where: {
                !$0.deleted && $0.name.caseInsensitiveCompare("Cindy") == .orderedSame
            }) {
                throw AgentPrivateSurfaceError.cindyExists
            }
        }
        let canonicalFields = try adoptingBuiltinForm(fields, serverId: serverId, external: external)
        let rawConfig = external ? AgentRuntimeConfigDocument.external
            : try Self.requestRuntimeConfig(canonicalFields, env: envValidation.env)
        try validateFormValues(fields, serverId: serverId)
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
            config.setUserEnv(envValidation.env ?? [:])
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
        if runtime == "grok", !dependencies.agents.evaluateFeatureFlag(
            key: "grok_runtime_v0", userId: userId, serverId: serverId, platform: nil,
            client: .init(os: nil, buildNumber: nil, buildType: nil)
        ).enabled {
            throw AgentPrivateSurfaceError.grokRuntimeDisabled
        }
        if runtime == "grok", let assignedMachine, !assignedMachine.runtimes.contains("grok") {
            throw AgentPrivateSurfaceError.grokCapabilityUnavailable
        }
        try checkBuiltinCatalog(machineId: machineId, config: config)
        let duplicate = oauth.serverAgents(serverId: serverId).contains {
            !$0.deleted && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        guard !duplicate else { throw AgentPrivateSurfaceError.nameTaken }
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
        let creatorDm = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: agentId, secondKind: .agent)
        oauth.addChannelAgent(channelId: creatorDm, agentId: agentId)
        // Publish a DM only after both existing owners hold its real facts.
        dependencies.channels.upsertDirectChannel(serverId: serverId, channelId: creatorDm, memberIds: [userId, agentId])
        let dmPayload = OrderedJSON.object([OrderedJSONField("channelId", creatorDm)]).render()
        dependencies.emitRealtime("channel:\(creatorDm)", "dm:new", dmPayload)
        dependencies.emitRealtime("user:\(userId)", "dm:new", dmPayload)
        if let machineId, !machineId.isEmpty, let execution = dependencies.execution {
            // Node creation retains the agent if automatic startup is not ready.
            // A staged command failure still aborts this business transaction.
            _ = try execution.requestAutomaticStartIfReady(.init(serverId: serverId, agentId: agentId, control: .automatic))
        }
        let responseConfigJSON = AgentRuntimeConfigDocument.redactedConfigJSON(configJSON) ?? configJSON
        let model = AgentRuntimeConfigDocument.agentModel(from: responseConfigJSON, external: external)
        let created = oauth.agentRuntimeInfo(id: agentId)
        let projection = AgentRuntimeProjection(
            id: agentId,
            name: effectiveName,
            runtime: runtime,
            model: model,
            external: external,
            envVarsJSON: envJSON,
            runtimeConfigJSON: responseConfigJSON,
            serverId: serverId,
            status: created?.status,
            machineId: dependencies.agents.agentMachineIds[agentId],
            reasoningEffort: config.reasoningEffort
        )
        let response = CreatedAgentResponse(
            agent: projection,
            creatorId: userId,
            displayName: created?.displayName ?? effectiveName,
            description: created?.description,
            avatarUrl: created?.avatarUrl,
            serverRole: oauth.agentRole(serverId: serverId, agentId: agentId) ?? "member",
            hostedProvider: hostedProvider
        )
        dependencies.emitRealtime(
            "server:\(serverId)", "agent:created",
            OrderedJSON.object([OrderedJSONField("agent", .raw(response.broadcastJSON))]).render()
        )
        return response
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
        let facts = presenceFacts(agent)
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
                : nil,
            serverId: agent.serverId,
            status: agent.status,
            machineId: facts.machineId,
            reasoningEffort: AgentRuntimeConfigProjection.parse(agent.runtimeConfigJSON).reasoningEffort,
            avatarUrl: agent.avatarUrl,
            activity: facts.activity,
            activityDetail: facts.detail,
            activityDetailKind: facts.detailKind
        )
    }

    /// Upstream `getActivity`: a retained live observation wins; otherwise the
    /// `active` + reachable-machine fallback is `online`. A terminal-failure /
    /// manual-recovery gate is a server-authored block (RFC 071 §9), served as
    /// the typed offline `terminal_failure_paused` activity regardless of what
    /// the daemon last reported. Both the full and the guest projections read
    /// the same resolved facts.
    private func presenceFacts(_ agent: OAuthLedger.AgentRuntimeInfo)
        -> (machineId: String?, activity: String, detail: String, detailKind: String?) {
        let facts = dependencies.agents.presenceFacts(agentId: agent.id)
        if agent.status != "stopped",
           let block = AgentPresenceSignal.terminalBlock(needsManual: facts.needsManual,
                                                         blockedUntil: facts.blockedUntil, now: Date()) {
            return (facts.machineId, "offline", block.detail, block.detailKind)
        }
        let reachable = facts.machineId.map {
            dependencies.machines.machineIsReachable(machineId: $0, serverId: agent.serverId)
        } ?? false
        let visible = AgentPresenceSignal.visiblePresence(recorded: facts.activity, status: agent.status, machineReachable: reachable)
        return (facts.machineId, visible.activity, visible.detail, facts.detailKind)
    }

    private func guestSummary(_ agent: OAuthLedger.AgentRuntimeInfo) -> GuestAgentSummary {
        .init(id: agent.id, serverId: agent.serverId, name: agent.name, displayName: agent.displayName,
              avatarUrl: agent.avatarUrl, description: agent.description, status: agent.status,
              activity: presenceFacts(agent).activity)
    }

    /// Node listChannels(archived:include) -> channelAgents, with #all's implicit
    /// membership. The shared query owns the real guest/parent/joint read rules.
    private func guestVisibleAgentIds(serverId: String, userId: String) -> Set<String> {
        let readable = HumanChannelReadAccessQuery(channels: dependencies.channels,
            messages: dependencies.messages, oauth: oauth, flags: dependencies.agents).readableLocalChannelIds(serverId: serverId, userId: userId)
        let listable = oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: true)
            .filter { readable.contains($0.id) && ["channel", "private", "joint"].contains($0.type) }
        let live = oauth.serverAgents(serverId: serverId)
        if listable.contains(where: { $0.name == "all" && $0.type == "channel" }) { return Set(live.map(\.id)) }
        let related = Set(listable.flatMap { oauth.channelAgentIds(channelId: $0.id) })
        return Set(live.lazy.filter { related.contains($0.id) }.map(\.id))
    }

    public func listServerAgents(authorization: String?, serverId: String) throws -> AgentListResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId),
              let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw AgentPrivateSurfaceError.notAMember
        }
        if role == "guest" {
            let visible = guestVisibleAgentIds(serverId: serverId, userId: userId)
            return AgentListResponse(guests: oauth.serverAgents(serverId: serverId)
                .filter { visible.contains($0.id) }.map { guestSummary($0) })
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
        agentId: String,
        includeRuntimeFormV2: Bool = false
    ) throws -> AgentRuntimeOptionsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AgentPrivateSurfaceError.unauthorized
        }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId),
              let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw AgentPrivateSurfaceError.notAMember
        }
        guard role != "guest" else { throw AgentRuntimeOptionsReadDenied() }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
            throw AgentPrivateSurfaceError.agentMissing
        }
        let machine = dependencies.agents.agentMachineIds[agentId].flatMap { id in
            dependencies.machines.machine(id: id, serverId: serverId)
        }
        return AgentRuntimeOptionsResponse(machineId: machine?.id,
            options: RuntimeFormsAndProbesService.admissionOptions(
                installedRuntimeIds: machine?.runtimes ?? [], currentRuntime: agent.runtime,
                grokEnabled: dependencies.agents.evaluateFeatureFlag(
                    key: "grok_runtime_v0", userId: userId, serverId: serverId, platform: nil,
                    client: .init(os: nil, buildNumber: nil, buildType: nil)
                ).enabled,
                includeRuntimeFormV2: includeRuntimeFormV2))
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
        guard oauth.activeRegularServerMember(serverId: agent.serverId, userId: userId),
              let role = oauth.memberRole(serverId: agent.serverId, userId: userId) else {
            throw AgentPrivateSurfaceError.notAMember
        }
        if role == "guest" {
            guard guestVisibleAgentIds(serverId: agent.serverId, userId: userId).contains(agent.id) else {
                throw AgentPrivateSurfaceError.agentNotFound
            }
            return .guest(guestSummary(agent))
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
        contentType: String?,
        body: Data
    ) async throws -> AgentAvatarResponse {
        let actor = try authorizedActor(authorization: authorization, agentId: agentId)
        guard let file = FormPayload.multipartFilePart(named: "avatar", contentType: contentType, body: body) else {
            throw AgentPrivateSurfaceError.noAvatarProvided
        }
        let stored: AvatarStoredFile
        do {
            stored = try await AvatarService(storage: oauth.assets, oauth: oauth)
                .storeAgentAvatar(serverId: actor.info.serverId, existingAvatarUrl: actor.info.avatarUrl, file: file)
        } catch let error as AvatarStoreError {
            switch error {
            case .tooLarge(let maxBytes): throw AgentPrivateSurfaceError.avatarTooLarge(maxBytes: maxBytes)
            case .badFormat: throw AgentPrivateSurfaceError.avatarBadFormat
            case .notAnImage, .storageNotConfigured, .storageFailure:
                throw AgentPrivateSurfaceError.avatarUploadFailed
            }
        }
        oauth.updateAgentAvatar(id: agentId, avatarUrl: stored.url)
        return AgentAvatarResponse(avatarUrl: stored.url)
    }

    // MARK: - POST /internal/agent-api/profile/avatar

    /// The credential-surface profile avatar upload. The bound agent is the
    /// credential's; the route's `send` capability is checked here, then the
    /// upload limit. The stored URL uses the same namespace scheme as
    /// `storeAgentAvatar` (the server id) and the response is the caller's full
    /// profile projection, which the feature reads back after this write.
    public func uploadAgentProfileAvatar(
        authorization: String?,
        byteCount: Int
    ) throws -> AgentAvatarResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentPrivateSurfaceError.authRequired
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = dependencies.agents.agentCredential(token: token), credential.revokedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentPrivateSurfaceError.authRequired
        }
        guard credential.scopes.contains("send") else {
            throw FeedbackLocatorError.capabilityNotAuthorized(capability: "send")
        }
        guard byteCount > 0 else { throw AgentAvatarUploadError.noAvatarFile }
        guard byteCount <= AgentAvatarUploadError.maximumBytes else {
            throw AgentPrivateSurfaceError.avatarTooLarge(maxBytes: AgentAvatarUploadError.maximumBytes)
        }
        let key = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let avatarUrl = "/api/avatars/\(agent.serverId)/\(key).webp"
        oauth.updateAgentAvatar(id: agent.id, avatarUrl: avatarUrl)
        return AgentAvatarResponse(avatarUrl: avatarUrl)
    }

    // MARK: - Credential use and the push webhook

    /// Records one use of an agent credential and tells the server room when an
    /// external agent was seen.
    public func recordAgentCredentialUse(token: String) {
        dependencies.credentialUse.record(token: token)
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

private struct AgentRuntimeOptionsReadDenied: DomainError {
    var status: UInt { 403 }
    var errorMessage: String { "The `viewAgents` capability is required to inspect runtime options" }
}
