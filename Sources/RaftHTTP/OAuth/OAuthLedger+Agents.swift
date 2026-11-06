import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public func createAgent(
        serverId: String,
        name: String,
        displayName: String? = nil,
        avatarUrl: String? = nil,
        description: String? = nil,
        creatorUserId: String? = nil,
        runtime: String = "managed",
        runtimeConfigJSON: String? = nil,
        envVarsJSON: String? = nil
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        agents[id] = Agent(
            id: id,
            serverId: serverId,
            name: name,
            displayName: displayName ?? name,
            avatarUrl: avatarUrl,
            description: description,
            creatorUserId: creatorUserId,
            runtime: runtime,
            runtimeConfigJSON: runtimeConfigJSON,
            envVarsJSON: envVarsJSON
        )
        agentRoles["\(serverId)\n\(id)"] = "member"
        lock.unlock()
        return id
    }

    @discardableResult
    public func setAgentCreator(id: String, creatorUserId: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = agents.keys.first(where: { $0 == id }) else { return false }
        agents[key]?.creatorUserId = creatorUserId
        return true
    }

    public func setAgentRuntime(id: String, runtime: String) {
        lock.lock()
        agents[id]?.runtime = runtime
        lock.unlock()
    }

    public struct AgentAudienceClient: Sendable {
        public var id: String
        public var clientId: String
        public var name: String
        public var appType: String
        public var enabled: Bool
        public var allowedScopes: [String]
    }

    /// A user-managed App this Server may mint an audience JWT for. A published
    /// App needs an active installation on this Server; a server-local App
    /// needs to belong to it.
    public func localClientForAgentAudience(clientId: String, serverId: String) -> AgentAudienceClient? {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { candidate in
            guard candidate.clientId == clientId, isUserManaged(candidate) else { return false }
            if candidate.appType == "server_local" { return candidate.serverId == serverId }
            return installations.contains(where: {
                $0.clientId == candidate.id && $0.serverId == serverId && $0.status == "active"
            })
        }) else { return nil }
        return AgentAudienceClient(
            id: client.id,
            clientId: client.clientId,
            name: client.name,
            appType: client.appType,
            enabled: client.enabled,
            allowedScopes: client.allowedScopes ?? []
        )
    }

    /// The App row as the legacy Agent JWT settings route reads it.
    public struct LegacyAgentJWTClient: Sendable {
        public var id: String
        public var clientKey: String
        public var serverId: String
        public var appType: String
        public var enabled: Bool
        public var allowedScopes: [String]
        public var installationStatus: String?
    }

    public func legacyAgentJWTClient(clientRecordId: String) -> LegacyAgentJWTClient? {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { $0.id == clientRecordId && isUserManaged($0) }) else {
            return nil
        }
        let installation = installations.first { $0.clientId == client.id }
        return LegacyAgentJWTClient(
            id: client.id,
            clientKey: client.clientId,
            serverId: client.serverId,
            appType: client.appType,
            enabled: client.enabled,
            allowedScopes: client.allowedScopes ?? [],
            installationStatus: installation?.status
        )
    }

    public func legacyAgentJWTInstallationStatus(clientRecordId: String, serverId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return installations.first { $0.clientId == clientRecordId && $0.serverId == serverId }?.status
    }

    public func clientAgentJWTEnabled(clientRecordId: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return clients.first { $0.id == clientRecordId }?.agentJwtEnabled
    }

    public func installationAgentJWTEnabled(clientRecordId: String, serverId: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return installations.first { $0.clientId == clientRecordId && $0.serverId == serverId }?.agentJwtEnabled
    }

    public func signAgentAudienceToken(
        agentId: String,
        agentName: String,
        clientKey: String,
        serverId: String,
        serverSlug: String,
        issuer: String
    ) -> (token: String, jti: String, issuedAt: Int)? {
        lock.lock()
        let secret = jwtSecret
        lock.unlock()
        return OAuthIDToken.signAgentAudience(
            agentId: agentId,
            agentName: agentName,
            clientKey: clientKey,
            serverId: serverId,
            serverSlug: serverSlug,
            issuer: issuer,
            secret: secret
        )
    }

    public func setAgentRole(serverId: String, agentId: String, role: String) {
        lock.lock()
        agentRoles["\(serverId)\n\(agentId)"] = role
        lock.unlock()
    }

    @discardableResult
    public func adoptAgentIdentity(
        serverId: String,
        agentId: String,
        name: String,
        displayName: String,
        description: String?,
        avatarUrl: String?,
        role: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = agents.keys.first(where: { $0 == agentId }), agents[key]?.serverId == serverId else {
            return false
        }
        agents[key]?.name = name
        agents[key]?.displayName = displayName
        agents[key]?.description = description
        agents[key]?.avatarUrl = avatarUrl
        agentRoles["\(serverId)\n\(agentId)"] = role
        return true
    }

    public func agentRole(serverId: String, agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return agentRoles["\(serverId)\n\(agentId)"]
    }

    public func removeAgentMember(serverId: String, agentId: String) {
        lock.lock()
        agentRoles.removeValue(forKey: "\(serverId)\n\(agentId)")
        lock.unlock()
    }

    public struct ProviderAgentInfo: Sendable {
        public var name: String
        public var displayName: String
        public var runtime: String
        public var status: String
        public var deleted: Bool
    }

    public func providerAgentInfo(serverId: String, agentId: String) -> ProviderAgentInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let agent = agents[agentId], agent.serverId == serverId else { return nil }
        return ProviderAgentInfo(
            name: agent.name,
            displayName: agent.displayName,
            runtime: "builtin",
            status: "inactive",
            deleted: agent.deleted
        )
    }

    public struct AgentManagementInfo: Sendable {
        public var id: String
        public var serverId: String
        public var name: String
        public var description: String?
        public var creatorUserId: String?
        public var runtime: String
        public var runtimeConfigJSON: String?
        public var envVarsJSON: String?
        public var deleted: Bool
    }

    public struct ManageableAgent: Sendable {
        public var id: String
        public var name: String
        public var serverId: String
        public var serverName: String?
    }

    public func manageableAgents(userId: String) -> (agents: [ManageableAgent], serverCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        var rows: [ManageableAgent] = []
        var contributingServers = Set<String>()
        for key in members.keys {
            let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] == userId, let server = servers[parts[0]], !server.deleted else { continue }
            let role = members[key] ?? ""
            let serverAgents = agents.values.filter { $0.serverId == server.id && !$0.deleted }
            let visible: [Agent]
            if role == "owner" || role == "admin" {
                visible = serverAgents
            } else {
                visible = serverAgents.filter { $0.creatorUserId == userId }
            }
            if role == "owner" || role == "admin" || !visible.isEmpty {
                contributingServers.insert(server.id)
            }
            for agent in visible {
                rows.append(ManageableAgent(
                    id: agent.id,
                    name: agent.name,
                    serverId: server.id,
                    serverName: server.name
                ))
            }
        }
        return (rows, contributingServers.count)
    }

    public func agentManagementInfo(id: String) -> AgentManagementInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let agent = agents[id] else { return nil }
        return AgentManagementInfo(
            id: agent.id,
            serverId: agent.serverId,
            name: agent.name,
            description: agent.description,
            creatorUserId: agent.creatorUserId,
            runtime: agent.runtime,
            runtimeConfigJSON: agent.runtimeConfigJSON,
            envVarsJSON: agent.envVarsJSON,
            deleted: agent.deleted
        )
    }

    public struct AgentRuntimeInfo: Sendable {
        public var id: String
        public var serverId: String
        public var name: String
        public var displayName: String
        public var description: String?
        public var avatarUrl: String?
        public var creatorUserId: String?
        public var runtime: String
        public var runtimeConfigJSON: String?
        public var envVarsJSON: String?
        public var status: String
        public var deleted: Bool
    }

    public func agentRuntimeInfo(id: String) -> AgentRuntimeInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let agent = agents[id] else { return nil }
        return AgentRuntimeInfo(
            id: agent.id,
            serverId: agent.serverId,
            name: agent.name,
            displayName: agent.displayName,
            description: agent.description,
            avatarUrl: agent.avatarUrl,
            creatorUserId: agent.creatorUserId,
            runtime: agent.runtime,
            runtimeConfigJSON: agent.runtimeConfigJSON,
            envVarsJSON: agent.envVarsJSON,
            status: agent.status,
            deleted: agent.deleted
        )
    }

    public func serverAgents(serverId: String) -> [AgentRuntimeInfo] {
        lock.lock()
        defer { lock.unlock() }
        return agents.values
            .filter { $0.serverId == serverId && !$0.deleted }
            .map { agent in
                AgentRuntimeInfo(
                    id: agent.id,
                    serverId: agent.serverId,
                    name: agent.name,
                    displayName: agent.displayName,
                    description: agent.description,
                    avatarUrl: agent.avatarUrl,
                    creatorUserId: agent.creatorUserId,
                    runtime: agent.runtime,
                    runtimeConfigJSON: agent.runtimeConfigJSON,
                    envVarsJSON: agent.envVarsJSON,
                    status: agent.status,
                    deleted: agent.deleted
                )
            }
    }

    public func setAgentStatus(id: String, status: String) {
        lock.lock()
        agents[id]?.status = status
        lock.unlock()
    }

    public func updateAgentRuntimeId(id: String, runtime: String) {
        lock.lock()
        agents[id]?.runtime = runtime
        lock.unlock()
    }

    public func updateAgentRuntime(id: String, runtimeConfigJSON: String?, envVarsJSON: String?) {
        lock.lock()
        agents[id]?.runtimeConfigJSON = runtimeConfigJSON
        agents[id]?.envVarsJSON = envVarsJSON
        lock.unlock()
    }

    public func updateAgentAvatar(id: String, avatarUrl: String?) {
        lock.lock()
        agents[id]?.avatarUrl = avatarUrl
        lock.unlock()
    }

    public func updateAgentDisplayName(id: String, displayName: String) {
        lock.lock()
        agents[id]?.displayName = displayName
        lock.unlock()
    }

    public func updateAgentDescription(id: String, description: String) {
        lock.lock()
        agents[id]?.description = description
        lock.unlock()
    }

    public func deleteAgent(id: String) {
        lock.lock()
        agents[id]?.deleted = true
        lock.unlock()
    }

    /// The URL-safe key the pixel avatar route uses.
    public static func pixelAvatarKey(_ avatar: String) -> String {
        let key = avatar.hasPrefix("pixel:") ? String(avatar.dropFirst("pixel:".count)) : avatar
        return Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
