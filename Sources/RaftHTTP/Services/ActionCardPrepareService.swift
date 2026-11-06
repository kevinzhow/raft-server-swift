import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Action-card preparation and the agent context / app-config / send surfaces.
/// Migrated verbatim from the first half of `EmailLogin+ActionCards1.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ActionCardPrepareService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    // MARK: - Action cards (`POST /internal/agent-api/prepare-action`, `POST /api/actions/:id/execute`)

    static let appConfigSchemaJSON = "{\"enabled\":{\"type\":\"boolean\"},\"threshold_bytes\":{\"type\":\"integer\",\"minimum\":4096,\"maximum\":1073741824},\"interval_seconds\":{\"type\":\"integer\",\"minimum\":900,\"maximum\":604800}}"

    func appConfigReply(agentId: String, appId: String) -> HTTPReply? {
        guard appId == "system.cleaner" else { return nil }
        lock.lock()
        let revision = appConfigRevisions[agentId]?[appId] ?? 0
        let overrides = appConfigOverrides[agentId]?[appId] ?? [:]
        lock.unlock()
        var effective = Self.appConfigDefaults()
        for (key, value) in overrides {
            effective[key] = value
        }
        let order = ["enabled", "threshold_bytes", "interval_seconds"]
        var overridesJSON: [String] = []
        for key in order {
            guard let value = overrides[key] else { continue }
            overridesJSON.append("\(jsonString(key)):\(Self.appConfigValueJSON(value))")
        }
        var effectiveJSON: [String] = []
        for key in order {
            guard let value = effective[key] else { continue }
            effectiveJSON.append("\(jsonString(key)):\(Self.appConfigValueJSON(value))")
        }
        let body = "{\"appId\":\(jsonString(appId)),\"revision\":\(revision),\"schema\":\(Self.appConfigSchemaJSON),\"defaults\":{\"enabled\":true,\"threshold_bytes\":65536,\"interval_seconds\":3600},\"overrides\":{\(overridesJSON.joined(separator: ","))},\"effective\":{\(effectiveJSON.joined(separator: ","))}}"
        return Self.json(200, body)
    }

    func appConfigError(_ status: Int, error: String, code: String) -> HTTPReply {
        Self.json(status, "{\"error\":\(jsonString(error)),\"errorCode\":\(jsonString(code))}")
    }

    func featureFlagEnabledForServer(_ key: String, serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let flag = featureFlagRecords[key], flag.enabled, !flag.killSwitch else { return false }
        let rules = featureFlagRuleRecords
            .filter { $0.key == key && $0.stage == "server" && $0.values.contains(serverId) }
            .sorted { $0.priority < $1.priority }
        if let rule = rules.first {
            return rule.decision == "allow"
        }
        return flag.defaultEnabled
    }

    func marketplaceReviewerIds() -> Set<String> {
        lock.lock()
        let override = marketplaceReviewerOverride
        lock.unlock()
        if let override { return override }
        let raw = ProcessInfo.processInfo.environment["SLOCK_MARKETPLACE_REVIEWER_USER_IDS"] ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public func integrationMarketplace(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let reviewers = marketplaceReviewerIds()
        let rows = oauth.appPermissionReviewRows(serverId: serverId).map { row -> String in
            let groups = row.pendingGroups.map { jsonString($0) }.joined(separator: ",")
            let revision = row.pendingRevisionId.map(jsonString) ?? "null"
            return "{\"id\":\(jsonString(row.id)),\"clientId\":\(jsonString(row.clientId)),\"name\":\(jsonString(row.name)),\"appNotificationPendingGroups\":[\(groups)],\"appNotificationPendingRevisionId\":\(revision),\"canReviewAppNotifications\":\(reviewers.contains(userId))}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func reviewAppNotificationPermissions(
        authorization: String?,
        serverId: String,
        clientId: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let raw = object["expected_revision_id"] as? String,
              ServerScope.isUUID(raw)
        else {
            return Self.json(400, "{\"error\":\"expected_revision_id must be a revision UUID\",\"code\":\"invalid_expected_revision_id\"}")
        }
        do {
            let groups = try oauth.approveAppOutboundPermission(clientRecordId: clientId, expectedRevisionId: raw)
            let groupsJSON = groups.map { jsonString($0) }.joined(separator: ",")
            return Self.json(200, "{\"ok\":true,\"groups\":[\(groupsJSON)]}")
        } catch OAuthLedger.AppPermissionReviewError.notFound {
            return Self.json(404, "{\"error\":\"App not found\"}")
        } catch {
            return Self.json(409, "{\"error\":\"The permission request changed since it was displayed\",\"code\":\"permission_revision_stale\"}")
        }
    }

    /// `GET /api/integrations/clients/:clientId/agent-jwt`. Read-only state for
    /// web bundles from the previous release.
    public func legacyAppAgentJWTSettings(authorization: String?, serverId: String, clientRecordId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            var reply = Self.json(403, "{\"error\":\"Only server owners and admins can read Agent JWT access\"}")
            reply.headers["Cache-Control"] = "private, no-store"
            return reply
        }
        guard let client = oauth.legacyAgentJWTClient(clientRecordId: clientRecordId) else {
            var reply = Self.json(404, "{\"error\":\"App not found on this Server\"}")
            reply.headers["Cache-Control"] = "private, no-store"
            return reply
        }
        let source = client.serverId == serverId
        let installationStatus = oauth.legacyAgentJWTInstallationStatus(clientRecordId: clientRecordId, serverId: serverId)
        if !source, client.appType != "third_party_global" || installationStatus == nil {
            var reply = Self.json(404, "{\"error\":\"App not found on this Server\"}")
            reply.headers["Cache-Control"] = "private, no-store"
            return reply
        }
        let scopesOK = client.allowedScopes.contains("openid") && client.allowedScopes.contains("profile")
        let installationOK = installationStatus == nil || installationStatus == "active"
        let effective = client.enabled && scopesOK && installationOK
            && (client.appType == "server_local" || installationStatus == "active")
        let scopeValue = source ? "app" : "installation"
        let body = "{\"scope\":\(jsonString(scopeValue)),\"enabled\":true,\"appEnabled\":true,\"effectiveEnabled\":\(effective),\"canEnable\":false,\"audience\":\(jsonString(client.clientKey)),\"expiresIn\":300}"
        var reply = Self.json(200, body)
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    public func refuseLegacyAppAgentJWTWrite() -> HTTPReply {
        var reply = Self.json(410, "{\"error\":\"Agent JWT is built in for every App; there is no setting to change\"}")
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    public func agentContext(authorization: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        guard let server = oauth.serverProfile(id: agent.serverId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        let role = oauth.agentRole(serverId: agent.serverId, agentId: agent.id) ?? "member"
        let external = agent.runtime == "external"
        let capabilities = credential.scopes.sorted().map { jsonString($0) }.joined(separator: ",")
        let description = agent.description.map { jsonString($0) } ?? "null"
        let prompt: String
        if external {
            let displayName = agent.displayName
            let text = """
            # Raft CLI operating guide

            You are "\(displayName)" (@\(agent.name)), an external AI agent in the Raft server "\(server.name)".

            Your server role is \(role). Permission checks always use your current role.

            Initial role: \(agent.description ?? "No initial role was provided.").

            reminders_unsupported_for_external_agents — external agents cannot create reminders; ask a human instead.
            """
            prompt = "{\"audience\":\"self-hosted-runner\",\"text\":\(jsonString(text))}"
        } else {
            prompt = "null"
        }
        let features = "{\"reminderApp\":\(featureFlagEnabledForServer("reminder_app", serverId: server.id)),\"vaultApp\":\(featureFlagEnabledForServer("vault_app", serverId: server.id))}"
        let assistantJSON: String
        if let owner = assistantOwnerFor(agentId: agent.id, serverId: agent.serverId) {
            assistantJSON = "{\"userId\":\(jsonString(owner))}"
        } else {
            assistantJSON = "null"
        }
        let body = "{\"agent\":{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"description\":\(description),\"runtime\":\(jsonString(agent.runtime)),\"external\":\(external),\"assistantOf\":\(assistantJSON),\"serverRole\":\(jsonString(role))},\"server\":{\"id\":\(jsonString(server.id)),\"slug\":\(jsonString(server.slug)),\"name\":\(jsonString(server.name))},\"credential\":{\"capabilities\":[\(capabilities)]},\"prompt\":\(prompt),\"features\":\(features)}"
        return Self.json(200, body)
    }

    public func agentAppConfig(authorization: String?, appId: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let reply = appConfigReply(agentId: identity.agentId, appId: appId) else {
            return appConfigError(404, error: "Unknown app", code: "RAP_APP_CONFIG_APP_UNKNOWN")
        }
        return reply
    }

    public func patchAgentAppConfig(authorization: String?, appId: String, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("tasks") else {
            return Self.json(403, "{\"error\":\"missing required capability\",\"requiredCapability\":\"tasks\"}")
        }
        guard appId == "system.cleaner" else {
            return appConfigError(404, error: "Unknown app", code: "RAP_APP_CONFIG_APP_UNKNOWN")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let expectedRevision = object["expectedRevision"] as? NSNumber
        else {
            return Self.json(400, "{\"error\":\"Invalid config request\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
        }
        let set = object["set"] as? [String: Any] ?? [:]
        let unset = (object["unset"] as? [Any])?.compactMap { $0 as? String } ?? []
        for (key, value) in set {
            switch key {
            case "enabled":
                guard value is Bool || (value as? NSNumber).map({ String(cString: $0.objCType) == "c" || String(cString: $0.objCType) == "B" }) == true else {
                    return Self.json(400, "{\"error\":\"Invalid value for enabled\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
                }
            case "threshold_bytes", "interval_seconds":
                guard let number = value as? NSNumber,
                      String(cString: number.objCType) != "c", String(cString: number.objCType) != "B"
                else {
                    return Self.json(400, "{\"error\":\"Invalid value for \(key)\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
                }
                let intValue = number.intValue
                if key == "threshold_bytes", intValue < 4096 || intValue > 1_073_741_824 {
                    return Self.json(400, "{\"error\":\"Invalid value for threshold_bytes\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
                }
                if key == "interval_seconds", intValue < 900 || intValue > 604_800 {
                    return Self.json(400, "{\"error\":\"Invalid value for interval_seconds\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
                }
            default:
                return Self.json(400, "{\"error\":\"Unknown config key\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
            }
        }
        for key in unset where !["enabled", "threshold_bytes", "interval_seconds"].contains(key) {
            return Self.json(400, "{\"error\":\"Unknown config key\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
        }
        lock.lock()
        let current = appConfigRevisions[agent.id]?[appId] ?? 0
        guard expectedRevision.intValue == current else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Config revision is stale; current revision is \(current)\",\"errorCode\":\"RAP_APP_CONFIG_REVISION_STALE\",\"currentRevision\":\(current)}")
        }
        var overrides = appConfigOverrides[agent.id]?[appId] ?? [:]
        for (key, value) in set { overrides[key] = value }
        for key in unset { overrides.removeValue(forKey: key) }
        appConfigOverrides[agent.id, default: [:]][appId] = overrides
        appConfigRevisions[agent.id, default: [:]][appId] = current + 1
        lock.unlock()
        return appConfigReply(agentId: agent.id, appId: appId) ?? appConfigError(404, error: "Unknown app", code: "RAP_APP_CONFIG_APP_UNKNOWN")
    }

    /// Callers hold the directory lock.
    func resolveDMPeerLocked(serverId: String, agentId: String, name rawName: String, kind rawKind: String?) -> DMPeerResolution {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = rawKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let kind, kind != "agent", kind != "human" {
            return .invalidKind(kind, name)
        }
        // A migration receipt DM has no peer account: its only member is the
        // migrated agent, and only that agent may name it. Caller holds the lock.
        if kind == nil, name.hasPrefix("migration-receipt-") {
            let owned = postableChannels.first { _, channel in
                channel.kind == "dm" && channel.name == name && channel.memberIds == [agentId]
            }
            guard let owned else { return .notFound }
            return .resolved(peerId: agentId, peerKind: "agent", name: name)
        }
        let humans = accounts.values.filter {
            $0.id != agentId
                && ($0.name.caseInsensitiveCompare(name) == .orderedSame
                    || ($0.displayName ?? "").caseInsensitiveCompare(name) == .orderedSame)
                && oauth.memberRole(serverId: serverId, userId: $0.id) != nil
        }.map(\.id)
        let agents = oauth.serverAgents(serverId: serverId)
            .filter { $0.id != agentId && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map(\.id)
        switch kind {
        case "agent":
            guard let id = agents.first else { return .notFound }
            return .resolved(peerId: id, peerKind: "agent", name: name)
        case "human":
            guard let id = humans.first else { return .notFound }
            return .resolved(peerId: id, peerKind: "human", name: name)
        default:
            if !humans.isEmpty, !agents.isEmpty { return .ambiguous(name) }
            if let id = humans.first { return .resolved(peerId: id, peerKind: "human", name: name) }
            if let id = agents.first { return .resolved(peerId: id, peerKind: "agent", name: name) }
            return .notFound
        }
    }

    /// Callers hold the directory lock.
    func dmChannelIdLocked(serverId: String, agentId: String, peerId: String) -> String? {
        postableChannels.first { _, channel in
            channel.serverId == serverId
                && channel.kind == "dm"
                && channel.deletedAt == nil
                && channel.memberIds.contains(agentId)
                && channel.memberIds.contains(peerId)
        }?.key
    }

    func dmPeerFailure(_ resolution: DMPeerResolution) -> HTTPReply? {
        switch resolution {
        case .ambiguous(let name):
            return Self.json(409, "{\"error\":\"More than one DM peer is named \(name). Address it as dm:@\(name)~agent or dm:@\(name)~human.\",\"code\":\"DM_TARGET_AMBIGUOUS\",\"suggestedNextAction\":\"Retry with dm:@\(name)~agent for the agent or dm:@\(name)~human for the human.\"}")
        case .invalidKind(let kind, _):
            return Self.json(400, "{\"error\":\"Unknown DM peer kind \(kind).\",\"code\":\"DM_TARGET_INVALID_PEER_KIND\",\"suggestedNextAction\":\"Use dm:@<name>~human or dm:@<name>~agent.\"}")
        case .notFound:
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        case .resolved:
            return nil
        }
    }

    /// Which attested-send freshness interface this server/agent runs under.
    /// The upstream default is on; `off` disables the interface entirely and
    /// `allowlist` enables it only for the listed server/agent ids (or `*`).
    /// The channel card an agent sees for a send target: a thread shows its
    /// parent channel's card, a DM has none.

    /// Callers hold `lock`. The DM peer card exists only when the peer has a
    /// profile description or a timezone on their latest message.
    func peerCardJSONLocked(channelId: String, agentId: String) -> String? {
        guard let channel = postableChannels[channelId] else { return nil }
        let baseId: String
        if channel.kind == "dm" {
            baseId = channelId
        } else if channel.kind == "thread", let parentId = channel.parentChannelId,
                  postableChannels[parentId]?.kind == "dm" {
            baseId = parentId
        } else {
            return nil
        }
        guard let peerId = oauth.channelHumanIds(channelId: baseId).first(where: { $0 != agentId }),
              let account = accounts.values.first(where: { $0.id == peerId })
        else { return nil }
        let timezone = humanMessageRows.last {
            $0.channelId == baseId && $0.senderId == peerId && ($0.senderTimezone?.isEmpty == false)
        }?.senderTimezone
        let description = account.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (description?.isEmpty == false) || timezone != nil else { return nil }
        var fields = "\"kind\":\"human\",\"name\":\(jsonString(account.name))"
        if let description, !description.isEmpty { fields += ",\"description\":\(jsonString(description))" }
        if let timezone { fields += ",\"timezone\":\(jsonString(timezone))" }
        return "{\(fields)}"
    }

    /// Callers hold `lock`.
    func channelCardSnapshotLocked(channelId: String) -> AgentChannelCardSnapshot? {
        guard let channel = postableChannels[channelId], channel.kind != "dm" else { return nil }
        let cardId: String
        if channel.kind == "thread", let parentId = channel.parentChannelId {
            cardId = parentId
        } else {
            cardId = channelId
        }
        guard let info = oauth.channelInfo(id: cardId) else { return nil }
        let type = oauth.channelType(id: cardId) ?? "channel"
        let archived = oauth.channelArchivedAt(id: cardId) != nil || postableChannels[cardId]?.archived == true
        return AgentChannelCardSnapshot(
            id: cardId,
            name: info.name,
            type: type,
            description: info.description,
            archived: archived
        )
    }

    func sendFreshnessModeValue() -> String {
        let configured = sendFreshnessModeOverride
            ?? ProcessInfo.processInfo.environment["SLOCK_ATTESTED_SEND_MODE"]
            ?? "on"
        return configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func sendFreshnessInterfaceEnabled(serverId: String, agentId: String) -> Bool {
        let mode = sendFreshnessModeValue()
        switch mode {
        case "on", "force", "1", "true":
            return true
        case "allowlist":
            func listed(_ key: String) -> Set<String> {
                Set((ProcessInfo.processInfo.environment[key] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
            }
            let servers = listed("SLOCK_ATTESTED_SEND_SERVER_IDS")
            let agents = listed("SLOCK_ATTESTED_SEND_AGENT_IDS")
            return servers.contains("*") || agents.contains("*")
                || servers.contains(serverId) || agents.contains(agentId)
        default:
            return false
        }
    }

    /// `freshness_decision_fact:<sha256>` over the shared projector's stable
    /// input object: keys sorted, absent optional fields serialized as null.

    /// The conversation identity the agent sees for the target, so held
    /// messages keep a reply target instead of being dropped by clients.
    /// Callers hold `lock`.
    func heldConversationIdentityLocked(channelId: String, agentId: String) -> String {
        guard let channel = postableChannels[channelId] else {
            return "{\"channel_id\":\(jsonString(channelId)),\"channel_type\":\"channel\",\"channel_name\":\"\"}"
        }
        let channelType: String
        switch channel.kind {
        case "dm": channelType = "dm"
        case "thread": channelType = "thread"
        case "private": channelType = "private"
        default: channelType = "channel"
        }
        var peerName: String?
        if channel.kind == "dm" || channel.kind == "thread" {
            let dmId: String? = channel.kind == "dm"
                ? channelId
                : (channel.parentChannelId.flatMap { postableChannels[$0]?.kind == "dm" ? $0 : nil })
            if let dmId, let dm = postableChannels[dmId] {
                if let peerId = dm.memberIds.first(where: { $0 != agentId }) {
                    peerName = accounts.values.first { $0.id == peerId }?.name
                }
            }
        }
        let channelName = channel.kind == "dm" ? (peerName ?? channel.name) : channel.name
        var json = "{\"channel_id\":\(jsonString(channelId)),\"channel_type\":\(jsonString(channelType)),\"channel_name\":\(jsonString(channelName))"
        if channel.kind == "thread", let parentId = channel.parentChannelId, let parent = postableChannels[parentId] {
            let parentType: String
            switch parent.kind {
            case "dm": parentType = "dm"
            case "private": parentType = "private"
            default: parentType = "channel"
            }
            let parentName = parent.kind == "dm" ? (peerName ?? parent.name) : parent.name
            json += ",\"parent_channel_id\":\(jsonString(parentId)),\"parent_channel_type\":\(jsonString(parentType)),\"parent_channel_name\":\(jsonString(parentName))"
        }
        json += "}"
        return json
    }

    /// One held-context message envelope: the legacy camelCase fields plus the
    /// agent-facing snake_case identity and sender fields. Callers hold `lock`.
    func heldFreshnessMessageJSONLocked(
        seq: Int,
        message: StoredHumanMessage,
        conversationIdentity: String
    ) -> String {
        let senderType: String
        if message.senderType == "external_projection" {
            senderType = "third_party_app"
        } else if message.messageType == "system" || message.senderId == "system" {
            senderType = "system"
        } else if message.senderType == "agent" {
            senderType = "agent"
        } else {
            senderType = "human"
        }
        let senderName = message.externalSenderName
            ?? accounts.values.first { $0.id == message.senderId }?.name
            ?? (message.senderId == "system" ? "system" : message.senderId)
        let timestamp = Self.isoString(message.createdAt)
        let identityFields = String(conversationIdentity.dropFirst().dropLast())
        var json = "{\"id\":\(jsonString(message.id)),\"message_id\":\(jsonString(message.id)),\"channelId\":\(jsonString(message.channelId)),\"seq\":\(seq),\"content\":\(jsonString(message.content)),\"sender_id\":\(jsonString(message.senderId)),\"sender_name\":\(jsonString(senderName)),\"senderName\":\(jsonString(senderName)),\"sender_type\":\(jsonString(senderType)),\"senderType\":\(jsonString(senderType)),\"createdAt\":\(jsonString(timestamp)),\"timestamp\":\(jsonString(timestamp))"
        if !identityFields.isEmpty {
            json += ",\(identityFields)"
        }
        json += "}"
        return json
    }
}
