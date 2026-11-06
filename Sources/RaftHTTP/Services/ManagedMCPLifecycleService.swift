import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Read mutations, provider connections and push registration lifecycle.
/// Migrated verbatim from the second half of `EmailLogin+ManagedMCP3.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ManagedMCPLifecycleService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {
    public func conversationReadAll(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = sidebarReadAllEnabled
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil,
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let hasAccess = postableChannels[channelId]?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: channelId).contains(userId)
            || oauth.channelType(id: channelId) == "channel"
        guard hasAccess else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        var scopeIds = [channelId]
        for (_, follow) in threadFollows where follow.userId == userId && follow.parentMessageId != "" {
            guard let parentRow = humanMessageRows.first(where: { $0.id == follow.parentMessageId }),
                  parentRow.channelId == channelId
            else { continue }
            if !scopeIds.contains(follow.threadChannelId) { scopeIds.append(follow.threadChannelId) }
        }
        let rows = scopeIds.map { scope -> String in
            let latest = humanMessageRows.filter { $0.channelId == scope }.map(\.seq).max() ?? 0
            let key = "\(userId)\n\(scope)"
            let previous = userChannelReadCursors[key] ?? 0
            let version = previous + 1
            userChannelReadCursors[key] = max(previous, latest)
            return "{\"scopeId\":\(jsonString(scope)),\"maxReadSeq\":\(latest),\"readStateVersion\":\(version)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"serverId\":\(jsonString(serverId)),\"scopes\":[\(rows)]}")
    }

    public func postReadMutation(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let mutationId = object["mutationId"] as? String,
              ServerScope.isUUID(mutationId)
        else {
            return Self.json(400, "{\"error\":\"Invalid mutation id\",\"code\":\"INVALID_MUTATION_ID\"}")
        }
        guard mutationId != "00000000-0000-1000-8000-000000000000" else {
            return Self.json(400, "{\"error\":\"Invalid mutation id\",\"code\":\"INVALID_MUTATION_ID\"}")
        }
        guard let rawKind = object["kind"] as? String else {
            return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
        }
        let rawScope = (object["scopeId"] as? String).flatMap { ServerScope.isUUID($0) ? $0 : nil }
        let rawThrough = (object["throughSeq"] as? NSNumber)?.stringValue ?? (object["throughSeq"] as? String)
        let fingerprint = "\(rawKind):\(rawScope ?? ""):\(rawThrough ?? "")"
        let key = "\(serverId)\n\(userId)\n\(mutationId)"
        lock.lock()
        if let existing = readMutationRecords[key] {
            guard existing.fingerprint == fingerprint else {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Mutation id reused with a different payload\",\"code\":\"MUTATION_ID_PAYLOAD_MISMATCH\"}")
            }
            let cursor = userChannelReadCursors["\(userId)\n\(existing.scopeId ?? "")"] ?? 0
            lock.unlock()
            if existing.kind == "channel_read_all", cursor > 0 {
                return Self.json(200, "{\"outcome\":\"ALREADY_TERMINAL\",\"ack\":{\"terminalReason\":\"completed\",\"capturedBoundary\":[{\"scopeId\":\(jsonString(existing.scopeId ?? "")),\"throughSeq\":\(cursor)}],\"scopes\":[{\"scopeId\":\(jsonString(existing.scopeId ?? "")),\"maxReadSeq\":\(cursor)}]}}")
            }
            return Self.json(200, "{\"outcome\":\"ALREADY_ADMITTED\"}")
        }
        lock.unlock()
        guard rawKind == "global_read_all" || rawKind == "channel_read_all" else {
            return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
        }
        var scopeId: String?
        if rawKind == "channel_read_all" {
            guard let rawScope else {
                return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
            }
            guard let channelType = oauth.channelType(id: rawScope), oauth.channelInfo(id: rawScope) != nil else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            lock.lock()
            let hasOwnedCursor = userChannelReadCursors["\(userId)\n\(rawScope)"] != nil
            let visible = postableChannels[rawScope]?.memberIds.contains(userId) == true
                || oauth.channelHumanIds(channelId: rawScope).contains(userId)
                || (channelType == "channel" && oauth.memberRole(serverId: serverId, userId: userId) != nil)
                || (hasOwnedCursor && oauth.memberRole(serverId: serverId, userId: userId) != nil)
            lock.unlock()
            guard visible else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            scopeId = rawScope
        }
        lock.lock()
        let sequenceKey = "\(serverId)\n\(userId)"
        let seq = (readMutationAuthoritySeq[sequenceKey] ?? 0) + 1
        readMutationAuthoritySeq[sequenceKey] = seq
        readMutationRecords[key] = ReadMutationRecord(
            mutationId: mutationId, serverId: serverId, principalId: userId,
            kind: rawKind, scopeId: scopeId, fingerprint: fingerprint,
            authoritySeq: seq, state: "admitted"
        )
        readMutationOrder.append(key)
        lock.unlock()
        return Self.json(201, "{\"outcome\":\"ADMITTED\",\"serverId\":\(jsonString(serverId)),\"principalId\":\(jsonString(userId)),\"authoritySeq\":\(seq),\"mutationId\":\(jsonString(mutationId))}")
    }

    public func readMutationFrontier(authorization: String?, scopeIds: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let sequences = readMutationAuthoritySeq.filter { $0.key.hasSuffix("\n\(userId)") || $0.key.contains("\n\(userId)") }
        let upper = sequences.values.max() ?? 0
        let keys = readMutationOrder.filter { readMutationRecords[$0]?.principalId == userId }
        let records = keys.compactMap { readMutationRecords[$0] }
        var lastTerminal = 0
        let items = records.map { record -> String in
            if record.state != "admitted" { lastTerminal = max(lastTerminal, record.authoritySeq) }
            return "{\"mutationId\":\(jsonString(record.mutationId)),\"authoritySeq\":\(record.authoritySeq),\"state\":\(jsonString(record.state))}"
        }.joined(separator: ",")
        var scopesJSON: String?
        if let scopeIds {
            let rows = scopeIds.split(separator: ",").map(String.init).map { scope -> String in
                let cursor = userChannelReadCursors["\(userId)\n\(scope)"] ?? 0
                return "{\"scopeId\":\(jsonString(scope)),\"maxReadSeq\":\(cursor)}"
            }.joined(separator: ",")
            scopesJSON = "[\("\(rows)")]"
        }
        lock.unlock()
        let scopesField = scopesJSON.map { ",\"scopes\":\($0)" } ?? ""
        return Self.json(200, "{\"nextAuthoritySeq\":\(upper + 1),\"lastTerminalAuthoritySeq\":\(lastTerminal),\"snapshotUpperAuthoritySeq\":\(upper),\"items\":[\(items)]\(scopesField)}")
    }


    public func acceptJointChannelInvite(authorization: String?, inviteId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = jointInvites.firstIndex(where: { $0.id == inviteId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Invite not found\"}")
        }
        let invite = jointInvites[index]
        lock.unlock()
        guard oauth.memberRole(serverId: invite.targetServerId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        oauth.addChannelHuman(channelId: invite.targetChannelId, userId: userId)
        lock.lock()
        jointInvites[index].status = "accepted"
        postableChannels[invite.targetChannelId]?.memberIds.insert(userId)
        let channel = postableChannels[invite.targetChannelId]
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(invite.targetChannelId)),\"name\":\(jsonString(channel?.name ?? "")),\"type\":\"joint\",\"joined\":true}")
    }

    public func listChannels(authorization: String?, serverId: String, archived: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let guestVisibleSnapshot = guestVisibleChannels
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: archived == "include")
            .filter { archived == "include" || oauth.channelArchivedAt(id: $0.id) == nil }
            .filter { role != "guest" || (guestVisibleSnapshot[$0.id] ?? true) }
            .map { channel -> String in
            let last = channel.lastMessageAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
            let muteSeq = channel.muteFromSeq.map(String.init) ?? "null"
            let archivedAt = oauth.channelArchivedAt(id: channel.id).map { jsonString(formatter.string(from: $0)) } ?? "null"
            let displayPrefs = oauth.channelDisplayPrefs(channelId: channel.id, userId: userId)
            lock.lock()
            let localRole = channelHumanRoles["\(channel.id)\n\(userId)"]
            let isJoint = jointProjections.contains { $0.localChannelId == channel.id }
            lock.unlock()
            let serverAdmin = role == "owner" || role == "admin"
            let capability = localRole == "admin" || serverAdmin
            let basis: String? = localRole == "admin" ? "channel_role" : (serverAdmin ? "server_role" : nil)
            let channelRole = basis == nil ? "member" : "admin"
            let caps = "{\"editChannelMetadata\":\(capability),\"archiveChannels\":\(capability && !isJoint),\"addChannelMembers\":\(capability && !isJoint),\"removeChannelMembers\":\(capability && !isJoint),\"changeChannelMemberRoles\":\(capability),\"manageGuestAccess\":\(serverAdmin && !isJoint),\"deleteChannels\":\(serverAdmin),\"changeChannelVisibility\":\(serverAdmin),\"federateChannels\":\(serverAdmin)}"
            return "{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(channel.type)),\"joined\":\(channel.name == "all" || channel.joined),\"archivedAt\":\(archivedAt),\"lastMessageAt\":\(last),\"activityMuted\":\(channel.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(channel.prefsVersion),\"activityMuteSupported\":\(channel.type == "channel"),\"collapseLongMessages\":\(displayPrefs.collapseLongMessages),\"displayPrefsVersion\":\(displayPrefs.prefsVersion),\"channelRole\":\(jsonString(channelRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"channelCapabilities\":\(caps)}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func completeProfile(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String,
              let rawDisplay = object["displayName"] as? String
        else {
            return Self.json(400, "{\"error\":\"name and displayName are required\",\"code\":\"PROFILE_SETUP_INVALID\"}")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !displayName.isEmpty else {
            return Self.json(400, "{\"error\":\"name and displayName are required\",\"code\":\"PROFILE_SETUP_INVALID\"}")
        }
        let lowered = name.lowercased()
        if lowered.hasPrefix("pending_") || Self.reservedAgentNames.contains(lowered) {
            return Self.json(400, "{\"error\":\"This username is reserved. Choose another name.\",\"code\":\"PROFILE_SETUP_NAME_RESERVED\"}")
        }
        lock.lock()
        guard let key = accounts.first(where: { $0.value.id == userId })?.key, var account = accounts[key] else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if let completedAt = account.profileSetupCompletedAt {
            let replay = account.name == name && (account.displayName ?? account.name) == displayName
            lock.unlock()
            if replay {
                let user = Self.userJSON(accounts[key] ?? account)
                return Self.json(200, "{\"name\":\(jsonString(account.name)),\"displayName\":\(jsonString(account.displayName ?? account.name)),\"profileSetupCompletedAt\":\(jsonString(Self.isoString(completedAt))),\"user\":\(user)}")
            }
            return Self.json(409, "{\"error\":\"Profile setup is already completed\",\"code\":\"PROFILE_SETUP_ALREADY_COMPLETED\"}")
        }
        let taken = Set(accounts.values.filter { $0.id != userId }.map { $0.name.lowercased() })
        guard !taken.contains(lowered) else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"That username is taken\",\"code\":\"PROFILE_SETUP_NAME_TAKEN\"}")
        }
        account.name = name
        account.displayName = displayName
        account.profileSetupCompletedAt = Date()
        accounts[key] = account
        lock.unlock()
        let completed = account.profileSetupCompletedAt ?? Date()
        let user = Self.userJSON(account)
        return Self.json(200, "{\"name\":\(jsonString(name)),\"displayName\":\(jsonString(displayName)),\"profileSetupCompletedAt\":\(jsonString(Self.isoString(completed))),\"user\":\(user)}")
    }

    public func createServer(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let profileSetupPending = accounts.values.first { $0.id == userId }.map {
            $0.emailVerified && $0.profileSetupCompletedAt == nil
        } ?? false
        lock.unlock()
        if profileSetupPending {
            return Self.json(403, "{\"error\":\"Profile setup required\",\"code\":\"PROFILE_SETUP_REQUIRED\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String,
              let rawSlug = object["slug"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid server request\"}")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !slug.isEmpty else {
            return Self.json(400, "{\"error\":\"Invalid server request\"}")
        }
        if let existing = oauth.serverIdForSlug(slug) {
            if let profile = oauth.serverProfile(id: existing), let role = oauth.memberRole(serverId: existing, userId: userId) {
                return Self.json(200, "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"role\":\(jsonString(role))}")
            }
            return Self.json(409, "{\"error\":\"Slug is already taken\"}")
        }
        guard slug.count >= 5 else {
            return Self.json(400, "{\"error\":\"Slug must be at least 5 characters\"}")
        }
        let serverId = UUID().uuidString.lowercased()
        oauth.addOwnedServer(id: serverId, slug: slug, name: name, ownerId: userId)
        return Self.json(200, "{\"id\":\(jsonString(serverId)),\"name\":\(jsonString(name)),\"slug\":\(jsonString(slug)),\"role\":\"owner\"}")
    }

    public func serverProductAnalyticsSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let enabled = oauth.serverAnalyticsAllowed(id: serverId) ?? true
        let canManage = role == "owner" || role == "admin"
        return Self.json(200, "{\"productAnalyticsEnabled\":\(enabled),\"canManageProductAnalytics\":\(canManage)}")
    }

    public func patchServerProductAnalyticsSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["productAnalyticsEnabled"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"productAnalyticsEnabled must be a boolean\"}")
        }
        oauth.setServerProductAnalytics(id: serverId, enabled: enabled)
        return Self.json(200, "{\"productAnalyticsEnabled\":\(enabled),\"canManageProductAnalytics\":true}")
    }

    public func serverDetails(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let profile = oauth.serverProfile(id: serverId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        if role == "guest" {
            return Self.json(200, "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":null}")
        }
        let avatar = profile.avatarUrl.map { jsonString($0) } ?? "null"
        let body = "{\"id\":\(jsonString(profile.id)),\"ownerId\":\(jsonString(profile.ownerId)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":\(avatar),\"plan\":\(jsonString(profile.plan)),\"translationEnabled\":\(profile.translationEnabled),\"publiclyVisible\":\(profile.publiclyVisible),\"publicGuestJoinEnabled\":\(profile.publicGuestJoinEnabled)}"
        return Self.json(200, body)
    }

    public func setProviderConnectionsEnabled(serverId: String, enabled: Bool) {
        lock.lock()
        if enabled {
            providerConnectionsEnabledServers.insert(serverId)
        } else {
            providerConnectionsEnabledServers.remove(serverId)
        }
        lock.unlock()
    }

    public static let providerConnectionProviderIds = [
        "deepseek", "minimax", "minimax-cn", "zai", "zai-coding-cn", "moonshotai",
        "moonshotai-cn", "kimi-coding", "qwen-token-plan", "qwen-token-plan-cn",
        "openrouter", "openai", "anthropic", "google", "xai", "xiaomi",
        "openai-compatible", "anthropic-compatible",
    ]

    public func listProviderConnections(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = providerConnections.filter { $0.serverId == serverId }
        lock.unlock()
        let connections = rows.map { Self.providerConnectionJSON($0) }.joined(separator: ",")
        let options = Self.providerConnectionProviderIds.map { id -> String in
            let kind = id.hasSuffix("-compatible") ? "gateway" : "preset"
            return "{\"id\":\(jsonString(id)),\"label\":\(jsonString(Self.providerConnectionLabel(id))),\"providerKind\":\(jsonString(kind))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"connections\":[\(connections)],\"providerOptions\":[\(options)]}")
    }

    public func createProviderConnection(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let providerId = object["providerId"] as? String,
              Self.providerConnectionProviderIds.contains(providerId),
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let allowedKeys: Set<String> = ["name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let now = Date()
        let connection = ProviderConnection(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            providerId: providerId,
            endpointUrl: object["endpointUrl"] as? String,
            supportsImageInput: object["supportsImageInput"] as? Bool ?? false,
            status: "unchecked",
            configVersion: 1,
            credentialVersion: 1,
            hasCredential: true,
            createdAt: now,
            updatedAt: now
        )
        lock.lock()
        providerConnections.append(connection)
        lock.unlock()
        return Self.json(201, Self.providerConnectionJSON(connection))
    }

    public func retiredProviderProbe(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        return Self.json(410, "{\"error\":\"Provider probing is retired\"}")
    }

    public func patchProviderConnection(authorization: String?, serverId: String, connectionId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let allowedKeys: Set<String> = ["name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        if object["apiKey"] != nil, object["providerId"] != nil {
            return Self.json(400, "{\"error\":\"Rotate the credential separately from provider configuration\"}")
        }
        lock.lock()
        guard let index = providerConnections.firstIndex(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        if let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providerConnections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let endpoint = object["endpointUrl"] as? String {
            providerConnections[index].endpointUrl = endpoint
        }
        if let supports = object["supportsImageInput"] as? Bool {
            providerConnections[index].supportsImageInput = supports
        }
        if let apiKey = object["apiKey"] as? String, !apiKey.isEmpty {
            providerConnections[index].credentialVersion += 1
            providerConnections[index].status = "unchecked"
            providerConnections[index].hasCredential = true
        }
        providerConnections[index].updatedAt = Date()
        let updated = providerConnections[index]
        lock.unlock()
        return Self.json(200, Self.providerConnectionJSON(updated))
    }

    public func rotateProviderConnectionCredential(authorization: String?, serverId: String, connectionId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"apiKey is required\"}")
        }
        lock.lock()
        guard let index = providerConnections.firstIndex(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        providerConnections[index].credentialVersion += 1
        providerConnections[index].status = "unchecked"
        providerConnections[index].hasCredential = true
        providerConnections[index].updatedAt = Date()
        let updated = providerConnections[index]
        lock.unlock()
        return Self.json(200, Self.providerConnectionJSON(updated))
    }

    public func pushRegistration(installationId: String, provider: String) -> PushRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return pushRegistrations.first { $0.installationId == installationId && $0.provider == provider }
    }

    public func registerPushDevice(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let installationId = object["installationId"] as? String,
              installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil,
              let provider = object["provider"] as? String, provider == "apns" || provider == "fcm",
              let topic = object["topic"] as? String,
              topic.wholeMatch(of: /^[A-Za-z0-9.-]{1,155}$/) != nil,
              let deviceToken = object["deviceToken"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid push registration\"}")
        }
        let env = object["env"] as? String ?? ""
        if provider == "apns" {
            guard env == "sandbox" || env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._-]{1,256}$/) != nil
            else {
                return Self.json(400, "{\"error\":\"Invalid push registration\"}")
            }
        } else {
            guard env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._:-]{1,4096}$/) != nil
            else {
                return Self.json(400, "{\"error\":\"Invalid push registration\"}")
            }
        }
        let appVersion = object["appVersion"] as? String
        lock.lock()
        let familyId = principal.familyId ?? UUID().uuidString.lowercased()
        if sessionFamilies[familyId] == nil {
            sessionFamilies[familyId] = SessionFamily(userId: principal.userId)
        }
        var nonce = sessionFamilies[familyId]?.revokeCapabilityNonce
        if nonce == nil {
            let minted = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            sessionFamilies[familyId]?.revokeCapabilityNonce = minted
            nonce = minted
        }
        let revokeCapability = "\(familyId).\(nonce ?? "")"
        if let index = pushRegistrations.firstIndex(where: {
            $0.installationId == installationId && $0.provider == provider
        }) {
            pushRegistrations[index].env = env
            pushRegistrations[index].topic = topic
            pushRegistrations[index].deviceToken = deviceToken
            pushRegistrations[index].appVersion = appVersion
            pushRegistrations[index].userId = principal.userId
            pushRegistrations[index].serverId = serverId
            pushRegistrations[index].sessionFamilyId = familyId
            pushRegistrations[index].revokeCapability = revokeCapability
        } else {
            pushRegistrations.append(PushRegistration(
                installationId: installationId,
                provider: provider,
                env: env,
                topic: topic,
                deviceToken: deviceToken,
                appVersion: appVersion,
                userId: principal.userId,
                serverId: serverId,
                sessionFamilyId: familyId,
                revokeCapability: revokeCapability
            ))
        }
        lock.unlock()
        let registration = "{\"installationId\":\(jsonString(installationId)),\"provider\":\(jsonString(provider)),\"env\":\(jsonString(env)),\"topic\":\(jsonString(topic))}"
        return Self.json(200, "{\"revoke_capability\":\(jsonString(revokeCapability)),\"registration\":\(registration)}")
    }

    public func webPushEndpoints(userId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return webPushSubscriptions.filter { $0.userId == userId }.map { $0.endpoint }
    }

    public func recordWebPushSubscription(authorization: String?, body: String) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let endpoint = object["endpoint"] as? String,
              Self.isPublicHTTPSPushEndpoint(endpoint),
              let keys = object["keys"] as? [String: Any],
              let p256dh = keys["p256dh"] as? String, !p256dh.isEmpty,
              let auth = keys["auth"] as? String, !auth.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid push subscription\"}")
        }
        lock.lock()
        if !webPushSubscriptions.contains(where: { $0.userId == principal.userId && $0.endpoint == endpoint }) {
            webPushSubscriptions.append(WebPushSubscription(userId: principal.userId, endpoint: endpoint))
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }


    public func revokePushFamily(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let capability = object["capability"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid capability\"}")
        }
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0].wholeMatch(of: /^[A-Za-z0-9-]+$/) != nil,
              parts[1].wholeMatch(of: /^[A-Za-z0-9]+$/) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid capability\"}")
        }
        lock.lock()
        guard let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key,
              var family = sessionFamilies[familyId]
        else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Capability is no longer valid\"}")
        }
        let now = Date()
        if let revokedAt = family.revokedAt {
            if let retain = family.capabilityRetainUntil, retain > now {
                lock.unlock()
                return Self.json(204, "")
            }
            _ = revokedAt
            lock.unlock()
            return Self.json(403, "{\"error\":\"Capability is no longer valid\"}")
        }
        family.revokedAt = now
        family.revokedReason = "push_family"
        family.capabilityRetainUntil = now.addingTimeInterval(30 * 24 * 60 * 60)
        sessionFamilies[familyId] = family
        let refreshTokens = sessions.filter { $0.value.familyId == familyId }.map { $0.key }
        for token in refreshTokens { sessions.removeValue(forKey: token) }
        let accessTokensToDrop = accessTokenFamilies.filter { $0.value == familyId }.map { $0.key }
        for token in accessTokensToDrop {
            accessTokens.removeValue(forKey: token)
            accessTokenFamilies.removeValue(forKey: token)
        }
        lock.unlock()
        return Self.json(204, "")
    }

    public func pushFamilyStatus(capability: String) -> (revoked: Bool, reason: String?, retainUntil: Date?)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let family = sessionFamilies.values.first(where: { $0.revokeCapabilityNonce == parts[1] }) else {
            return nil
        }
        return (family.revokedAt != nil, family.revokedReason, family.capabilityRetainUntil)
    }

    public func expirePushFamilyCapability(capability: String) {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return }
        lock.lock()
        if let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key {
            sessionFamilies[familyId]?.capabilityRetainUntil = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    public func pushDeliveryStatus(authorization: String?, installationId: String?) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let installationId, installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil else {
            return Self.json(400, "{\"error\":\"Valid installationId is required\"}")
        }
        lock.lock()
        let active = fcmPushAvailable && pushRegistrations.contains {
            $0.installationId == installationId
                && $0.provider == "fcm"
                && $0.userId == principal.userId
        }
        lock.unlock()
        let servers = oauth.serverIdsForMember(userId: principal.userId).sorted()
        let rows = servers.map { "\"\($0)\":{\"fcmActive\":\(active ? "true" : "false")}" }.joined(separator: ",")
        return Self.json(200, "{\"servers\":{\(rows)}}")
    }

    public func unbindPushInstallation(authorization: String?, serverId: String, installationId: String) -> HTTPReply {
        guard pushPrincipal(authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        var unbound = 0
        for index in pushRegistrations.indices where pushRegistrations[index].installationId == installationId {
            pushRegistrations[index].userId = nil
            pushRegistrations[index].serverId = nil
            pushRegistrations[index].sessionFamilyId = nil
            unbound += 1
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"unbound\":\(unbound)}")
    }

    func pushPrincipal(_ authorization: String?) -> (userId: String, familyId: String?)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let userId = accessTokens[token]
        let familyId = accessTokenFamilies[token]
        lock.unlock()
        guard let userId else { return nil }
        return (userId, familyId)
    }

    public func assignAgentToProviderConnection(connectionId: String, serverId: String, agentId: String, computerName: String?) {
        lock.lock()
        providerAssignments.append(ProviderAssignment(
            connectionId: connectionId,
            serverId: serverId,
            agentId: agentId,
            computerName: computerName
        ))
        lock.unlock()
    }

    public func listAssignedProviderAgents(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        var rows: [String] = []
        for assignment in assignments {
            guard let info = oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId) else { continue }
            let computer = assignment.computerName.map { jsonString($0) } ?? "null"
            rows.append("{\"id\":\(jsonString(assignment.agentId)),\"name\":\(jsonString(info.name)),\"displayName\":\(jsonString(info.displayName)),\"runtime\":\(jsonString(info.runtime)),\"status\":\(jsonString(info.status)),\"computerName\":\(computer),\"deleted\":\(info.deleted)}")
        }
        return Self.json(200, "{\"agents\":[\(rows.joined(separator: ","))]}")
    }

}
