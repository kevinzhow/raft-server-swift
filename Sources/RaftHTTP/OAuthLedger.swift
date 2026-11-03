import Crypto
import Foundation

public struct ThirdPartyEventMessage: Sendable {
    public var id: String
    public var serverId: String
    public var clientKey: String
    public var clientName: String
    public var clientRecordId: String
    public var kind: String
    public var summary: String
}

public struct OAuthHuman: Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var emailVerified: Bool
    public var avatarUrl: String?

    public init(id: String, email: String, name: String, emailVerified: Bool = false, avatarUrl: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.emailVerified = emailVerified
        self.avatarUrl = avatarUrl
    }
}

public enum OAuthSession: Sendable {
    case missing
    case invalid
    case user(OAuthHuman)
}

public struct CreatedOAuthClient: Sendable {
    public var id: String
    public var clientId: String
    public var clientSecret: String
}

public struct OAuthClientRejection: Error, Sendable {
    public var message: String
}

/// In-memory OAuth clients, human authorization codes, and access tokens.
/// `POST /api/oauth/authorize/human` and `POST /api/oauth/token` both use this ledger.
public final class OAuthLedger: @unchecked Sendable {
    public var jwtSecret: String = "test-jwt-secret"
    private let lock = NSLock()
    private var servers: [String: Server] = [:]
    private var agents: [String: Agent] = [:]
    private var agentRoles: [String: String] = [:]
    /// Agent owners of a server-local App (`oauth_client_maintainers`).
    private var clientMaintainerOwners: [String: Set<String>] = [:]
    private var agentEvents: [AgentEvent] = []
    private var revokedGrantClients: Set<String> = []
    private var members: [String: String] = [:]
    private var channelRecords: [ChannelRecord] = []
    private var channelHumans: Set<String> = []
    private var channelAgents: Set<String> = []
    private var channelMessages: [ChannelMessageRecord] = []
    private var channelSystemMessages: [ChannelSystemMessageRecord] = []
    private var channelNotificationPrefs: [String: ChannelNotificationPrefs] = [:]
    private var channelReadCursors: [String: Int] = [:]
    private var channelDisplayPrefs: [String: ChannelDisplayPrefs] = [:]
    private var savedMessageRecords: [SavedMessageRecord] = []
    private var savedMessageCounter = 0
    private var sidebarOrders: [String: SidebarOrder] = [:]
    private var serverAgreementRecords: [String: [ServerAgreementInfo]] = [:]
    private var serverPushMutes: Set<String> = []

    private var clients: [Client] = []
    private var requests: [AccessRequest] = []
    private var tokens: [AccessToken] = []
    private var installations: [Installation] = []
    private var installationTokens: [InstallationToken] = []

    public init() {}

    public func addOwnedServer(id: String, slug: String, name: String, ownerId: String) {
        lock.lock()
        servers[id] = Server(id: id, slug: slug, name: name, ownerId: ownerId)
        members["\(id)\n\(ownerId)"] = "owner"
        let allId = UUID().uuidString.lowercased()
        channelRecords.append(ChannelRecord(id: allId, serverId: id, name: "all", type: "channel"))
        channelHumans.insert("\(allId)\n\(ownerId)")
        lock.unlock()
    }

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

