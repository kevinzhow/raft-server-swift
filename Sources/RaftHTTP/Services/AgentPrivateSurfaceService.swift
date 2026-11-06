import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Agent records and their private surfaces: creation, listing, profile
/// patching, credentials, the wake-hint stream and the assistant-owner
/// inbox.
///
/// These handlers were lifted from `EmailLogin+Agents2.swift`.

public struct AgentPrivateSurfaceService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    public func createAgentRoute(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid Agent\"}")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let reservedHandles: Set<String> = [
            "all", "human", "humans", "agent", "agents", "here",
            "idle", "busy", "system", "reminders",
        ]
        guard !reservedHandles.contains(trimmedName.lowercased()) else {
            return Self.json(400, "{\"error\":\"This username is reserved. Choose another name.\"}")
        }
        let onboardingRequest = object["onboarding"] as? Bool == true
        if onboardingRequest {
            guard role == "owner" || role == "admin" else {
                return Self.json(403, "{\"error\":\"Only server owners and admins can create the onboarding agent\"}")
            }
            lock.lock()
            let existingOnboardingAgentId = serverOnboardingSettings[serverId]?.agentId
            lock.unlock()
            if let existingOnboardingAgentId {
                return Self.json(409, "{\"error\":\"Onboarding agent already exists\",\"onboardingAgentId\":\(jsonString(existingOnboardingAgentId))}")
            }
            if oauth.serverAgents(serverId: serverId).contains(where: {
                !$0.deleted && $0.name.caseInsensitiveCompare("Cindy") == .orderedSame
            }) {
                return Self.json(409, "{\"error\":\"Cindy agent already exists\"}")
            }
        }
        let duplicate = oauth.serverAgents(serverId: serverId).contains {
            !$0.deleted && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        guard !duplicate else {
            return Self.json(409, "{\"error\":\"Agent name is already taken\"}")
        }
        let external = object["external"] as? Bool ?? false
        if external, object["machineId"] != nil {
            return Self.json(400, "{\"error\":\"External agents cannot be assigned to a Computer\"}")
        }
        var hostedProvider: String?
        if let provider = object["provider"] as? String, !provider.isEmpty {
            guard provider == "antiproton" else {
                return Self.json(400, "{\"error\":\"Unknown runtime provider\"}")
            }
            guard external else {
                return Self.json(400, "{\"error\":\"provider is only for external agents\"}")
            }
            lock.lock()
            let flagged = hostedRuntimeServers.contains(serverId)
            lock.unlock()
            guard flagged else {
                return Self.json(403, "{\"error\":\"The hosted runtime provider is not enabled for this server\",\"code\":\"agent_runtime_provider_disabled\"}")
            }
            guard hostedProviderConfigured() else {
                return Self.json(409, "{\"error\":\"The hosted runtime provider is not configured for this deployment\",\"code\":\"agent_runtime_provider_not_configured\"}")
            }
            hostedProvider = provider
        }
        let rawConfig = object["runtimeConfig"] as? [String: Any] ?? [:]
        if let formRef = object["formDefinitionRef"] as? [String: Any],
           (formRef["protocolVersion"] as? Int) == 2,
           let formValues = object["formValues"] as? [String: Any],
           let providerId = formValues["providerId"] as? String,
           providerId.hasPrefix("connection:") {
            let connectionId = String(providerId.dropFirst("connection:".count))
            guard ServerScope.isUUID(connectionId) else {
                return Self.json(400, "{\"error\":\"Invalid provider connection id\",\"issues\":[{\"pointer\":\"/formValues/providerId\",\"code\":\"provider_connection_id_invalid\"}]}")
            }
            lock.lock()
            let exists = providerConnections.contains {
                $0.id == connectionId && $0.serverId == serverId
            }
            lock.unlock()
            guard exists else {
                return Self.json(409, "{\"error\":\"Provider connection is not available\",\"issues\":[{\"pointer\":\"/formValues/providerId\",\"code\":\"provider_connection_unavailable\"}]}")
            }
        }
        if let formRef = object["formDefinitionRef"] as? [String: Any],
           (formRef["protocolVersion"] as? Int) == 2,
           let formValues = object["formValues"] as? [String: Any],
           let machineId = object["machineId"] as? String,
           let runtimeId = formRef["runtimeId"] as? String,
           let model = formValues["model"] as? String,
           !model.isEmpty,
           let models = agentRuntimeModelsForMachine?(machineId, runtimeId),
           !models.contains(model) {
            return Self.json(400, "{\"error\":\"The selected model is not available on this Computer\",\"issues\":[{\"pointer\":\"/formValues/model\",\"code\":\"model_not_available\"}]}")
        }
        if let legacyRuntime = object["runtime"] as? String,
           Self.deprecatedAgentRuntimes.contains(legacyRuntime) {
            return Self.deprecatedRuntimeReply(legacyRuntime)
        }
        if let configRuntime = rawConfig["runtime"] as? String,
           Self.deprecatedAgentRuntimes.contains(configRuntime) {
            return Self.deprecatedRuntimeReply(configRuntime)
        }
        if let reply = Self.runtimeConfigStructureError(rawConfig) { return reply }
        var config = Self.normalizeRuntimeConfig(rawConfig)
        var envVars: [String: String] = [:]
        if external {
            config = [
                "version": 1,
                "runtime": "external",
                "model": ["kind": "preset", "id": "external"],
                "mode": ["kind": "default"],
                "reasoningEffort": NSNull(),
                "envVars": NSNull(),
            ]
        } else if object["envVars"] != nil {
            let validation = Self.validatedEnvVars(object["envVars"])
            if let error = validation.error {
                return Self.json(400, "{\"error\":\(jsonString(error))}")
            }
            if let env = validation.env {
                config["envVars"] = env
            }
        }
        if !external {
            if let command = config["command"] as? String, !command.isEmpty,
               let configRuntime = config["runtime"] as? String, configRuntime != "claude" {
                return Self.json(400, "{\"error\":\"runtimeConfig.command is not supported for runtime: \(configRuntime)\"}")
            }
            let userEnv = (config["envVars"] as? [String: String]) ?? [:]
            envVars = Self.derivedAgentEnvVars(config, userEnv: userEnv)
        }
        if onboardingRequest {
            var onboardingEnv = (config["envVars"] as? [String: String]) ?? [:]
            onboardingEnv["SLOCK_ONBOARDING_MEMORY_SEED"] = "first-cindy"
            config["envVars"] = onboardingEnv
            envVars = Self.derivedAgentEnvVars(config, userEnv: onboardingEnv)
        }
        let effectiveName = onboardingRequest ? "Cindy" : name
        let runtime = external ? "external" : (config["runtime"] as? String ?? "managed")
        if let machineId = object["machineId"] as? String,
           builtinModelCheck(machineId: machineId, config: config) == .catalogUnavailable {
            return builtinCatalogFailureReply()
        }
        let configJSON = Self.serializeJSON(config)
        let envJSON = external ? "null" : Self.serializeJSON(envVars)
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
            lock.lock()
            let greeting = serverOnboardingSettings[serverId]?.greeting ?? true
            serverOnboardingSettings[serverId] = (agentId: agentId, greeting: greeting)
            lock.unlock()
            emitRealtime("server:\(serverId)", "agent:updated", "{\"agentId\":\(jsonString(agentId))}")
        }
        if let machineId = object["machineId"] as? String, !machineId.isEmpty {
            lock.lock()
            agentMachineIds[agentId] = machineId
            lock.unlock()
        }
        if let hostedProvider {
            lock.lock()
            hostedRuntimes[agentId] = (hostedProvider, nil, "provisioning", false, Date())
            lock.unlock()
        }
        let creatorDm = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: agentId)
        oauth.addChannelAgent(channelId: creatorDm, agentId: agentId)
        emitRealtime("channel:\(creatorDm)", "dm:new", "{\"channelId\":\(jsonString(creatorDm))}")
        emitRealtime("user:\(userId)", "dm:new", "{\"channelId\":\(jsonString(creatorDm))}")
        let creator = "{\"type\":\"human\",\"id\":\(jsonString(userId))}"
        let responseConfigJSON = Self.redactedRuntimeConfigJSON(configJSON)
        let runtimeJSON = Self.agentRuntimeJSON(
            id: agentId,
            name: effectiveName,
            runtime: runtime,
            runtimeConfigJSON: responseConfigJSON ?? configJSON,
            envVarsJSON: envJSON,
            external: external
        )
        let broadcastJSON = Self.agentRuntimeJSON(
            id: agentId,
            name: name,
            runtime: runtime,
            runtimeConfigJSON: responseConfigJSON ?? configJSON,
            envVarsJSON: envJSON,
            external: external,
            includeEnvVars: false
        )
        emitRealtime("server:\(serverId)", "agent:created", "{\"agent\":\(broadcastJSON)}")
        let createdAgent = oauth.agentRuntimeInfo(id: agentId)
        let createdDisplayName = createdAgent?.displayName ?? effectiveName
        let createdDescription = createdAgent?.description
        let createdAvatar = createdAgent?.avatarUrl
        let createdRole = oauth.agentRole(serverId: serverId, agentId: agentId) ?? "member"
        var created = String(runtimeJSON.dropLast()) + ",\"creator\":\(creator)" + ",\"displayName\":\(jsonString(createdDisplayName)),\"description\":\(createdDescription.map(jsonString) ?? "null"),\"avatarUrl\":\(createdAvatar.map(jsonString) ?? "null"),\"serverRole\":\(jsonString(createdRole))"
        if let hostedProvider {
            created += ",\"hostedRuntime\":{\"kind\":\(jsonString(hostedProvider)),\"state\":\"provisioning\"}"
        }
        return Self.json(200, created + "}")
    }

    public func listServerAgents(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let seen = agentLastSeenAt
        lock.unlock()
        let rows = oauth.serverAgents(serverId: serverId).map { agent -> String in
            let canSeeConfig = role == "owner" || role == "admin" || agent.creatorUserId == userId
            let creatorJSON = agent.creatorUserId.map { "{\"type\":\"human\",\"id\":\(jsonString($0))}" } ?? "null"
            var base = "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"runtime\":\(jsonString(agent.runtime)),\"model\":\(jsonString(Self.agentModel(from: agent.runtimeConfigJSON, external: agent.runtime == "external"))),\"external\":\(agent.runtime == "external"),\"serverRole\":\(jsonString(oauth.agentRole(serverId: agent.serverId, agentId: agent.id) ?? "member")),\"creator\":\(creatorJSON),\"description\":\(agent.description.map { jsonString($0) } ?? "null")"
            if agent.runtime == "external" {
                let lastSeen = seen[agent.id].map { jsonString(formatter.string(from: $0)) } ?? "null"
                base += ",\"lastSeenAt\":\(lastSeen)"
            }
            if canSeeConfig {
                return base + ",\"runtimeConfig\":\(Self.redactedRuntimeConfigJSON(agent.runtimeConfigJSON) ?? "null"),\"envVars\":\(agent.envVarsJSON ?? "null")}"
            }
            return base + "}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func listArchivedAgents(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = agentArchiveRecords
            .filter { $0.value.serverId == serverId }
            .map { id, record in
                "{\"agentId\":\(jsonString(id)),\"machineName\":\(record.machineName.isEmpty ? "null" : jsonString(record.machineName)),\"workspaceState\":\(jsonString(record.workspaceState))}"
            }
            .sorted()
        lock.unlock()
        return Self.json(200, "{\"agents\":[\("\(rows.joined(separator: ","))")]}")
    }

    public func agentRuntimeOptions(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"runtimes\":[],\"models\":[]}")
    }

    public func agentLogin(authorization: String?, body: String) -> HTTPReply {
        let enabled = (ProcessInfo.processInfo.environment["SLOCK_SELF_HOSTED_RUNNER_BOOTSTRAP_ENABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        guard enabled else {
            return Self.json(404, "{\"error\":\"Self-hosted runner bootstrap is not enabled\",\"code\":\"self_hosted_runner_bootstrap_disabled\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let token = (object["bootstrapToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            return Self.json(400, "{\"error\":\"bootstrapToken is required\",\"code\":\"missing_bootstrap_token\"}")
        }
        return Self.json(401, "{\"error\":\"token_invalid\",\"code\":\"token_invalid\"}")
    }

    public func createAgentBootstrapToken(authorization: String?, serverId: String, agentId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"insufficient_role\",\"error\":\"issueAgentCredentials requires human creator authority\"}")
        }
        guard info.runtime == "external" else {
            return Self.json(400, "{\"code\":\"agent_not_external\",\"error\":\"Only external Agents get bootstrap tokens\"}")
        }
        return Self.json(201, "{\"token\":\"bootstrap-disabled\",\"createdAt\":\"1970-01-01T00:00:00.000Z\",\"scopes\":[\"channels\",\"knowledge\",\"mentions\",\"reactions\",\"read\",\"send\",\"tasks\"]}")
    }

    public func patchAgentCreator(authorization: String?, serverId: String, agentId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let creatorType = object["creatorType"] as? String, creatorType == "user",
              let creatorId = object["creatorId"] as? String,
              oauth.memberRole(serverId: serverId, userId: creatorId) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid creator\"}")
        }
        _ = oauth.setAgentCreator(id: agentId, creatorUserId: creatorId)
        return Self.json(200, "{\"creator\":{\"type\":\"human\",\"id\":\(jsonString(creatorId))}}")
    }

    public func getAgentRoute(authorization: String?, agentId: String, serverId: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard agentId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted,
              serverId.isEmpty || agent.serverId == serverId
        else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let role = oauth.memberRole(serverId: agent.serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if role == "guest" {
            let avatar = "null"
            let description = agent.description.map { jsonString($0) } ?? "null"
            return Self.json(200, "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"avatarUrl\":\(avatar),\"description\":\(description),\"profileProjection\":\"channel_summary\"}")
        }
        let canSeeConfig = role == "owner" || role == "admin" || agent.creatorUserId == userId
        let creatorJSON = agent.creatorUserId.map { "{\"type\":\"human\",\"id\":\(jsonString($0))}" } ?? "null"
        let base = "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"runtime\":\(jsonString(agent.runtime)),\"model\":\(jsonString(Self.agentModel(from: agent.runtimeConfigJSON, external: agent.runtime == "external"))),\"external\":\(agent.runtime == "external"),\"serverRole\":\(jsonString(oauth.agentRole(serverId: agent.serverId, agentId: agent.id) ?? "member")),\"creator\":\(creatorJSON),\"description\":\(agent.description.map { jsonString($0) } ?? "null")"
        let body = canSeeConfig
            ? base + ",\"runtimeConfig\":\(Self.redactedRuntimeConfigJSON(agent.runtimeConfigJSON) ?? "null"),\"envVars\":\(agent.envVarsJSON ?? "null")}"
            : base + "}"
        return Self.json(200, body)
    }

    /// nil means the field was absent and must be ignored.

    public func uploadAgentAvatar(authorization: String?, agentId: String, byteCount: Int) -> HTTPReply {
        switch agentAuthority(authorization, agentId: agentId) {
        case .denied(let reply):
            return reply
        case .allowed:
            let maxBytes = 5 * 1024 * 1024
            guard byteCount <= maxBytes else {
                return Self.json(400, "{\"error\":\"Avatar image must be 5 MB or smaller\",\"errorCode\":\"PROFILE_AVATAR_TOO_LARGE\",\"maxBytes\":\(maxBytes)}")
            }
            let key = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let avatarUrl = "/api/avatars/users/\(key).webp"
            oauth.updateAgentAvatar(id: agentId, avatarUrl: avatarUrl)
            return Self.json(200, "{\"avatarUrl\":\(jsonString(avatarUrl))}")
        }
    }

    public func externalAgentStatus(authorization: String?, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentRuntimeInfo(id: agentId), !info.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: info.serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard info.runtime == "external" else {
            return Self.json(400, "{\"error\":\"Agent is not external\"}")
        }
        lock.lock()
        let credentials = agentCredentials.values.filter { $0.agentId == agentId }
        let minted = !credentials.isEmpty
        let lastUsedAt = credentials.compactMap { $0.lastUsedAt }.max()
        lock.unlock()
        let setupState: String
        if lastUsedAt != nil {
            setupState = "connected"
        } else if minted {
            setupState = "credential_minted"
        } else {
            setupState = "waiting_for_login"
        }
        let usedJSON = lastUsedAt.map { jsonString(ISO8601DateFormatter().string(from: $0)) } ?? "null"
        return Self.json(200, "{\"setupState\":\(jsonString(setupState)),\"credentialLastUsedAt\":\(usedJSON),\"lastActivityAt\":null}")
    }

    func recordAgentCredentialUse(token: String) {
        let now = Date()
        lock.lock()
        guard var credential = agentCredentials[token], credential.revokedAt == nil else {
            lock.unlock()
            return
        }
        let throttle = agentCredentialUseThrottleOverrideMs ?? Self.agentCredentialUseDefaultThrottleMs
        if let last = credential.lastUsedAt, now.timeIntervalSince(last) * 1000 < Double(throttle) {
            lock.unlock()
            return
        }
        credential.lastUsedAt = now
        agentCredentials[token] = credential
        agentLastSeenAt[credential.agentId] = now
        lock.unlock()
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), agent.runtime == "external" else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        emitRealtime("server:\(agent.serverId)", "agent:seen", "{\"agentId\":\(jsonString(agent.id)),\"lastSeenAt\":\(jsonString(formatter.string(from: now)))}")
    }

    public func refreshAgentWakeStreamCredential(token: String) {
        recordAgentCredentialUse(token: token)
    }

    /// Opens `GET /internal/agent-api/wake-hints/stream`. The stream is the SSE
    /// projection of the same content-free peek: pending hints replay first,
    /// later hints arrive on the next tick, and nothing drains the inbox.
    public func beginAgentWakeHintsStream(authorization: String?, since: String?) -> AgentWakeStreamStart {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .refused(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil, credential.scopes.contains("read") else {
            return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
        let raw = (since ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var cursorSeq: Int?
        var latestOnly = false
        if !raw.isEmpty {
            if raw == "latest" {
                latestOnly = true
            } else {
                guard let value = Int(raw), value >= 0 else {
                    return .refused(Self.json(400, "{\"error\":\"since / Last-Event-ID must be a non-negative integer (messageSeq) or 'latest'\",\"code\":\"since_invalid\"}"))
                }
                cursorSeq = value
            }
        }
        recordAgentCredentialUse(token: token)
        lock.lock()
        let pending = pendingWakeHintRowsLocked(agentId: credential.agentId, agent: agent, sinceSeq: cursorSeq, limit: 500)
        let thirdParty = oauth.pendingThirdPartyEventMessages(agentId: credential.agentId)
        lock.unlock()
        var frames = ": connected\n\n"
        if latestOnly {
            cursorSeq = pending.rows.last?.seq
        } else {
            for row in pending.rows {
                frames += Self.sseWakeHintFrame(id: "\(row.seq)", json: row.json)
                cursorSeq = row.seq
            }
            for event in thirdParty {
                let data = "{\"event_id\":\(jsonString("wake-hint:\(event.id)")),\"seq\":null,\"message_id\":\(jsonString(event.id)),\"target\":null,\"wake_reason\":\"message_pending\"}"
                frames += Self.sseWakeHintFrame(id: "null", json: data)
            }
        }
        return .start(token: token, cursorSeq: cursorSeq, firstFrame: frames)
    }

    /// `nil` means the credential or agent is gone: the stream must close.
    public func agentWakeStreamBatch(token: String, after: Int?) -> (frames: String, cursorSeq: Int?)? {
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil, credential.scopes.contains("read") else { return nil }
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else { return nil }
        lock.lock()
        let pending = pendingWakeHintRowsLocked(agentId: credential.agentId, agent: agent, sinceSeq: after, limit: 500)
        lock.unlock()
        guard let last = pending.rows.last else { return ("", after) }
        let frames = pending.rows.map { Self.sseWakeHintFrame(id: "\($0.seq)", json: $0.json) }.joined()
        return (frames, last.seq)
    }

    static func sseWakeHintFrame(id: String, json: String) -> String {
        "event: wake-hint\nid: \(id)\ndata: \(json)\n\n"
    }

    public func markAgentCredentialUsed(agentId: String) {
        lock.lock()
        for key in agentCredentials.keys where agentCredentials[key]?.agentId == agentId {
            agentCredentials[key]?.lastUsedAt = Date()
        }
        lock.unlock()
    }

    public func manageableAgentList(authorization: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let result = oauth.manageableAgents(userId: userId)
        let rows = result.agents.map { agent in
            "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"serverId\":\(jsonString(agent.serverId)),\"serverName\":\(agent.serverName.map { jsonString($0) } ?? "null")}"
        }.joined(separator: ",")
        let reason: String
        if !result.agents.isEmpty {
            reason = "ok"
        } else if result.serverCount > 0 {
            reason = "no_agents_on_manageable_servers"
        } else {
            reason = "no_manageable_server"
        }
        return Self.json(200, "{\"ok\":true,\"data\":{\"agents\":[\("\(rows)")],\"reason\":\(jsonString(reason)),\"manageable_server_count\":\(result.serverCount)}}")
    }

    public func patchAgent(authorization: String?, agentId: String, body: String, serverId: String = "") -> HTTPReply {
        if !serverId.isEmpty,
           let info = oauth.agentManagementInfo(id: agentId),
           info.serverId != serverId || info.deleted {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        switch agentAuthority(authorization, agentId: agentId) {
        case .denied(let reply):
            return reply
        case .allowed(let actorId, let actorRole, let info):
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
                return Self.json(400, "{\"error\":\"Invalid Agent update\"}")
            }
            let previousConfigSnapshot = info.runtimeConfigJSON.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8))
            } as? [String: Any] ?? [:]
            let previousModelValue = Self.agentModel(from: info.runtimeConfigJSON, external: info.runtime == "external")
            let previousEffortValue = previousConfigSnapshot["reasoningEffort"] as? String
            let previousRuntimeValue = info.runtime
            if let restartMode = object["restartMode"] as? String,
               restartMode != "restart", restartMode != "session" {
                return Self.json(400, "{\"error\":\"Invalid restart mode: \(restartMode)\"}")
            }
            // External agents run on their own machine; Raft-managed runtime
            // fields are immutable for them (descriptions still update).
            if info.runtime == "external",
               ["runtime", "runtimeConfig", "model", "reasoningEffort", "envVars"].contains(where: { object[$0] != nil }) {
                return Self.json(400, "{\"error\":\"External agent runtime fields are immutable\"}")
            }
            if object["serverRole"] != nil {
                if let reply = Self.applyAgentServerRole(
                    directory: self,
                    actorUserId: actorId,
                    actorRole: actorRole,
                    info: info,
                    object: object
                ) {
                    return reply
                }
            }
            var description: String?
            if let value = object["description"] as? String {
                oauth.updateAgentDescription(id: agentId, description: value)
                description = value
            }
            var displayName: String?
            if let value = object["displayName"] as? String {
                oauth.updateAgentDisplayName(id: agentId, displayName: value)
                displayName = value
            }
            var avatarUrl: String?
            if let value = object["avatarUrl"] as? String {
                oauth.updateAgentAvatar(id: agentId, avatarUrl: value)
                avatarUrl = value
            }
            var runtimeConfigJSON = info.runtimeConfigJSON
            var envVarsJSON = info.envVarsJSON
            var replacedRuntime: String?
            if let legacyRuntime = object["runtime"] as? String {
                if Self.deprecatedAgentRuntimes.contains(legacyRuntime), legacyRuntime != info.runtime {
                    return Self.deprecatedRuntimeReply(legacyRuntime)
                }
                replacedRuntime = legacyRuntime
            }
            var configChanged = false
            var config = runtimeConfigJSON.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8))
            } as? [String: Any] ?? [:]
            if let rawConfig = object["runtimeConfig"] as? [String: Any] {
                if let configRuntime = rawConfig["runtime"] as? String,
                   Self.deprecatedAgentRuntimes.contains(configRuntime), configRuntime != info.runtime {
                    return Self.deprecatedRuntimeReply(configRuntime)
                }
                if let reply = Self.runtimeConfigStructureError(rawConfig) { return reply }
                let previousConfig = config
                var normalized = Self.normalizeRuntimeConfig(rawConfig)
                if var provider = normalized["provider"] as? [String: Any] {
                    let incomingKey = provider["apiKey"] as? String ?? ""
                    if incomingKey.isEmpty,
                       let previousKey = (previousConfig["provider"] as? [String: Any])?["apiKey"] as? String,
                       !previousKey.isEmpty {
                        provider["apiKey"] = previousKey
                        normalized["provider"] = provider
                    }
                }
                if let command = normalized["command"] as? String, !command.isEmpty,
                   let configRuntime = normalized["runtime"] as? String, configRuntime != "claude" {
                    return Self.json(400, "{\"error\":\"runtimeConfig.command is not supported for runtime: \(configRuntime)\"}")
                }
                config = normalized
                configChanged = true
                replacedRuntime = normalized["runtime"] as? String
            } else {
                if let model = object["model"] as? String {
                    config["model"] = ["kind": "preset", "id": model]
                    configChanged = true
                }
                if let effort = object["reasoningEffort"] {
                    config["reasoningEffort"] = effort is NSNull ? NSNull() : (effort as? String ?? NSNull())
                    configChanged = true
                }
            }
            if object["envVars"] != nil {
                let validation = Self.validatedEnvVars(object["envVars"])
                if let error = validation.error {
                    return Self.json(400, "{\"error\":\(jsonString(error))}")
                }
                var userEnv: [String: String] = [:]
                for (key, value) in validation.env ?? [:] {
                    if key.hasPrefix("ANTHROPIC_") { continue }
                    userEnv[key] = value
                }
                config["envVars"] = userEnv
                configChanged = true
            }
            if let replacedRuntime {
                config["runtime"] = replacedRuntime
                configChanged = true
            }
            if configChanged {
                if let machineId = agentMachineIds[info.id],
                   builtinModelCheck(machineId: machineId, config: config) == .catalogUnavailable {
                    return builtinCatalogFailureReply()
                }
                if config["version"] == nil { config["version"] = 1 }
                if config["mode"] == nil { config["mode"] = ["kind": "default"] }
                if config["reasoningEffort"] == nil { config["reasoningEffort"] = NSNull() }
                if config["envVars"] == nil { config["envVars"] = [String: String]() }
                let userEnv = (config["envVars"] as? [String: String]) ?? [:]
                let env = Self.derivedAgentEnvVars(config, userEnv: userEnv)
                runtimeConfigJSON = Self.serializeJSON(config)
                envVarsJSON = Self.serializeJSON(env)
                oauth.updateAgentRuntime(id: agentId, runtimeConfigJSON: runtimeConfigJSON, envVarsJSON: envVarsJSON)
                if let replacedRuntime { oauth.updateAgentRuntimeId(id: agentId, runtime: replacedRuntime) }
            }
            let descriptionJSON = description.map { jsonString($0) } ?? "null"
            let latest = oauth.agentRuntimeInfo(id: agentId)
            let runtimeForResponse = latest?.runtime ?? info.runtime
            let configForModel = runtimeConfigJSON ?? latest?.runtimeConfigJSON ?? info.runtimeConfigJSON
            let model = Self.agentModel(from: configForModel, external: runtimeForResponse == "external")
            let avatarJSON = avatarUrl.map { jsonString($0) } ?? "null"
            let displayNameJSON = displayName.map { jsonString($0) } ?? "null"
            let effortValue = config["reasoningEffort"]
            let effortJSON = effortValue is NSNull || effortValue == nil ? "null" : jsonString(effortValue as? String ?? "")
            let effectiveRole = oauth.agentRole(serverId: info.serverId, agentId: info.id) ?? "member"
            // RFC 071 §5: only a real runtime value change lifts the terminal breaker.
            let nextEffort = config["reasoningEffort"] as? String
            let runtimeValuesChanged = model != previousModelValue
                || runtimeForResponse != previousRuntimeValue
                || nextEffort != previousEffortValue
            agentConfigLiftDispatch?(agentId, runtimeValuesChanged)
            return Self.json(200, "{\"id\":\(jsonString(info.id)),\"name\":\(jsonString(info.name)),\"displayName\":\(displayNameJSON),\"model\":\(jsonString(model)),\"runtime\":\(jsonString(runtimeForResponse)),\"reasoningEffort\":\(effortJSON),\"description\":\(descriptionJSON),\"avatarUrl\":\(avatarJSON),\"serverRole\":\(jsonString(effectiveRole)),\"runtimeConfig\":\(Self.redactedRuntimeConfigJSON(runtimeConfigJSON ?? latest?.runtimeConfigJSON) ?? "null"),\"envVars\":\(envVarsJSON ?? "null")}")
        }
    }


    /// Human role-transition policy for `serverRole` on an agent: the owner may
    /// promote and demote, an admin may only promote an agent they created, and
    /// `owner` itself is never assignable to an agent. A real change posts a
    /// system notice into the actor's DM with the agent.

    func postAgentRoleNotice(
        serverId: String,
        actorUserId: String,
        agentId: String,
        agentName: String,
        from: String,
        to: String
    ) {
        lock.lock()
        let actorName = accounts.values.first { $0.id == actorUserId }?.name ?? "Someone"
        var dmId = postableChannels.first { _, channel in
            channel.serverId == serverId && channel.kind == "dm"
                && channel.memberIds.contains(actorUserId) && channel.memberIds.contains(agentId)
        }?.key
        if dmId == nil {
            dmId = oauth.createDirectChannel(serverId: serverId, firstUserId: actorUserId, secondUserId: agentId)
            if let created = dmId {
                postableChannels[created] = PostableChannel(serverId: serverId, memberIds: [actorUserId, agentId], kind: "dm", name: "dm")
                oauth.addChannelAgent(channelId: created, agentId: agentId)
                oauth.addChannelHuman(channelId: created, userId: actorUserId)
            }
        }
        if let dmId {
            appendHumanMessageLocked(StoredHumanMessage(
                id: UUID().uuidString.lowercased(),
                channelId: dmId,
                senderId: actorUserId,
                content: "@\(actorName) changed @\(agentName)'s server role from \(from) to \(to).",
                messageType: "system",
                senderType: "user",
                actionKind: "agent.server_role_changed"
            ))
        }
        lock.unlock()
    }

    /// The assistant link is live only while the flag is on and the owner is
    /// still a member of the agent's Server.
    func assistantOwnerFor(agentId: String, serverId: String) -> String? {
        lock.lock()
        let owner = assistantOwners[agentId]
        lock.unlock()
        guard let owner, oauth.memberRole(serverId: serverId, userId: owner) != nil else { return nil }
        guard agentsRuntimeStore.featureFlagEnabled(key: "identity_borrowing", serverId: serverId) else { return nil }
        return owner
    }

    func assistantOwnerRaw(_ agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return assistantOwners[agentId]
    }

    func assistantIsInRegularChannel(serverId: String, agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for (id, channel) in postableChannels {
            guard channel.serverId == serverId, channel.deletedAt == nil,
                  channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint"
            else { continue }
            if channel.memberIds.contains(agentId)
                || channelAgentMembers[id]?.contains(agentId) == true
                || oauth.channelAgentIds(channelId: id).contains(agentId) {
                return true
            }
        }
        return false
    }

    public func agentAssistantOwner(authorization: String?, serverId: String, agentId: String, method: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"assistant_requires_creator\",\"error\":\"Only the agent creator can lend assistant ownership\"}")
        }
        guard agentsRuntimeStore.featureFlagEnabled(key: "identity_borrowing", serverId: serverId) else {
            return Self.json(403, "{\"code\":\"assistant_not_enabled\",\"error\":\"Assistant ownership is not enabled\"}")
        }
        if method == "DELETE" {
            lock.lock()
            assistantOwners.removeValue(forKey: agentId)
            lock.unlock()
            return Self.json(200, "{\"assistantOf\":null}")
        }
        if assistantOwnerRaw(agentId) == userId {
            return Self.json(200, "{\"assistantOf\":{\"userId\":\(jsonString(userId))}}")
        }
        lock.lock()
        let conflict = assistantOwners.contains { candidate, owner in
            guard owner == userId, candidate != agentId else { return false }
            guard let other = oauth.agentRuntimeInfo(id: candidate) else { return false }
            return other.serverId == serverId && !other.deleted
        }
        lock.unlock()
        guard !conflict else {
            return Self.json(409, "{\"code\":\"assistant_already_set\",\"error\":\"This user already has an assistant\"}")
        }
        guard !assistantIsInRegularChannel(serverId: serverId, agentId: agentId) else {
            return Self.json(409, "{\"code\":\"assistant_has_channels\",\"error\":\"An assistant can only be in its DM with its owner\"}")
        }
        lock.lock()
        let existingDM = actionCardPrepare.dmChannelId(serverId: serverId, agentId: agentId, peerId: userId)
        lock.unlock()
        let dmId = existingDM ?? oauth.createDirectChannel(serverId: serverId, firstUserId: agentId, secondUserId: userId)
        addPostableChannel(serverId: serverId, channelId: dmId, memberId: agentId, kind: "dm", name: "dm")
        addPostableChannel(serverId: serverId, channelId: dmId, memberId: userId, kind: "dm", name: "dm")
        oauth.addChannelHuman(channelId: dmId, userId: userId)
        lock.lock()
        assistantOwners[agentId] = userId
        lock.unlock()
        return Self.json(200, "{\"assistantOf\":{\"userId\":\(jsonString(userId))}}")
    }

    func assistantReadRefusal() -> HTTPReply {
        Self.json(403, "{\"code\":\"assistant_not_enabled\",\"error\":\"Assistant ownership is not enabled for this agent\"}")
    }

    func assistantReadOwner(_ authorization: String?) -> (agentId: String, serverId: String, ownerId: String)? {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              let owner = assistantOwnerFor(agentId: agent.id, serverId: agent.serverId)
        else { return nil }
        return (agent.id, agent.serverId, owner)
    }

    func ownerCanSeeChannelLocked(ownerId: String, channel: PostableChannel) -> Bool {
        if channel.kind == "channel" || channel.kind == "joint" { return true }
        return channel.memberIds.contains(ownerId)
    }

    public func agentAssistantOwnerInbox(authorization: String?, rawQuery: String?) -> HTTPReply {
        guard let context = assistantReadOwner(authorization) else { return assistantReadRefusal() }
        var limit = 50
        for pair in (rawQuery ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "limit", let value = Int(parts[1]), value > 0 {
                limit = min(value, 100)
            }
        }
        lock.lock()
        var items: [String] = []
        for (id, channel) in postableChannels {
            guard channel.serverId == context.serverId, channel.deletedAt == nil else { continue }
            guard ownerCanSeeChannelLocked(ownerId: context.ownerId, channel: channel) else { continue }
            var kind = "channel"
            var parentChannelId: String?
            if channel.kind == "thread" {
                guard let parentId = channel.parentChannelId,
                      let parent = postableChannels[parentId],
                      parent.kind != "dm",
                      ownerCanSeeChannelLocked(ownerId: context.ownerId, channel: parent)
                else { continue }
                kind = "thread"
                parentChannelId = parentId
            } else if channel.kind == "dm" {
                continue
            } else if channel.kind != "channel" && channel.kind != "private" && channel.kind != "joint" {
                continue
            }
            let cursor = oauth.channelReadCursor(channelId: id, userId: context.ownerId)
            let messages = humanMessageRows.filter { message in
                message.channelId == id && message.seq > cursor
            }
            let unread = messages.filter { $0.senderId != context.ownerId }.count
            guard unread > 0 else { continue }
            var item = "{\"kind\":\(jsonString(kind)),\"channelId\":\(jsonString(id)),\"unreadCount\":\(unread)"
            if let parentChannelId {
                item += ",\"parentChannelId\":\(jsonString(parentChannelId))"
            }
            item += "}"
            items.append(item)
            if items.count >= limit { break }
        }
        lock.unlock()
        return Self.json(200, "{\"owner\":{\"userId\":\(jsonString(context.ownerId))},\"items\":[\(items.joined(separator: ","))]}")
    }

    public func agentAssistantOwnerMessages(authorization: String?, channelId: String) -> HTTPReply {
        guard let context = assistantReadOwner(authorization) else { return assistantReadRefusal() }
        let neutral = Self.json(404, "{\"error\":\"Channel not found or not visible\",\"code\":\"channel_not_found\"}")
        lock.lock()
        guard let channel = postableChannels[channelId], channel.serverId == context.serverId,
              channel.deletedAt == nil
        else {
            lock.unlock()
            return neutral
        }
        if channel.kind == "dm" { lock.unlock(); return neutral }
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId,
                  let parent = postableChannels[parentId], parent.kind != "dm",
                  ownerCanSeeChannelLocked(ownerId: context.ownerId, channel: parent)
            else {
                lock.unlock()
                return neutral
            }
        } else if !ownerCanSeeChannelLocked(ownerId: context.ownerId, channel: channel) {
            lock.unlock()
            return neutral
        }
        let messages = humanMessageRows.filter { $0.channelId == channelId }.map { message in
            "{\"id\":\(jsonString(message.id)),\"content\":\(jsonString(message.content)),\"senderId\":\(jsonString(message.senderId)),\"senderType\":\(jsonString(message.senderType))}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"owner\":{\"userId\":\(jsonString(context.ownerId))},\"channelId\":\(jsonString(channelId)),\"messages\":[\(messages)]}")
    }

    public func putAgentPushWebhook(authorization: String?, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawURL = object["url"] as? String,
              let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let secret = object["secret"] as? String, !secret.isEmpty
        else {
            return Self.json(400, "{\"error\":\"url and secret are required\"}")
        }
        lock.lock()
        externalPushWebhooks[credential.agentId] = (url: rawURL, secret: secret)
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

}
