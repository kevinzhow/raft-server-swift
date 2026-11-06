import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public func addOwnedServer(id: String, slug: String, name: String, ownerId: String) {
        lock.lock()
        servers[id] = Server(id: id, slug: slug, name: name, ownerId: ownerId)
        members["\(id)\n\(ownerId)"] = "owner"
        let allId = UUID().uuidString.lowercased()
        channelRecords.append(ChannelRecord(id: allId, serverId: id, name: "all", type: "channel"))
        channelHumans.insert("\(allId)\n\(ownerId)")
        lock.unlock()
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
    public func updateServerName(id: String, name: String) {
        lock.lock()
        if var server = servers[id] {
            server.name = name
            servers[id] = server
        }
        lock.unlock()
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
    public func memberRoles(serverId: String) -> [(userId: String, role: String)] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(serverId)\n"
        return members.compactMap { key, role in
            guard key.hasPrefix(prefix) else { return nil }
            return (String(key.dropFirst(prefix.count)), role)
        }.sorted { $0.userId < $1.userId }
    }

    public func memberRole(serverId: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return members["\(serverId)\n\(userId)"]
    }
}