    public func setClientAgentJWTEnabledForTesting(clientRecordId: String, enabled: Bool?) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].agentJwtEnabled = enabled
        }
        lock.unlock()
    }

    public func clientAgentJWTEnabled(clientRecordId: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return clients.first { $0.id == clientRecordId }?.agentJwtEnabled
    }

    public func setInstallationAgentJWTEnabledForTesting(clientRecordId: String, serverId: String, enabled: Bool?) {
        lock.lock()
        if let index = installations.firstIndex(where: { $0.clientId == clientRecordId && $0.serverId == serverId }) {
            installations[index].agentJwtEnabled = enabled
        }
        lock.unlock()
    }

    public func installationAgentJWTEnabled(clientRecordId: String, serverId: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return installations.first { $0.clientId == clientRecordId && $0.serverId == serverId }?.agentJwtEnabled
    }

    /// Conversion into a private share: the App keeps issuing for its source
    /// because conversion installs it there too.
    @discardableResult
    public func convertClientToPrivateShareForTesting(
        clientRecordId: String,
        installedByUserId: String
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = clients.firstIndex(where: { $0.id == clientRecordId }) else { return nil }
        clients[index].appType = "third_party_global"
        clients[index].humanMarketplaceVisible = false
        if !installations.contains(where: { $0.clientId == clientRecordId && $0.serverId == clients[index].serverId }) {
            installations.append(Installation(
                id: UUID().uuidString.lowercased(),
                serverId: clients[index].serverId,
                clientId: clientRecordId,
                installedByUserId: installedByUserId,
                approvedGroups: [],
                grantRevision: 0,
                status: "active"
            ))
        }
        return "raft_share_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func installSharedClientForTesting(
        clientRecordId: String,
        serverId: String,
        installedByUserId: String
    ) {
        lock.lock()
        if !installations.contains(where: { $0.clientId == clientRecordId && $0.serverId == serverId }) {
            installations.append(Installation(
                id: UUID().uuidString.lowercased(),
                serverId: serverId,
                clientId: clientRecordId,
                installedByUserId: installedByUserId,
                approvedGroups: [],
                grantRevision: 0,
                status: "active"
            ))
        }
        lock.unlock()
    }

    public func setInstallationStatusForTesting(clientRecordId: String, serverId: String, status: String) {
        lock.lock()
        if let index = installations.firstIndex(where: { $0.clientId == clientRecordId && $0.serverId == serverId }) {
            installations[index].status = status
        }
        lock.unlock()
    }

    public func removeInstallationForTesting(clientRecordId: String, serverId: String) {
        lock.lock()
        installations.removeAll { $0.clientId == clientRecordId && $0.serverId == serverId }
        lock.unlock()
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
                    deleted: agent.deleted
                )
            }
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

    public struct ServerProfile: Sendable {
        public var id: String
        public var slug: String
        public var name: String
        public var ownerId: String
        public var avatarUrl: String?
        public var plan: String
        public var translationEnabled: Bool
        public var publiclyVisible: Bool
        public var publicGuestJoinEnabled: Bool
    }

    public func serverIdForSlug(_ slug: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return servers.values.first { $0.slug == slug && !$0.deleted }?.id
    }

    public func serverProfile(id: String) -> ServerProfile? {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers[id], !server.deleted else { return nil }
        return ServerProfile(
            id: server.id,
            slug: server.slug,
            name: server.name,
            ownerId: server.ownerId,
            avatarUrl: server.avatarUrl,
            plan: server.plan,
            translationEnabled: server.translationEnabled,
            publiclyVisible: server.publiclyVisible,
            publicGuestJoinEnabled: server.publicGuestJoinEnabled
        )
    }

    public func setServerProfile(
        id: String,
        avatarUrl: String?,
        plan: String,
        translationEnabled: Bool,
        publiclyVisible: Bool,
        publicGuestJoinEnabled: Bool
    ) {
        lock.lock()
        if servers[id] != nil {
            servers[id]?.avatarUrl = avatarUrl
            servers[id]?.plan = plan
            servers[id]?.translationEnabled = translationEnabled
            servers[id]?.publiclyVisible = publiclyVisible
            servers[id]?.publicGuestJoinEnabled = publicGuestJoinEnabled
        }
        lock.unlock()
    }

    public func serverIdsForMember(userId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return members.keys.compactMap { key -> String? in
            let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] == userId else { return nil }
            guard let server = servers[parts[0]], !server.deleted else { return nil }
            return parts[0]
        }
    }

    public struct ChannelListInfo: Sendable {
        public var id: String
        public var name: String
        public var type: String
        public var joined: Bool
        public var lastMessageAt: Date?
        public var activityMuted: Bool
        public var muteFromSeq: Int?
        public var prefsVersion: Int
    }

    public struct ChannelNotificationPrefs: Sendable {
        public var activityMuted: Bool = false
        public var muteFromSeq: Int? = nil
        public var prefsVersion: Int = 0
    }

    public func createChannel(serverId: String, name: String, creatorUserId: String, type: String = "channel", description: String? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        channelRecords.append(ChannelRecord(id: id, serverId: serverId, name: name, type: type, description: description))
        if type == "channel" {
            channelHumans.insert("\(id)\n\(creatorUserId)")
        }
        lock.unlock()
        return id
    }

    public func addChannelAgent(channelId: String, agentId: String) {
        lock.lock()
        channelAgents.insert("\(channelId)\n\(agentId)")
        lock.unlock()
    }

    public func removeChannelAgent(channelId: String, agentId: String) {
        lock.lock()
        channelAgents.remove("\(channelId)\n\(agentId)")
        lock.unlock()
    }

    public func channelAgentIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return channelAgents
            .filter { $0.hasPrefix("\(channelId)\n") }
            .compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) }
            .sorted()
    }

    public func channelHumanIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return channelHumans
            .filter { $0.hasPrefix("\(channelId)\n") }
            .compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) }
            .sorted()
    }

    public func addChannelHuman(channelId: String, userId: String) {
        lock.lock()
        channelHumans.insert("\(channelId)\n\(userId)")
        lock.unlock()
    }

    @discardableResult
    public func createChannelMessage(
        channelId: String,
        content: String,
        createdAt: Date = Date(),
        senderId: String = "user"
    ) -> Date {
        lock.lock()
        let seq = channelMessages.filter { $0.channelId == channelId }.count
            + channelSystemMessages.filter { $0.channelId == channelId }.count + 1
        channelMessages.append(ChannelMessageRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            content: content,
            createdAt: createdAt,
            senderId: senderId,
            seq: seq
        ))
        lock.unlock()
        return createdAt
    }

    /// Records a message row the directory already sequenced. The directory
    /// keeps the authoritative message list; this mirror makes the same rows
    /// visible to the ledger-backed reads (history, thread anchors).
    public func appendMirroredMessage(
        id: String,
        channelId: String,
        content: String,
        senderId: String,
        seq: Int,
        createdAt: Date,
        senderTimezone: String?,
        senderType: String?,
        messageType: String?
    ) {
        lock.lock()
        if !channelMessages.contains(where: { $0.id == id }) {
            channelMessages.append(ChannelMessageRecord(
                id: id,
                channelId: channelId,
                content: content,
                createdAt: createdAt,
                senderId: senderId,
                seq: seq,
                senderTimezone: senderTimezone,
                senderType: senderType,
                messageType: messageType
            ))
        }
        lock.unlock()
    }

    public func createMessageRecord(
        channelId: String,
        content: String,
        senderId: String,
        id explicitId: String? = nil,
        seq explicitSeq: Int? = nil,
        createdAt: Date = Date(),
        senderTimezone: String? = nil
    ) -> (id: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let seq = explicitSeq ?? (channelMessages.filter { $0.channelId == channelId }.count
            + channelSystemMessages.filter { $0.channelId == channelId }.count + 1)
        let id = explicitId ?? UUID().uuidString.lowercased()
        channelMessages.append(ChannelMessageRecord(
            id: id,
            channelId: channelId,
            content: content,
            createdAt: createdAt,
            senderId: senderId,
            seq: seq,
            senderTimezone: senderTimezone
        ))
        return (id, seq)
    }

    public func createDirectChannel(serverId: String, firstUserId: String, secondUserId: String) -> String {
        lock.lock()
        if let existing = channelRecords.first(where: {
            $0.serverId == serverId && $0.type == "dm"
                && channelHumans.contains("\($0.id)\n\(firstUserId)")
                && channelHumans.contains("\($0.id)\n\(secondUserId)")
        }) {
            lock.unlock()
            return existing.id
        }
        let id = UUID().uuidString.lowercased()
        channelRecords.append(ChannelRecord(id: id, serverId: serverId, name: "", type: "dm"))
        channelHumans.insert("\(id)\n\(firstUserId)")
        channelHumans.insert("\(id)\n\(secondUserId)")
        lock.unlock()
        return id
    }

    public func channelReadCursor(channelId: String, userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return channelReadCursors["\(channelId)\n\(userId)"] ?? 0
    }

    public func setChannelReadCursor(channelId: String, userId: String, seq: Int) {
        lock.lock()
        channelReadCursors["\(channelId)\n\(userId)"] = seq
        lock.unlock()
    }

    public struct ChannelUnreadInfo: Sendable {
        public var unreadCount: Int
        public var maxReadSeq: Int
        public var latestMessageId: String?
        public var latestSeq: Int?
    }

    public func firstUnreadMessageId(channelId: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let cursor = channelReadCursors["\(channelId)\n\(userId)"] ?? 0
        return channelMessages
            .filter { $0.channelId == channelId && $0.senderId != userId && $0.seq > cursor }
            .min { $0.seq < $1.seq }?.id
    }

    public func latestPeerMessageSeq(channelId: String, excluding userId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return channelMessages
            .filter { $0.channelId == channelId && $0.senderId != userId }
            .map(\.seq)
            .max()
    }

    public func channelUnreadInfo(channelId: String, userId: String) -> ChannelUnreadInfo {
        lock.lock()
        defer { lock.unlock() }
        let cursor = channelReadCursors["\(channelId)\n\(userId)"] ?? 0
        let messages = channelMessages.filter { $0.channelId == channelId }
        let unread = messages.filter { $0.senderId != userId && $0.seq > cursor }.count
        let latest = messages.max { $0.seq < $1.seq }
        return ChannelUnreadInfo(
            unreadCount: unread,
            maxReadSeq: cursor,
            latestMessageId: latest?.id,
            latestSeq: latest?.seq
        )
    }

    public struct ChannelDisplayPrefs: Sendable {
        public var collapseLongMessages: Bool = true
        public var prefsVersion: Int = 0
    }

    @discardableResult
    public func renameChannel(id: String, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = channelRecords.firstIndex(where: { $0.id == id }) else { return false }
        channelRecords[index].name = name
        return true
    }

    public func updateServerName(id: String, name: String) {
        lock.lock()
        if var server = servers[id] {
            server.name = name
            servers[id] = server
        }
        lock.unlock()
    }

    public func setChannelType(id: String, type: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = channelRecords.firstIndex(where: { $0.id == id }) else { return false }
        channelRecords[index].type = type
        return true
    }

    public struct SidebarOrder: Sendable {
        public var channelOrder: [String]
        public var agentOrder: [String]
        public var dmOrder: [String]
        public var pinnedOrder: [String]
        public var hiddenDmIds: [String]

        public init(
            channelOrder: [String] = [],
            agentOrder: [String] = [],
            dmOrder: [String] = [],
            pinnedOrder: [String] = [],
            hiddenDmIds: [String] = []
        ) {
            self.channelOrder = channelOrder
            self.agentOrder = agentOrder
            self.dmOrder = dmOrder
            self.pinnedOrder = pinnedOrder
            self.hiddenDmIds = hiddenDmIds
        }
    }

    public struct ServerAgreementInfo: Sendable {
        public var id: String
        public var serverId: String
        public var version: Int
        public var title: String
        public var bodyMarkdown: String
        public var enabled: Bool
    }

    public func putServerAgreement(serverId: String, title: String, bodyMarkdown: String) -> ServerAgreementInfo {
        lock.lock()
        defer { lock.unlock() }
        var records = serverAgreementRecords[serverId] ?? []
        for index in records.indices {
            records[index].enabled = false
        }
        let record = ServerAgreementInfo(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            version: records.count + 1,
            title: title,
            bodyMarkdown: bodyMarkdown,
            enabled: true
        )
        records.append(record)
        serverAgreementRecords[serverId] = records
        return record
    }

    public func activeServerAgreement(serverId: String) -> ServerAgreementInfo? {
        lock.lock()
        defer { lock.unlock() }
        return serverAgreementRecords[serverId]?.last(where: { $0.enabled })
    }

    public func isServerPushMuted(serverId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return serverPushMutes.contains("\(serverId)\n\(userId)")
    }

    public func setServerPushMuted(serverId: String, userId: String, muted: Bool) {
        lock.lock()
        if muted {
            serverPushMutes.insert("\(serverId)\n\(userId)")
        } else {
            serverPushMutes.remove("\(serverId)\n\(userId)")
        }
        lock.unlock()
    }

    public func serverAgreementVersions(serverId: String) -> [ServerAgreementInfo] {
        lock.lock()
        defer { lock.unlock() }
        return serverAgreementRecords[serverId] ?? []
    }

    public func setSidebarOrder(serverId: String, userId: String, order: SidebarOrder) {
        lock.lock()
        sidebarOrders["\(serverId)\n\(userId)"] = order
        lock.unlock()
    }

    public func sanitizedSidebarOrder(serverId: String, userId: String) -> SidebarOrder {
        lock.lock()
        defer { lock.unlock() }
        let stored = sidebarOrders["\(serverId)\n\(userId)"] ?? SidebarOrder()
        func isUUID(_ value: String) -> Bool {
            value.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
        }
        let channelIds = Set(channelRecords.filter { $0.serverId == serverId && $0.type != "dm" && $0.type != "thread" }.map { $0.id })
        let agentIds = Set(agents.values.filter { $0.serverId == serverId && !$0.deleted }.map { $0.id })
        let dmIds = Set(channelRecords.filter {
            $0.serverId == serverId && $0.type == "dm" && channelHumans.contains("\($0.id)\n\(userId)")
        }.map { $0.id })
        func keep(_ ids: [String], in allowed: Set<String>) -> [String] {
            ids.filter { isUUID($0) && allowed.contains($0) }
        }
        let pinned = stored.pinnedOrder.filter { value in
            isUUID(value) && (channelIds.contains(value) || agentIds.contains(value) || dmIds.contains(value))
        }
        return SidebarOrder(
            channelOrder: keep(stored.channelOrder, in: channelIds),
            agentOrder: keep(stored.agentOrder, in: agentIds),
            dmOrder: keep(stored.dmOrder, in: dmIds),
            pinnedOrder: pinned,
            hiddenDmIds: keep(stored.hiddenDmIds, in: dmIds)
        )
    }

    public struct SavedMessageInfo: Sendable {
        public var messageId: String
        public var savedAt: Int
        public var content: String
        public var channelId: String
        public var channelType: String
        public var parentChannelId: String?
        public var parentMessageId: String?
        public var parentMessagePreview: String?
        public var replyCount: Int
    }

    public func createThreadChannel(parentChannelId: String, parentMessageId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID().uuidString.lowercased()
        channelRecords.append(ChannelRecord(
            id: id,
            serverId: channelRecords.first(where: { $0.id == parentChannelId })?.serverId ?? "",
            name: "",
            type: "thread",
            parentChannelId: parentChannelId,
            parentMessageId: parentMessageId
        ))
        return id
    }

    public struct HistoryMessage: Sendable {
        public var id: String
        public var content: String
        public var senderId: String
        public var seq: Int
        public var createdAt: Date
        public var senderTimezone: String?
        public var senderType: String?
        public var messageType: String?
    }

    public func historyMessages(channelId: String) -> [HistoryMessage] {
        lock.lock()
        defer { lock.unlock() }
        return channelMessages
            .filter { $0.channelId == channelId }
            .sorted { $0.seq < $1.seq }
            .map { HistoryMessage(id: $0.id, content: $0.content, senderId: $0.senderId, seq: $0.seq, createdAt: $0.createdAt, senderTimezone: $0.senderTimezone, senderType: $0.senderType, messageType: $0.messageType) }
    }

    public func messageContent(id: String) -> (channelId: String, content: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let message = channelMessages.first(where: { $0.id == id }) else { return nil }
        return (message.channelId, message.content)
    }

    public func messageChannelId(_ messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelMessages.first(where: { $0.id == messageId })?.channelId
    }

    public func saveMessage(userId: String, messageId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let message = channelMessages.first(where: { $0.id == messageId }) else { return false }
        if savedMessageRecords.contains(where: { $0.userId == userId && $0.messageId == messageId }) {
            return true
        }
        savedMessageCounter += 1
        savedMessageRecords.append(SavedMessageRecord(userId: userId, messageId: messageId, savedAt: savedMessageCounter))
        _ = message
        return true
    }

    public func savedMessages(userId: String) -> [SavedMessageInfo] {
        lock.lock()
        defer { lock.unlock() }
        return savedMessageRecords
            .filter { $0.userId == userId }
            .compactMap { saved -> SavedMessageInfo? in
                guard let message = channelMessages.first(where: { $0.id == saved.messageId }),
                      let channel = channelRecords.first(where: { $0.id == message.channelId })
                else { return nil }
                let parentPreview = channel.parentMessageId.flatMap { parentId in
                    channelMessages.first(where: { $0.id == parentId })?.content
                }
                let replyCount = channel.type == "thread"
                    ? channelMessages.filter { $0.channelId == channel.id }.count
                    : 0
                return SavedMessageInfo(
                    messageId: saved.messageId,
                    savedAt: saved.savedAt,
                    content: message.content,
                    channelId: channel.id,
                    channelType: channel.type,
                    parentChannelId: channel.parentChannelId,
                    parentMessageId: channel.parentMessageId,
                    parentMessagePreview: parentPreview,
                    replyCount: replyCount
                )
            }
    }

    private struct SavedMessageRecord {
        var userId: String
        var messageId: String
        var savedAt: Int
    }

    public func allChannelId(serverId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.serverId == serverId && $0.name == "all" })?.id
    }

    /// `all` is implicit for every Server human; other channels require membership.
    public func canAccessChannelPrefs(channelId: String, userId: String, serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = channelRecords.first(where: { $0.id == channelId }), channel.serverId == serverId else {
            return false
        }
        if channel.name == "all" { return true }
        return channelHumans.contains("\(channelId)\n\(userId)")
    }

    public func channelDisplayPrefs(channelId: String, userId: String) -> ChannelDisplayPrefs {
        lock.lock()
        defer { lock.unlock() }
        return channelDisplayPrefs["\(channelId)\n\(userId)"] ?? ChannelDisplayPrefs()
    }

    public func setCollapseLongMessages(channelId: String, userId: String, collapse: Bool) -> ChannelDisplayPrefs {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(userId)"
        var prefs = channelDisplayPrefs[key] ?? ChannelDisplayPrefs()
        if prefs.collapseLongMessages != collapse {
            prefs.collapseLongMessages = collapse
            prefs.prefsVersion += 1
            channelDisplayPrefs[key] = prefs
        }
        return prefs
    }

    public func channelServerId(_ channelId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.id == channelId })?.serverId
    }

    public func removeChannelHuman(channelId: String, userId: String) {
        lock.lock()
        channelHumans.remove("\(channelId)\n\(userId)")
        lock.unlock()
    }

    public func isChannelParticipant(channelId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return channelHumans.contains("\(channelId)\n\(userId)")
    }

    public func setChannelArchived(id: String, archivedAt: Date?) {
        lock.lock()
        if let index = channelRecords.firstIndex(where: { $0.id == id }) {
            channelRecords[index].archived = archivedAt != nil
            channelRecords[index].archivedAt = archivedAt
            if let parent = channelRecords[index].parentChannelId,
               let parentIndex = channelRecords.firstIndex(where: { $0.id == parent }),
               archivedAt != nil {
                channelRecords[parentIndex].archived = true
            }
        }
        lock.unlock()
    }

    public func channelArchivedAt(id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.id == id })?.archivedAt
    }

    public func channelInfo(id: String) -> (serverId: String, name: String, description: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = channelRecords.first(where: { $0.id == id }) else { return nil }
        return (channel.serverId, channel.name, channel.description)
    }

    @discardableResult
    public func updateChannel(id: String, name: String?, description: String?, systemMessage: String?) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = channelRecords.firstIndex(where: { $0.id == id }) else { return nil }
        if let name { channelRecords[index].name = name }
        if let description { channelRecords[index].description = description }
        guard let systemMessage else { return nil }
        let seq = channelMessages.filter { $0.channelId == id }.count + channelSystemMessages.filter { $0.channelId == id }.count + 1
        channelSystemMessages.append(ChannelSystemMessageRecord(
            channelId: id,
            content: systemMessage,
            seq: seq,
            createdAt: Date()
        ))
        return seq
    }

    public func systemMessages(channelId: String) -> [(id: String, content: String, seq: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return channelSystemMessages
            .filter { $0.channelId == channelId }
            .map { (UUID().uuidString.lowercased(), $0.content, $0.seq) }
    }

    private struct ChannelSystemMessageRecord {
        var channelId: String
        var content: String
        var seq: Int
        var createdAt: Date
    }

    public func channelType(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.id == id })?.type
    }

    public func latestChannelSeq(channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let messages = channelMessages.filter { $0.channelId == channelId }.count
        let systems = channelSystemMessages.filter { $0.channelId == channelId }.count
        return messages + systems
    }

    public func notificationPrefs(channelId: String, userId: String) -> ChannelNotificationPrefs {
        lock.lock()
        defer { lock.unlock() }
        return channelNotificationPrefs["\(channelId)\n\(userId)"] ?? ChannelNotificationPrefs()
    }

    public func setActivityMuted(channelId: String, userId: String, muted: Bool) -> (prefs: ChannelNotificationPrefs, changed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(userId)"
        var prefs = channelNotificationPrefs[key] ?? ChannelNotificationPrefs()
        if prefs.activityMuted == muted {
            return (prefs, false)
        }
        prefs.activityMuted = muted
        prefs.muteFromSeq = muted ? latestChannelSeqLocked(channelId: channelId) + 1 : nil
        prefs.prefsVersion += 1
        channelNotificationPrefs[key] = prefs
        return (prefs, true)
    }

    private func latestChannelSeqLocked(channelId: String) -> Int {
        channelMessages.filter { $0.channelId == channelId }.count
            + channelSystemMessages.filter { $0.channelId == channelId }.count
    }

    public func channelsForServer(serverId: String, userId: String, includeArchived: Bool = false) -> [ChannelListInfo] {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords
            .filter { $0.serverId == serverId && (includeArchived || !$0.archived) }
            .filter { channel in
                if channel.type == "private" || channel.type == "dm" {
                    return channelHumans.contains("\(channel.id)\n\(userId)")
                }
                return true
            }
            .map { channel in
                let last = channelMessages
                    .filter { $0.channelId == channel.id }
                    .map { $0.createdAt }
                    .max()
                let prefs = channelNotificationPrefs["\(channel.id)\n\(userId)"] ?? ChannelNotificationPrefs()
                return ChannelListInfo(
                    id: channel.id,
                    name: channel.name,
                    type: channel.type,
                    joined: channelHumans.contains("\(channel.id)\n\(userId)"),
                    lastMessageAt: last,
                    activityMuted: prefs.activityMuted,
                    muteFromSeq: prefs.muteFromSeq,
                    prefsVersion: prefs.prefsVersion
                )
            }
    }

    private struct ChannelRecord {
        var id: String
        var serverId: String
        var name: String
        var type: String
        var description: String?
        var parentChannelId: String?
        var parentMessageId: String?
        var archived = false
        var archivedAt: Date?
    }

    private struct ChannelMessageRecord {
        var id: String
        var channelId: String
        var content: String
        var createdAt: Date
        var senderId: String
        var seq: Int
        var senderTimezone: String? = nil
        var senderType: String? = nil
        var messageType: String? = nil
    }

    public func memberRole(serverId: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return members["\(serverId)\n\(userId)"]
    }

    public func addMember(serverId: String, userId: String, role: String) {
        lock.lock()
        members["\(serverId)\n\(userId)"] = role
        lock.unlock()
    }

    public func memberIdsWithRoles(serverId: String) -> [(id: String, role: String)] {
        lock.lock()
        defer { lock.unlock() }
        return members.compactMap { key, role -> (String, String)? in
            let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == serverId else { return nil }
            guard let server = servers[serverId], !server.deleted else { return nil }
            return (parts[1], role)
        }.sorted { $0.0 < $1.0 }
    }

    public func memberIds(serverId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return members.keys.compactMap { key -> String? in
            let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == serverId else { return nil }
            guard let server = servers[serverId], !server.deleted else { return nil }
            return parts[1]
        }.sorted()
    }

    public func activeAgentIds(serverId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return agents.values
            .filter { $0.serverId == serverId && !$0.deleted }
            .map { $0.id }
            .sorted()
    }

    public func ownerCount(serverId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return members.filter { key, role in
            key.hasPrefix("\(serverId)\n") && role == "owner"
        }.count
    }

    public func removeMember(serverId: String, userId: String) {
        lock.lock()
        members.removeValue(forKey: "\(serverId)\n\(userId)")
        lock.unlock()
    }

    public func setServerAvatar(id: String, avatarUrl: String?) {
        lock.lock()
        servers[id]?.avatarUrl = avatarUrl
        lock.unlock()
    }

    public func updateServer(id: String, name: String, avatarUrl: String?) {
        lock.lock()
        if var server = servers[id] {
            server.name = name
            server.avatarUrl = avatarUrl
            servers[id] = server
        }
        lock.unlock()
    }

    public func serverDetailsValue(id: String) -> (slug: String, name: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers[id], !server.deleted else { return nil }
        return (server.slug, server.name)
    }

    public func setServerTranslationEnabled(id: String, enabled: Bool) {
        lock.lock()
        servers[id]?.translationEnabled = enabled
        lock.unlock()
    }

    public func setServerProductAnalytics(id: String, enabled: Bool) {
        lock.lock()
        servers[id]?.productAnalyticsEnabled = enabled
        lock.unlock()
    }

    /// nil means the Server does not exist.
    public func serverAnalyticsAllowed(id: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers[id], !server.deleted else { return nil }
        return server.productAnalyticsEnabled
    }

    public func setServerPlan(id: String, plan: String) {
        lock.lock()
        if var server = servers[id] {
            server.plan = plan
            servers[id] = server
        }
        lock.unlock()
    }

    public func deleteServer(id: String) {
        lock.lock()
        if var server = servers[id] {
            server.deleted = true
            servers[id] = server
        }
        lock.unlock()
    }

    public func createClient(
        serverId: String,
        createdByUserId: String,
        name: String,
        clientId: String,
        appType: String = "server_local",
        description: String? = nil,
        homepageUrl: String? = nil,
        returnUrl: String? = nil,
        allowedScopes: [String]? = nil,
        agentManifestUrl: String? = nil,
        agentManifestUrlSource: String? = nil
    ) throws -> CreatedOAuthClient {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthClientRejection(message: "name is required") }
        let normalized = clientId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.wholeMatch(of: /^[a-z][a-z0-9-]{2,63}$/) != nil else {
            throw OAuthClientRejection(message: "clientId must start with a letter and contain only lowercase letters, numbers, and hyphens")
        }
        if let returnUrl, !Self.isSafeReturnURL(returnUrl) {
            throw OAuthClientRejection(message: "returnUrl must be HTTPS (or loopback HTTP), without credentials or fragment")
        }
        var bytes = Data(count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let secret = "raft_secret_" + bytes.map { String(format: "%02x", $0) }.joined()
        let id = UUID().uuidString.lowercased()
        lock.lock()
        clients.append(Client(
            id: id,
            serverId: serverId,
            clientId: normalized,
            secretHash: sha256(secret),
            appType: appType,
            name: trimmed,
            createdByUserId: createdByUserId,
            descriptionText: description,
            homepageUrl: homepageUrl,
            returnUrl: returnUrl,
            allowedScopes: allowedScopes,
            agentManifestUrl: agentManifestUrl,
            agentManifestUrlSource: agentManifestUrlSource ?? (agentManifestUrl == nil ? nil : "explicit")
        ))
        lock.unlock()
        return CreatedOAuthClient(id: id, clientId: normalized, clientSecret: secret)
    }

    public func integrationServices(serverId: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return clients.filter {
            $0.serverId == serverId && $0.appType != "slock_builtin" && $0.enabled
        }.map { client in
            let manifest = manifestFields(client)
            return [
                "id": client.id,
                "clientId": client.clientId,
                "name": client.name,
                "description": client.descriptionText.map { $0 as Any } ?? NSNull(),
                "homepageUrl": client.homepageUrl.map { $0 as Any } ?? NSNull(),
                "agentManifestUrl": manifest.url,
                "agentManifestUrlSource": manifest.source,
                "allowedScopes": client.allowedScopes as Any,
                "appType": client.appType,
                "whenToUse": client.whenToUse as Any,
            ]
        }
    }

    public func setClientWhenToUse(clientRecordId: String, whenToUse: String?) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].whenToUse = whenToUse
        }
        lock.unlock()
    }

    public func clientRecordId(serverId: String, clientKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return clients.first {
            $0.serverId == serverId && ($0.clientId == clientKey || $0.id == clientKey)
        }?.id
    }

    public func publicIntegrationClient(clientId: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { candidate in
            (candidate.clientId == clientId || candidate.id == clientId) && isMarketplaceVisible(candidate)
        }) else { return nil }
        let manifest = manifestFields(client)
        return [
            "id": client.id,
            "clientId": client.clientId,
            "name": client.name,
            "description": client.descriptionText as Any,
            "homepageUrl": client.homepageUrl as Any,
            "agentManifestUrl": manifest.url,
            "agentManifestUrlSource": manifest.source,
            "allowedScopes": client.allowedScopes as Any,
            "appType": client.appType,
        ]
    }

    /// The live Marketplace row an install card must still bind to at
    /// execution time: same record id, enabled, published, human-visible.
    public func marketplaceInstallableClient(recordId: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { $0.id == recordId }),
              client.appType == "third_party_global",
              client.enabled,
              isUserManaged(client),
              client.humanMarketplaceVisible,
              client.publishStatus == "published" || client.publishStatus == "unpublish_requested"
        else { return nil }
        return [
            "id": client.id,
            "clientId": client.clientId,
            "name": client.name,
            "allowedScopes": client.allowedScopes as Any,
        ]
    }

    public func isClientInstalled(serverId: String, clientRecordId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return installations.contains {
            $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
        }
    }

    public func integrationLoginClient(serverId: String, clientId: String) -> [String: Any]? {
        integrationServices(serverId: serverId).first {
            ($0["clientId"] as? String) == clientId || ($0["id"] as? String) == clientId
        } ?? {
            lock.lock()
            defer { lock.unlock() }
            guard let client = clients.first(where: { candidate in
                (candidate.clientId == clientId || candidate.id == clientId)
                    && candidate.appType != "slock_builtin"
                    && installations.contains {
                        $0.clientId == candidate.id && $0.serverId == serverId && $0.status == "active"
                    }
            }) else { return nil }
            let manifest = manifestFields(client)
            return [
                "id": client.id,
                "clientId": client.clientId,
                "name": client.name,
                "description": client.descriptionText as Any,
                "homepageUrl": client.homepageUrl as Any,
                "agentManifestUrl": manifest.url,
                "agentManifestUrlSource": manifest.source,
                "allowedScopes": client.allowedScopes as Any,
                "appType": client.appType,
            ]
        }()
    }

    public func integrationClient(serverId: String, clientId: String) -> [String: Any]? {
        integrationServices(serverId: serverId).first { ($0["clientId"] as? String) == clientId || ($0["id"] as? String) == clientId }
    }

    /// Moves a human authorization code one second past its 10-minute life. The token endpoint must not mint.
    public func removeAuthorizationCodeForTesting(id: String) {
        lock.lock()
        requests.removeAll { $0.id == id }
        lock.unlock()
    }

    public func expireAuthorizationCode(id: String) {
        lock.lock()
        if let index = requests.firstIndex(where: { $0.id == id }) {
            requests[index].createdAt = Date().addingTimeInterval(-(10 * 60 + 1))
        }
        lock.unlock()
    }

    /// Records an active installation whose approved groups are also the App's current outbound groups.
    public func installClient(serverId: String, clientRecordId: String, installedByUserId: String, groups: [String]) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].outboundGroups = groups
        }
        installations.append(Installation(
            id: id,
            serverId: serverId,
            clientId: clientRecordId,
            installedByUserId: installedByUserId,
            approvedGroups: groups,
            grantRevision: 1,
            status: "active"
        ))
        lock.unlock()
        return id
    }

    /// Test and retirement support: App class and platform registration are
    /// live authorities, never copied onto a token row.
    public func setClientAppType(clientRecordId: String, appType: String) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].appType = appType
        }
        lock.unlock()
    }

    /// Reviewer transition used by the publish/moderation flow. Publishing or
    /// returning the App to private restores the owning Server's installation;
    /// the in-between requested states touch only the declaration.
    @discardableResult
    public func reviewClientPublish(clientRecordId: String, status: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = clients.firstIndex(where: { $0.id == clientRecordId }) else { return false }
        clients[index].publishStatus = status
        if status == "published" {
            clients[index].humanMarketplaceVisible = true
        }
        guard status == "published" || status == "private" else { return true }
        let client = clients[index]
        let hasInstall = installations.contains {
            $0.clientId == client.id && $0.serverId == client.serverId && $0.status == "active"
        }
        if !hasInstall {
            installations.append(Installation(
                id: UUID().uuidString.lowercased(),
                serverId: client.serverId,
                clientId: client.id,
                installedByUserId: client.createdByUserId,
                approvedGroups: [],
                grantRevision: 1,
                status: "active"
            ))
        }
        return true
    }

    public func setClientPublishStatusForTesting(clientRecordId: String, status: String) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].publishStatus = status
        }
        lock.unlock()
    }

    public func removeInstallationsForTesting(clientRecordId: String) {
        lock.lock()
        installations.removeAll { $0.clientId == clientRecordId }
        lock.unlock()
    }

    public func installationGroupsForTesting(clientRecordId: String, serverId: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return installations.first {
            $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
        }?.approvedGroups
    }

    public func seedRevokedOAuthAccessTokenForTesting(
        serverId: String,
        clientRecordId: String,
        userId: String,
        rawToken: String
    ) {
        lock.lock()
        tokens.append(AccessToken(
            serverId: serverId,
            userId: userId,
            clientId: clientRecordId,
            requestId: UUID().uuidString.lowercased(),
            tokenHash: sha256(rawToken),
            scopes: ["openid"],
            expiresAt: Date().addingTimeInterval(3600),
            revokedAt: Date()
        ))
        lock.unlock()
    }

    public func revokedOAuthTokenCountForTesting(clientRecordId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tokens.filter { $0.clientId == clientRecordId && $0.revokedAt != nil }.count
    }

    /// Settings list: every App this Server owns or has installed. A published
    /// marketplace App without a local installation is not listed.
    public func integrationSettingsClients(serverId: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return clients.filter { client in
            guard client.enabled, isUserManaged(client) else { return false }
            if client.serverId == serverId { return true }
            return installations.contains {
                $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
            }
        }.map { client in
            [
                "id": client.id,
                "clientId": client.clientId,
                "name": client.name,
                "appType": client.appType,
                "description": client.descriptionText as Any,
                "homepageUrl": client.homepageUrl as Any,
                "publishStatus": client.publishStatus,
            ]
        }
    }

    public func publishClient(clientRecordId: String, humanMarketplaceVisible: Bool = true) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].publishStatus = "published"
            clients[index].humanMarketplaceVisible = humanMarketplaceVisible
        }
        lock.unlock()
    }

    public struct AppPermissionReviewRow: Sendable {
        public var id: String
        public var clientId: String
        public var name: String
        public var pendingGroups: [String]
        public var pendingRevisionId: String?
    }

    public enum AppPermissionReviewError: Error, Sendable {
        case notFound
        case stale
    }

    public func appPermissionReviewRows(serverId: String) -> [AppPermissionReviewRow] {
        lock.lock()
        defer { lock.unlock() }
        return clients
            .filter {
                $0.serverId == serverId
                    && $0.appType == "third_party_global"
                    && $0.publishStatus == "published"
                    && $0.enabled
            }
            .map {
                AppPermissionReviewRow(
                    id: $0.id,
                    clientId: $0.clientId,
                    name: $0.name,
                    pendingGroups: $0.pendingOutboundGroups,
                    pendingRevisionId: $0.pendingOutboundRevisionId
                )
            }
    }

    @discardableResult
    public func createAppOutboundPermissionRevision(clientRecordId: String, groups: [String]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = clients.firstIndex(where: { $0.id == clientRecordId }) else { return nil }
        let revisionId = UUID().uuidString.lowercased()
        clients[index].pendingOutboundRevisionId = revisionId
        clients[index].pendingOutboundGroups = groups
        return revisionId
    }

    public func approveAppOutboundPermission(clientRecordId: String, expectedRevisionId: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let index = clients.firstIndex(where: { $0.id == clientRecordId }) else {
            throw AppPermissionReviewError.notFound
        }
        guard clients[index].pendingOutboundRevisionId == expectedRevisionId else {
            throw AppPermissionReviewError.stale
        }
        let groups = clients[index].pendingOutboundGroups
        clients[index].outboundGroups = groups
        clients[index].pendingOutboundRevisionId = nil
        clients[index].pendingOutboundGroups = []
        return groups
    }

    public func registerExternalApp(clientRecordId: String, provider: String, state: String) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].externalProvider = provider
            clients[index].externalState = state
        }
        lock.unlock()
    }

    public func installationTokenCount(clientRecordId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return installationTokens.filter { $0.clientId == clientRecordId }.count
    }

    public func setInstallationStatus(id: String, status: String) {
        lock.lock()
        if let index = installations.firstIndex(where: { $0.id == id }) {
            installations[index].status = status
        }
        lock.unlock()
    }

    public func setClientEnabled(clientRecordId: String, enabled: Bool) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].enabled = enabled
        }
        lock.unlock()
    }

    public func setClientAllowedScopes(clientRecordId: String, scopes: [String]?) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].allowedScopes = scopes
        }
        lock.unlock()
    }

    /// `updateOAuthClient`'s return-URL guard: an existing client cannot be
    /// moved to a script or data URL either.
    public func updateClientReturnUrl(clientRecordId: String, returnUrl: String?) throws {
        if let returnUrl, !Self.isSafeReturnURL(returnUrl) {
            throw OAuthClientRejection(message: "returnUrl must be HTTPS (or loopback HTTP), without credentials or fragment")
        }
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].returnUrl = returnUrl
        }
        lock.unlock()
    }

    public func setClientReturnUrl(clientRecordId: String, returnUrl: String?) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].returnUrl = returnUrl
        }
        lock.unlock()
    }

    public func expireAccessTokensForTesting(clientRecordId: String) {
        lock.lock()
        for index in tokens.indices where tokens[index].clientId == clientRecordId {
            tokens[index].expiresAt = Date(timeIntervalSince1970: 0)
        }
        lock.unlock()
    }

    public func revokeAccessTokens(clientRecordId: String) {
        lock.lock()
        for index in tokens.indices where tokens[index].clientId == clientRecordId {
            tokens[index].revokedAt = Date()
        }
        lock.unlock()
    }

    public func revokeAgentGrants(clientRecordId: String) {
        lock.lock()
        revokedGrantClients.insert(clientRecordId)
        lock.unlock()
    }

    public func accessTokenCount(requestId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tokens.filter { $0.requestId == requestId }.count
    }

    /// `POST /api/oauth/installation-token`. Client credentials mint a token for one active installation.
    public func mintInstallationToken(authorization: String?, body: String) -> HTTPReply {
        let fields = tokenFields(body)
        guard let credentials = clientCredentials(authorization: authorization, fields: fields) else {
            return json(401, "{\"error\":\"Client credentials are required\"}", cacheControl: "private, no-store")
        }
        let installationId = fields["installation_id"] ?? fields["installationId"] ?? ""
        guard !installationId.isEmpty else {
            return json(400, "{\"error\":\"installation_id is required\"}", cacheControl: "private, no-store")
        }
        lock.lock()
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId && isUserManaged($0) && $0.enabled && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            lock.unlock()
            return json(401, "{\"error\":\"Invalid client credentials\"}", cacheControl: "private, no-store")
        }
        guard let installation = installations.first(where: {
            $0.id == installationId && $0.clientId == client.id && $0.status == "active"
        }) else {
            lock.unlock()
            return json(404, "{\"error\":\"Active installation not found\"}", cacheControl: "private, no-store")
        }
        let groups = client.outboundGroups.filter { installation.approvedGroups.contains($0) }
        guard !groups.isEmpty else {
            lock.unlock()
            return json(400, "{\"error\":\"Installation has no effective read groups\"}", cacheControl: "private, no-store")
        }
        var raw = Data(count: 32)
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        let accessToken = "raft_installation_" + base64url(raw)
        installationTokens.append(InstallationToken(
            tokenHash: sha256(accessToken),
            installationId: installation.id,
            clientId: client.id,
            serverId: installation.serverId,
            grantRevision: installation.grantRevision,
            groups: groups,
            audience: "raft:app-installation-api",
            expiresAt: Date().addingTimeInterval(10 * 60)
        ))
        lock.unlock()
        let groupJSON = groups.map { jsonString($0) }.joined(separator: ",")
        let document = "{\"access_token\":\(jsonString(accessToken)),\"token_type\":\"Bearer\",\"expires_in\":600,\"installation_id\":\(jsonString(installation.id)),\"server_id\":\(jsonString(installation.serverId)),\"grant_revision\":\(installation.grantRevision),\"groups\":[\(groupJSON)],\"audience\":\"raft:app-installation-api\"}"
        return json(200, document, cacheControl: "private, no-store")
    }

    /// `GET /api/oauth/userinfo`. Only principal access tokens resolve; an App
    /// installation credential is not a principal and stays 401.
    public func userinfo(authorization: String?, baseURL: String, scopeServerId: String? = nil) -> HTTPReply {
        guard let raw = bearerToken(authorization) else {
            return json(401, "{\"error\":\"Missing bearer token\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let token = principalTokenLocked(raw),
              let client = clients.first(where: { $0.id == token.clientId }),
              isUserManaged(client),
              let server = servers[token.serverId], !server.deleted
        else {
            return json(401, "{\"error\":\"Invalid or expired access token\"}")
        }
        if let scopeServerId, scopeServerId != token.serverId {
            return json(401, "{\"error\":\"Access token was issued for a different Server than this issuer\"}")
        }
        if token.principalType == "agent" {
            guard let agentId = token.agentId,
                  let agent = agents[agentId],
                  agent.serverId == server.id,
                  !agent.deleted,
                  let role = agentRoles["\(server.id)\n\(agentId)"]
            else {
                return json(401, "{\"error\":\"Invalid or expired access token\"}")
            }
            let avatar = agent.avatarUrl
            let avatarJSON = avatar.map { jsonString($0) } ?? "null"
            let pictureJSON = agentPicture(avatar: avatar, baseURL: baseURL).map { jsonString($0) } ?? "null"
            let descriptionJSON = agent.description.map { jsonString($0) } ?? "null"
            let document = "{\"scope\":\(jsonString(token.scopes.joined(separator: " "))),\"client_id\":\(jsonString(client.clientId)),\"client_name\":\(jsonString(client.name)),\"server_id\":\(jsonString(server.id)),\"server_slug\":\(jsonString(server.slug)),\"sub\":\(jsonString(agent.id)),\"type\":\"agent\",\"server_role\":\(jsonString(role)),\"preferred_username\":\(jsonString(agent.name)),\"name\":\(jsonString(agent.displayName)),\"avatar_url\":\(avatarJSON),\"picture\":\(pictureJSON),\"description\":\(descriptionJSON)}"
            return json(200, document)
        }
        guard let request = requests.first(where: { $0.id == token.requestId }),
              let role = members["\(token.serverId)\n\(token.userId)"]
        else {
            return json(401, "{\"error\":\"Invalid or expired access token\"}")
        }
        let avatar = request.humanAvatarUrl
        let avatarJSON = avatar.map { jsonString($0) } ?? "null"
        let pictureJSON = userinfoPicture(avatar: avatar, baseURL: baseURL).map { jsonString($0) } ?? "null"
        var document = "{\"scope\":\(jsonString(token.scopes.joined(separator: " "))),\"client_id\":\(jsonString(client.clientId)),\"client_name\":\(jsonString(client.name)),\"server_id\":\(jsonString(server.id)),\"server_slug\":\(jsonString(server.slug)),\"sub\":\(jsonString(token.userId)),\"type\":\"human\",\"server_role\":\(jsonString(role)),\"preferred_username\":\(jsonString(request.humanName)),\"name\":\(jsonString(request.humanName)),\"avatar_url\":\(avatarJSON),\"picture\":\(pictureJSON),\"description\":null"
        if token.scopes.contains("email"), !request.humanEmail.isEmpty {
            document += ",\"email\":\(jsonString(request.humanEmail)),\"email_verified\":\(request.humanEmailVerified ? "true" : "false")"
        }
        document += "}"
        return json(200, document)
    }

    /// Only a Raft-uploaded user avatar becomes a picture URL.
    private func userinfoPicture(avatar: String?, baseURL: String) -> String? {
        guard let avatar,
              avatar.wholeMatch(of: /^(?i)\/(?:api\/)?avatars\/users\/[0-9a-f]+\.webp$/) != nil
        else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + avatar
    }

    private func agentPicture(avatar: String?, baseURL: String) -> String? {
        guard let avatar else { return nil }
        if avatar.hasPrefix("pixel:") {
            let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            return base + "/api/avatars/pixel/\(Self.pixelAvatarKey(avatar)).svg"
        }
        return absolutePicture(avatar, baseURL: baseURL)
    }

    /// `GET /api/oauth/serverinfo`. The token names the Server; a query cannot
    /// redirect the read. Fields come from the live Server row.
    public func serverinfo(authorization: String?, baseURL: String, scopeServerId: String? = nil) -> HTTPReply {
        guard let raw = bearerToken(authorization) else {
            return json(401, "{\"error\":\"Missing bearer token\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let token = principalTokenLocked(raw),
              let client = clients.first(where: { $0.id == token.clientId }),
              isUserManaged(client),
              let server = servers[token.serverId], !server.deleted
        else {
            return json(401, "{\"error\":\"Invalid or expired access token\"}")
        }
        if let scopeServerId, scopeServerId != token.serverId {
            return json(401, "{\"error\":\"Access token was issued for a different Server than this issuer\"}")
        }
        if token.principalType == "agent" {
            guard let agentId = token.agentId,
                  let agent = agents[agentId],
                  agent.serverId == server.id,
                  !agent.deleted
            else {
                return json(401, "{\"error\":\"Invalid or expired access token\"}")
            }
        } else {
            guard members["\(token.serverId)\n\(token.userId)"] != nil else {
                return json(401, "{\"error\":\"Invalid or expired access token\"}")
            }
        }
        let avatarJSON = server.avatarUrl.map { jsonString($0) } ?? "null"
        let pictureJSON = absolutePicture(server.avatarUrl, baseURL: baseURL).map { jsonString($0) } ?? "null"
        let paid = server.plan != "free"
        let document = "{\"id\":\(jsonString(server.id)),\"slug\":\(jsonString(server.slug)),\"name\":\(jsonString(server.name)),\"avatar_url\":\(avatarJSON),\"picture\":\(pictureJSON),\"is_paid\":\(paid ? "true" : "false"),\"plan_tier\":\(jsonString(paid ? "paid" : "free"))}"
        return json(200, document)
    }

    private func absolutePicture(_ path: String?, baseURL: String) -> String? {
        guard let path else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        guard path.hasPrefix("/") else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + path
    }

    /// `GET /api/oauth/agents`. Directory authority is the `agent:read` login
    /// scope, never an installation credential.
    /// Resolves an `/oidc/:server` segment by id or slug.
    public func serverScopeId(_ segment: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return servers.values.first(where: {
            ($0.id == segment || $0.slug == segment) && !$0.deleted
        })?.id
    }

    public func agentDirectory(authorization: String?, baseURL: String, scopeServerId: String? = nil) -> HTTPReply {
        guard let raw = bearerToken(authorization) else {
            return json(401, "{\"error\":\"Missing bearer token\"}", cacheControl: "no-store")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let token = principalTokenLocked(raw),
              let client = clients.first(where: { $0.id == token.clientId }),
              isUserManaged(client),
              let server = servers[token.serverId], !server.deleted
        else {
            return json(401, "{\"error\":\"Invalid or expired access token\"}", cacheControl: "no-store")
        }
        guard client.enabled, token.scopes.contains("agent:read") else {
            return json(403, "{\"error\":\"agent:read permission is required from an enabled App\"}", cacheControl: "no-store")
        }
        if let scopeServerId, scopeServerId != token.serverId {
            return json(401, "{\"error\":\"Access token was issued for a different Server than this issuer\"}", cacheControl: "no-store")
        }
        if token.principalType == "agent" {
            guard let agentId = token.agentId,
                  let agent = agents[agentId], !agent.deleted,
                  agentRoles["\(server.id)\n\(agentId)"] != nil
            else {
                return json(401, "{\"error\":\"Invalid or expired access token\"}", cacheControl: "no-store")
            }
        } else {
            guard members["\(server.id)\n\(token.userId)"] != nil else {
                return json(401, "{\"error\":\"Invalid or expired access token\"}", cacheControl: "no-store")
            }
        }
        let entries = agents.values
            .filter { $0.serverId == server.id && !$0.deleted }
            .sorted { $0.name < $1.name }
            .map { agent -> String in
                let avatarJSON = agent.avatarUrl.map { jsonString($0) } ?? "null"
                let pictureJSON = agentPicture(avatar: agent.avatarUrl, baseURL: baseURL).map { jsonString($0) } ?? "null"
                return "{\"id\":\(jsonString(agent.id)),\"handle\":\(jsonString(agent.name)),\"display_name\":\(jsonString(agent.displayName)),\"avatar_url\":\(avatarJSON),\"picture\":\(pictureJSON)}"
            }
            .joined(separator: ",")
        return json(200, "{\"agents\":[\(entries)]}", cacheControl: "no-store")
    }

    /// `GET /api/oauth/authorize`. The browser flow hands off to the web app
    /// after shape checks; the setup page owns client lookup.
    public func browserAuthorize(query: String, appURL: String, serverScope: String? = nil) -> HTTPReply {
        let params = queryParameters(query)
        func invalidRequest(_ message: String) -> HTTPReply {
            json(400, "{\"error\":\"invalid_request\",\"error_description\":\(jsonString(message))}")
        }
        if serverScope == nil, let legacyServer = params["server"], !legacyServer.isEmpty {
            return invalidRequest("The server query parameter is no longer supported; use the /oidc/<server> mount")
        }
        guard params["response_type"] == "code" else { return invalidRequest("response_type must be code") }
        let clientKey = (params["client_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientKey.isEmpty else { return invalidRequest("client_id is required") }
        let redirectURI = params["redirect_uri"] ?? ""
        guard !redirectURI.isEmpty, !redirectURI.contains("#"), let redirectURL = URLComponents(string: redirectURI),
              let redirectScheme = redirectURL.scheme?.lowercased(), redirectScheme == "https" || redirectScheme == "http"
        else { return invalidRequest("redirect_uri is invalid") }
        let scopeText = (params["scope"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scopeText.isEmpty else { return invalidRequest("scope is required") }
        let challenge = params["code_challenge"] ?? ""
        if !challenge.isEmpty {
            guard challenge.wholeMatch(of: /^[A-Za-z0-9_-]{43}$/) != nil else {
                return invalidRequest("code_challenge must be a SHA-256 challenge")
            }
            guard params["code_challenge_method"] == "S256" else {
                return invalidRequest("code_challenge_method must be S256")
            }
        }
        let nonce = params["nonce"] ?? ""
        guard nonce.utf8.count <= 512 else { return invalidRequest("nonce is too long") }
        var components = URLComponents(string: appURL.hasSuffix("/") ? String(appURL.dropLast()) : appURL)
        let basePath = components?.path ?? ""
        components?.path = basePath + "/login-with-raft/setup"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "flow", value: "oidc"),
            URLQueryItem(name: "client_id", value: clientKey),
            URLQueryItem(name: "return_to", value: redirectURI),
            URLQueryItem(name: "scope", value: scopeText),
        ]
        if let state = params["state"], !state.isEmpty { items.append(URLQueryItem(name: "state", value: state)) }
        if !nonce.isEmpty { items.append(URLQueryItem(name: "nonce", value: nonce)) }
        if !challenge.isEmpty {
            items.append(URLQueryItem(name: "code_challenge", value: challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        if let serverScope, !serverScope.isEmpty {
            items.append(URLQueryItem(name: "server", value: serverScope))
        }
        components?.queryItems = items
        guard let location = components?.string else {
            return json(503, "{\"error\":\"oidc_not_configured\"}")
        }
        return json(302, "", extraHeaders: ["Location": location])
    }

    private func queryParameters(_ query: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let rawName = parts.first ?? ""
            let rawValue = parts.count > 1 ? parts[1] : ""
            let name = (rawName.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawName)
            let value = (rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue)
            if !name.isEmpty { values[name] = value }
        }
        return values
    }

    /// `GET /api/oauth/jwks`. Public ES256 verification key for the ID tokens.
    public func jwks() -> HTTPReply {
        guard let body = OAuthIDToken.jwks(secret: jwtSecret) else {
            return json(503, "{\"error\":\"oidc_not_configured\"}")
        }
        return json(200, body, cacheControl: "public, max-age=300")
    }

    /// `POST /api/oauth/authorize/human`. A member receives a one-time human code.
    public func issueHumanAuthorization(session: OAuthSession, body: String) -> HTTPReply {
        switch session {
        case .missing:
            return json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        case .invalid:
            return json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        case .user(let human):
            return issueHumanAuthorization(human: human, body: body)
        }
    }

    /// `GET /api/app-installation/server`. A user session is not an App
    /// credential; only an active installation token resolves here.
    public func appInstallationServer(authorization: String?) -> HTTPReply {
        switch installationCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let credential):
            guard credential.groups.contains("server") else {
                return json(403, "{\"error\":\"Installation credential lacks server read authority\"}", cacheControl: "private, no-store")
            }
            lock.lock()
            guard let server = servers[credential.serverId], !server.deleted else {
                lock.unlock()
                return json(404, "{\"error\":\"Server not found\"}", cacheControl: "private, no-store")
            }
            let id = server.id
            let name = server.name
            let slug = server.slug
            lock.unlock()
            let document = "{\"installation_id\":\(jsonString(credential.installationId)),\"server\":{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"slug\":\(jsonString(slug)),\"avatar_url\":null}}"
            return json(200, document, cacheControl: "private, no-store")
        }
    }

    /// `GET /api/app-installation/channels`. The `channel` group is separate
    /// from the `server` group an installation may have approved.
    public func appInstallationChannels(authorization: String?) -> HTTPReply {
        switch installationCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let credential):
            guard credential.groups.contains("channel") else {
                return json(403, "{\"error\":\"Installation credential lacks channel read authority\"}", cacheControl: "private, no-store")
            }
            return json(200, "{\"installation_id\":\(jsonString(credential.installationId)),\"channels\":[]}", cacheControl: "private, no-store")
        }
    }

    /// `POST /api/oauth/installations/lookup`. The authenticated client is the
    /// App boundary; a miss never discloses another App's installation.
    public func installationLookup(authorization: String?, body: String) -> HTTPReply {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        var fields: [String: String] = [:]
        if let value = object?["client_id"] as? String { fields["client_id"] = value }
        if let value = object?["client_secret"] as? String { fields["client_secret"] = value }
        guard let credentials = clientCredentials(authorization: authorization, fields: fields) else {
            return json(401, "{\"error\":\"Client credentials are required\"}", cacheControl: "private, no-store")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId
                && isUserManaged($0)
                && ($0.appType != "third_party_global" || $0.enabled)
                && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            return json(401, "{\"error\":\"Invalid client credentials\"}", cacheControl: "private, no-store")
        }
        let raw = object?["server_id"] ?? object?["serverId"]
        let serverId = (raw as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverId.isEmpty else {
            return json(400, "{\"error\":\"server_id is required\"}", cacheControl: "private, no-store")
        }
        guard serverId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return json(400, "{\"error\":\"server_id must be a Server ID\"}", cacheControl: "private, no-store")
        }
        guard client.enabled else {
            return json(404, "{\"error\":\"Active installation not found\"}", cacheControl: "private, no-store")
        }
        guard let installation = installations.first(where: {
            $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
        }) else {
            return json(404, "{\"error\":\"Active installation not found\"}", cacheControl: "private, no-store")
        }
        let document = "{\"installation_id\":\(jsonString(installation.id)),\"server_id\":\(jsonString(installation.serverId)),\"setup\":{\"status\":\"not_required\",\"url\":null,\"description\":null,\"revision\":1,\"completedAt\":null}}"
        return json(200, document, cacheControl: "private, no-store")
    }

    /// `POST /api/oauth/requests/agent`. A server-local or installed App asks
    /// for an Agent; the owner behind the App may auto-grant.
    public func requestAgentAccess(authorization: String?, body: String) -> HTTPReply {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        var fields: [String: String] = [:]
        if let value = object?["client_id"] as? String { fields["client_id"] = value }
        if let value = object?["clientId"] as? String { fields["clientId"] = value }
        if let value = object?["client_secret"] as? String { fields["client_secret"] = value }
        if let value = object?["clientSecret"] as? String { fields["clientSecret"] = value }
        guard let credentials = clientCredentials(authorization: authorization, fields: fields) else {
            return json(401, "{\"error\":\"Client credentials are required\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId
                && isUserManaged($0)
                && ($0.appType != "third_party_global" || $0.enabled)
                && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            return json(401, "{\"error\":\"Invalid client credentials\"}")
        }
        let serverSlug = (object?["serverSlug"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = servers.values.first(where: { $0.slug == serverSlug && !$0.deleted }) else {
            return json(404, "{\"error\":\"Server not found\"}")
        }
        let agent: Agent?
        if let rawId = object?["agentId"] as? String, !rawId.isEmpty {
            guard rawId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
                return json(404, "{\"error\":\"Agent not found\"}")
            }
            agent = agents[rawId.lowercased()].flatMap { $0.serverId == server.id && !$0.deleted ? $0 : nil }
        } else {
            let agentName = (object?["agentName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            agent = agents.values.first(where: { $0.serverId == server.id && $0.name == agentName && !$0.deleted })
        }
        guard let agent else {
            return json(404, "{\"error\":\"Agent not found\"}")
        }
        let installed = installations.contains(where: {
            $0.clientId == client.id && $0.serverId == server.id && $0.status == "active"
        })
        guard (client.appType == "server_local" && client.serverId == server.id) || installed else {
            return json(404, "{\"error\":\"OAuth client not found for server\"}")
        }
        guard let scopes = normalizeScopes(object?["scopes"], allowed: client.allowedScopes ?? ["openid", "profile", "identity"], clientId: client.clientId) else {
            return json(400, "{\"error\":\"invalid_scope\"}")
        }
        let requestId = UUID().uuidString.lowercased()
        requests.append(AccessRequest(
            id: requestId,
            serverId: server.id,
            userId: client.createdByUserId,
            clientId: client.id,
            scopes: scopes,
            humanName: "",
            humanEmail: "",
            humanEmailVerified: false,
            humanAvatarUrl: nil,
            agentId: agent.id,
            status: "approved",
            createdAt: Date()
        ))
        let scopeJSON = scopes.map { jsonString($0) }.joined(separator: ",")
        let document = "{\"requestId\":\(jsonString(requestId)),\"status\":\"approved\",\"client\":{\"clientId\":\(jsonString(client.clientId)),\"appType\":\(jsonString(client.appType)),\"name\":\(jsonString(client.name)),\"description\":null,\"homepageUrl\":null},\"agent\":{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"serverId\":\(jsonString(server.id)),\"serverSlug\":\(jsonString(server.slug))},\"scopes\":[\(scopeJSON)]}"
        return json(200, document)
    }

    /// `GET /api/oauth/clients/lookup`. A server member reads one App and the
    /// requested scopes it may not ask for.
    public func clientLookup(session: OAuthSession, clientId: String, serverId: String, scope: String) -> HTTPReply {
        switch session {
        case .missing:
            return json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        case .invalid:
            return json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        case .user(let human):
            lock.lock()
            defer { lock.unlock() }
            guard let role = members["\(serverId)\n\(human.id)"] else {
                return json(404, "{\"error\":\"OAuth client not found for server\"}")
            }
            let requested = scope.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let client = clients.first(where: { candidate in
                guard candidate.clientId == clientId, isUserManaged(candidate) else { return false }
                if candidate.appType == "server_local" && candidate.serverId == serverId { return true }
                return installations.contains(where: {
                    $0.clientId == candidate.id && $0.serverId == serverId && $0.status == "active"
                })
            }) {
                let allowed = client.allowedScopes ?? ["openid", "profile", "identity"]
                let validation = validateScopes(requested, allowed: allowed, clientId: client.clientId)
                let allowedJSON = allowed.map { jsonString($0) }.joined(separator: ",")
                let descriptionJSON = client.descriptionText.map { jsonString($0) } ?? "null"
                let homepageJSON = client.homepageUrl.map { jsonString($0) } ?? "null"
                let returnJSON = client.returnUrl.map { jsonString($0) } ?? "null"
                var document = "{\"clientId\":\(jsonString(client.clientId)),\"appType\":\(jsonString(client.appType)),\"name\":\(jsonString(client.name)),\"description\":\(descriptionJSON),\"homepageUrl\":\(homepageJSON),\"returnUrl\":\(returnJSON),\"logoUrl\":null,\"setupUrl\":null,\"setupDescription\":null,\"allowedScopes\":[\(allowedJSON)]"
                if isMarketplaceVisible(client) {
                    document += ",\"marketplace\":true"
                }
                document += ",\"availability\":\"ready\""
                if !requested.isEmpty {
                    let reasonJSON = validation.reason.map { jsonString($0) } ?? "null"
                    let disallowedJSON = validation.disallowed.map { jsonString($0) }.joined(separator: ",")
                    document += ",\"scopeValidation\":{\"allowed\":\(validation.allowed ? "true" : "false"),\"reason\":\(reasonJSON),\"disallowedScopes\":[\(disallowedJSON)]}"
                }
                document += "}"
                return json(200, document)
            }
            guard let published = clients.first(where: {
                $0.clientId == clientId && isUserManaged($0) && isMarketplaceVisible($0)
            }) else {
                return json(404, "{\"error\":\"OAuth client not found for server\"}")
            }
            let allowedJSON = published.allowedScopes.map { scopes in
                "[" + scopes.map { jsonString($0) }.joined(separator: ",") + "]"
            } ?? "null"
            let descriptionJSON = published.descriptionText.map { jsonString($0) } ?? "null"
            let homepageJSON = published.homepageUrl.map { jsonString($0) } ?? "null"
            let returnJSON = published.returnUrl.map { jsonString($0) } ?? "null"
            let canInstall = role == "owner" || role == "admin"
            let document = "{\"id\":\(jsonString(published.id)),\"clientId\":\(jsonString(published.clientId)),\"appType\":\(jsonString(published.appType)),\"name\":\(jsonString(published.name)),\"description\":\(descriptionJSON),\"homepageUrl\":\(homepageJSON),\"returnUrl\":\(returnJSON),\"logoUrl\":null,\"allowedScopes\":\(allowedJSON),\"marketplace\":true,\"availability\":\"install_required\",\"setupUrl\":null,\"setupDescription\":null,\"installation\":{\"serverId\":\(jsonString(serverId)),\"canInstall\":\(canInstall ? "true" : "false")}}"
            return json(200, document)
        }
    }

    /// Seeds a queued event for the duplicate-retry contract.
    public func seedQueuedAgentEvent(
        serverId: String,
        agentId: String,
        clientRecordId: String,
        externalEventId: String
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        agentEvents.append(AgentEvent(
            id: id,
            serverId: serverId,
            agentId: agentId,
            clientId: clientRecordId,
            kind: "event",
            summary: "Queued before delivery failed",
            payloadHash: String(repeating: "0", count: 64),
            externalEventId: externalEventId,
            status: "queued",
            expiresAt: Date().addingTimeInterval(24 * 60 * 60),
            createdAt: Date()
        ))
        lock.unlock()
        return id
    }

    /// `POST /api/oauth/agent-events`. Only a resource-bound agent token with
    /// the matching inbound scope may enqueue an event.
    public func postAgentEvent(authorization: String?, body: String) -> HTTPReply {
        guard let raw = bearerToken(authorization) else {
            return json(401, "{\"error\":\"Missing bearer token\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let token = principalTokenLocked(raw) else {
            return json(401, "{\"error\":\"Invalid or expired access token\"}")
        }
        guard token.principalType == "agent", let agentId = token.agentId else {
            return json(403, "{\"error\":\"agent token required\"}")
        }
        let expectedResource = "urn:raft:server:\(token.serverId):agent-inbound"
        guard token.resource == expectedResource else {
            return json(403, "{\"error\":\"resource-bound token required\",\"resource\":\(jsonString(expectedResource))}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let kind = object?["kind"] as? String ?? ""
        guard kind == "event" || kind == "notification" else {
            return json(400, "{\"error\":\"kind must be event or notification\"}")
        }
        let requiredScope = kind == "event" ? "agent:event:write" : "agent:notification:write"
        guard token.scopes.contains(requiredScope) else {
            return json(403, "{\"error\":\"insufficient_scope\",\"required_scope\":\(jsonString(requiredScope))}")
        }
        let target = (object?["agentId"] as? String ?? object?["agent_id"] as? String ?? agentId).lowercased()
        guard target == agentId else {
            return json(403, "{\"error\":\"token cannot target a different agent\"}")
        }
        let summary = (object?["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 500 else {
            return json(400, "{\"error\":\"summary is required\"}")
        }
        guard let payload = object?["payload"], JSONSerialization.isValidJSONObject(payload) else {
            return json(400, "{\"error\":\"payload must be an object\"}")
        }
        let external = (object?["externalEventId"] as? String ?? object?["external_event_id"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)
        let payloadHash = sha256(payloadJSON)
        let now = Date()
        if let external, !external.isEmpty,
           let index = agentEvents.firstIndex(where: {
               $0.serverId == token.serverId && $0.agentId == agentId
                   && $0.clientId == token.clientId && $0.externalEventId == external
                   && $0.expiresAt > now
           }) {
            var event = agentEvents[index]
            let claimed = event.status == "queued"
            if claimed {
                event.status = "delivering"
                agentEvents[index] = event
            }
            let document = "{\"id\":\(jsonString(event.id)),\"status\":\(jsonString(claimed ? "queued" : "duplicate")),\"deduped\":true,\"expiresAt\":\(jsonString(iso8601(event.expiresAt))),\"payloadHash\":\(jsonString(event.payloadHash))}"
            return json(200, document)
        }
        let event = AgentEvent(
            id: UUID().uuidString.lowercased(),
            serverId: token.serverId,
            agentId: agentId,
            clientId: token.clientId,
            kind: kind,
            summary: summary,
            payloadHash: payloadHash,
            payloadJSON: payloadJSON,
            externalEventId: external,
            status: "delivering",
            expiresAt: now.addingTimeInterval(24 * 60 * 60),
            createdAt: now
        )
        agentEvents.append(event)
        let document = "{\"id\":\(jsonString(event.id)),\"status\":\"queued\",\"deduped\":false,\"expiresAt\":\(jsonString(iso8601(event.expiresAt))),\"payloadHash\":\(jsonString(event.payloadHash))}"
        return json(202, document)
    }

    /// One re-readable third-party event body, scoped to the agent that owns it.
    public struct ThirdPartyEventReadMessage: Sendable {
        public var id: String
        public var kind: String
        public var summary: String
        public var content: String
        public var clientKey: String
        public var clientName: String
        public var externalEventId: String?
        public var payloadHash: String
        public var payloadJSON: String
        public var createdAt: Date
        public var expiresAt: Date
    }

    public enum ThirdPartyEventReadResult: Sendable {
        case found(ThirdPartyEventReadMessage)
        case expired
        case ambiguous
        case absent
    }

    /// `agent-event:<id8 | uuid>`: only ever resolves rows the acting agent owns,
    /// so "not yours" and "does not exist" take the same path.
    public func readThirdPartyAgentEventForAgent(agentId: String, ref rawRef: String) -> ThirdPartyEventReadResult {
        let ref = rawRef.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isFull = ref.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil
        let isShort = ref.wholeMatch(of: /^[0-9a-f]{8}$/) != nil
        guard isFull || isShort else { return .absent }
        lock.lock()
        let matches = agentEvents
            .filter { $0.agentId == agentId && (isFull ? $0.id == ref : $0.id.hasPrefix(ref)) }
            .sorted { $0.createdAt < $1.createdAt }
        lock.unlock()
        if matches.isEmpty { return .absent }
        if matches.count > 1 { return .ambiguous }
        let event = matches[0]
        if event.status == "expired" || event.expiresAt <= Date() {
            return .expired
        }
        lock.lock()
        let client = clients.first(where: { $0.id == event.clientId })
        lock.unlock()
        let clientKey = client?.clientId ?? ""
        let clientName = client?.name ?? ""
        let content = [
            "Third-party \(event.kind): \(event.summary)",
            "",
            "event_id: \(event.id)",
            "payload_hash: \(event.payloadHash)",
            "resource: urn:raft:server:\(event.serverId):agent-inbound",
        ].joined(separator: "\n")
        return .found(ThirdPartyEventReadMessage(
            id: event.id,
            kind: event.kind,
            summary: event.summary,
            content: content,
            clientKey: clientKey,
            clientName: clientName,
            externalEventId: event.externalEventId,
            payloadHash: event.payloadHash,
            payloadJSON: event.payloadJSON,
            createdAt: event.createdAt,
            expiresAt: event.expiresAt
        ))
    }

    public func addThirdPartyAgentEventForTesting(
        id: String,
        serverId: String,
        agentId: String,
        clientRecordId: String,
        kind: String = "notification",
        summary: String,
        payloadJSON: String = "{}",
        expiresAt: Date,
        status: String = "delivered"
    ) {
        lock.lock()
        agentEvents.append(AgentEvent(
            id: id.lowercased(),
            serverId: serverId,
            agentId: agentId,
            clientId: clientRecordId,
            kind: kind,
            summary: summary,
            payloadHash: sha256(payloadJSON),
            payloadJSON: payloadJSON,
            externalEventId: nil,
            status: status,
            expiresAt: expiresAt,
            createdAt: Date()
        ))
        lock.unlock()
    }

    public func pendingThirdPartyEventMessages(agentId: String) -> [ThirdPartyEventMessage] {
        lock.lock()
        defer { lock.unlock() }
        return agentEvents
            .filter { $0.agentId == agentId && $0.status == "delivering" && $0.expiresAt > Date() }
            .map { projectionLocked($0) }
    }

    public func takeThirdPartyEventMessages(agentId: String) -> [ThirdPartyEventMessage] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var messages: [ThirdPartyEventMessage] = []
        for index in agentEvents.indices where
            agentEvents[index].agentId == agentId
                && agentEvents[index].status == "delivering"
                && agentEvents[index].expiresAt > now {
            messages.append(projectionLocked(agentEvents[index]))
            agentEvents[index].status = "delivered"
            agentEvents[index].deliveredAt = now
        }
        return messages
    }

    public func markThirdPartyEventsDelivered(agentId: String, ids: [String]) -> Int {
        let wanted = Set(ids.map { $0.lowercased() })
        guard !wanted.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var delivered = 0
        for index in agentEvents.indices where
            agentEvents[index].agentId == agentId
                && wanted.contains(agentEvents[index].id)
                && agentEvents[index].status != "delivered" {
            agentEvents[index].status = "delivered"
            agentEvents[index].deliveredAt = now
            delivered += 1
        }
        return delivered
    }

    private func projectionLocked(_ event: AgentEvent) -> ThirdPartyEventMessage {
        let client = clients.first(where: { $0.id == event.clientId })
        return ThirdPartyEventMessage(
            id: event.id,
            serverId: event.serverId,
            clientKey: client?.clientId ?? "",
            clientName: client?.name ?? "",
            clientRecordId: event.clientId,
            kind: event.kind,
            summary: event.summary
        )
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// `POST /api/oauth/token`. Form fields, camelCase JSON, and HTTP Basic all name the same client.
    public func exchangeToken(
        authorization: String?,
        body: String,
        issuer: String,
        scopeServerId: String? = nil
    ) -> HTTPReply {
        let fields = tokenFields(body)
        guard let credentials = clientCredentials(authorization: authorization, fields: fields) else {
            return json(401, "{\"error\":\"Client credentials are required\"}")
        }
        let grantType = fields["grantType"] ?? fields["grant_type"] ?? ""
        let verifierPresent = fields["code_verifier"] != nil || jsonBodyHasKey(body, "code_verifier")
        if grantType == "urn:slock:grant-type:agent_request" {
            if verifierPresent {
                return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"This authorization request is not a PKCE request\"}")
            }
            return exchangeAgentRequest(fields: fields, credentials: credentials, scopeServerId: scopeServerId)
        }
        guard grantType == "authorization_code" else {
            return json(400, "{\"error\":\"Unsupported grant type\"}")
        }
        let rawCode = (fields["code"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isOIDC = rawCode.hasPrefix("raft_oidc_")
        if !isOIDC, verifierPresent {
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization code, redirect URI, or PKCE verifier is invalid\"}")
        }
        let code = isOIDC ? rawCode : rawCode.lowercased()
        guard !code.isEmpty else { return json(400, "{\"error\":\"code is required\"}") }
        if !isOIDC {
            guard code.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil else {
                return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}")
            }
        }

        lock.lock()
        guard let client = clients.first(where: { $0.clientId == credentials.clientId && $0.appType != "slock_builtin" && $0.secretHash == sha256(credentials.clientSecret) }) else {
            lock.unlock()
            return json(401, "{\"error\":\"Invalid client credentials\"}")
        }
        guard let index = requests.firstIndex(where: { $0.id == code && $0.clientId == client.id }) else {
            lock.unlock()
            if isOIDC {
                return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}")
            }
            return json(404, "{\"error\":\"Access request not found\"}")
        }
        let request = requests[index]
        if isOIDC {
            guard request.oidc else {
                lock.unlock()
                return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization code, redirect URI, or PKCE verifier is invalid\"}")
            }
            if request.codeChallenge == nil, verifierPresent {
                lock.unlock()
                return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"This authorization request is not a PKCE request\"}")
            }
            if let challenge = request.codeChallenge {
                guard let verifier = fields["code_verifier"], !verifier.isEmpty,
                      challenge == Self.pkceChallenge(verifier)
                else {
                    lock.unlock()
                    return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization code, redirect URI, or PKCE verifier is invalid\"}")
                }
            }
            if let redirect = request.oidcRedirectURI {
                guard fields["redirect_uri"] == redirect else {
                    lock.unlock()
                    return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization code, redirect URI, or PKCE verifier is invalid\"}")
                }
            }
        }
        if let scopeServerId, scopeServerId != request.serverId {
            lock.unlock()
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization was granted for a different Server than this issuer\"}")
        }
        if request.consumedAt != nil {
            lock.unlock()
            if isOIDC {
                return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}")
            }
            return json(409, "{\"error\":\"request_already_consumed\",\"error_description\":\"This Login with Raft request is one-time and has already been exchanged. Discard it and obtain a fresh request before retrying.\",\"next_action\":\"obtain_fresh_request\"}")
        }
        let now = Date()
        if now.timeIntervalSince(request.createdAt) > 10 * 60 {
            lock.unlock()
            if isOIDC {
                return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}")
            }
            return json(400, "{\"error\":\"authorization_code_expired\",\"error_description\":\"This Login with Raft authorization code has expired. Obtain a fresh human authorization before retrying.\",\"next_action\":\"obtain_fresh_authorization\"}")
        }
        guard let server = servers[request.serverId], !server.deleted,
              let role = members["\(request.serverId)\n\(request.userId)"]
        else {
            lock.unlock()
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization identity is no longer available\"}")
        }
        var raw = Data(count: 32)
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        let accessToken = "slock_at_" + raw.map { String(format: "%02x", $0) }.joined()
        let expiresAt = now.addingTimeInterval(60 * 60)
        tokens.append(AccessToken(
            serverId: request.serverId,
            userId: request.userId,
            clientId: client.id,
            requestId: request.id,
            tokenHash: sha256(accessToken),
            scopes: request.scopes,
            expiresAt: expiresAt
        ))
        requests[index].consumedAt = now
        let humanName = request.humanName
        let humanEmail = request.humanEmail
        let scopes = request.scopes
        let clientKey = client.clientId
        let serverId = server.id
        let serverSlug = server.slug
        lock.unlock()

        let expiresIn = max(1, Int(expiresAt.timeIntervalSince(now)))
        let identity = OAuthIdentity(
            sub: request.userId,
            clientId: clientKey,
            scopes: scopes,
            name: humanName,
            email: humanEmail,
            serverId: serverId,
            serverSlug: serverSlug,
            serverRole: role
        )
        let idToken: String
        if scopes.contains("openid") {
            guard let signed = OAuthIDToken.sign(
                identity: identity,
                issuer: issuer,
                expiresIn: expiresIn,
                secret: jwtSecret,
                nonce: isOIDC ? request.nonce : nil
            ) else {
                return json(500, "{\"error\":\"Failed to issue access token\"}")
            }
            idToken = signed
        } else {
            idToken = ""
        }
        let scope = scopes.joined(separator: " ")
        var document = "{\"access_token\":\(jsonString(accessToken)),\"token_type\":\"Bearer\",\"expires_in\":\(expiresIn),\"scope\":\(jsonString(scope))"
        if !idToken.isEmpty { document += ",\"id_token\":\(jsonString(idToken))" }
        document += "}"
        return json(200, document, cacheControl: "no-store")
    }

    private func exchangeAgentRequest(
        fields: [String: String],
        credentials: (clientId: String, clientSecret: String),
        scopeServerId: String? = nil
    ) -> HTTPReply {
        let requestId = (fields["requestId"] ?? fields["request_id"] ?? "").lowercased()
        guard !requestId.isEmpty else {
            return json(400, "{\"error\":\"requestId is required\"}")
        }
        guard requestId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil else {
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId
                && isUserManaged($0)
                && ($0.appType != "third_party_global" || $0.enabled)
                && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            return json(401, "{\"error\":\"Invalid client credentials\"}")
        }
        guard let index = requests.firstIndex(where: { $0.id == requestId && $0.clientId == client.id && $0.agentId != nil }) else {
            return json(404, "{\"error\":\"Access request not found\"}")
        }
        let request = requests[index]
        if let scopeServerId, scopeServerId != request.serverId {
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization was granted for a different Server than this issuer\"}")
        }
        if request.consumedAt != nil {
            return json(409, "{\"error\":\"request_already_consumed\",\"error_description\":\"This Login with Raft request is one-time and has already been exchanged. Discard it and obtain a fresh request before retrying.\",\"next_action\":\"obtain_fresh_request\"}")
        }
        guard request.status == "approved" else {
            return json(400, "{\"error\":\"authorization_pending\"}")
        }
        guard let agentId = request.agentId, let agent = agents[agentId], !agent.deleted else {
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization identity is no longer available\"}")
        }
        let resource = fields["resource"].flatMap { $0.isEmpty ? nil : $0 }
        let requiresResource = request.scopes.contains(where: {
            ["agent:event:write", "agent:notification:write", "agent:action_request:write"].contains($0)
        })
        let boundResource: String?
        if requiresResource {
            guard let resource else {
                return json(400, "{\"error\":\"resource is required for requested scopes\"}")
            }
            guard resource == "urn:raft:server:\(request.serverId):agent-inbound" else {
                return json(400, "{\"error\":\"resource does not match requested server\"}")
            }
            boundResource = resource
        } else {
            boundResource = resource
        }
        var raw = Data(count: 32)
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        let accessToken = "slock_at_" + raw.map { String(format: "%02x", $0) }.joined()
        let now = Date()
        tokens.append(AccessToken(
            serverId: request.serverId,
            userId: request.userId,
            clientId: client.id,
            requestId: request.id,
            tokenHash: sha256(accessToken),
            scopes: request.scopes,
            expiresAt: now.addingTimeInterval(60 * 60),
            principalType: "agent",
            agentId: agent.id,
            resource: boundResource
        ))
        requests[index].consumedAt = now
        let scope = request.scopes.joined(separator: " ")
        var document = "{\"access_token\":\(jsonString(accessToken)),\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\(jsonString(scope))"
        if let boundResource {
            document += ",\"resource\":\(jsonString(boundResource))"
        }
        document += "}"
        return json(200, document, cacheControl: "no-store")
    }

    private func issueHumanAuthorization(human: OAuthHuman, body: String) -> HTTPReply {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        guard let clientKey = object?["clientId"] as? String, !clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return json(400, "{\"error\":\"clientId is required\"}")
        }
        guard let serverId = object?["serverId"] as? String, !serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return json(400, "{\"error\":\"serverId is required\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { candidate in
            guard candidate.clientId == clientKey.trimmingCharacters(in: .whitespacesAndNewlines),
                  isUserManaged(candidate)
            else { return false }
            if candidate.appType == "server_local" && candidate.serverId == serverId { return true }
            return candidate.appType == "third_party_global" && installations.contains(where: {
                $0.clientId == candidate.id && $0.serverId == serverId && $0.status == "active"
            })
        }) else {
            return json(404, "{\"error\":\"OAuth client not found for server\"}")
        }
        let requested = object?["scopes"]
        let oidc = (object?["oidc"] as? Bool) ?? false
        var nonce: String?
        var challenge: String?
        if oidc {
            if let hint = object?["server"] as? String, !hint.isEmpty {
                guard let hinted = servers.values.first(where: { ($0.id == hint || $0.slug == hint) && !$0.deleted }),
                      hinted.id == serverId
                else {
                    return json(400, "{\"error\":\"server does not match the selected Server\"}")
                }
            }
            nonce = object?["nonce"] as? String
            if let nonce, nonce.utf8.count > 512 {
                return json(400, "{\"error\":\"invalid_request\"}")
            }
            challenge = object?["codeChallenge"] as? String
            if let challenge {
                guard challenge.wholeMatch(of: /^[A-Za-z0-9_-]{43}$/) != nil,
                      (object?["codeChallengeMethod"] as? String) == "S256"
                else {
                    return json(400, "{\"error\":\"invalid_request\"}")
                }
            }
        }
        let scopes: [String]
        if requested == nil || requested is NSNull {
            scopes = ["openid", "profile"]
        } else {
            let validation = validateScopes(requested, allowed: client.allowedScopes ?? ["openid", "profile", "identity"], clientId: client.clientId)
            guard validation.allowed, !validation.scopes.isEmpty else {
                if validation.disallowed.isEmpty {
                    return json(400, "{\"error\":\"invalid_scope\"}")
                }
                return scopeError(validation)
            }
            scopes = validation.scopes.sorted()
        }
        if let requestedReturnURL = (object?["returnUrl"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            guard client.returnUrl == requestedReturnURL, Self.isSafeReturnURL(requestedReturnURL) else {
                return json(400, "{\"error\":\"returnUrl is not allowed\"}")
            }
        }
        guard let server = servers[serverId], !server.deleted, let role = members["\(serverId)\n\(human.id)"] else {
            return json(404, "{\"error\":\"User is not a member of this server\"}")
        }
        let code: String
        if oidc {
            var raw = Data(count: 24)
            for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
            code = "raft_oidc_" + base64url(raw)
        } else {
            code = UUID().uuidString.lowercased()
        }
        requests.append(AccessRequest(
            id: code,
            serverId: serverId,
            userId: human.id,
            clientId: client.id,
            scopes: scopes,
            humanName: human.name,
            humanEmail: human.email,
            humanEmailVerified: human.emailVerified,
            humanAvatarUrl: human.avatarUrl,
            oidc: oidc,
            nonce: nonce,
            codeChallenge: challenge,
            oidcRedirectURI: oidc ? client.returnUrl : nil,
            createdAt: Date()
        ))
        let scopeJSON = scopes.map { jsonString($0) }.joined(separator: ",")
        let returnJSON = client.returnUrl.map { jsonString($0) } ?? "null"
        let document = "{\"code\":\(jsonString(code)),\"client\":{\"clientId\":\(jsonString(client.clientId)),\"appType\":\(jsonString(client.appType)),\"name\":\(jsonString(client.name)),\"description\":null,\"homepageUrl\":null},\"server\":{\"id\":\(jsonString(server.id)),\"slug\":\(jsonString(server.slug)),\"role\":\(jsonString(role))},\"scopes\":[\(scopeJSON)],\"returnUrl\":\(returnJSON)}"
        return json(200, document)
    }

    private struct ScopeValidation {
        var scopes: [String]
        var allowed: Bool
        var reason: String?
        var disallowed: [String]
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private func validateScopes(_ value: Any?, allowed: [String], clientId: String) -> ScopeValidation {
        let rawList: [Any]
        if let list = value as? [String] {
            rawList = list
        } else if let list = value as? [Any] {
            rawList = list
        } else {
            return ScopeValidation(scopes: [], allowed: false, reason: nil, disallowed: [])
        }
        var seen = Set<String>()
        var scopes: [String] = []
        var unsupported = false
        var notAllowed = false
        var disallowed: [String] = []
        for item in rawList {
            guard let text = item as? String else {
                return ScopeValidation(scopes: [], allowed: false, reason: nil, disallowed: [])
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            if Self.legacyScopeAllowlist[clientId]?.contains(trimmed) == true {
                scopes.append(trimmed)
                continue
            }
            if !Self.raftScopes.contains(trimmed) {
                unsupported = true
                disallowed.append(trimmed)
                continue
            }
            if !allowed.contains(trimmed) {
                notAllowed = true
                disallowed.append(trimmed)
                continue
            }
            scopes.append(trimmed)
        }
        let reason: String?
        if unsupported && notAllowed {
            reason = "mixed"
        } else if unsupported {
            reason = "unsupported"
        } else if notAllowed {
            reason = "not_allowed"
        } else {
            reason = nil
        }
        return ScopeValidation(scopes: scopes, allowed: disallowed.isEmpty, reason: reason, disallowed: disallowed)
    }

    private func scopeError(_ validation: ScopeValidation) -> HTTPReply {
        let scopeList = validation.disallowed.joined(separator: ", ")
        let code: String
        let description: String
        switch validation.reason {
        case "unsupported":
            code = "OAUTH_SCOPE_UNSUPPORTED"
            description = "Raft does not support the requested OAuth scope: \(scopeList). Update the requested scopes and try again."
        case "not_allowed":
            code = "OAUTH_SCOPE_NOT_ALLOWED"
            description = "This OAuth client is not allowed to request: \(scopeList). Update the client's allowed scopes and try again."
        default:
            code = "OAUTH_SCOPE_INVALID"
            description = "Some requested OAuth scopes are unsupported or not allowed for this client: \(scopeList). Update the requested scopes or client permissions and try again."
        }
        let disallowedJSON = validation.disallowed.map { jsonString($0) }.joined(separator: ",")
        return json(400, "{\"error\":\"invalid_scope\",\"errorCode\":\(jsonString(code)),\"error_description\":\(jsonString(description)),\"disallowedScopes\":[\(disallowedJSON)]}")
    }

    private func normalizeScopes(_ value: Any?, allowed: [String], clientId: String) -> [String]? {
        let validation = validateScopes(value, allowed: allowed, clientId: clientId)
        guard validation.allowed, !validation.scopes.isEmpty else { return nil }
        return validation.scopes.sorted()
    }

    private static let raftScopes: Set<String> = [
        "openid", "profile", "email", "identity", "agent:read",
        "agent:event:write", "agent:notification:write", "agent:action_request:write",
    ]

    /// Exact legacy tuples still accepted for their original client only.
    private static let legacyScopeAllowlist: [String: Set<String>] = [
        "local-collabdoc-1": ["creator", "owner"],
        "linkerdog-796e47": ["meetings:read"],
        "winbox": [
            "winbox:opencli:google", "winbox:opencli:nga",
            "winbox:opencli:qixin", "winbox:opencli:twitter",
        ],
        "winbox-315c18": [
            "winbox:opencli:nga", "winbox:opencli:qixin", "winbox:opencli:slock",
            "winbox:opencli:twitter", "winbox:opencli:wcl", "winbox:python:exec",
        ],
    ]

    private func bearerToken(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    /// Caller holds `lock`. Installation tokens live in a different table and never match.
    private func principalTokenLocked(_ raw: String) -> AccessToken? {
        let hash = sha256(raw)
        guard let token = tokens.last(where: { $0.tokenHash == hash }),
              token.expiresAt > Date(),
              token.revokedAt == nil
        else {
            return nil
        }
        if token.principalType == "agent", revokedGrantClients.contains(token.clientId) {
            return nil
        }
        return token
    }

    private func installationCredential(_ authorization: String?) -> InstallationCredentialResult {
        guard let raw = bearerToken(authorization) else {
            return .failure(json(401, "{\"error\":\"Installation bearer token is required\"}"))
        }
        lock.lock()
        defer { lock.unlock() }
        guard let credential = installationCredentialLocked(raw) else {
            return .failure(json(401, "{\"error\":\"Invalid, expired, or stale installation credential\"}"))
        }
        return .success(credential)
    }

    private enum InstallationCredentialResult {
        case failure(HTTPReply)
        case success(VerifiedInstallationCredential)
    }

    /// Caller holds `lock`. Rechecks the live App class, installation status,
    /// grant revision, and that the token's groups are still granted.
    private func installationCredentialLocked(_ raw: String) -> VerifiedInstallationCredential? {
        guard raw.hasPrefix("raft_installation_") else { return nil }
        guard let record = installationTokens.last(where: { $0.tokenHash == sha256(raw) }),
              record.expiresAt > Date(),
              record.audience == "raft:app-installation-api"
        else {
            return nil
        }
        guard let installation = installations.first(where: { $0.id == record.installationId }),
              installation.status == "active",
              installation.clientId == record.clientId,
              installation.serverId == record.serverId,
              installation.grantRevision == record.grantRevision
        else {
            return nil
        }
        guard let client = clients.first(where: { $0.id == record.clientId }),
              isUserManaged(client),
              client.enabled
        else {
            return nil
        }
        let currentGroups = client.outboundGroups.filter { installation.approvedGroups.contains($0) }
        guard record.groups.allSatisfy({ currentGroups.contains($0) }) else { return nil }
        return VerifiedInstallationCredential(
            installationId: installation.id,
            clientId: client.id,
            serverId: installation.serverId,
            groups: record.groups
        )
    }

    private struct VerifiedInstallationCredential {
        var installationId: String
        var clientId: String
        var serverId: String
        var groups: [String]
    }

    private func clientCredentials(authorization: String?, fields: [String: String]) -> (clientId: String, clientSecret: String)? {
        if let authorization, authorization.hasPrefix("Basic ") {
            let encoded = String(authorization.dropFirst("Basic ".count))
            if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8),
               let separator = decoded.firstIndex(of: ":"), separator != decoded.startIndex {
                return (String(decoded[..<separator]), String(decoded[decoded.index(after: separator)...]))
            }
        }
        let clientId = fields["client_id"] ?? fields["clientId"]
        let clientSecret = fields["client_secret"] ?? fields["clientSecret"]
        if let clientId, let clientSecret, !clientId.isEmpty, !clientSecret.isEmpty {
            return (clientId, clientSecret)
        }
        return nil
    }

    /// Presence matters even when the JSON value is null or not a string.
    private func jsonBodyHasKey(_ body: String, _ key: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return false
        }
        return object[key] != nil
    }

    private func tokenFields(_ body: String) -> [String: String] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            var fields: [String: String] = [:]
            for (key, value) in object {
                if let text = value as? String { fields[key] = text }
            }
            if object["code_verifier"] != nil { fields["code_verifier"] = fields["code_verifier"] ?? "" }
            return fields
        }
        var fields: [String: String] = [:]
        for part in trimmed.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = formDecode(pieces.first ?? "")
            let value = formDecode(pieces.count > 1 ? pieces[1] : "")
            if !name.isEmpty { fields[name] = value }
        }
        return fields
    }

    private func formDecode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    private struct Server {
        var id: String
        var slug: String
        var name: String
        var ownerId: String = ""
        var avatarUrl: String? = nil
        var plan: String = "free"
        var deleted = false
        var productAnalyticsEnabled = true
        var translationEnabled = false
        var publiclyVisible = false
        var publicGuestJoinEnabled = false
    }

    private struct Agent {
        var id: String
        var serverId: String
        var name: String
        var displayName: String
        var avatarUrl: String?
        var description: String?
        var creatorUserId: String? = nil
        var runtime: String = "managed"
        var runtimeConfigJSON: String? = nil
        var envVarsJSON: String? = nil
        var deleted = false
    }

    private struct AgentEvent {
        var id: String
        var serverId: String
        var agentId: String
        var clientId: String
        var kind: String
        var summary: String
        var payloadHash: String
        var payloadJSON: String = "{}"
        var externalEventId: String?
        var status: String
        var expiresAt: Date
        var createdAt: Date
        var deliveredAt: Date? = nil
    }

    private struct Client {
        var id: String
        var serverId: String
        var clientId: String
        var secretHash: String
        var appType: String
        var name: String
        var createdByUserId: String
        var descriptionText: String? = nil
        var homepageUrl: String? = nil
        var returnUrl: String? = nil
        var allowedScopes: [String]? = nil
        var outboundGroups: [String] = []
        var pendingOutboundRevisionId: String? = nil
        var pendingOutboundGroups: [String] = []
        /// Legacy App-level switch. Built-in issuance ignores it; the column
        /// survives only for old web bundles.
        var agentJwtEnabled: Bool? = false
        var enabled: Bool = true
        var externalProvider: String? = nil
        var externalState: String? = nil
        var publishStatus: String = "draft"
        var humanMarketplaceVisible: Bool = false
        var agentManifestUrl: String? = nil
        var agentManifestUrlSource: String? = nil
        var whenToUse: String? = nil
    }

    public func addClientMaintainer(clientRecordId: String, agentId: String, role: String = "owner") {
        guard role == "owner" else { return }
        lock.lock()
        clientMaintainerOwners[clientRecordId, default: []].insert(agentId)
        lock.unlock()
    }

    public func isClientMaintainerOwner(clientRecordId: String, agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clientMaintainerOwners[clientRecordId]?.contains(agentId) == true
    }

    public func installationId(serverId: String, clientRecordId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return installations.first {
            $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
        }?.id
    }

    /// The agent-facing projection of Apps this agent may manage: every
    /// user-managed app of the Server for an admin agent, otherwise only the
    /// ones this agent owns. Installation ids never cross the Server boundary.
    public func ownedIntegrationApps(serverId: String, agentId: String, admin: Bool) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return clients.filter { client in
            guard client.serverId == serverId, isUserManaged(client),
                  client.appType == "server_local" || client.appType == "third_party_global"
            else { return false }
            return admin || clientMaintainerOwners[client.id]?.contains(agentId) == true
        }.map { client in
            integrationAppProjection(client, serverId: serverId, admin: admin)
        }
    }

    public func ownedIntegrationApp(serverId: String, agentId: String, clientKey: String, admin: Bool) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { candidate in
            candidate.serverId == serverId
                && (candidate.clientId == clientKey || candidate.id == clientKey)
                && isUserManaged(candidate)
                && (candidate.appType == "server_local" || candidate.appType == "third_party_global")
        }) else { return nil }
        guard admin || clientMaintainerOwners[client.id]?.contains(agentId) == true else { return nil }
        return integrationAppProjection(client, serverId: serverId, admin: admin)
    }

    private func integrationAppProjection(_ client: Client, serverId: String, admin: Bool) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = formatter.string(from: Date())
        let installation: Any = installations.first {
            $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
        }?.id ?? NSNull()
        return [
            "state": "committed",
            "card": NSNull(),
            "installationId": installation,
            "name": client.name,
            "clientKey": client.clientId,
            "createdAt": now,
            "updatedAt": now,
            "description": client.descriptionText as Any,
            "homepageUrl": client.homepageUrl as Any,
            "callbackUrl": client.returnUrl as Any,
            "agentManifestUrl": client.agentManifestUrl as Any,
            "scopes": client.allowedScopes ?? [],
            "category": "Other",
            "dataAccessSummary": NSNull(),
            "logoUrl": NSNull(),
            "appType": client.appType,
            "publishStatus": client.publishStatus,
            "enabled": client.enabled,
            "authority": admin ? "admin" : "owner",
            "recoveryCommand": "raft integration app rotate-secret --client \(client.clientId) --output <new-private-path>",
        ]
    }

    /// An App that declares no manifest still points agents at its own
    /// well-known document, derived from the homepage origin.
    private static func wellKnownAgentManifestUrl(homepageUrl: String?) -> String? {
        guard let homepageUrl,
              let components = URLComponents(string: homepageUrl),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return "https://\(host)/.well-known/raft-agent-manifest.json"
    }

    private func manifestFields(_ client: Client) -> (url: Any, source: Any) {
        if let url = client.agentManifestUrl, !url.isEmpty {
            return (url, client.agentManifestUrlSource ?? "explicit")
        }
        if let derived = Self.wellKnownAgentManifestUrl(homepageUrl: client.homepageUrl) {
            return (derived, "well_known")
        }
        return (NSNull(), NSNull())
    }

    /// Mirrors `oauthClientIsUserManagedPredicate`: the tombstone class and
    /// any platform registration both remove installation authority.
    private func isUserManaged(_ client: Client) -> Bool {
        client.appType != "slock_builtin" && client.externalProvider == nil
    }

    private static func isSafeReturnURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { return false }
        if scheme == "https" { return true }
        if scheme == "http" {
            return ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        }
        return false
    }

    private func isMarketplaceVisible(_ client: Client) -> Bool {
        client.appType == "third_party_global"
            && client.enabled
            && client.publishStatus == "published"
            && client.humanMarketplaceVisible
    }

    public func marketplaceClients(serverId: String, query: String?) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clients.filter { client in
            guard isMarketplaceVisible(client) else { return false }
            guard !needle.isEmpty else { return true }
            return client.name.lowercased().contains(needle)
                || (client.descriptionText ?? "").lowercased().contains(needle)
                || client.clientId.lowercased().contains(needle)
        }.map { client in
            [
                "id": client.id,
                "clientId": client.clientId,
                "name": client.name,
                "description": client.descriptionText as Any,
                "homepageUrl": client.homepageUrl as Any,
                "allowedScopes": client.allowedScopes ?? ["openid", "profile", "identity"],
                "installedOnServer": installations.contains {
                    $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
                },
            ]
        }
    }

    private struct InstallationToken {
        var tokenHash: String
        var installationId: String
        var clientId: String
        var serverId: String
        var grantRevision: Int
        var groups: [String]
        var audience: String
        var expiresAt: Date
    }

    private struct Installation {
        var id: String
        var serverId: String
        var clientId: String
        var installedByUserId: String
        var approvedGroups: [String]
        var grantRevision: Int
        var status: String
        /// Legacy installation-level switch, ignored by issuance.
        var agentJwtEnabled: Bool? = false
    }

    private struct AccessRequest {
        var id: String
        var serverId: String
        var userId: String
        var clientId: String
        var scopes: [String]
        var humanName: String
        var humanEmail: String
        var humanEmailVerified: Bool
        var humanAvatarUrl: String?
        var agentId: String? = nil
        var status: String = "approved"
        var oidc: Bool = false
        var nonce: String? = nil
        var codeChallenge: String? = nil
        var oidcRedirectURI: String? = nil
        var createdAt: Date
        var consumedAt: Date? = nil
    }

    private struct AccessToken {
        var serverId: String
        var userId: String
        var clientId: String
        var requestId: String
        var tokenHash: String
        var scopes: [String]
        var expiresAt: Date
        var principalType: String = "human"
        var agentId: String? = nil
        var resource: String? = nil
        var revokedAt: Date? = nil
    }

    private func json(
        _ status: Int,
        _ body: String,
        cacheControl: String? = nil,
        extraHeaders: [String: String] = [:]
    ) -> HTTPReply {
        var headers = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ]
        if let cacheControl { headers["Cache-Control"] = cacheControl }
        for (name, value) in extraHeaders { headers[name] = value }
        return HTTPReply(status: status, headers: headers, body: body)
    }
}

