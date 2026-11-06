import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public func addOwnedServer(id: String, slug: String, name: String, ownerId: String) {
        self.state.withLock { ledgerState in
            ledgerState.servers[id] = Server(id: id, slug: slug, name: name, ownerId: ownerId)
            ledgerState.members["\(id)\n\(ownerId)"] = "owner"
            let allId = UUID().uuidString.lowercased()
            ledgerState.channelRecords.append(ChannelRecord(id: allId, serverId: id, name: "all", type: "channel"))
            ledgerState.channelHumans.insert("\(allId)\n\(ownerId)")
        }
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
        return self.state.withLock { ledgerState in
            return ledgerState.servers.values.first { $0.slug == slug && !$0.deleted }?.id
        }
    }

    public func serverProfile(id: String) -> ServerProfile? {
        return self.state.withLock { ledgerState in
            guard let server = ledgerState.servers[id], !server.deleted else { return nil }
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
    }

    public func setServerProfile(
        id: String,
        avatarUrl: String?,
        plan: String,
        translationEnabled: Bool,
        publiclyVisible: Bool,
        publicGuestJoinEnabled: Bool
    ) {
        self.state.withLock { ledgerState in
            if ledgerState.servers[id] != nil {
                ledgerState.servers[id]?.avatarUrl = avatarUrl
                ledgerState.servers[id]?.plan = plan
                ledgerState.servers[id]?.translationEnabled = translationEnabled
                ledgerState.servers[id]?.publiclyVisible = publiclyVisible
                ledgerState.servers[id]?.publicGuestJoinEnabled = publicGuestJoinEnabled
            }
        }
    }

    public func serverIdsForMember(userId: String) -> [String] {
        return self.state.withLock { ledgerState in
            return ledgerState.members.keys.compactMap { key -> String? in
                let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1] == userId else { return nil }
                guard let server = ledgerState.servers[parts[0]], !server.deleted else { return nil }
                return parts[0]
            }
        }
    }
    public func updateServerName(id: String, name: String) {
        self.state.withLock { ledgerState in
            if var server = ledgerState.servers[id] {
                server.name = name
                ledgerState.servers[id] = server
            }
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
        return self.state.withLock { ledgerState in
            var records = ledgerState.serverAgreementRecords[serverId] ?? []
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
            ledgerState.serverAgreementRecords[serverId] = records
            return record
        }
    }

    public func activeServerAgreement(serverId: String) -> ServerAgreementInfo? {
        return self.state.withLock { ledgerState in
            return ledgerState.serverAgreementRecords[serverId]?.last(where: { $0.enabled })
        }
    }

    public func isServerPushMuted(serverId: String, userId: String) -> Bool {
        return self.state.withLock { ledgerState in
            return ledgerState.serverPushMutes.contains("\(serverId)\n\(userId)")
        }
    }

    public func setServerPushMuted(serverId: String, userId: String, muted: Bool) {
        self.state.withLock { ledgerState in
            if muted {
                ledgerState.serverPushMutes.insert("\(serverId)\n\(userId)")
            } else {
                ledgerState.serverPushMutes.remove("\(serverId)\n\(userId)")
            }
        }
    }

    public func serverAgreementVersions(serverId: String) -> [ServerAgreementInfo] {
        return self.state.withLock { ledgerState in
            return ledgerState.serverAgreementRecords[serverId] ?? []
        }
    }
    public func addMember(serverId: String, userId: String, role: String) {
        self.state.withLock { ledgerState in
            ledgerState.members["\(serverId)\n\(userId)"] = role
        }
    }

    public func memberIdsWithRoles(serverId: String) -> [(id: String, role: String)] {
        return self.state.withLock { ledgerState in
            return ledgerState.members.compactMap { key, role -> (String, String)? in
                let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == serverId else { return nil }
                guard let server = ledgerState.servers[serverId], !server.deleted else { return nil }
                return (parts[1], role)
            }.sorted { $0.0 < $1.0 }
        }
    }

    public func memberIds(serverId: String) -> [String] {
        return self.state.withLock { ledgerState in
            return ledgerState.members.keys.compactMap { key -> String? in
                let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == serverId else { return nil }
                guard let server = ledgerState.servers[serverId], !server.deleted else { return nil }
                return parts[1]
            }.sorted()
        }
    }

    public func activeAgentIds(serverId: String) -> [String] {
        return self.state.withLock { ledgerState in
            return ledgerState.agents.values
                .filter { $0.serverId == serverId && !$0.deleted }
                .map { $0.id }
                .sorted()
        }
    }

    public func ownerCount(serverId: String) -> Int {
        return self.state.withLock { ledgerState in
            return ledgerState.members.filter { key, role in
                key.hasPrefix("\(serverId)\n") && role == "owner"
            }.count
        }
    }

    public func removeMember(serverId: String, userId: String) {
        _ = self.state.withLock { ledgerState in
            ledgerState.members.removeValue(forKey: "\(serverId)\n\(userId)")
        }
    }

    public func setServerAvatar(id: String, avatarUrl: String?) {
        self.state.withLock { ledgerState in
            ledgerState.servers[id]?.avatarUrl = avatarUrl
        }
    }

    public func updateServer(id: String, name: String, avatarUrl: String?) {
        self.state.withLock { ledgerState in
            if var server = ledgerState.servers[id] {
                server.name = name
                server.avatarUrl = avatarUrl
                ledgerState.servers[id] = server
            }
        }
    }

    public func serverDetailsValue(id: String) -> (slug: String, name: String)? {
        return self.state.withLock { ledgerState in
            guard let server = ledgerState.servers[id], !server.deleted else { return nil }
            return (server.slug, server.name)
        }
    }

    public func setServerTranslationEnabled(id: String, enabled: Bool) {
        self.state.withLock { ledgerState in
            ledgerState.servers[id]?.translationEnabled = enabled
        }
    }

    public func setServerProductAnalytics(id: String, enabled: Bool) {
        self.state.withLock { ledgerState in
            ledgerState.servers[id]?.productAnalyticsEnabled = enabled
        }
    }

    /// nil means the Server does not exist.
    public func serverAnalyticsAllowed(id: String) -> Bool? {
        return self.state.withLock { ledgerState in
            guard let server = ledgerState.servers[id], !server.deleted else { return nil }
            return server.productAnalyticsEnabled
        }
    }

    public func setServerPlan(id: String, plan: String) {
        self.state.withLock { ledgerState in
            if var server = ledgerState.servers[id] {
                server.plan = plan
                ledgerState.servers[id] = server
            }
        }
    }

    public func deleteServer(id: String) {
        self.state.withLock { ledgerState in
            if var server = ledgerState.servers[id] {
                server.deleted = true
                ledgerState.servers[id] = server
            }
        }
    }
    public func memberRoles(serverId: String) -> [(userId: String, role: String)] {
        return self.state.withLock { ledgerState in
            let prefix = "\(serverId)\n"
            return ledgerState.members.compactMap { key, role in
                guard key.hasPrefix(prefix) else { return nil }
                return (String(key.dropFirst(prefix.count)), role)
            }.sorted { $0.userId < $1.userId }
        }
    }

    public func memberRole(serverId: String, userId: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.members["\(serverId)\n\(userId)"]
        }
    }
}
