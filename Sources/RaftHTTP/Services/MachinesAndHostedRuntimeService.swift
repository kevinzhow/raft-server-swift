import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Machine registration surfaces and the hosted runtime: onboarding
/// identity adoption, hosted usage/runtime/model state, provisioning retry
/// and provider connections.
///
/// These handlers were lifted from `EmailLogin+MachinesAndRuntime1.swift`.

public struct MachinesAndHostedRuntimeService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    public func machineAPIKey(machineId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return machines.first { $0.id == machineId }?.apiKey
    }

    public func bumpMachineStatusVersion(machineId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (machineStatusVersions[machineId] ?? 0) + 1
        machineStatusVersions[machineId] = next
        return next
    }

    public func setMachineOnline(machineId: String, online: Bool) {
        lock.lock()
        machineOnline[machineId] = online
        lock.unlock()
    }

    func onboardingAdoptionState(
        serverId: String,
        agentId: String
    ) -> (agent: OAuthLedger.AgentRuntimeInfo, role: String, changes: [OnboardingAdoptionChange])? {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return nil
        }
        let role = oauth.agentRole(serverId: serverId, agentId: agentId) ?? "member"
        var changes: [OnboardingAdoptionChange] = []
        if agent.name != "Cindy" {
            changes.append(OnboardingAdoptionChange(field: "name", before: agent.name, after: "Cindy"))
        }
        if agent.displayName != "Cindy" {
            changes.append(OnboardingAdoptionChange(field: "displayName", before: agent.displayName, after: "Cindy"))
        }
        if agent.description != "Onboarding Assistant" {
            changes.append(OnboardingAdoptionChange(field: "role", before: agent.description, after: "Onboarding Assistant"))
        }
        if role != "admin" {
            changes.append(OnboardingAdoptionChange(field: "serverRole", before: role, after: "admin"))
        }
        if agent.avatarUrl != "pixel:mug" {
            changes.append(OnboardingAdoptionChange(field: "avatarUrl", before: agent.avatarUrl, after: "pixel:mug"))
        }
        return (agent, role, changes)
    }

    func onboardingAdoptionJSON(
        canAdopt: Bool,
        changes: [OnboardingAdoptionChange],
        appliedChanges: [OnboardingAdoptionChange]? = nil,
        agent: OAuthLedger.AgentRuntimeInfo? = nil,
        role: String? = nil
    ) -> String {
        func changesJSON(_ values: [OnboardingAdoptionChange]) -> String {
            values.map { change in
                let before = change.before.map(jsonString) ?? "null"
                let after = change.after.map(jsonString) ?? "null"
                return "{\"field\":\(jsonString(change.field)),\"before\":\(before),\"after\":\(after)}"
            }.joined(separator: ",")
        }
        var body = "{\"canAdopt\":\(canAdopt),\"changes\":[\(changesJSON(changes))]"
        if let appliedChanges {
            body += ",\"appliedChanges\":[\(changesJSON(appliedChanges))]"
        }
        if let agent {
            let description = agent.description.map(jsonString) ?? "null"
            let avatar = agent.avatarUrl.map(jsonString) ?? "null"
            body += ",\"agent\":{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"description\":\(description),\"avatarUrl\":\(avatar),\"serverRole\":\(jsonString(role ?? "member"))}"
        }
        return body + "}"
    }

    public func onboardingIdentityAdoption(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let state = onboardingAdoptionState(serverId: serverId, agentId: agentId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || state.agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to edit agents\"}")
        }
        lock.lock()
        let onboardingAgentId = serverOnboardingSettings[serverId]?.agentId
        lock.unlock()
        guard onboardingAgentId == agentId else {
            return Self.json(400, "{\"error\":\"Agent is not this server's onboarding agent\"}")
        }
        return Self.json(200, onboardingAdoptionJSON(canAdopt: !state.changes.isEmpty, changes: state.changes))
    }

    public func adoptOnboardingIdentity(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let state = onboardingAdoptionState(serverId: serverId, agentId: agentId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || state.agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to edit agents\"}")
        }
        lock.lock()
        let onboardingAgentId = serverOnboardingSettings[serverId]?.agentId
        lock.unlock()
        guard onboardingAgentId == agentId else {
            return Self.json(400, "{\"error\":\"Agent is not this server's onboarding agent\"}")
        }
        let changes = state.changes
        guard !changes.isEmpty else {
            return Self.json(200, onboardingAdoptionJSON(
                canAdopt: false,
                changes: [],
                appliedChanges: [],
                agent: state.agent,
                role: state.role
            ))
        }
        if oauth.serverAgents(serverId: serverId).contains(where: { $0.id != agentId && $0.name == "Cindy" }) {
            return Self.json(409, "{\"error\":\"Agent name is already taken\"}")
        }
        oauth.adoptAgentIdentity(
            serverId: serverId,
            agentId: agentId,
            name: "Cindy",
            displayName: "Cindy",
            description: "Onboarding Assistant",
            avatarUrl: "pixel:mug",
            role: "admin"
        )
        emitRealtime("server:\(serverId)", "agent:updated", "{\"agentId\":\(jsonString(agentId))}")
        let updated = oauth.agentRuntimeInfo(id: agentId) ?? state.agent
        return Self.json(200, onboardingAdoptionJSON(
            canAdopt: false,
            changes: [],
            appliedChanges: changes,
            agent: updated,
            role: "admin"
        ))
    }

    public func agentHostedUsage(authorization: String?, serverId: String, agentId: String, query: String?) -> HTTPReply {
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
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to view cloud agent usage\"}")
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        let body = hostedUsage[agentId]
        lock.unlock()
        guard hosted != nil else {
            return Self.json(404, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"hosted_runtime_missing\"}")
        }
        var params: [String: String] = [:]
        for pair in (query ?? "").split(separator: "&") {
            let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(item[0]).removingPercentEncoding ?? String(item[0])
            let value = item.count == 2 ? (String(item[1]).removingPercentEncoding ?? String(item[1])) : ""
            params[name] = value
        }
        let bucket = params["bucket"] ?? "1d"
        guard ["1h", "1d"].contains(bucket) else {
            return Self.json(400, "{\"error\":\"Invalid usage query\",\"code\":\"hosted_runtime_usage_invalid_query\"}")
        }
        let now = Date()
        func parse(_ name: String) -> Date? {
            guard let raw = params[name], !raw.isEmpty else { return nil }
            return Self.isoDate(raw)
        }
        if params["from"] != nil, parse("from") == nil {
            return Self.json(400, "{\"error\":\"Invalid usage query\",\"code\":\"hosted_runtime_usage_invalid_query\"}")
        }
        if params["to"] != nil, parse("to") == nil {
            return Self.json(400, "{\"error\":\"Invalid usage query\",\"code\":\"hosted_runtime_usage_invalid_query\"}")
        }
        let from = parse("from") ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        let to = parse("to") ?? now
        guard to >= from, to.timeIntervalSince(from) <= 31 * 24 * 60 * 60 else {
            return Self.json(400, "{\"error\":\"Invalid usage query\",\"code\":\"hosted_runtime_usage_invalid_query\"}")
        }
        guard let body else {
            return Self.json(409, "{\"error\":\"The cloud runtime is not ready\",\"code\":\"hosted_runtime_usage_not_ready\"}")
        }
        return Self.json(200, body)
    }

    public func agentHostedRuntime(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
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
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to view cloud agent status\"}")
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        lock.unlock()
        guard let hosted else {
            return Self.json(404, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"hosted_runtime_missing\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let model = hosted.model.map(jsonString) ?? "null"
        return Self.json(200, "{\"hostedRuntime\":{\"agentId\":\(jsonString(agentId)),\"provider\":\(jsonString(hosted.provider)),\"model\":\(model),\"state\":\(jsonString(hosted.state)),\"retryNeedsModel\":\(hosted.retryNeedsModel),\"createdAt\":\(jsonString(formatter.string(from: hosted.createdAt)))},\"onboardingSetup\":null}")
    }

    public func enableHostedModelPicker(serverId: String) {
        lock.lock()
        hostedModelPickerServers.insert(serverId)
        lock.unlock()
    }

    public func retryAgentProvisioning(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: String
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
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to retry provisioning\"}")
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        lock.unlock()
        guard let hosted else {
            return Self.json(404, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"hosted_runtime_missing\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        var modelProvided = false
        var providedModel: String?
        if let raw = object?["model"] {
            modelProvided = true
            if raw is NSNull {
                providedModel = nil
            } else if let value = raw as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.count <= 200 {
                providedModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return Self.json(400, "{\"error\":\"`model` must be a model id or null\",\"code\":\"hosted_runtime_model_invalid\"}")
            }
        }
        if modelProvided, hosted.retryNeedsModel {
            lock.lock()
            let picker = hostedModelPickerServers.contains(serverId)
            let state = hostedModels[agentId]
            lock.unlock()
            if let providedModel, providedModel != Self.hostedDefaultModel, !picker {
                return Self.json(403, "{\"error\":\"This server does not pick a cloud agent model\",\"code\":\"model_picker_disabled\"}")
            }
            let picked = providedModel == Self.hostedDefaultModel && !picker ? nil : providedModel
            if let picked {
                if state?.locked == true {
                    return Self.json(409, "{\"error\":\"An administrator has set this agent's model\",\"code\":\"hosted_runtime_model_locked\"}")
                }
                guard state?.models.contains(where: { $0.id == picked }) == true else {
                    return Self.json(422, "{\"error\":\"The provider does not offer this model\",\"code\":\"hosted_runtime_model_not_offered\"}")
                }
            }
        }
        switch hosted.state {
        case "failed":
            if hosted.retryNeedsModel, !modelProvided {
                return Self.json(409, "{\"error\":\"The provider refused the picked model; retry with `model` set to an offered id, or null for the default\",\"code\":\"hosted_runtime_model_required\"}")
            }
        case "provisioning", "deleting":
            break
        default:
            return Self.json(409, "{\"error\":\"Nothing to retry\",\"code\":\"hosted_runtime_nothing_to_retry\"}")
        }
        lock.lock()
        hostedRuntimes[agentId] = (hosted.provider, hosted.model, "provisioning", false, hosted.createdAt)
        if modelProvided, var state = hostedModels[agentId] {
            let picked = providedModel == Self.hostedDefaultModel && hostedModelPickerServers.contains(serverId) == false ? nil : providedModel
            if let picked, let option = state.models.first(where: { $0.id == picked }) {
                state.model = option.id
                state.label = option.label
                state.source = "chosen"
            } else if picked == nil {
                state.model = state.defaultModel
                state.label = state.defaultLabel
                state.source = "default"
            }
            hostedModels[agentId] = state
        }
        let updated = hostedRuntimes[agentId]!
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let modelJSON = updated.model.map(jsonString) ?? "null"
        return Self.json(200, "{\"hostedRuntime\":{\"agentId\":\(jsonString(agentId)),\"provider\":\(jsonString(updated.provider)),\"model\":\(modelJSON),\"state\":\(jsonString(updated.state)),\"retryNeedsModel\":\(updated.retryNeedsModel),\"createdAt\":\(jsonString(formatter.string(from: updated.createdAt)))}}")
    }

    /// Shared guard for the hosted model reads and writes: agent membership,
    /// owner/admin/creator authority, an existing hosted runtime, and an
    /// active provision. Returns the agent id or the reply to send.

    func hostedModelGuard(
        authorization: String?,
        serverId: String,
        agentId: String,
        action: String
    ) -> HostedModelGuardResult {
        guard let userId = sessionUserId(authorization: authorization) else {
            return .refused(Self.json(401, "{\"error\":\"Unauthorized\"}"))
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return .refused(Self.json(404, "{\"error\":\"Agent not found\"}"))
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || agent.creatorUserId == userId
        else {
            return .refused(Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to \(action) a cloud agent's model\"}"))
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        let models = hostedModels[agentId]
        lock.unlock()
        guard let hosted else {
            return .refused(Self.json(404, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"hosted_runtime_missing\"}"))
        }
        guard hosted.state == "active", models != nil else {
            return .refused(Self.json(409, "{\"error\":\"The cloud runtime is not ready\",\"code\":\"hosted_runtime_model_not_ready\"}"))
        }
        return .allowed(agentId)
    }

    func hostedModelView(_ state: HostedModelState, picker: Bool) -> String {
        let models = state.models.map { model in
            "{\"id\":\(jsonString(model.id)),\"label\":\(jsonString(model.label)),\"provider\":\(jsonString(model.provider))}"
        }.joined(separator: ",")
        let defaultModel = state.defaultModel.map(jsonString) ?? "null"
        let defaultLabel = state.defaultLabel.map(jsonString) ?? "null"
        let model = state.model.map(jsonString) ?? "null"
        let label = state.label.map(jsonString) ?? "null"
        return "{\"models\":[\(models)],\"default\":\(defaultModel),\"defaultLabel\":\(defaultLabel),\"model\":\(model),\"label\":\(label),\"source\":\(jsonString(state.source)),\"locked\":\(state.locked),\"picker\":\(picker)}"
    }

    public func agentHostedModel(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        switch hostedModelGuard(authorization: authorization, serverId: serverId, agentId: agentId, action: "view") {
        case .refused(let reply):
            return reply
        case .allowed(let id):
            lock.lock()
            let state = hostedModels[id]
            let picker = hostedModelPickerServers.contains(serverId)
            lock.unlock()
            guard let state else {
                return Self.json(409, "{\"error\":\"The cloud runtime is not ready\",\"code\":\"hosted_runtime_model_not_ready\"}")
            }
            return Self.json(200, hostedModelView(state, picker: picker))
        }
    }

    public func setAgentHostedModel(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: String
    ) -> HTTPReply {
        switch hostedModelGuard(authorization: authorization, serverId: serverId, agentId: agentId, action: "change") {
        case .refused(let reply):
            return reply
        case .allowed(let id):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let raw = object?["model"] else {
                return Self.json(400, "{\"error\":\"`model` must be a model id or null\",\"code\":\"hosted_runtime_model_invalid\"}")
            }
            let requested: String?
            if raw is NSNull {
                requested = nil
            } else if let value = raw as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.count <= 200 {
                requested = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return Self.json(400, "{\"error\":\"`model` must be a model id or null\",\"code\":\"hosted_runtime_model_invalid\"}")
            }
            lock.lock()
            let picker = hostedModelPickerServers.contains(serverId)
            lock.unlock()
            if let requested, requested != Self.hostedDefaultModel, !picker {
                return Self.json(403, "{\"error\":\"This server does not pick a cloud agent model\",\"code\":\"model_picker_disabled\"}")
            }
            let picked: String?
            if let requested, requested == Self.hostedDefaultModel, !picker {
                picked = nil
            } else {
                picked = requested
            }
            lock.lock()
            guard var state = hostedModels[id] else {
                lock.unlock()
                return Self.json(409, "{\"error\":\"The cloud runtime is not ready\",\"code\":\"hosted_runtime_model_not_ready\"}")
            }
            if let picked {
                if state.locked {
                    lock.unlock()
                    return Self.json(409, "{\"error\":\"An administrator has set this agent's model\",\"code\":\"hosted_runtime_model_locked\"}")
                }
                guard let option = state.models.first(where: { $0.id == picked }) else {
                    lock.unlock()
                    return Self.json(422, "{\"error\":\"The provider does not offer this model\",\"code\":\"hosted_runtime_model_not_offered\"}")
                }
                state.model = option.id
                state.label = option.label
                state.source = "chosen"
            } else {
                state.model = state.defaultModel
                state.label = state.defaultLabel
                state.source = "default"
            }
            hostedModels[id] = state
            lock.unlock()
            return Self.json(200, hostedModelView(state, picker: picker))
        }
    }

    func agentConnectionProviderCall(
        method: String,
        action: String,
        provider: String,
        agentId: String,
        body: String? = nil
    ) -> AgentConnectionProviderResult {
        let relay = agentConnectionProvider
        guard let relay else { return .unavailable }
        return relay(AgentConnectionProviderRequest(
            method: method,
            action: action,
            provider: provider,
            agentId: agentId,
            body: body
        ))
    }

    func loadAgentForConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) -> AgentConnectionLoadResult {
        guard let userId = sessionUserId(authorization: authorization) else {
            return .refused(Self.json(401, "{\"error\":\"Unauthorized\"}"))
        }
        guard Self.agentConnectionProviders.contains(provider) else {
            return .refused(Self.json(404, "{\"error\":\"Unknown connection provider\",\"code\":\"agent_connection_provider_unknown\"}"))
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return .refused(Self.json(404, "{\"error\":\"Agent not found\"}"))
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role != "guest",
              role == "owner" || role == "admin" || agent.creatorUserId == userId
        else {
            return .refused(Self.json(403, "{\"error\":\"Only the agent's creator or a server owner/admin can manage its connections\",\"code\":\"agent_connection_forbidden\"}"))
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        lock.unlock()
        guard let hosted else {
            return .refused(Self.json(400, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"agent_connection_not_provider_backed\"}"))
        }
        guard hosted.state == "active" else {
            return .refused(Self.json(409, "{\"error\":\"The agent is not provisioned on its provider yet\",\"code\":\"agent_connection_agent_not_active\",\"state\":\(jsonString(hosted.state))}"))
        }
        return .loaded(agentId: agentId, userId: userId, role: role)
    }

    func connectionMemberIdentity(serverId: String, userId: String) -> (name: String, displayName: String)? {
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else { return nil }
        lock.lock()
        let account = accounts.values.first { $0.id == userId }
        lock.unlock()
        guard let account else { return nil }
        return (account.name, account.name)
    }

    func connectionUserJSON(serverId: String, userId: String) -> String {
        let identity = connectionMemberIdentity(serverId: serverId, userId: userId)
        let name = identity.map { jsonString($0.name) } ?? "null"
        let displayName = identity.map { jsonString($0.displayName) } ?? "null"
        return "{\"id\":\(jsonString(userId)),\"name\":\(name),\"displayName\":\(displayName)}"
    }

    func connectionStatusJSON(
        _ parsed: HostedConnectionStatusRecord,
        provider: String,
        serverId: String,
        userId: String,
        role: String
    ) -> String {
        let connectedBy: String
        if parsed.connected, let id = parsed.connectedBy {
            let identity = connectionMemberIdentity(serverId: serverId, userId: id)
            let name = identity.map { jsonString($0.displayName) } ?? "null"
            connectedBy = "{\"id\":\(jsonString(id)),\"name\":\(name)}"
        } else {
            connectedBy = "null"
        }
        let connectors = parsed.connectors.map { connector -> String in
            let creator: String
            if let creatorId = connector.creatorRaftUserId {
                creator = connectionUserJSON(serverId: serverId, userId: creatorId)
            } else {
                creator = "null"
            }
            let canManage = role == "owner" || role == "admin" || connector.creatorRaftUserId == userId
            let createdAt = connector.createdAt.map(jsonString) ?? "null"
            return "{\"id\":\(jsonString(connector.id)),\"account\":\(jsonString(connector.account)),\"createdAt\":\(createdAt),\"creator\":\(creator),\"current\":\(connector.current),\"canManage\":\(canManage)}"
        }.joined(separator: ",")
        let scopes = parsed.scopes.map { jsonString($0) }.joined(separator: ",")
        let account = parsed.connected ? (parsed.account.map(jsonString) ?? "null") : "null"
        let connectedAt = parsed.connected ? (parsed.connectedAt.map(jsonString) ?? "null") : "null"
        let connectorId = parsed.connectorId.map(jsonString) ?? "null"
        return "{\"provider\":\(jsonString(provider)),\"supported\":true,\"connected\":\(parsed.connected),\"account\":\(account),\"connectedAt\":\(connectedAt),\"connectedBy\":\(connectedBy),\"scopes\":[\(scopes)],\"connectorId\":\(connectorId),\"connectors\":[\(connectors)]}"
    }

    func redactProviderMessage(_ message: String?) -> String? {
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

    func agentConnectionProviderFailure(_ result: AgentConnectionProviderResult, thisServer: Bool = true) -> HTTPReply {
        switch result {
        case .unavailable:
            return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":null,\"providerMessage\":null,\"providerStatus\":null}")
        case .empty(let status):
            return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":null,\"providerMessage\":null,\"providerStatus\":\(status)}")
        case .response(let status, let body):
            let parts = Self.providerErrorParts(body)
            let message = redactProviderMessage(parts.message)
            if (400..<500).contains(status) {
                let error = message ?? "The provider refused the request"
                return Self.json(409, "{\"error\":\(jsonString(error)),\"code\":\"agent_connection_provider_refused\",\"providerCode\":\(parts.code.map(jsonString) ?? "null"),\"providerMessage\":\(message.map(jsonString) ?? "null"),\"providerStatus\":\(status)}")
            }
            return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":\(parts.code.map(jsonString) ?? "null"),\"providerMessage\":\(message.map(jsonString) ?? "null"),\"providerStatus\":\(status)}")
        }
    }

    /// A 404 from the provider may mean the connections route is missing
    /// (unsupported) or that the provider no longer knows the agent. Only the
    /// agent lookup can tell them apart.
    func agentConnection404Reply(
        provider: String,
        agentId: String,
        body: String,
        connectorScoped: Bool = false
    ) -> HTTPReply {
        let lookup = agentConnectionProviderCall(method: "GET", action: "agentLookup", provider: provider, agentId: agentId)
        switch lookup {
        case .response(let status, _) where (200..<300).contains(status):
            if connectorScoped {
                return Self.json(404, "{\"error\":\"That connection does not exist on this server\",\"code\":\"agent_connection_connector_not_found\"}")
            }
            return Self.json(409, "{\"error\":\"The provider does not support connections\",\"code\":\"agent_connection_unsupported\"}")
        case .response(let status, let lookupBody) where status == 404:
            return agentConnectionMissingReply(providerMessage: Self.providerErrorParts(lookupBody).message ?? Self.providerErrorParts(body).message)
        default:
            return agentConnectionProviderFailure(lookup)
        }
    }

    func agentConnectionMissingReply(providerMessage: String?) -> HTTPReply {
        let message = redactProviderMessage(providerMessage)
        return Self.json(409, "{\"error\":\"This agent no longer exists at its provider; connections are unavailable. Recreate the agent.\",\"code\":\"agent_connection_agent_missing_at_provider\",\"providerMessage\":\(message.map(jsonString) ?? "null")}")
    }

    func agentConnectionStatus404Reply(provider: String, agentId: String) -> HTTPReply {
        let lookup = agentConnectionProviderCall(method: "GET", action: "agentLookup", provider: provider, agentId: agentId)
        switch lookup {
        case .response(let status, _) where (200..<300).contains(status):
            return Self.json(200, "{\"provider\":\(jsonString(provider)),\"supported\":false}")
        case .response(let status, let lookupBody) where status == 404:
            return agentConnectionMissingReply(providerMessage: Self.providerErrorParts(lookupBody).message)
        default:
            return agentConnectionProviderFailure(lookup)
        }
    }

    func pendingInvalidReply(providerCode: String? = nil, message: String? = nil) -> HTTPReply {
        Self.json(404, "{\"error\":\"The connection link expired or is invalid; start again\",\"code\":\"agent_connection_pending_invalid\",\"providerCode\":\(providerCode.map(jsonString) ?? "null"),\"providerMessage\":\(redactProviderMessage(message).map(jsonString) ?? "null")}")
    }

    func agentConnectionStatusFailure(_ result: AgentConnectionProviderResult, provider: String, agentId: String, serverId: String, userId: String, role: String) -> HTTPReply {
        switch result {
        case .response(let status, let body) where (200..<300).contains(status):
            guard let parsed = Self.parseConnectionStatus(body) else {
                return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":\"invalid_response\",\"providerMessage\":null,\"providerStatus\":\(status)}")
            }
            return Self.json(200, connectionStatusJSON(parsed, provider: provider, serverId: serverId, userId: userId, role: role))
        case .response(let status, _) where status == 404:
            return agentConnectionStatus404Reply(provider: provider, agentId: agentId)
        default:
            return agentConnectionProviderFailure(result)
        }
    }

    public func agentConnectionStatus(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, let role):
            let result = agentConnectionProviderCall(method: "GET", action: "status", provider: provider, agentId: agentId)
            return agentConnectionStatusFailure(result, provider: provider, agentId: agentId, serverId: serverId, userId: userId, role: role)
        }
    }

    public func startAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, _):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let rawAccess = object?["access"]
            let access: String?
            if rawAccess == nil || rawAccess is NSNull {
                access = nil
            } else if let value = rawAccess as? String, value == "private" {
                access = "private"
            } else {
                return Self.json(400, "{\"error\":\"access must be \\\"private\\\" when present\",\"code\":\"agent_connection_invalid\"}")
            }
            lock.lock()
            let origin = agentConnectionOrigin
            lock.unlock()
            var bodyJSON = "{\"returnUrl\":\(jsonString("\(origin)/api/connections/callback/\(serverId)/\(agentId)")),\"initiatedBy\":{\"raftUserId\":\(jsonString(userId))}"
            if let access {
                bodyJSON += ",\"access\":\(jsonString(access))"
            }
            bodyJSON += "}"
            let result = agentConnectionProviderCall(method: "POST", action: "start", provider: provider, agentId: agentId, body: bodyJSON)
            switch result {
            case .response(let status, let responseBody) where (200..<300).contains(status):
                guard let parsed = (try? JSONSerialization.jsonObject(with: Data(responseBody.utf8))) as? [String: Any],
                      let url = parsed["url"] as? String,
                      let parsedURL = URL(string: url),
                      parsedURL.scheme == "http" || parsedURL.scheme == "https"
                else {
                    return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":\"invalid_connection_url\",\"providerMessage\":null,\"providerStatus\":\(status)}")
                }
                let expiresAt = (parsed["expiresAt"] as? String).map(jsonString) ?? "\"\""
                let scopes = ((parsed["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []).map(jsonString).joined(separator: ",")
                return Self.json(200, "{\"url\":\(jsonString(parsedURL.absoluteString)),\"expiresAt\":\(expiresAt),\"scopes\":[\(scopes)]}")
            case .response(let status, let responseBody) where status == 404:
                return agentConnection404Reply(provider: provider, agentId: agentId, body: responseBody)
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func confirmAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, let role):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let pending = object?["pending"] as? String, !pending.isEmpty else {
                return Self.json(400, "{\"error\":\"pending is required\",\"code\":\"agent_connection_invalid\"}")
            }
            guard Self.isAgentConnectionIdentifier(pending) else {
                return pendingInvalidReply()
            }
            let requestBody = "{\"pending\":\(jsonString(pending)),\"raftUserId\":\(jsonString(userId))}"
            let result = agentConnectionProviderCall(method: "POST", action: "confirm", provider: provider, agentId: agentId, body: requestBody)
            switch result {
            case .response(let status, let responseBody) where (200..<300).contains(status):
                guard let parsed = Self.parseConnectionStatus(responseBody) else {
                    return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":\"invalid_response\",\"providerMessage\":null,\"providerStatus\":\(status)}")
                }
                return Self.json(200, connectionStatusJSON(parsed, provider: provider, serverId: serverId, userId: userId, role: role))
            case .response(let status, let responseBody) where status == 404:
                let parts = Self.providerErrorParts(responseBody)
                return pendingInvalidReply(providerCode: parts.code, message: parts.message)
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func assignAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, let role):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let connectorId = object?["connectorId"] as? String, Self.isAgentConnectionIdentifier(connectorId) else {
                return Self.json(400, "{\"error\":\"connectorId is required\",\"code\":\"agent_connection_invalid\"}")
            }
            let statusResult = agentConnectionProviderCall(method: "GET", action: "status", provider: provider, agentId: agentId)
            guard case .response(let statusCode, let statusBody) = statusResult,
                  (200..<300).contains(statusCode)
            else {
                if case .response(404, let body) = statusResult {
                    return agentConnection404Reply(provider: provider, agentId: agentId, body: body)
                }
                return agentConnectionProviderFailure(statusResult)
            }
            guard let parsed = Self.parseConnectionStatus(statusBody),
                  let connector = parsed.connectors.first(where: { $0.id == connectorId })
            else {
                return Self.json(404, "{\"error\":\"That connection does not exist on this server\",\"code\":\"agent_connection_connector_not_found\"}")
            }
            let isManager = role == "owner" || role == "admin"
            guard isManager || connector.creatorRaftUserId == userId else {
                return Self.json(403, "{\"error\":\"Only the connection's creator or a server admin can assign or disconnect it\",\"code\":\"agent_connection_connector_forbidden\"}")
            }
            let actingRole = connector.creatorRaftUserId == userId ? "creator" : "admin"
            let requestBody = "{\"connectorId\":\(jsonString(connectorId)),\"actingRaftUserId\":\(jsonString(userId)),\"actingRole\":\(jsonString(actingRole))}"
            let result = agentConnectionProviderCall(method: "PUT", action: "assign", provider: provider, agentId: agentId, body: requestBody)
            switch result {
            case .response(let status, _) where (200..<300).contains(status):
                let refreshed = agentConnectionProviderCall(method: "GET", action: "status", provider: provider, agentId: agentId)
                return agentConnectionStatusFailure(refreshed, provider: provider, agentId: agentId, serverId: serverId, userId: userId, role: role)
            case .response(let status, let responseBody) where status == 404:
                return agentConnection404Reply(provider: provider, agentId: agentId, body: responseBody, connectorScoped: true)
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func disconnectAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded:
            let result = agentConnectionProviderCall(method: "DELETE", action: "disconnect", provider: provider, agentId: agentId)
            switch result {
            case .response(let status, let responseBody) where status == 404:
                return agentConnection404Reply(provider: provider, agentId: agentId, body: responseBody)
            case .response(let status, _) where (200..<300).contains(status):
                return Self.json(204, "")
            case .empty(let status) where (200..<300).contains(status):
                return Self.json(204, "")
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func disconnectAgentConnector(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        connectorId: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, let role):
            guard Self.isAgentConnectionIdentifier(connectorId) else {
                return Self.json(400, "{\"error\":\"connectorId is required\",\"code\":\"agent_connection_invalid\"}")
            }
            let statusResult = agentConnectionProviderCall(method: "GET", action: "status", provider: provider, agentId: agentId)
            guard case .response(let statusCode, let statusBody) = statusResult,
                  (200..<300).contains(statusCode)
            else {
                if case .response(404, let body) = statusResult {
                    return agentConnection404Reply(provider: provider, agentId: agentId, body: body)
                }
                return agentConnectionProviderFailure(statusResult)
            }
            guard let parsed = Self.parseConnectionStatus(statusBody),
                  let connector = parsed.connectors.first(where: { $0.id == connectorId })
            else {
                return Self.json(404, "{\"error\":\"That connection does not exist on this server\",\"code\":\"agent_connection_connector_not_found\"}")
            }
            let isManager = role == "owner" || role == "admin"
            guard isManager || connector.creatorRaftUserId == userId else {
                return Self.json(403, "{\"error\":\"Only the connection's creator or a server admin can assign or disconnect it\",\"code\":\"agent_connection_connector_forbidden\"}")
            }
            let actingRole = connector.creatorRaftUserId == userId ? "creator" : "admin"
            let requestBody = "{\"actingRaftUserId\":\(jsonString(userId)),\"actingRole\":\(jsonString(actingRole))}"
            let result = agentConnectionProviderCall(method: "DELETE", action: "disconnectConnector", provider: provider, agentId: agentId, body: requestBody)
            switch result {
            case .response(let status, let responseBody) where status == 502:
                let failed = (try? JSONSerialization.jsonObject(with: Data(responseBody.utf8))) as? [String: Any]
                let failedCount = (failed?["failed"] as? [Any])?.count ?? 0
                return Self.json(502, "{\"error\":\"Disconnect partially completed; retry to finish\",\"code\":\"agent_connection_connector_disconnect_partial\",\"failedCount\":\(failedCount)}")
            case .response(let status, let responseBody) where status == 404:
                return agentConnection404Reply(provider: provider, agentId: agentId, body: responseBody, connectorScoped: true)
            case .response(let status, _) where (200..<300).contains(status):
                return Self.json(204, "")
            case .empty(let status) where (200..<300).contains(status):
                return Self.json(204, "")
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

}