private struct OAuthIdentity {
    var sub: String
    var clientId: String
    var scopes: [String]
    var name: String
    var email: String
    var serverId: String
    var serverSlug: String
    var serverRole: String
}

private enum OAuthIDToken {
    static func signAgentAudience(
        agentId: String,
        agentName: String,
        clientKey: String,
        serverId: String,
        serverSlug: String,
        issuer: String,
        secret: String,
        ttl: Int = 300
    ) -> (token: String, jti: String, issuedAt: Int)? {
        guard !secret.isEmpty, let privateKey = signingKey(secret: secret) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let jti = UUID().uuidString.lowercased()
        let kidValue = kid(secret: secret) ?? ""
        let login = "raft-agent-\(agentId)"
        let header = "{\"alg\":\"ES256\",\"typ\":\"at+jwt\",\"kid\":\(jsonString(kidValue))}"
        let payload = "{\"iss\":\(jsonString(issuer)),\"aud\":\(jsonString(clientKey)),\"sub\":\(jsonString(agentId)),\"server_id\":\(jsonString(serverId)),\"server_slug\":\(jsonString(serverSlug)),\"type\":\"agent\",\"token_use\":\"agent_access\",\"login\":\(jsonString(login)),\"preferred_username\":\(jsonString(agentName)),\"iat\":\(now),\"nbf\":\(now),\"exp\":\(now + ttl),\"jti\":\(jsonString(jti))}"
        let signingInput = "\(base64url(Data(header.utf8))).\(base64url(Data(payload.utf8)))"
        guard let signature = try? privateKey.signature(for: Data(signingInput.utf8)) else { return nil }
        return ("\(signingInput).\(base64url(signature.rawRepresentation))", jti, now)
    }

