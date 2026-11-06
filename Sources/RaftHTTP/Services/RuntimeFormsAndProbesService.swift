import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runtime form definitions, option sources and probes, machine runtime
/// account usage, and the server settings/notification projections the
/// runtime routes read.
///
/// These handlers were lifted from `EmailLogin+MachinesAndRuntime2.swift`.

public struct RuntimeFormsAndProbesService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    public func agentRuntimeForm(
        authorization: String?,
        serverId: String,
        agentId: String,
        language: String?
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to edit agents\"}")
        }
        guard agent.runtime != "external", let schemaVersion = Self.runtimeFormSchemas[agent.runtime] else {
            return Self.json(404, "{\"error\":\"This agent's runtime configuration has no editable runtime form\",\"issues\":[{\"code\":\"no_runtime_form\",\"pointer\":\"/runtimeConfig\"}]}")
        }
        let config = (agent.runtimeConfigJSON.flatMap { $0.data(using: .utf8) })
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        var values: [String: Any] = [:]
        if agent.runtime != "antigravity",
           let model = config["model"] as? [String: Any],
           let id = (model["id"] as? String) ?? (model["name"] as? String) {
            values["model"] = id
        }
        values["envVars"] = (config["envVars"] as? [String: String]) ?? [:]
        var writeOnly: [String] = []
        if agent.runtime == "claude" {
            let provider = config["provider"] as? [String: Any]
            values["provider"] = (provider?["kind"] as? String) ?? "default"
            if let apiUrl = provider?["apiUrl"] as? String { values["apiUrl"] = apiUrl }
            if let effort = config["reasoningEffort"] as? String { values["reasoningEffort"] = effort }
            values["fastMode"] = (config["fastMode"] as? Bool) ?? false
            if let command = config["command"] as? String { values["command"] = command }
            writeOnly = ["/apiKey"]
        }
        let zh = Self.prefersChinese(language)
        let label = zh ? "模型" : "Model"
        let valueJSON = (try? JSONSerialization.data(withJSONObject: values))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let fields = "[{\"key\":\"model\",\"kind\":\"select\",\"label\":\(jsonString(label)),\"required\":true}]"
        let capabilities = "{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\(writeOnly.map(jsonString).joined(separator: ","))],\"forbiddenPointers\":[\"/hostUserState\"]}"
        return Self.json(200, "{\"protocolVersion\":2,\"runtimeId\":\(jsonString(agent.runtime)),\"schemaVersion\":\(jsonString(schemaVersion)),\"fields\":\(fields),\"values\":\(valueJSON),\"capabilities\":\(capabilities)}")
    }

    public func addAgentMigrationForTesting(id: String, agentId: String = "", sourceMachineId: String, targetMachineId: String, state: String) {
        lock.lock()
        activeAgentMigrations[id] = AgentMigrationFact(
            agentId: agentId,
            sourceMachineId: sourceMachineId,
            targetMachineId: targetMachineId,
            state: state
        )
        lock.unlock()
    }

    public func setAgentMigrationStateForTesting(id: String, state: String) {
        lock.lock()
        if var migration = activeAgentMigrations[id] {
            migration.state = state
            activeAgentMigrations[id] = migration
        }
        lock.unlock()
    }

    public func agentMigrationStateForTesting(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeAgentMigrations[id]?.state
    }

    public func agentMigrationCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeAgentMigrations.count
    }

    public func setLatestComputerReleaseForTesting(version: String, releaseNotesJSON: String) {
        lock.lock()
        latestComputerRelease = (version, releaseNotesJSON)
        lock.unlock()
    }

    public func setMachineBroadcastPolicyForTesting(machineId: String, policyJSON: String) {
        lock.lock()
        machineBroadcastPolicies[machineId] = policyJSON
        lock.unlock()
    }

    public func setAgentRuntimeProfileForTesting(
        agentId: String,
        machineId: String,
        baselineMachineId: String? = nil,
        pendingBeforeMachineId: String? = nil,
        pendingAfterMachineId: String? = nil,
        migrationStatus: String? = nil,
        pendingKind: String? = nil,
        pendingReleaseNotesUrl: String? = nil
    ) {
        lock.lock()
        agentRuntimeProfiles[agentId] = AgentRuntimeProfileFact(
            agentId: agentId,
            machineId: machineId,
            baselineMachineId: baselineMachineId,
            pendingBeforeMachineId: pendingBeforeMachineId,
            pendingAfterMachineId: pendingAfterMachineId,
            migrationStatus: migrationStatus,
            pendingKind: pendingKind,
            pendingReleaseNotesUrl: pendingReleaseNotesUrl
        )
        lock.unlock()
    }

    public func agentRuntimeProfileMachineId(agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return agentRuntimeProfiles[agentId]?.machineId
    }

    public func agentRuntimeProfileForTesting(agentId: String) -> AgentRuntimeProfileFact? {
        lock.lock()
        defer { lock.unlock() }
        return agentRuntimeProfiles[agentId]
    }

    public func agentMachineIdForTesting(agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return agentMachineIds[agentId]
    }

    public func revokeAccessTokenForTesting(_ token: String) {
        lock.lock()
        accessTokens.removeValue(forKey: token)
        lock.unlock()
    }

    public func retireUserForTesting(userId: String) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == userId })?.key {
            accounts[key]?.retiredAt = Date()
        }
        lock.unlock()
    }

    public func setAgentMachineForTesting(agentId: String, machineId: String) {
        lock.lock()
        agentMachineIds[agentId] = machineId
        lock.unlock()
    }

    public func setAgentStatusForTesting(agentId: String, status: String) {
        oauth.setAgentStatus(id: agentId, status: status)
        lock.lock()
        serverAgents[agentId]?.status = status
        lock.unlock()
    }

    /// Whether the presented bearer is a live Computer credential (used before
    /// parsing an oversized control-manifest body so secrets never reach a parser).
    public func machineCredentialIsLive(authorization: String?) -> Bool {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return false }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard !token.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return machines.contains { $0.apiKey == token }
            || computers.contains { $0.apiKey == token && $0.revokedAt == nil }
    }

    public func computerCredentialIsLive(authorization: String?) -> Bool {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return false }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        return computers.contains { $0.apiKey == token && $0.revokedAt == nil }
    }

    /// Keyed lookup shared by `/daemon/connect` and the legacy machine surface.
    /// A row that was adopted into a Computer attachment carries its migration
    /// stamp so the connect handshake refuses the legacy key immediately, with
    /// no TTL window.
    public func machineCredential(apiKey: String) -> MachineCredentialIdentity? {        lock.lock()
        defer { lock.unlock() }
        guard let machine = machines.first(where: { $0.apiKey == apiKey }) else { return nil }
        return MachineCredentialIdentity(
            machineId: machine.id,
            serverId: machine.serverId,
            legacyKeyMigratedAt: machine.legacyKeyMigratedAt
        )
    }

    public func machineCredential(id: String) -> MachineCredentialIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let machine = machines.first(where: { $0.id == id }) else { return nil }
        return MachineCredentialIdentity(machineId: machine.id, serverId: machine.serverId)
    }

    public func serverExists(id: String) -> Bool {
        oauth.serverDetailsValue(id: id) != nil
    }

    /// Exact key match wins, then a revoked row with the same 16-character
    /// prefix, then a live row whose key does not verify, then absence.
    public func computerCredential(apiKey: String) -> ComputerCredentialLookup {
        lock.lock()
        defer { lock.unlock() }
        let prefix = String(apiKey.prefix(Self.computerAPIKeyPrefixLength))
        let candidates = computers.filter {
            String($0.apiKey.prefix(Self.computerAPIKeyPrefixLength)) == prefix
        }
        if let computer = candidates.first(where: { $0.apiKey == apiKey }) {
            if computer.revokedAt != nil { return .revoked }
            guard let machineId = computer.machineId,
                  machines.contains(where: { $0.id == machineId })
            else { return .machineUnlinked }
            return .linked(computerId: computer.id, machineId: machineId)
        }
        if candidates.contains(where: { $0.revokedAt != nil }) { return .revoked }
        if !candidates.isEmpty { return .keyMismatch }
        return .notFound
    }

    func onboardingJSON(serverId: String, userId: String) -> String {
        lock.lock()
        let server = serverOnboardingSettings[serverId] ?? (agentId: nil, greeting: true)
        let user = userOnboardingSettings["\(serverId)\n\(userId)"] ?? UserOnboarding()
        let slug = oauth.serverDetailsValue(id: serverId)?.slug ?? ""
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func dismissed(_ key: String) -> String {
            user.dismissed[key].map { jsonString(formatter.string(from: $0)) } ?? "null"
        }
        let agent = server.agentId.map { jsonString($0) } ?? "null"
        let step = user.currentStep.map { jsonString($0) } ?? "null"
        let wizardEnabled = !(slug == "community" || slug == "community-cn")
        return "{\"onboardingAgentId\":\(agent),\"agentAllChannelGreetingEnabled\":\(server.greeting),\"onboardingWizardEnabled\":\(wizardEnabled),\"setupModalReminderOptOut\":\(user.reminderOptOut),\"dismissedAddComputerStepAt\":\(dismissed("add-computer")),\"dismissedCreateAgentStepAt\":\(dismissed("create-agent")),\"dismissedInviteStepAt\":\(dismissed("invite-teammates")),\"dismissedCommunityStepAt\":\(dismissed("join-community")),\"dismissedNotificationStepAt\":\(dismissed("notifications")),\"onboardingWizardCurrentStep\":\(step)}"
    }

    public func serverSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let onboarding = onboardingJSON(serverId: serverId, userId: userId)
        return Self.json(200, "{\"settings\":{\"onboardSettings\":\(onboarding),\"feedbackSettings\":{\"enabled\":true}}}")
    }

    public func serverOnboardingSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        return Self.json(200, onboardingJSON(serverId: serverId, userId: userId))
    }

    public func patchServerOnboardingSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid onboarding settings\"}")
        }
        let isAdmin = role == "owner" || role == "admin"
        if object["onboardingAgentId"] != nil || object["agentAllChannelGreetingEnabled"] != nil {
            guard isAdmin else {
                return Self.json(403, "{\"error\":\"Only server owners and admins can update onboarding settings\"}")
            }
        }
        if let greeting = object["agentAllChannelGreetingEnabled"] {
            guard greeting is Bool else {
                return Self.json(400, "{\"error\":\"agentAllChannelGreetingEnabled must be a boolean\"}")
            }
        }
        if let rawStep = object["onboardingWizardCurrentStep"], !(rawStep is NSNull) {
            guard let step = rawStep as? String, Self.onboardingSteps.contains(step) else {
                return Self.json(400, "{\"error\":\"Invalid onboarding step\"}")
            }
        }
        lock.lock()
        var server = serverOnboardingSettings[serverId] ?? (agentId: nil, greeting: true)
        if isAdmin {
            if let rawAgent = object["onboardingAgentId"] {
                if rawAgent is NSNull {
                    server.agentId = nil
                } else if let agentId = rawAgent as? String {
                    server.agentId = agentId
                }
            }
            if let greeting = object["agentAllChannelGreetingEnabled"] as? Bool {
                server.greeting = greeting
            }
            serverOnboardingSettings[serverId] = server
        }
        let key = "\(serverId)\n\(userId)"
        var user = userOnboardingSettings[key] ?? UserOnboarding()
        if let value = object["setupModalReminderOptOut"] as? Bool {
            user.reminderOptOut = value
        }
        if let rawStep = object["onboardingWizardCurrentStep"] {
            user.currentStep = rawStep is NSNull ? nil : rawStep as? String
        }
        let dismissKeys: [(String, String)] = [
            ("dismissedAddComputerStep", "add-computer"),
            ("dismissedCreateAgentStep", "create-agent"),
            ("dismissedInviteStep", "invite-teammates"),
            ("dismissedCommunityStep", "join-community"),
            ("dismissedNotificationStep", "notifications"),
        ]
        for (field, step) in dismissKeys {
            if object[field] as? Bool == true, user.dismissed[step] == nil {
                user.dismissed[step] = Date()
            }
        }
        userOnboardingSettings[key] = user
        lock.unlock()
        return Self.json(200, onboardingJSON(serverId: serverId, userId: userId))
    }

    func serverNotificationJSON(_ prefs: (muted: Bool, mentionsOnly: Bool, mode: String, version: Int)) -> String {
        "{\"serverPushMuted\":\(prefs.muted),\"serverPushMentionsOnly\":\(prefs.mentionsOnly),\"serverPushMode\":\(jsonString(prefs.mode)),\"prefsVersion\":\(prefs.version)}"
    }

    public func memberNotificationSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        let prefs = serverNotificationPrefs["\(serverId)\n\(userId)"] ?? (muted: false, mentionsOnly: false, mode: "all", version: 0)
        lock.unlock()
        return Self.json(200, serverNotificationJSON(prefs))
    }

    public func patchServerNotificationSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid notification settings\"}")
        }
        if let muted = object["serverPushMuted"], !(muted is Bool) {
            return Self.json(400, "{\"error\":\"serverPushMuted must be a boolean\"}")
        }
        if let rawMode = object["serverPushMode"] {
            guard let mode = rawMode as? String, ["all", "mentions", "none"].contains(mode) else {
                return Self.json(400, "{\"error\":\"serverPushMode must be one of all, mentions, none\"}")
            }
        }
        lock.lock()
        let key = "\(serverId)\n\(userId)"
        var prefs = serverNotificationPrefs[key] ?? (muted: false, mentionsOnly: false, mode: "all", version: 0)
        if let mode = object["serverPushMode"] as? String {
            prefs.mode = mode
            prefs.muted = mode == "none"
            prefs.mentionsOnly = mode == "mentions"
        }
        if let muted = object["serverPushMuted"] as? Bool {
            prefs.muted = muted
            if muted {
                prefs.mode = "none"
                prefs.mentionsOnly = false
            } else if prefs.mode == "none" {
                prefs.mode = "all"
                prefs.mentionsOnly = false
            }
        }
        let previous = serverNotificationPrefs[key]
        let changed = previous == nil
            || previous!.muted != prefs.muted
            || previous!.mentionsOnly != prefs.mentionsOnly
            || previous!.mode != prefs.mode
        if changed {
            prefs.version = (previous?.version ?? 0) + 1
        }
        serverNotificationPrefs[key] = prefs
        lock.unlock()
        if changed {
            let payload = "{\"serverId\":\(jsonString(serverId)),\"scopeId\":\(jsonString(serverId)),\"prefs\":{\"serverPushMuted\":\(prefs.muted),\"serverPushMentionsOnly\":\(prefs.mentionsOnly),\"serverPushMode\":\(jsonString(prefs.mode))},\"prefsVersion\":\(prefs.version)}"
            emitRealtime("user:\(userId)", "notification_prefs:updated", payload)
        }
        return Self.json(200, serverNotificationJSON(prefs))
    }

    public func registerServerMachine(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"The `registerMachines` capability is required to register machines\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Self.json(400, "{\"error\":\"Name is required\"}")
        }
        let machineId = registerMachine(serverId: serverId, userId: userId, name: name)
        let apiKey = machineAPIKey(machineId: machineId) ?? ""
        let machine = "{\"id\":\(jsonString(machineId)),\"serverId\":\(jsonString(serverId)),\"name\":\(jsonString(name)),\"userId\":\(jsonString(userId)),\"description\":null}"
        emitRealtime("server:\(serverId)", "machine:updated", "{\"serverId\":\(jsonString(serverId)),\"machineId\":\(jsonString(machineId))}")
        return Self.json(200, "{\"machine\":\(machine),\"apiKey\":\(jsonString(apiKey))}")
    }

    public func runtimeFormDefinition(
        authorization: String?,
        serverId: String,
        machineId: String,
        runtimeId: String,
        protocolVersion: Int,
        schemaVersion: String?,
        language: String?
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime forms\"}")
        }
        guard let expected = Self.runtimeFormSchemas[runtimeId] else {
            return Self.json(404, "{\"error\":\"Runtime form not found\",\"issues\":[{\"code\":\"unknown_form_runtime\",\"pointer\":\"/runtimeId\"}]}")
        }
        if protocolVersion == 1, Self.runtimeFormV2Only.contains(runtimeId) {
            return Self.json(404, "{\"error\":\"Runtime form not found\",\"issues\":[{\"code\":\"unknown_form_runtime\",\"pointer\":\"/runtimeId\"}]}")
        }
        if protocolVersion == 1, let schemaVersion, schemaVersion != expected {
            return Self.json(409, "{\"error\":\"Runtime form schema is stale or unknown\",\"issues\":[{\"code\":\"stale_form_schema\",\"pointer\":\"/schemaVersion\"}]}")
        }
        let zh = Self.prefersChinese(language)
        if protocolVersion == 2 {
            if runtimeId == "builtin" {
                let providerLabel = zh ? "提供方" : "Provider"
                let modelLabel = zh ? "模型" : "Model"
                let apiKeyLabel = zh ? "API 密钥" : "API Key"
                let imageLabel = zh ? "图片输入" : "Image input"
                return Self.json(200, "{\"protocolVersion\":2,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"requiredClientCapabilities\":[\"option_source.status\"],\"fields\":[{\"key\":\"providerId\",\"kind\":\"select\",\"label\":\(jsonString(providerLabel)),\"required\":true},{\"key\":\"apiKey\",\"kind\":\"password\",\"label\":\(jsonString(apiKeyLabel)),\"required\":true,\"writeOnly\":true},{\"key\":\"model\",\"kind\":\"dependent_select\",\"label\":\(jsonString(modelLabel)),\"required\":true,\"dependsOn\":\"providerId\"},{\"key\":\"supportsImageInput\",\"kind\":\"boolean\",\"label\":\(jsonString(imageLabel)),\"required\":false}],\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\"/apiKey\"],\"forbiddenPointers\":[\"/hostUserState\"]},\"optionSources\":{\"provider\":{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"provider\"},\"model\":{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\"}}}")
            }
            if let form = RuntimeFormCatalog.v2Forms[runtimeId] {
                return Self.json(200, form)
            }
            let label = zh ? "模型" : "Model"
            return Self.json(200, "{\"protocolVersion\":2,\"runtimeId\":\(jsonString(runtimeId)),\"schemaVersion\":\(jsonString(expected)),\"requiredClientCapabilities\":[\"option_source.status\"],\"fields\":[{\"key\":\"model\",\"kind\":\"select\",\"label\":\(jsonString(label)),\"required\":true}],\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\"/apiKey\"],\"forbiddenPointers\":[\"/hostUserState\"]}}")
        }
        if runtimeId == "builtin" {
            return Self.json(200, RuntimeFormCatalog.builtinV1Definition)
        }
        if runtimeId == "kimi-sdk", let definition = RuntimeFormCatalog.optionSources["kimi-sdk/edit"] {
            return Self.json(200, definition)
        }
        let properties: String
        let required: String
        let sources: String
        if runtimeId == "builtin" {
            properties = "{\"apiKey\":{\"type\":\"string\",\"writeOnly\":true},\"supportsImageInput\":{\"type\":\"boolean\"},\"providerId\":{\"type\":\"string\"},\"model\":{\"type\":\"string\"}}"
            required = "[\"providerId\",\"model\"]"
            sources = "{\"provider\":{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"provider\"},\"model\":{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\"}}"
        } else {
            properties = "{\"model\":{\"type\":\"string\"}}"
            required = "[\"model\"]"
            sources = "{\"model\":{\"protocolVersion\":1,\"runtimeId\":\(jsonString(runtimeId)),\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\"}}"
        }
        return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\(jsonString(runtimeId)),\"schemaVersion\":\(jsonString(expected)),\"dataSchema\":{\"type\":\"object\",\"properties\":\(properties),\"required\":\(required)},\"uiSchema\":{},\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\"/apiKey\"],\"forbiddenPointers\":[\"/hostUserState\"]},\"optionSources\":\(sources)}")
    }

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
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime form option sources\"}")
        }
        guard let expected = Self.runtimeFormSchemas[runtimeId] else {
            return Self.json(404, "{\"error\":\"Runtime form option source not found\",\"issues\":[{\"code\":\"unknown_form_runtime\",\"pointer\":\"/runtimeId\"}]}")
        }
        if protocolVersion == 1, Self.runtimeFormV2Only.contains(runtimeId) {
            return Self.json(404, "{\"error\":\"Runtime form option source not found\",\"issues\":[{\"code\":\"unknown_form_runtime\",\"pointer\":\"/runtimeId\"}]}")
        }
        if protocolVersion == 1, let schemaVersion, schemaVersion != expected {
            return Self.json(409, "{\"error\":\"Runtime form schema is stale or unknown\",\"issues\":[{\"code\":\"stale_form_schema\",\"pointer\":\"/schemaVersion\"}]}")
        }
        let zh = Self.prefersChinese(language)

        if protocolVersion == 2 {
            // Static sources never probe the Computer.
            if runtimeId == "antigravity" {
                return Self.json(404, "{\"error\":\"Runtime form option source not found\",\"issues\":[{\"code\":\"unknown_option_source\",\"pointer\":\"/sourceId\"}]}")
            }
            if sourceId == "provider", runtimeId == "pi" {
                return Self.json(200, RuntimeFormCatalog.optionSources["pi/provider"] ?? "")
            }
            if sourceId == "providerModel", runtimeId == "pi" {
                return Self.json(200, RuntimeFormCatalog.optionSources["pi/providerModel"] ?? "")
            }
            if sourceId == "model", runtimeId == "kimi" || runtimeId == "gemini" {
                return Self.json(200, RuntimeFormCatalog.optionSources["\(runtimeId)/model"] ?? "")
            }
            if sourceId == "model", runtimeId == "kimi-sdk" {
                return Self.kimiSDKSource(
                    resolution: runtimeProbeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh),
                    protocolVersion: 2,
                    expected: expected
                )
            }
            if sourceId == "model", runtimeId == "builtin" {
                return builtinModelSource(protocolVersion: 2, expected: expected)
            }
            if sourceId == "provider", runtimeId == "claude" {
                return Self.json(200, RuntimeFormCatalog.optionSources["claude/provider"] ?? "")
            }
            if sourceId == "model", runtimeId == "claude" || runtimeId == "cursor" {
                let resolution = runtimeProbeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh)
                switch resolution {
                case .live(let models, let defaultModel):
                    let defaultValue = defaultModel ?? models.first?.id ?? ""
                    let options = models.map { Self.runtimeProbeOptionJSON($0, reasoning: runtimeId == "claude") }.joined(separator: ",")
                    return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\(jsonString(runtimeId)),\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[\(options)],\"defaultValue\":\(jsonString(defaultValue)),\"customValueAllowed\":true,\"status\":\"live\"}")
                case .notLive(let reason):
                    let raw = RuntimeFormCatalog.optionSources["\(runtimeId)/model"] ?? ""
                    let adjusted = raw
                        .replacingOccurrences(of: "\"reason\": \"missing_config\"", with: "\"reason\": \"\(reason)\"")
                        .replacingOccurrences(of: "\"retryable\": false", with: "\"retryable\": \(Self.runtimeReasonRetryable(reason))")
                    return Self.json(200, adjusted)
                }
            }
            if sourceId == "model", ["opencode", "codex", "grok", "pi"].contains(runtimeId) {
                switch Self.resolveRuntimeModelProbe(
                    machineId: machineId,
                    runtimeId: runtimeId,
                    refresh: refresh,
                    routedLocally: machineRoutedLocally,
                    probe: machineRuntimeModelProbe,
                    cached: { [weak self] in
                        guard let self else { return [] }
                        self.lock.lock()
                        defer { self.lock.unlock() }
                        return self.machineRuntimeModels[machineId]?[runtimeId]?.models ?? []
                    }
                ) {
                case .live(let models, let defaultModel):
                    let defaultValue = defaultModel ?? models.first?.id ?? ""
                    let defaultJSON = jsonString(defaultValue)
                    let options: String
                    switch runtimeId {
                    case "codex", "grok", "pi":
                        options = models.map { Self.runtimeProbeOptionJSON($0, reasoning: true) }.joined(separator: ",")
                    default:
                        options = models.map { Self.runtimeProbeOptionJSON($0, reasoning: false) }.joined(separator: ",")
                    }
                    let custom = runtimeId == "codex" || runtimeId == "pi" ? ",\"customValueAllowed\":true" : ""
                    let status = runtimeId == "opencode" ? "" : ",\"status\":\"live\""
                    return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\(jsonString(runtimeId)),\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[\(options)],\"defaultValue\":\(defaultJSON)\(custom)\(status)}")
                case .notLive(let reason):
                    let retryable = Self.runtimeReasonRetryable(reason)
                    switch runtimeId {
                    case "opencode":
                        return Self.json(200, RuntimeFormCatalog.optionSources["opencode/model"] ?? "")
                    case "codex":
                        let raw = RuntimeFormCatalog.optionSources["codex/model"] ?? ""
                        if reason == "missing_config" { return Self.json(200, raw) }
                        let adjusted = raw
                            .replacingOccurrences(of: "\"reason\": \"missing_config\"", with: "\"reason\": \"\(reason)\"")
                            .replacingOccurrences(of: "\"retryable\": false", with: "\"retryable\": \(retryable)")
                        return Self.json(200, adjusted)
                    case "grok":
                        let options = Self.grokBundledModels
                            .map { Self.runtimeProbeOptionJSON($0, reasoning: true) }
                            .joined(separator: ",")
                        return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"grok\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"select\",\"pointer\":\"/model\",\"options\":[\(options)],\"defaultValue\":\"grok-4.5\",\"status\":\"fallback\",\"reason\":\(jsonString(reason)),\"retryable\":\(retryable)}")
                    default:
                        let raw = RuntimeFormCatalog.optionSources["pi/model"] ?? ""
                        if reason == "missing_config" { return Self.json(200, raw) }
                        let adjusted = raw
                            .replacingOccurrences(of: "\"reason\": \"missing_config\"", with: "\"reason\": \"\(reason)\"")
                            .replacingOccurrences(of: "\"retryable\": false", with: "\"retryable\": \(retryable)")
                        return Self.json(200, adjusted)
                    }
                }
            }
        }

        if sourceId == "model", runtimeId == "kimi-sdk" {
            return Self.kimiSDKSource(
                resolution: runtimeProbeResolution(machineId: machineId, runtimeId: runtimeId, refresh: refresh),
                protocolVersion: 1,
                expected: expected
            )
        }
        if sourceId == "model", runtimeId == "builtin" {
            return builtinModelSource(protocolVersion: 1, expected: expected)
        }
        lock.lock()
        let cachedModels = machineRuntimeModels[machineId]?[runtimeId]?.models ?? []
        lock.unlock()
        switch sourceId {
        case "provider" where runtimeId == "builtin":
            let options = "{\"value\":\"deepseek\",\"label\":\(jsonString(zh ? "DeepSeek" : "DeepSeek")),\"providerKind\":\"preset\"},{\"value\":\"moonshotai\",\"label\":\(jsonString(zh ? "月之暗面" : "Moonshot AI")),\"providerKind\":\"preset\"}"
            return Self.json(200, "{\"sourceId\":\"provider\",\"schemaVersion\":\(jsonString(expected)),\"kind\":\"select\",\"options\":[\(options)]}")
        case "model":
            if runtimeId == "builtin" {
                let deepseek = "{\"value\":\"deepseek-chat\",\"label\":\"DeepSeek Chat\"}"
                let moonshot = "{\"value\":\"kimi-k2\",\"label\":\"Kimi K2\"}"
                return Self.json(200, "{\"sourceId\":\"model\",\"schemaVersion\":\(jsonString(expected)),\"kind\":\"dependent_select\",\"optionsByValue\":{\"deepseek\":[\(deepseek)],\"moonshotai\":[\(moonshot)]}}")
            }
            let options = cachedModels.map { "{\"value\":\(jsonString($0.id)),\"label\":\(jsonString($0.label))}" }.joined(separator: ",")
            return Self.json(200, "{\"sourceId\":\"model\",\"schemaVersion\":\(jsonString(expected)),\"kind\":\"select\",\"options\":[\(options)]}")
        default:
            return Self.json(404, "{\"error\":\"Runtime form option source not found\",\"issues\":[{\"code\":\"unknown_option_source\",\"pointer\":\"/sourceId\"}]}")
        }
    }

    func runtimeProbeResolution(machineId: String, runtimeId: String, refresh: Bool) -> RuntimeProbeResolution {
        Self.resolveRuntimeModelProbe(
            machineId: machineId,
            runtimeId: runtimeId,
            refresh: refresh,
            routedLocally: machineRoutedLocally,
            probe: machineRuntimeModelProbe,
            cached: { [weak self] in
                guard let self else { return [] }
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.machineRuntimeModels[machineId]?[runtimeId]?.models ?? []
            }
        )
    }

    func builtinModelSource(protocolVersion: Int, expected: String) -> HTTPReply {
        let mode = builtinCatalogMode
        if mode == "legacy" {
            return Self.json(409, "{\"error\":\"This Computer is too old to prove which Built-in models it supports. Upgrade the Computer before selecting or starting this model.\",\"code\":\"builtin_catalog_capability_required\",\"daemonVersion\":\"1.0.17\",\"computerVersion\":\"1.0.17\",\"recovery\":\"upgrade_required\"}")
        }
        let bundled = "{\"deepseek\":[{\"value\":\"deepseek-chat\",\"label\":\"DeepSeek Chat\"}],\"moonshotai\":[{\"value\":\"kimi-k2\",\"label\":\"Kimi K2\"}]}"
        if protocolVersion == 1 {
            if mode == "timeout" {
                return Self.json(409, "{\"issues\":[{\"code\":\"builtin_catalog_unavailable\",\"pointer\":\"/optionSources/model\"}]}")
            }
            let groups = mode == "offline" ? bundled : liveBuiltinGroups(bundled: bundled)
            return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"dependent_select\",\"pointer\":\"/model\",\"optionsByValue\":\(groups)}")
        }
        switch mode {
        case "timeout":
            return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"dependent_select\",\"pointer\":\"/model\",\"optionsByValue\":{},\"status\":\"unavailable\",\"reason\":\"probe_timeout\",\"retryable\":true}")
        case "offline":
            return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"dependent_select\",\"pointer\":\"/model\",\"optionsByValue\":\(bundled),\"status\":\"fallback\",\"reason\":\"machine_offline\",\"retryable\":true}")
        default:
            let groups = liveBuiltinGroups(bundled: bundled)
            return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\",\"kind\":\"dependent_select\",\"pointer\":\"/model\",\"optionsByValue\":\(groups),\"status\":\"live\"}")
        }
    }

    func liveBuiltinGroups(bundled: String) -> String {
        lock.lock()
        let models = machines.isEmpty ? [] : Array(machineRuntimeModels.values.flatMap { $0["builtin"]?.models ?? [] })
        lock.unlock()
        guard !models.isEmpty else { return bundled }
        let options = models.map { "{\"value\":\(jsonString($0.id)),\"label\":\(jsonString($0.label))}" }.joined(separator: ",")
        return "{\"deepseek\":[\(options)]}"
    }

    public func setRuntimeAccountUsageForTesting(
        machineId: String,
        provider: String,
        json: String,
        staleAfter: Date
    ) {
        lock.lock()
        runtimeAccountUsage["\(machineId)\n\(provider)"] = (json, staleAfter)
        lock.unlock()
    }

    public func machineRuntimeAccountUsage(
        authorization: String?,
        serverId: String,
        machineId: String,
        provider: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard Self.runtimeAccountUsageProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Runtime account usage provider not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let attacher = computerAttachers[machineId]
        let record = runtimeAccountUsage["\(machineId)\n\(provider)"]
        lock.unlock()
        guard canInspectRuntimeAccountUsage(serverId: serverId, userId: userId, attacher: attacher) else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or attaching-human authority is required to inspect runtime account usage\"}")
        }
        _ = machine
        guard let record else {
            var reply = Self.json(200, "{\"state\":\"missing\",\"snapshot\":null}")
            reply.headers["Cache-Control"] = "private, no-store"
            return reply
        }
        let state = record.staleAfter <= Date() ? "stale" : "fresh"
        var reply = Self.json(200, "{\"state\":\(jsonString(state)),\"snapshot\":\(record.json)}")
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    public func refreshMachineRuntimeAccountUsage(
        authorization: String?,
        serverId: String,
        machineId: String,
        provider: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard Self.runtimeAccountUsageProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Runtime account usage provider not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let attacher = computerAttachers[machineId]
        let online = machineOnline[machineId] == true
        lock.unlock()
        _ = machine
        guard canInspectRuntimeAccountUsage(serverId: serverId, userId: userId, attacher: attacher) else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or attaching-human authority is required to refresh runtime account usage\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let manual = (object["reason"] as? String) == "manual"
        let key = "\(machineId)\n\(provider)"
        lock.lock()
        let now = Date()
        if let last = runtimeAccountUsageRefreshAt[key], now.timeIntervalSince(last) < 60 {
            lock.unlock()
            return Self.json(202, "{\"accepted\":false,\"state\":\"cooldown\"}")
        }
        lock.unlock()

        guard manual else {
            lock.lock()
            runtimeAccountUsageRefreshAt[key] = now
            lock.unlock()
            return Self.json(202, "{\"accepted\":true,\"state\":\"requested\"}")
        }

        guard online else {
            return Self.json(202, "{\"accepted\":false,\"state\":\"computer_offline\"}")
        }

        let result = runtimeAccountUsageManualRefresh?(machineId, provider) ?? .timeout
        switch result {
        case .snapshot(let json):
            let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            let staleAfter = (parsed?["staleAfter"] as? String).flatMap(Self.isoDate) ?? now.addingTimeInterval(1800)
            lock.lock()
            runtimeAccountUsage[key] = (json, staleAfter)
            runtimeAccountUsageRefreshAt[key] = now
            lock.unlock()
            return Self.json(200, "{\"accepted\":true,\"state\":\"fresh\",\"snapshot\":\(json)}")
        case .timeout:
            lock.lock()
            runtimeAccountUsageRefreshAt[key] = now
            lock.unlock()
            return Self.json(200, "{\"accepted\":true,\"state\":\"timeout\"}")
        case .offline:
            return Self.json(202, "{\"accepted\":false,\"state\":\"computer_offline\"}")
        }
    }

    func canInspectRuntimeAccountUsage(serverId: String, userId: String, attacher: String?) -> Bool {
        if attacher == userId { return true }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        return role == "owner" || role == "admin"
    }

    public func machineRuntimeOptions(authorization: String?, serverId: String, machineId: String, includeRuntimeFormV2: Bool = false) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let installed = Set(machine.runtimes)
        let grokEnabled = grokRuntimeServers.contains(serverId)
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime options\"}")
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
        let options = catalog.filter { entry in
            entry.id != "grok" || grokEnabled
        }.map { runtime -> String in
            let capability = installed.contains(runtime.id)
                ? "available"
                : (runtime.binary.isEmpty ? "update_required" : "not_installed")
            let canSelect = capability == "available"
            let v2Marker = includeRuntimeFormV2 && RuntimeFormCatalog.v2Forms[runtime.id] != nil
                ? ",\"runtimeFormV2\":{\"protocolVersion\":2}"
                : ""
            let v1Ref = !includeRuntimeFormV2 && Self.runtimeFormV1Runtimes.contains(runtime.id)
                ? ",\"formDefinitionRef\":{\"protocolVersion\":1,\"runtimeId\":\(jsonString(runtime.id)),\"schemaVersion\":\(jsonString(Self.runtimeFormSchemas[runtime.id] ?? ""))}"
                : ""
            return "{\"runtimeId\":\(jsonString(runtime.id)),\"capabilityStatus\":\(jsonString(capability)),\"admissionStatus\":\"available_for_new\",\"admissionReason\":null,\"current\":false,\"availableForNew\":true,\"manageableForCurrentAgent\":false,\"canSelectInThisContext\":\(canSelect)\(v2Marker)\(v1Ref)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"context\":\"new_agent\",\"machineId\":\(jsonString(machine.id)),\"options\":[\(options)]}")
    }

    public func machineRuntimeModels(authorization: String?, serverId: String, machineId: String, runtime: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        let cached = machineRuntimeModels[machineId]?[runtime]?.models ?? []
        let probe = machineRuntimeModelProbe
        let routed = machineRoutedLocally?(machineId) ?? true
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime models\"}")
        }
        func modelList(_ models: [RuntimeModelProbeModel]) -> String {
            models.map {
                "{\"id\":\(jsonString($0.id)),\"label\":\(jsonString($0.label))}"
            }.joined(separator: ",")
        }
        guard routed else {
            return Self.json(200, "{\"kind\":\"error\",\"retryable\":true,\"code\":\"computer_offline\"}")
        }
        if let probe {
            switch probe(machineId, runtime, true) {
            case .live(let models, let defaultModel):
                let list = modelList(models)
                let defaultJSON = defaultModel.map(jsonString) ?? "null"
                return Self.json(200, "{\"kind\":\"live\",\"value\":{\"models\":[\(list)],\"default\":\(defaultJSON)},\"models\":[\(list)],\"default\":\(defaultJSON)}")
            case .models(let models, let defaultModel):
                let list = modelList(models)
                let defaultJSON = defaultModel.map(jsonString) ?? "null"
                return Self.json(200, "{\"models\":[\(list)],\"default\":\(defaultJSON)}")
            case .missingConfig:
                return Self.json(200, "{\"kind\":\"missing_config\",\"recovery\":\"kimi_login\"}")
            case .noModels:
                return Self.json(200, "{\"kind\":\"no_models\"}")
            case .unsupported:
                return Self.json(200, "{\"kind\":\"unsupported\"}")
            case .error(let code, _):
                if code.isEmpty {
                    return Self.json(200, "{\"kind\":\"error\",\"retryable\":true}")
                }
                return Self.json(200, "{\"kind\":\"error\",\"retryable\":true,\"code\":\(jsonString(code))}")
            case .failed:
                return Self.json(200, "{\"kind\":\"error\",\"retryable\":true}")
            }
        }
        let list = modelList(cached.map { RuntimeModelProbeModel(id: $0.id, label: $0.label) })
        let defaultJSON = cached.first.map { jsonString($0.id) } ?? "null"
        return Self.json(200, "{\"kind\":\"live\",\"value\":{\"models\":[\(list)],\"default\":\(defaultJSON)},\"models\":[\(list)],\"default\":\(defaultJSON)}")
    }

    public func machineWorkspaces(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        let canManage = role == "owner" || role == "admin" || machine.userId == userId
        let keys = agentMachineIds.filter { $0.value == machineId }.map(\.key)
        let deleted = deletedMachineWorkspaces
        lock.unlock()
        guard canManage else {
            return Self.json(403, "{\"error\":\"You do not have permission to view machine workspaces\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let epoch = formatter.string(from: Date(timeIntervalSince1970: 0))
        let rows = keys.compactMap { agentId -> String? in
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId else { return nil }
            if deleted.contains("\(machineId)\n\(agentId)") { return nil }
            let agentStatus: String
            lock.lock()
            agentStatus = serverAgents[agentId]?.status ?? "inactive"
            lock.unlock()
            let status = agent.deleted ? "deleted" : (agentStatus == "inactive" ? "stopped" : "active")
            let name = agent.displayName.isEmpty ? agent.name : agent.displayName
            return "{\"directoryName\":\(jsonString(agent.id)),\"totalSizeBytes\":0,\"lastModified\":\(jsonString(epoch)),\"fileCount\":0,\"status\":\(jsonString(status)),\"agentName\":\(jsonString(name)),\"agentStatus\":\(jsonString(agentStatus))}"
        }
        return Self.json(200, "[\(rows.joined(separator: ","))]")
    }

}