    static func kid(secret: String) -> String? {
        guard let key = signingKey(secret: secret) else { return nil }
        return base64url(Data(SHA256.hash(data: key.publicKey.x963Representation).prefix(16)))
    }

    static func sign(
        identity: OAuthIdentity,
        issuer: String,
        expiresIn: Int,
        secret: String,
        nonce: String? = nil
    ) -> String? {
        guard !secret.isEmpty, let privateKey = signingKey(secret: secret) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        var payload = "{\"iss\":\(jsonString(issuer)),\"sub\":\(jsonString(identity.sub)),\"aud\":\(jsonString(identity.clientId)),\"iat\":\(now),\"exp\":\(now + expiresIn)"
        if let nonce, !nonce.isEmpty {
            payload += ",\"nonce\":\(jsonString(nonce))"
        }
        if identity.scopes.contains("profile"), !identity.name.isEmpty {
            payload += ",\"name\":\(jsonString(identity.name)),\"preferred_username\":\(jsonString(identity.name))"
        }
        if identity.scopes.contains("email"), !identity.email.isEmpty {
            payload += ",\"email\":\(jsonString(identity.email)),\"email_verified\":true"
        }
        payload += ",\"type\":\"human\",\"server_id\":\(jsonString(identity.serverId)),\"server_slug\":\(jsonString(identity.serverSlug)),\"server_role\":\(jsonString(identity.serverRole))}"
        let publicBytes = privateKey.publicKey.x963Representation
        let kid = base64url(Data(SHA256.hash(data: publicBytes).prefix(16)))
        let header = "{\"alg\":\"ES256\",\"typ\":\"JWT\",\"kid\":\(jsonString(kid))}"
        let signingInput = "\(base64url(Data(header.utf8))).\(base64url(Data(payload.utf8)))"
        guard let signature = try? privateKey.signature(for: Data(signingInput.utf8)) else { return nil }
        return "\(signingInput).\(base64url(signature.rawRepresentation))"
    }

    static func jwks(secret: String) -> String? {
        guard !secret.isEmpty, let key = signingKey(secret: secret) else { return nil }
        let publicBytes = key.publicKey.x963Representation
        guard publicBytes.count == 65, publicBytes.first == 0x04 else { return nil }
        let x = base64url(Data(publicBytes[1..<33]))
        let y = base64url(Data(publicBytes[33..<65]))
        let kid = base64url(Data(SHA256.hash(data: publicBytes).prefix(16)))
        return "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"use\":\"sig\",\"alg\":\"ES256\",\"kid\":\(jsonString(kid)),\"x\":\(jsonString(x)),\"y\":\(jsonString(y))}]}"
    }

    private static func signingKey(secret: String) -> P256.Signing.PrivateKey? {
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data("raft-oidc-v1".utf8),
            info: Data("id-token-es256-private".utf8),
            outputByteCount: 32
        )
        let seedBytes: [UInt8] = seed.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt8.self))
        }
        let scalar = p256Scalar(seedBytes)
        return try? P256.Signing.PrivateKey(rawRepresentation: scalar)
    }

    /// `(seed mod (n-1)) + 1`, matching the Node P-256 reduction.
    private static func p256Scalar(_ seed: [UInt8]) -> Data {
        let modulus = hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550")
        var reduced = seed
        if compare(reduced, modulus) >= 0 {
            reduced = subtract(reduced, modulus)
        }
        return Data(addOne(reduced))
    }

    private static func hex(_ value: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    private static func compare(_ left: [UInt8], _ right: [UInt8]) -> Int {
        for (lhs, rhs) in zip(left, right) where lhs != rhs {
            return lhs < rhs ? -1 : 1
        }
        return 0
    }

    private static func subtract(_ value: [UInt8], _ modulus: [UInt8]) -> [UInt8] {
        var result = value
        var borrow = 0
        for index in stride(from: result.count - 1, through: 0, by: -1) {
            let diff = Int(result[index]) - Int(modulus[index]) - borrow
            if diff < 0 {
                result[index] = UInt8(diff + 256)
                borrow = 1
            } else {
                result[index] = UInt8(diff)
                borrow = 0
            }
        }
        return result
    }

    private static func addOne(_ value: [UInt8]) -> [UInt8] {
        var result = value
        var carry = 1
        for index in stride(from: result.count - 1, through: 0, by: -1) {
            let sum = Int(result[index]) + carry
            result[index] = UInt8(sum & 0xff)
            carry = sum >> 8
            if carry == 0 { break }
        }
        return result
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
