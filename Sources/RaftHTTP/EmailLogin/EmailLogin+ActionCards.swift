import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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



    public func setMarketplaceReviewerIdsForTesting(_ ids: Set<String>?) {
        lock.lock()
        marketplaceReviewerOverride = ids
        lock.unlock()
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

    public func setSendFreshnessModeForTesting(_ mode: String?) {
        lock.lock()
        sendFreshnessModeOverride = mode
        lock.unlock()
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

    public func agentSendMessage(authorization: String?, body: String, v2: Bool) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "send") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid send request\"}")
        }
        let content = (object["content"] as? String) ?? ""
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("dm:@reminders") {
            return Self.json(403, "{\"error\":\"dm:@reminders is your private reminder conversation; nobody else reads it. Act at the reminder's anchor instead.\",\"code\":\"DM_TARGET_NOT_SENDABLE\"}")
        }
        let isSendDraft = object["sendDraft"] as? Bool == true
        let isContinueAnyway = object["continueAnyway"] as? Bool == true
        if object["continue"] as? Bool == true {
            return Self.json(400, "{\"error\":\"--continue is no longer supported. Use normal message send to update a draft, or --send-draft to send the current saved draft.\"}")
        }
        if isContinueAnyway && !isSendDraft {
            return Self.json(400, "{\"error\":\"--send-draft --anyway requires a saved draft\"}")
        }
        let assistantOwner = assistantOwnerFor(agentId: identity.agentId, serverId: identity.serverId)
        if let assistantOwner {
            guard trimmed.hasPrefix("dm:@") else {
                return Self.json(403, "{\"code\":\"assistant_channel_forbidden\",\"error\":\"An assistant can only post in its DM with its owner\"}")
            }
            var raw = String(trimmed.dropFirst("dm:@".count))
            if let suffixStart = raw.lastIndex(of: ":") { raw = String(raw[..<suffixStart]) }
            if let tilde = raw.firstIndex(of: "~") { raw = String(raw[..<tilde]) }
            lock.lock()
            let resolution = resolveDMPeerLocked(serverId: identity.serverId, agentId: identity.agentId, name: raw, kind: nil)
            lock.unlock()
            guard case .resolved(let peerId, _, _) = resolution, peerId == assistantOwner else {
                return Self.json(403, "{\"code\":\"assistant_channel_forbidden\",\"error\":\"An assistant can only post in its DM with its owner\"}")
            }
        }
        func threadTargetError(_ detail: String) -> HTTPReply {
            Self.json(404, "{\"error\":\"Thread target not found or not replyable: \(detail)\"}")
        }
        let reconcileOnly = object["reconcileOnly"] as? Bool == true
        guard reconcileOnly || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.json(400, "{\"error\":\"Content is required\"}")
        }
        var attachmentIds: [String] = []
        if let rawAttachments = object["attachmentIds"], !(rawAttachments is NSNull) {
            guard let list = rawAttachments as? [Any] else {
                return Self.json(400, "{\"error\":\"Not sent: attachmentIds entry 1 is not a single attachment ID. Send one ID per --attachment-id.\",\"code\":\"attachment_id_invalid\"}")
            }
            for (index, value) in list.enumerated() {
                guard let id = value as? String, ServerScope.isUUID(id) else {
                    let entry = index + 1
                    return Self.json(400, "{\"error\":\"Not sent: attachmentIds entry \(entry) is not a single attachment ID. Send one ID per --attachment-id.\",\"code\":\"attachment_id_invalid\"}")
                }
                attachmentIds.append(id)
            }
        }
        let idempotencyKey = (object["idempotencyKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var sendReceiptKey: String?
        if !idempotencyKey.isEmpty {
            let key = "\(identity.serverId)\n\(identity.agentId)\n\(idempotencyKey)"
            sendReceiptKey = key
            lock.lock()
            let receipt = agentApiSendReceipts[key]
            lock.unlock()
            if reconcileOnly {
                guard let receipt else {
                    return Self.json(200, "{\"ok\":true,\"state\":\"not_found\",\"reconciliation\":true}")
                }
                return Self.json(200, "{\"ok\":true,\"state\":\"committed\",\"messageId\":\(jsonString(receipt.messageId)),\"messageSeq\":\(receipt.messageSeq),\"reconciliation\":true,\"receiptComplete\":false}")
            }
            if let receipt {
                let mismatch: String?
                if receipt.target != trimmed {
                    mismatch = "target"
                } else if receipt.content != content {
                    mismatch = "content"
                } else if receipt.attachmentIds != attachmentIds {
                    mismatch = "attachments"
                } else {
                    mismatch = nil
                }
                if let mismatch {
                    return Self.json(409, "{\"error\":\"This idempotencyKey was already used for a different send\",\"code\":\"idempotency_key_reused\",\"mismatch\":\(jsonString(mismatch)),\"suggestedNextAction\":\"Retry with a new idempotencyKey.\"}")
                }
                return Self.json(200, "{\"ok\":true,\"state\":\"sent\",\"messageId\":\(jsonString(receipt.messageId)),\"messageSeq\":\(receipt.messageSeq),\"id\":\(jsonString(receipt.messageId)),\"channelId\":\(jsonString(channelIdForReceipt(receipt.messageId) ?? "")),\"content\":\(jsonString(receipt.content)),\"seq\":\(receipt.messageSeq)}")
            }
        }
        let channelId: String
        if trimmed.hasPrefix("#") {
            var raw = String(trimmed.dropFirst())
            var suffix: String?
            if let colon = raw.lastIndex(of: ":") {
                suffix = String(raw[raw.index(after: colon)...])
                raw = String(raw[..<colon])
            }
            lock.lock()
            var parentId: String?
            for (id, channel) in postableChannels {
                guard channel.serverId == identity.serverId, channel.name == raw, channel.deletedAt == nil,
                      channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint"
                else { continue }
                if channel.kind == "channel"
                    || channel.memberIds.contains(identity.agentId)
                    || oauth.channelAgentIds(channelId: id).contains(identity.agentId) {
                    parentId = id
                    break
                }
            }
            var resolved: String?
            var pendingAnchorId: String?
            if let parentId {
                if let suffix, !suffix.isEmpty {
                    let isMember = postableChannels[parentId]?.memberIds.contains(identity.agentId) == true
                        || oauth.channelAgentIds(channelId: parentId).contains(identity.agentId)
                    guard isMember else {
                        let privateParent = postableChannels[parentId]?.kind == "private"
                        lock.unlock()
                        return privateParent
                            ? threadTargetError("the parent message must exist in a channel you can read")
                            : Self.json(403, "{\"error\":\"Agent is not a member of the parent channel\"}")
                    }
                    let anchorId = oauth.historyMessages(channelId: parentId).first { $0.id.hasPrefix(suffix) }?.id
                        ?? humanMessageRows.first { $0.channelId == parentId && $0.id.hasPrefix(suffix) }?.id
                    resolved = agentHistoryThread(parentId: parentId, anchorMessageId: anchorId ?? "")
                        ?? agentHistoryThreadById(parentId: parentId, suffix: suffix)
                        ?? agentHistoryThreadByAnchorPrefix(parentId: parentId, suffix: suffix)
                    if resolved == nil, let anchorId {
                        pendingAnchorId = anchorId
                    }
                } else {
                    resolved = parentId
                }
            }
            lock.unlock()
            if let parentId, let pendingAnchorId {
                let threadId = oauth.createThreadChannel(parentChannelId: parentId, parentMessageId: pendingAnchorId)
                addPostableChannel(
                    serverId: identity.serverId,
                    channelId: threadId,
                    memberId: identity.agentId,
                    kind: "thread",
                    parentChannelId: parentId,
                    parentMessageId: pendingAnchorId,
                    name: "thread"
                )
                resolved = threadId
            }
            guard let resolved else {
                return suffix == nil
                    ? Self.json(404, "{\"error\":\"Channel not found\"}")
                    : threadTargetError("the parent message must exist in #\(raw)")
            }
            channelId = resolved
        } else if trimmed.hasPrefix("dm:@") {
            var raw = String(trimmed.dropFirst("dm:@".count))
            var suffix: String?
            if let colon = raw.lastIndex(of: ":") {
                suffix = String(raw[raw.index(after: colon)...])
                raw = String(raw[..<colon])
            }
            var kind: String?
            if let tilde = raw.firstIndex(of: "~") {
                kind = String(raw[raw.index(after: tilde)...])
                raw = String(raw[..<tilde])
            }
            lock.lock()
            let resolution = resolveDMPeerLocked(serverId: identity.serverId, agentId: identity.agentId, name: raw, kind: kind)
            lock.unlock()
            if let failure = dmPeerFailure(resolution) { return failure }
            guard case .resolved(let peerId, _, _) = resolution else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            lock.lock()
            let existing = dmChannelIdLocked(serverId: identity.serverId, agentId: identity.agentId, peerId: peerId)
            lock.unlock()
            let dmChannelId: String
            if let existing {
                dmChannelId = existing
            } else {
                dmChannelId = oauth.createDirectChannel(serverId: identity.serverId, firstUserId: identity.agentId, secondUserId: peerId)
                addPostableChannel(serverId: identity.serverId, channelId: dmChannelId, memberId: identity.agentId, kind: "dm", name: "dm")
                addPostableChannel(serverId: identity.serverId, channelId: dmChannelId, memberId: peerId, kind: "dm", name: "dm")
                oauth.addChannelHuman(channelId: dmChannelId, userId: peerId)
            }
            if let suffix, !suffix.isEmpty {
                lock.lock()
                let anchorId = oauth.historyMessages(channelId: dmChannelId).first { $0.id.hasPrefix(suffix) }?.id
                    ?? humanMessageRows.first { $0.channelId == dmChannelId && $0.id.hasPrefix(suffix) }?.id
                var resolved = agentHistoryThread(parentId: dmChannelId, anchorMessageId: anchorId ?? "")
                    ?? agentHistoryThreadById(parentId: dmChannelId, suffix: suffix)
                    ?? agentHistoryThreadByAnchorPrefix(parentId: dmChannelId, suffix: suffix)
                lock.unlock()
                if resolved == nil, let anchorId {
                    let threadId = oauth.createThreadChannel(parentChannelId: dmChannelId, parentMessageId: anchorId)
                    addPostableChannel(
                        serverId: identity.serverId,
                        channelId: threadId,
                        memberId: identity.agentId,
                        kind: "thread",
                        parentChannelId: dmChannelId,
                        parentMessageId: anchorId,
                        name: "thread"
                    )
                    addPostableChannel(serverId: identity.serverId, channelId: threadId, memberId: peerId, kind: "thread", parentChannelId: dmChannelId, parentMessageId: anchorId, name: "thread")
                    resolved = threadId
                }
                guard let resolved else {
                    return threadTargetError("the parent message must exist in this DM")
                }
                channelId = resolved
            } else {
                channelId = dmChannelId
            }
        } else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }

        // A migration receipt DM is a one-way notice written at completion.
        if let channel = postableChannels[channelId], channel.name.hasPrefix("migration-receipt-") {
            return Self.json(409, "{\"error\":\"This migration receipt DM is a one-way notice; it cannot be replied to. Message your owner's DM instead.\",\"code\":\"MIGRATION_RECEIPT_READ_ONLY\",\"suggestedNextAction\":\"Read the receipt, then continue in your owner's DM.\"}")
        }

        // The gate and the commit it protects run under one lock: two
        // concurrent first replies must not both observe an empty thread.
        sendFreshnessCommitLock.lock()
        defer { sendFreshnessCommitLock.unlock() }

        // Freshness gate (SMR-006): a send that names the boundary its model
        // has seen (`seenUpToSeq`), a saved draft, a reviewer-isolation hold or
        // a re-hold opt into the gate. Newer messages from anyone but the
        // sender hold the draft; the response carries the latest bounded
        // context instead of committing anything.
        let seenUpToSeqValue = (object["seenUpToSeq"] as? NSNumber)?.doubleValue
        let hasClientSeenBoundary = seenUpToSeqValue.map { $0.isFinite } ?? false
        let clientSeenUpToSeq = hasClientSeenBoundary ? max(0, Int(seenUpToSeqValue!.rounded(.down))) : 0
        let withheldMode = (object["freshnessContextMode"] as? String) == "withheld"
        let draftReholdCount = max(0, (object["draftReholdCount"] as? NSNumber)?.intValue ?? 0)
        let draftReplacedExisting = object["draftReplacedExisting"] as? Bool == true
        // `seenExactSeqs`: sparse exact-seq observations (message check output).
        // Only seqs above the attested boundary and up to the latest message
        // count, deduplicated in request order.
        let requestedSeenExactSeqs: [Int] = {
            guard let raw = object["seenExactSeqs"] as? [Any] else { return [] }
            var seen = Set<Int>()
            var values: [Int] = []
            for item in raw {
                guard let number = item as? NSNumber, number.doubleValue.isFinite else { continue }
                let value = Int(number.doubleValue.rounded(.down))
                guard value > 0, seen.insert(value).inserted else { continue }
                values.append(value)
            }
            return Array(values.prefix(2500))
        }()
        let requestedSendFreshness = isSendDraft || isContinueAnyway || hasClientSeenBoundary
            || !requestedSeenExactSeqs.isEmpty
            || (object["draftReholdCount"] is NSNumber) || draftReplacedExisting || withheldMode
        let freshnessEnabled = sendFreshnessInterfaceEnabled(serverId: identity.serverId, agentId: identity.agentId)
        let forcedFreshness = sendFreshnessModeValue() == "force"
        if !freshnessEnabled && requestedSendFreshness {
            return Self.json(403, "{\"error\":\"Send freshness interface is not enabled for this agent.\"}")
        }
        // Passive channel card (policy "once"): only a client that names the
        // version its model context saw is checked. Never seen holds the send
        // once; an older version sends and returns the current card.
        var seenCardFields = ""
        var seenPeerCardFields = ""
        var cardHoldReasons: [String] = []
        if let seenCards = object["seenCards"] as? [String: Any], !withheldMode {
            lock.lock()
            let snapshot = channelCardSnapshotLocked(channelId: channelId)
            lock.unlock()
            if let rawChannel = seenCards["channel"], let snapshot {
                if let seenVersion = rawChannel as? String {
                    if snapshot.rev != seenVersion {
                        seenCardFields = ",\"channelCard\":\(snapshot.json),\"channelCardChanged\":true"
                    }
                } else {
                    seenCardFields = ",\"channelCard\":\(snapshot.json)"
                    cardHoldReasons.append("channel_card")
                }
            }
            if let rawPeer = seenCards["peer"] {
                lock.lock()
                let peerCard = peerCardJSONLocked(channelId: channelId, agentId: identity.agentId)
                lock.unlock()
                if let peerCard, !(rawPeer is String) {
                    seenPeerCardFields = ",\"peerCard\":\(peerCard)"
                    cardHoldReasons.append("peer_card")
                }
            }
        }
        let holdForCards = !cardHoldReasons.isEmpty && !isContinueAnyway
        var mentionExemption: (messageId: String, handle: String)?
        var mentionExemptionMessageCount = 0
        if freshnessEnabled, (requestedSendFreshness || forcedFreshness), !isContinueAnyway {
            lock.lock()
            let conversation = postableChannels[channelId]
            let storageChannelId = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId ?? channelId
            let rows = humanMessageRows.compactMap { message -> (seq: Int, message: StoredHumanMessage)? in
                guard message.channelId == storageChannelId else { return nil }
                return (message.seq, message)
            }
            let latestFromOthers = rows.last { $0.message.senderId != identity.agentId }?.seq ?? 0
            // The thread parent lives in the parent channel; the first reply
            // seeds its freshness boundary from that message's seq.
            let threadParentSeq = conversation?.kind == "thread"
                ? (conversation?.parentMessageId.flatMap { parentId in
                    humanMessageRows.first { $0.id == parentId }?.seq
                } ?? 0)
                : 0
            let fallbackBoundarySeq = conversation?.kind == "thread" ? threadParentSeq : 0
            let boundarySeq = min(hasClientSeenBoundary ? clientSeenUpToSeq : fallbackBoundarySeq, latestFromOthers)
            let effectiveExactSeqs = Set(requestedSeenExactSeqs.filter { $0 > boundarySeq && $0 <= latestFromOthers })
            let boundarySource: String
            if hasClientSeenBoundary {
                boundarySource = "client_seen"
            } else if !effectiveExactSeqs.isEmpty {
                boundarySource = "client_seen_exact"
            } else if fallbackBoundarySeq > 0 {
                boundarySource = "thread_parent"
            } else {
                boundarySource = "none"
            }
            let hasModelSeenProof = boundarySource == "client_seen" || boundarySource == "client_seen_exact"
            let newer = rows.filter {
                $0.seq > boundarySeq
                    && $0.message.senderId != identity.agentId
                    && !effectiveExactSeqs.contains($0.seq)
                    && !agentMessageSuppressedLocked($0.message, agentId: identity.agentId)
                    && !isSelfCausedFreshnessExemptLocked($0.message, agentId: identity.agentId)
            }
            let formalMentionCount = newer.reduce(0) { partial, entry in
                partial + (storedMentions.contains {
                    $0.messageId == entry.message.id && $0.targetType == "agent" && $0.targetId == identity.agentId
                } ? 1 : 0)
            }
            let boundaryMessageId: String? = boundarySeq > 0
                ? (conversation?.kind == "thread" && threadParentSeq == boundarySeq
                    ? conversation?.parentMessageId
                    : rows.first { $0.seq == boundarySeq }?.message.id)
                : nil
            // E1: a formal @handle mention inside the left-exclusive
            // (boundary, latest] range exempts the whole hold for this send.
            // Existing pre-E1 hold tests use fixture-injected mention rows
            // (senderId "peer"), so only resolved mention facts count here;
            // the explicit legacy read mark keeps those fixtures' hold
            // expectations while the upstream E1 case stays exempt.
            let legacyReadSeq = agentChannelReadCursors["\(channelId)\n\(identity.agentId)"]?.seq ?? 0
            let mentionFacts: [(messageId: String, handle: String)] = newer.compactMap { entry in
                guard let mention = storedMentions.first(where: {
                    $0.messageId == entry.message.id && $0.targetType == "agent" && $0.targetId == identity.agentId
                        && $0.senderId == "system"
                }) else { return nil }
                return (entry.message.id, mention.handle)
            }
            if boundarySeq > 0, legacyReadSeq == boundarySeq, !mentionFacts.isEmpty {
                mentionExemption = mentionFacts.first
                mentionExemptionMessageCount = newer.count
            }
            if let latestSeq = newer.last?.seq, mentionExemption == nil {
                let attentionCount = newer.count
                let shownRows = Array(newer.suffix(3))
                let shownCount = shownRows.count
                let holdCount = hasModelSeenProof ? attentionCount : min(attentionCount, 3)
                let omittedCount = hasModelSeenProof ? max(0, attentionCount - shownCount) : 0
                let showedEveryHeldMessage = shownCount >= attentionCount
                let conversationIdentity = heldConversationIdentityLocked(channelId: channelId, agentId: identity.agentId)
                let heldMessageJSON = shownRows.map { entry in
                    heldFreshnessMessageJSONLocked(seq: entry.seq, message: entry.message, conversationIdentity: conversationIdentity)
                }.joined(separator: ",")
                if !withheldMode, showedEveryHeldMessage {
                    // Every counted message was handed over: the read position
                    // may move through them. Omitted ones must stay queued.
                    let cursorKey = "\(channelId)\n\(identity.agentId)"
                    let previous = agentChannelReadCursors[cursorKey] ?? (seq: 0, version: 0)
                    if latestSeq > previous.seq {
                        agentChannelReadCursors[cursorKey] = (latestSeq, previous.version + 1)
                    }
                }
                lock.unlock()
                if withheldMode {
                    return Self.json(200, "{\"state\":\"held\",\"freshnessContextMode\":\"withheld\",\"withheldMessageCount\":\(holdCount)}")
                }
                let reason = boundarySource == "none" || boundarySource == "thread_parent"
                    ? "server_first_touch_context"
                    : "server_stale_model_boundary"
                let producerFactId = Self.freshnessDecisionProducerFactId(
                    agentId: identity.agentId,
                    target: trimmed,
                    reason: reason,
                    pendingMaxSeq: latestSeq,
                    modelSeenSeq: boundarySource == "client_seen" ? boundarySeq : 0,
                    heldMessageCount: shownCount,
                    omittedMessageCount: omittedCount
                )
                recordAttestedSendEvent(
                    "gate_triggered",
                    agentId: identity.agentId,
                    messageId: newer.last?.message.id,
                    metadata: [
                        "last_seen_msg_id": boundaryMessageId as Any? ?? NSNull(),
                        "latest_msg_id": newer.last?.message.id as Any? ?? NSNull(),
                        "has_formal_mention_since_last_seen": false,
                        "draft_replaced_existing": draftReplacedExisting,
                        "new_message_count": holdCount,
                        "boundary_source": boundarySource,
                        "boundary_seq": boundarySeq,
                        "latest_seq": latestSeq,
                    ]
                )
                recordAgentSendActivity(
                    agentId: identity.agentId,
                    title: "Send held by freshness check",
                    text: "target: \(trimmed)\n"
                        + "unreviewed synced context for this target: \(shownCount) messages\n"
                        + "reason: this target's latest synced context was not yet in your reviewed context\n"
                        + "action: review the synced context before sending",
                    producerFactId: producerFactId
                )
                var response = "{\"ok\":true,\"state\":\"held\",\"outcome\":\"held\",\"subtype\":\"freshness\",\"reason\":\"newer_messages_available\",\"decision\":\"syncing_hold\",\"producerFactId\":\(jsonString(producerFactId)),\"available_actions\":[\"check_messages\",\"send_draft\",\"send_anyway\"],\"heldMessages\":[\(heldMessageJSON)],\"newMessageCount\":\(holdCount),\"shownMessageCount\":\(shownCount),\"omittedMessageCount\":\(omittedCount),\"seenUpToSeq\":\(latestSeq)"
                if let latestMessageId = newer.last?.message.id {
                    response += ",\"seenUpToMessageId\":\(jsonString(latestMessageId))"
                }
                if let firstShownSeq = shownRows.first?.seq {
                    response += ",\"firstShownSeq\":\(firstShownSeq)"
                }
                response += ",\"mentionAnnotation\":{\"formalMentionCount\":\(formalMentionCount)}"
                if draftReholdCount >= 3 {
                    response += ",\"continueAnywaySuggested\":true"
                }
                if holdForCards {
                    let reasons = (["unread_messages"] + cardHoldReasons).map(jsonString).joined(separator: ",")
                    response += ",\"holdReasons\":[\(reasons)]"
                }
                response += seenCardFields
                response += seenPeerCardFields
                response += "}"
                return Self.json(200, response)
            }
            lock.unlock()
        }
        if let exemption = mentionExemption {
            recordAttestedSendEvent(
                "e1_exempt",
                agentId: identity.agentId,
                messageId: exemption.messageId,
                metadata: [
                    "mention_message_id": exemption.messageId,
                    "mentioned_handle": exemption.handle,
                    "new_message_count_since_last_seen": mentionExemptionMessageCount,
                ]
            )
            recordAgentSendActivity(
                agentId: identity.agentId,
                title: "Send freshness check passed by mention",
                text: "target: \(trimmed)\nreason: direct @\(exemption.handle) mention\nnew messages: \(mentionExemptionMessageCount)",
                producerFactId: nil
            )
        }
        if holdForCards {
            let reasons = cardHoldReasons.map(jsonString).joined(separator: ",")
            return Self.json(200, "{\"ok\":true,\"state\":\"held\",\"holdReasons\":[\(reasons)],\"heldMessages\":[],\"newMessageCount\":0,\"shownMessageCount\":0,\"omittedMessageCount\":0\(seenCardFields)\(seenPeerCardFields)}")
        }
        lock.lock()
        if let threadChannel = postableChannels[channelId], threadChannel.kind == "thread",
           let parentChannelId = threadChannel.parentChannelId,
           let parentMessageId = threadChannel.parentMessageId {
            threadFollows["\(identity.serverId)\n\(identity.agentId)\n\(channelId)"] = (
                serverId: identity.serverId,
                userId: identity.agentId,
                threadChannelId: channelId,
                parentMessageId: parentMessageId
            )
            let parentSender = oauth.historyMessages(channelId: parentChannelId).first { $0.id == parentMessageId }?.senderId
                ?? humanMessageRows.first { $0.id == parentMessageId }?.senderId
            if let parentSender, parentSender != "system",
               oauth.memberRole(serverId: identity.serverId, userId: parentSender) != nil {
                threadFollows["\(identity.serverId)\n\(parentSender)\n\(channelId)"] = (
                    serverId: identity.serverId,
                    userId: parentSender,
                    threadChannelId: channelId,
                    parentMessageId: parentMessageId
                )
            }
        }
        lock.unlock()
        let typedMentions = Self.mentionInputs(object["mentions"])
        if v2, Self.mentionBindingConflict(typedMentions) {
            return Self.json(400, "{\"error\":\"A mention handle is bound to more than one target\",\"code\":\"mention_binding_conflict\"}")
        }
        let mentionResolution = resolvedMessageMentions(
            serverId: identity.serverId,
            senderId: identity.agentId,
            content: content,
            typed: v2 ? typedMentions : [],
            warnUnresolved: v2
        )
        let messageId = UUID().uuidString.lowercased()
        lock.lock()
        var seenAttachmentIds = Set<String>()
        for id in attachmentIds {
            if seenAttachmentIds.contains(id) {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) was requested more than once. Send each attachment ID exactly once.\",\"code\":\"attachment_duplicate\"}")
            }
            seenAttachmentIds.insert(id)
            guard let row = channelAttachments[id], row.channelId == channelId, row.uploaderId == identity.agentId else {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) is not available for this sender. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_not_found\"}")
            }
            if row.messageId != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) is already attached to another message. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_already_linked\"}")
            }
        }
        appendHumanMessageLocked(StoredHumanMessage(
            id: messageId,
            channelId: channelId,
            senderId: identity.agentId,
            content: content,
            randomId: nil,
            attachmentIds: attachmentIds,
            messageType: "chat",
            senderType: "agent"
        ))
        for id in attachmentIds {
            channelAttachments[id]?.messageId = messageId
        }
        let ownSeq = humanMessageRows.last?.seq ?? humanMessageRows.count
        // Sending is not reading: the cursor may pass the own message only when
        // no message from someone else below it is still unhanded.
        let cursorKey = "\(channelId)\n\(identity.agentId)"
        let cursor = agentChannelReadCursors[cursorKey]?.seq ?? 0
        let unreadBelow = humanMessageRows.contains { message in
            message.channelId == channelId
                && message.senderId != identity.agentId
                && message.seq > cursor
                && message.seq < ownSeq
        }
        if !unreadBelow, ownSeq > cursor {
            let previous = agentChannelReadCursors[cursorKey] ?? (seq: 0, version: 0)
            agentChannelReadCursors[cursorKey] = (ownSeq, previous.version + 1)
        }
        if let sendReceiptKey {
            agentApiSendReceipts[sendReceiptKey] = AgentApiSendReceipt(
                messageId: messageId,
                messageSeq: ownSeq,
                target: trimmed,
                content: content,
                attachmentIds: attachmentIds
            )
        }
        lock.unlock()
        recordMemberMentionRows(messageId: messageId, channelId: channelId, mentions: mentionResolution.mentions)
        let report = sendMentionReport(
            content: content,
            typedMentions: (object["mentions"] as? [[String: Any]]) ?? [],
            v2: v2,
            channelId: channelId,
            serverId: identity.serverId,
            senderAgentId: identity.agentId,
            messageId: messageId
        )
        let unresolvedJSON = v2 && !mentionResolution.unresolved.isEmpty
            ? ",\"unresolvedMentionHandles\":[" + mentionResolution.unresolved.map(jsonString).joined(separator: ",") + "]"
            : ""
        let attentionJSON: String = {
            lock.lock()
            let key = "\(channelId)\n\(identity.agentId)"
            let channel = postableChannels[channelId]
            let joined = agentChannelJoinedAt[key]
            let isChannel = channel?.kind == "channel"
            let recent = joined.map { Date().timeIntervalSince($0) < 7 * 24 * 3600 } ?? false
            var payload = ""
            if isChannel, recent, !agentChannelPosted.contains(key) {
                agentChannelPosted.insert(key)
                let mute = "raft channel mute \"#\(channel?.name ?? "")\""
                let still = "@mentions still reach you, and threads you started stay followed and keep delivering until you unfollow them."
                payload = ",\"attention\":{\"driveByJoinedToPost\":{\"reason\":\"first_agent_message_with_recent_channel_join\",\"muteCommand\":\(jsonString(mute)),\"stillArrives\":[\(jsonString(still))]}}"
            }
            lock.unlock()
            return payload
        }()
        let sent = "{\"ok\":true,\"state\":\"sent\",\"messageId\":\(jsonString(messageId)),\"messageSeq\":\(ownSeq),\"id\":\(jsonString(messageId)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(content)),\"seq\":\(ownSeq)\(report.pendingJSON)\(unresolvedJSON)\(seenCardFields)\(seenPeerCardFields)\(attentionJSON)}"
        return Self.json(200, sent)
    }

    /// `@handle` tokens outside markdown code, in author order.

    /// Resolution of authored handles into the sender-only mention facts the
    /// send response reports: pending actions for a non-member agent (v1) and
    /// unresolved authored handles (v2). Hidden humans stay cloaked.
    func sendMentionReport(
        content: String,
        typedMentions: [[String: Any]],
        v2: Bool,
        channelId: String,
        serverId: String,
        senderAgentId: String,
        messageId: String
    ) -> (pendingJSON: String, unresolvedJSON: String) {
        let handles = Self.mentionHandlesOutsideCode(content)
        guard !handles.isEmpty else { return ("", "") }
        let typedByName: [String: (type: String, id: String)] = Dictionary(
            uniqueKeysWithValues: typedMentions.compactMap { mention in
                guard let name = mention["name"] as? String,
                      let type = mention["type"] as? String,
                      let id = mention["id"] as? String else { return nil }
                return (name, (type, id))
            }
        )
        lock.lock()
        let hiddenHumans = hideHumansFromMembers[serverId] == true
        lock.unlock()
        let senderName = oauth.agentRuntimeInfo(id: senderAgentId)?.name ?? ""
        let channelAgents = Set(oauth.channelAgentIds(channelId: channelId))
        let serverAgents = oauth.serverAgents(serverId: serverId)
        var pending: [String] = []
        var unresolved: [String] = []
        var seen = Set<String>()
        for handle in handles where seen.insert(handle).inserted {
            if handle == senderName { continue }
            if let typed = typedByName[handle] {
                if typed.type == "agent" {
                    if !serverAgents.contains(where: { $0.id == typed.id }) {
                        continue
                    }
                    if v2 { continue }
                    if !channelAgents.contains(typed.id) {
                        pending.append(Self.pendingMentionActionJSON(
                            messageId: messageId,
                            handle: handle,
                            avatarUrl: oauth.agentRuntimeInfo(id: typed.id)?.avatarUrl
                        ))
                    }
                    continue
                }
                // A typed human is either visible (resolved) or hidden (cloaked).
                continue
            }
            if let agent = serverAgents.first(where: { $0.name == handle }) {
                if v2 { continue }
                if !channelAgents.contains(agent.id) {
                    pending.append(Self.pendingMentionActionJSON(
                        messageId: messageId,
                        handle: handle,
                        avatarUrl: agent.avatarUrl
                    ))
                }
                continue
            }
            let humanExists = accounts.values.contains { $0.name == handle }
            if v2, !humanExists || hiddenHumans {
                unresolved.append("@" + handle)
            }
        }
        let pendingJSON = pending.isEmpty ? "" : ",\"pendingMentionActions\":[" + pending.joined(separator: ",") + "]"
        let unresolvedJSON = unresolved.isEmpty ? "" : ",\"unresolvedMentionHandles\":[" + unresolved.map(jsonString).joined(separator: ",") + "]"
        return (pendingJSON, unresolvedJSON)
    }


    func channelIdForReceipt(_ messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.channelId
    }


    func agentTaskAuth(authorization: String?, legacyAgentId: String?) -> AgentTaskAuthResult {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .refused(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let machine = machines.first { $0.apiKey == token }
        lock.unlock()
        if let credential, credential.revokedAt == nil {
            guard credential.scopes.contains("tasks") else {
                return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
            }
            guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
                return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
            }
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
    }

    /// Write routes accept both an `sk_agent_*` credential and the legacy
    /// machine key plus path agent id.
    func agentTaskWriter(_ authorization: String?, legacyAgentId: String?) -> (agentId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let machine = machines.first { $0.apiKey == token }
        lock.unlock()
        if let credential, credential.revokedAt == nil,
           let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted {
            return (agent.id, agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return (agent.id, agent.serverId)
        }
        return nil
    }

    func agentTaskChannel(serverId: String, agentId: String, reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if trimmed.hasPrefix("#") {
            let name = String(trimmed.dropFirst())
            for (id, channel) in postableChannels {
                guard channel.serverId == serverId, channel.name == name, channel.deletedAt == nil else { continue }
                guard channel.kind == "channel"
                    || channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
                else { continue }
                return id
            }
            return nil
        }
        guard postableChannels[trimmed]?.serverId == serverId else { return nil }
        return trimmed
    }

    public func agentTasksList(authorization: String?, legacyAgentId: String?, channelRef: String?) -> HTTPReply {
        let auth: (agentId: String, serverId: String)
        switch agentTaskAuth(authorization: authorization, legacyAgentId: legacyAgentId) {
        case .refused(let reply): return reply
        case .ok(let agentId, let serverId): auth = (agentId, serverId)
        }
        if let reply = agentGrantDenial(agentId: auth.agentId, scope: "task:read") { return reply }
        guard let channelRef,
              let channelId = agentTaskChannel(serverId: auth.serverId, agentId: auth.agentId, reference: channelRef)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let rows = taskRecords.filter { $0.channelId == channelId }.map { task in
            "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"title\":\(jsonString(task.title)),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"tasks\":[\(rows)]}")
    }

    func taskWriteFreshnessHold(agentId: String, channelId: String, seenUpToSeq: Int?, actionKey: String) -> HTTPReply? {
        guard let seen = seenUpToSeq else { return nil }
        lock.lock()
        let key = "\(agentId)\n\(channelId)\n\(actionKey)"
        if let held = taskWriteHolds[key], seen == held.seen {
            taskWriteHolds.removeValue(forKey: key)
            lock.unlock()
            return nil
        }
        let rows = humanMessageRows.filter { $0.channelId == channelId && $0.senderId != agentId && $0.seq > seen }
        guard !rows.isEmpty else { lock.unlock(); return nil }
        let latest = rows.map(\.seq).max() ?? seen
        taskWriteHolds[key] = (latest, latest)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let heldMessages = rows.sorted { $0.seq < $1.seq }.prefix(5).map { message in
            "{\"id\":\(jsonString(message.id)),\"seq\":\(message.seq),\"content\":\(jsonString(message.content)),\"senderId\":\(jsonString(message.senderId)),\"createdAt\":\(jsonString(formatter.string(from: message.createdAt)))}"
        }.joined(separator: ",")
        let count = rows.count
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"state\":\"held\",\"outcome\":\"held\",\"subtype\":\"freshness\",\"reason\":\"newer_messages_available\",\"decision\":\"syncing_hold\",\"available_actions\":[\"check_messages\",\"retry_action\"],\"heldMessages\":[\(heldMessages)],\"newMessageCount\":\(count),\"seenUpToSeq\":\(latest)}")
    }

    public func agentTaskClaim(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef)
        else {
            return Self.json(400, "{\"error\":\"Invalid task claim request\"}")
        }
        let taskNumbers = (object["task_numbers"] as? [Any])?.compactMap { $0 as? Int } ?? []
        let messageIds = (object["message_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let hold = taskWriteFreshnessHold(
            agentId: writer.agentId, channelId: channelId,
            seenUpToSeq: object["seenUpToSeq"] as? Int, actionKey: "claim:\(taskNumbers.first ?? 0)"
        ) { return hold }
        var results: [String] = []
        lock.lock()
        for number in taskNumbers {
            guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == number }) else {
                results.append("{\"taskNumber\":\(number),\"success\":false,\"reason\":\"not found\"}")
                continue
            }
            if !taskRecords[index].hasHostMessage {
                results.append("{\"taskNumber\":\(number),\"success\":false,\"reason\":\"task not found\"}")
                continue
            }
            if taskRecords[index].assigneeId == writer.agentId {
                results.append("{\"taskNumber\":\(number),\"success\":false,\"reason\":\"already claimed by you\"}")
                continue
            }
            if let assignee = taskRecords[index].assigneeId, assignee != writer.agentId {
                results.append("{\"taskNumber\":\(number),\"success\":false,\"reason\":\"already claimed\"}")
                continue
            }
            taskRecords[index].assigneeId = writer.agentId
            taskRecords[index].assigneeType = "agent"
            taskRecords[index].claimedAt = Date()
            if taskRecords[index].status == "todo" { taskRecords[index].status = "in_progress" }
            taskRecords[index].revision += 1
            let task = taskRecords[index]
            results.append("{\"taskNumber\":\(task.taskNumber),\"messageId\":\(jsonString(task.messageId)),\"success\":true}")
        }
        for prefix in messageIds {
            guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.messageId.hasPrefix(prefix) }) else {
                results.append("{\"messageId\":\(jsonString(prefix)),\"success\":false,\"reason\":\"not found\"}")
                continue
            }
            let task = taskRecords[index]
            if task.assigneeId == writer.agentId {
                results.append("{\"messageId\":\(jsonString(task.messageId)),\"success\":false,\"reason\":\"already claimed by you\",\"taskNumber\":\(task.taskNumber)}")
                continue
            }
            if let assignee = task.assigneeId, assignee != writer.agentId {
                results.append("{\"messageId\":\(jsonString(task.messageId)),\"success\":false,\"reason\":\"already claimed\",\"taskNumber\":\(task.taskNumber)}")
                continue
            }
            taskRecords[index].assigneeId = writer.agentId
            taskRecords[index].assigneeType = "agent"
            taskRecords[index].claimedAt = Date()
            if taskRecords[index].status == "todo" { taskRecords[index].status = "in_progress" }
            taskRecords[index].revision += 1
            let claimed = taskRecords[index]
            results.append("{\"messageId\":\(jsonString(claimed.messageId)),\"success\":true,\"taskNumber\":\(claimed.taskNumber)}")
        }
        lock.unlock()
        return Self.json(200, "{\"results\":[\(results.joined(separator: ","))]}")
    }

    public func agentTaskUpdateStatus(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef),
              let taskNumber = object["task_number"] as? Int,
              let status = object["status"] as? String,
              Self.validTaskStatuses.contains(status)
        else {
            return Self.json(400, "{\"error\":\"Invalid task status request\"}")
        }
        if let hold = taskWriteFreshnessHold(
            agentId: writer.agentId, channelId: channelId,
            seenUpToSeq: object["seenUpToSeq"] as? Int, actionKey: "update:\(taskNumber)"
        ) { return hold }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }),
              taskRecords[index].hasHostMessage
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let current = taskRecords[index]
        let isAdmin = oauth.agentRole(serverId: writer.serverId, agentId: writer.agentId) == "admin"
        if !isAdmin {
            if status == "todo", current.status == "in_progress", current.assigneeId != writer.agentId {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Task cannot transition from in_progress to todo\"}")
            }
            if current.status == "todo", ["done", "closed", "in_review", "cancelled"].contains(status) {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Task cannot transition from todo to \(status)\"}")
            }
        }
        if status == "done", taskRecords[index].requiresResourceReceipt, taskRecords[index].resourceReceiptJSON == nil {
            lock.unlock()
            return Self.json(409, "{\"error\":\"resource receipt required before task can move to done\"}")
        }
        taskRecords[index].status = status
        if status == "done" || status == "closed" { taskRecords[index].completedAt = Date() }
        if status == "in_progress" { taskRecords[index].claimedAt = Date() }
        if status == "todo" { taskRecords[index].claimedAt = nil }
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func agentTaskDelete(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef),
              let taskNumber = object["task_number"] as? Int
        else {
            return Self.json(400, "{\"error\":\"Invalid task delete request\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let task = taskRecords[index]
        let isAdmin = oauth.agentRole(serverId: writer.serverId, agentId: writer.agentId) == "admin"
        guard isAdmin || task.creatorId == writer.agentId else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Only the task creator can delete it\",\"code\":\"task_delete_forbidden\"}")
        }
        taskRecords.remove(at: index)
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func agentTaskConvert(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef),
              let messageRef = object["message_id"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid task convert request\"}")
        }
        lock.lock()
        guard let message = humanMessageRows.first(where: { $0.id == messageRef || $0.id.hasPrefix(messageRef) }), message.channelId == channelId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        if taskRecords.contains(where: { $0.messageId == message.id }) {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Message is already a task\"}")
        }
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        let id = UUID().uuidString.lowercased()
        var record = TaskRecord(
            id: id,
            channelId: channelId,
            title: "Converted message",
            description: nil,
            status: "todo",
            taskNumber: taskNumber,
            messageId: message.id,
            createdAt: Date()
        )
        record.creatorId = writer.agentId
        taskRecords.append(record)
        let json = taskJSON(record)
        lock.unlock()
        return Self.json(200, "{\"task\":\(json)}")
    }

    public func agentTasksCreate(authorization: String?, legacyAgentId: String?, body: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        let auth: (agentId: String, serverId: String)
        switch agentTaskAuth(authorization: authorization, legacyAgentId: legacyAgentId) {
        case .refused(let reply): return reply
        case .ok(let agentId, let serverId): auth = (agentId, serverId)
        }
        if let reply = agentGrantDenial(agentId: auth.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: auth.serverId, agentId: auth.agentId, reference: channelRef),
              let rawTasks = object["tasks"] as? [[String: Any]]
        else {
            return Self.json(400, "{\"error\":\"Invalid task request\"}")
        }
        if let reply = agentApiIdempotencyReply(agentId: auth.agentId, route: "taskCreate", object: object) {
            return reply
        }
        let titles = rawTasks.compactMap { task -> String? in
            let title = (task["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        guard !titles.isEmpty, titles.count == rawTasks.count else {
            return Self.json(400, "{\"error\":\"Invalid task request\"}")
        }
        var assignee: (id: String, type: String, name: String)?
        if let rawAssignee = object["assignee"] as? String, !rawAssignee.isEmpty {
            let handle = rawAssignee.hasPrefix("@") ? String(rawAssignee.dropFirst()) : rawAssignee
            let lowered = handle.lowercased()
            let agentMatch = oauth.channelAgentIds(channelId: channelId).compactMap { oauth.agentRuntimeInfo(id: $0) }.first {
                $0.name.lowercased() == lowered || $0.displayName.lowercased() == lowered
            }
            let humanMatch = oauth.channelHumanIds(channelId: channelId).compactMap { userId in
                accounts.values.first { $0.id == userId }
            }.first { $0.name.lowercased() == lowered }
            guard (agentMatch == nil) != (humanMatch == nil) else {
                return Self.json(404, "{\"error\":\"Assignee is not assignable\",\"code\":\"assignee_not_assignable\"}")
            }
            if let agentMatch {
                assignee = (agentMatch.id, "agent", agentMatch.name)
            } else if let humanMatch {
                assignee = (humanMatch.id, "user", humanMatch.name)
            }
        }
        let ids = addTasks(channelId: channelId, titles: titles, creatorId: auth.agentId, creatorType: "agent")
        let resourceFlags = rawTasks.map { $0["creates_resource"] as? Bool == true }
        if resourceFlags.contains(true) {
            lock.lock()
            for (offset, id) in ids.enumerated() where offset < resourceFlags.count && resourceFlags[offset] {
                if let index = taskRecords.firstIndex(where: { $0.id == id }) {
                    taskRecords[index].requiresResourceReceipt = true
                }
            }
            lock.unlock()
        }
        let idsJSON = ids.map { jsonString($0) }.joined(separator: ",")
        var receiptJSON = "null"
        lock.lock()
        if let assignee {
            for id in ids {
                guard let index = taskRecords.firstIndex(where: { $0.id == id }) else { continue }
                taskRecords[index].assigneeId = assignee.id
                taskRecords[index].assigneeType = assignee.type
                taskRecords[index].revision += 1
                inboxFactStore.append(StoredInboxFact(
                    messageId: taskRecords[index].messageId,
                    receiverType: assignee.type,
                    receiverId: assignee.id,
                    channelId: channelId,
                    serverId: auth.serverId,
                    personalMention: true,
                    unreadEligible: true
                ))
            }
            let receiptId = UUID().uuidString.lowercased()
            let receiptContent = "@\(assignee.name) assigned you: \(titles.first ?? "task")"
            appendHumanMessageLocked(StoredHumanMessage(
                id: receiptId,
                channelId: channelId,
                senderId: auth.agentId,
                content: receiptContent,
                randomId: nil,
                messageType: "task_assignment",
                senderType: "agent"
            ))
            inboxFactStore.append(StoredInboxFact(
                messageId: receiptId,
                receiverType: assignee.type,
                receiverId: assignee.id,
                channelId: channelId,
                serverId: auth.serverId,
                personalMention: true,
                unreadEligible: true
            ))
            receiptJSON = "{\"messageId\":\(jsonString(receiptId)),\"content\":\(jsonString(receiptContent)),\"assignee\":\(jsonString("@\(assignee.name)")),\"state\":\"assigned\"}"
        }
        let taskJSONs = ids.compactMap { id in taskRecords.first { $0.id == id }.map(taskJSON) }
        lock.unlock()
        let idempotentReply = Self.json(200, "{\"taskIds\":[\(idsJSON)],\"tasks\":[\(taskJSONs.joined(separator: ","))],\"assignmentReceipt\":\(receiptJSON)}")
        storeAgentApiIdempotency(agentId: auth.agentId, route: "taskCreate", object: object, reply: idempotentReply)
        return idempotentReply
    }

    public func agentTaskResourceReceipt(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId) else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef),
              let taskNumber = object["task_number"] as? Int,
              let receipt = object["receipt"] as? [String: Any],
              let objectName = (receipt["object"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !objectName.isEmpty,
              let purpose = (receipt["purpose"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty,
              let teardownOwner = (receipt["teardown_owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !teardownOwner.isEmpty,
              let securityPrivacy = (receipt["security_privacy"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !securityPrivacy.isEmpty,
              let expiryRaw = receipt["expiry"] as? String,
              let runbook = (receipt["runbook"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !runbook.isEmpty,
              let tracking = (receipt["tracking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !tracking.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid resource receipt\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = formatter.date(from: expiryRaw) else {
            return Self.json(400, "{\"error\":\"Invalid resource receipt\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }),
              taskRecords[index].requiresResourceReceipt
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let receiptJSON = Self.serializeJSON(receipt)
        taskRecords[index].resourceReceiptJSON = receiptJSON
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        let agentName = oauth.agentRuntimeInfo(id: writer.agentId)?.name ?? "agent"
        let reminder = ReminderRecord(
            id: UUID().uuidString.lowercased(),
            serverId: writer.serverId,
            ownerAgentId: writer.agentId,
            title: "Resource receipt expiry: \(objectName)",
            fireAt: expiry,
            notes: receiptJSON,
            channelId: channelId
        )
        reminderRecords.append(reminder)
        lock.unlock()
        let follow = "{\"ownerAgentId\":\(jsonString(writer.agentId)),\"owner\":\(jsonString("@" + agentName)),\"msgId\":\(jsonString(task.messageId)),\"targetChannelId\":\(jsonString(channelId)),\"reminderId\":\(jsonString(reminder.id)),\"fireAt\":\(jsonString(expiryRaw))}"
        return Self.json(200, "{\"ok\":true,\"taskNumber\":\(task.taskNumber),\"expiryFollowup\":\(follow)}")
    }

    public func agentTaskAssign(authorization: String?, body: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: agent.id, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: agent.serverId, agentId: agent.id, reference: channelRef),
              let taskNumber = object["task_number"] as? Int,
              let rawAssignee = object["assignee"] as? String, !rawAssignee.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid task assign request\"}")
        }
        let handle = rawAssignee.hasPrefix("@") ? String(rawAssignee.dropFirst()) : rawAssignee
        let lowered = handle.lowercased()
        let agentMatch = oauth.channelAgentIds(channelId: channelId).compactMap { oauth.agentRuntimeInfo(id: $0) }.first {
            $0.name.lowercased() == lowered || $0.displayName.lowercased() == lowered
        }
        let humanMatch = oauth.channelHumanIds(channelId: channelId).compactMap { userId in
            accounts.values.first { $0.id == userId }
        }.first { $0.name.lowercased() == lowered }
        guard (agentMatch == nil) != (humanMatch == nil) else {
            return Self.json(404, "{\"error\":\"Assignee is not assignable\",\"code\":\"assignee_not_assignable\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\",\"code\":\"assignee_not_assignable\"}")
        }
        if let agentMatch {
            taskRecords[index].assigneeId = agentMatch.id
            taskRecords[index].assigneeType = "agent"
        } else if let humanMatch {
            taskRecords[index].assigneeId = humanMatch.id
            taskRecords[index].assigneeType = "user"
        }
        taskRecords[index].claimedAt = nil
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }




    public func setAgentInboxAvailableForTesting(_ value: Bool?) {
        lock.lock()
        agentInboxAvailableForTesting = value
        lock.unlock()
    }



    /// `GET /internal/agent-api/inbox/conversations`.
    public func agentInboxConversations(
        authorization: String?,
        limit rawLimit: String?,
        beforeSeq rawBefore: String?,
        view rawView: String?
    ) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        lock.lock()
        let available = agentInboxAvailableForTesting ?? true
        lock.unlock()
        guard available else {
            return Self.json(503, "{\"error\":\"The agent inbox is unavailable\",\"code\":\"INBOX_UNAVAILABLE\",\"suggestedNextAction\":\"Retry after the inbox service recovers.\"}")
        }
        let view = rawView ?? "unread"
        guard view == "unread" || view == "mentions" else {
            return Self.json(400, "{\"error\":\"view must be unread or mentions\"}")
        }
        let limit: Int
        if let rawLimit, !rawLimit.isEmpty {
            guard let parsed = Int(rawLimit), parsed >= 1, parsed <= 100 else {
                return Self.json(400, "{\"error\":\"limit must be between 1 and 100\"}")
            }
            limit = parsed
        } else {
            limit = 20
        }
        var before: Int?
        if let rawBefore, !rawBefore.isEmpty {
            guard let parsed = Int(rawBefore), parsed > 0 else {
                return Self.json(400, "{\"error\":\"before_seq must be a positive integer\"}")
            }
            before = parsed
        }
        lock.lock()
        let serverId = identity.serverId
        let agentId = identity.agentId
        var rows: [AgentInboxRow] = []

        func latestMessage(_ storageChannelId: String) -> (seq: Int, message: StoredHumanMessage?) {
            let messages = humanMessageRows.filter { $0.channelId == storageChannelId }
            guard let last = messages.max(by: { $0.seq < $1.seq }) else { return (0, nil) }
            return (last.seq, last)
        }
        func senderName(_ message: StoredHumanMessage?) -> String? {
            guard let message else { return nil }
            if let external = message.externalSenderName { return external }
            if message.senderId == "system" { return "system" }
            return accounts.values.first { $0.id == message.senderId }?.name
                ?? oauth.agentRuntimeInfo(id: message.senderId)?.name
        }
        func mentionStats(channelId: String) -> (count: Int, maxSeq: Int?) {
            let ids = Set(storedMentions.filter {
                $0.targetType == "agent" && $0.targetId == agentId && $0.channelId == channelId
            }.map(\.messageId))
            guard !ids.isEmpty else { return (0, nil) }
            let messages = humanMessageRows.filter { $0.channelId == channelId }
            var maxSeq: Int?
            for message in messages where ids.contains(message.id) {
                maxSeq = message.seq
            }
            return (ids.count, maxSeq)
        }

        // Channel and DM rows.
        for (id, channel) in postableChannels {
            guard channel.serverId == serverId, channel.deletedAt == nil else { continue }
            let visible = channel.kind == "channel"
                || channel.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: id).contains(agentId)
            guard visible else { continue }
            var target: String
            var kind: String
            if channel.kind == "dm", channel.name.hasPrefix("migration-receipt-"), channel.memberIds == [agentId] {
                target = "dm:@\(channel.name)"
                kind = "dm"
            } else if channel.kind == "dm" {
                let peer = channel.memberIds.compactMap { member -> (String, String)? in
                    guard member != agentId,
                          let account = accounts.values.first(where: { $0.id == member }),
                          oauth.memberRole(serverId: serverId, userId: member) != nil
                    else { return nil }
                    return (member, account.name)
                }.first
                guard let peer else { continue }
                target = "dm:@\(peer.1)"
                kind = "dm"
            } else if channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint" {
                target = "#\(channel.name)"
                kind = "channel"
            } else {
                continue
            }
            let storage = jointProjections.first { $0.localChannelId == id }?.canonicalChannelId ?? id
            let latest = latestMessage(storage)
            guard latest.seq > 0 else { continue }
            let cursor = agentChannelReadCursors["\(id)\n\(agentId)"]?.seq ?? 0
            let unread = humanMessageRows.filter { $0.channelId == storage && $0.seq > cursor && $0.senderId != agentId }.count
            let mentions = mentionStats(channelId: storage)
            rows.append(AgentInboxRow(
                target: target,
                kind: kind,
                lastReadSeq: cursor,
                unread: unread,
                mentions: mentions.count,
                latestSeq: latest.seq,
                activitySeq: latest.seq,
                latestSenderName: senderName(latest.message) ?? "",
                latestAt: latest.message?.createdAt,
                joinedAt: latest.message?.createdAt ?? Date()
            ))
        }

        // Followed thread rows.
        for follow in threadFollows.values where follow.userId == agentId && follow.serverId == serverId {
            guard let thread = postableChannels[follow.threadChannelId], thread.deletedAt == nil,
                  let parentId = thread.parentChannelId,
                  let parent = postableChannels[parentId], parent.deletedAt == nil
            else { continue }
            let visible = thread.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: follow.threadChannelId).contains(agentId)
                || parent.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: parentId).contains(agentId)
            guard visible else { continue }
            let storage = jointProjections.first { $0.localChannelId == follow.threadChannelId }?.canonicalChannelId ?? follow.threadChannelId
            let latest = latestMessage(storage)
            guard latest.seq > 0 else { continue }
            let cursor = agentChannelReadCursors["\(follow.threadChannelId)\n\(agentId)"]?.seq ?? 0
            let unread = humanMessageRows.filter { $0.channelId == storage && $0.seq > cursor && $0.senderId != agentId }.count
            let mentions = mentionStats(channelId: storage)
            let parentShort = String((thread.parentMessageId ?? "").prefix(8))
            let target: String
            if parent.kind == "dm" {
                let peer = parent.memberIds.compactMap { member -> String? in
                    guard member != agentId,
                          let account = accounts.values.first(where: { $0.id == member }),
                          oauth.memberRole(serverId: serverId, userId: member) != nil
                    else { return nil }
                    return account.name
                }.first ?? "unknown"
                target = "dm:@\(peer):\(parentShort)"
            } else {
                target = "#\(parent.name):\(parentShort)"
            }
            rows.append(AgentInboxRow(
                target: target,
                kind: "thread",
                lastReadSeq: cursor,
                unread: unread,
                mentions: mentions.count,
                latestSeq: latest.seq,
                activitySeq: latest.seq,
                latestSenderName: senderName(latest.message) ?? "",
                latestAt: latest.message?.createdAt,
                joinedAt: threadFollowStarts["\(serverId)\n\(agentId)\n\(follow.threadChannelId)"] ?? Date()
            ))
        }
        lock.unlock()

        let totals = (
            conversations: rows.count,
            dms: rows.filter { $0.kind == "dm" }.count,
            mentions: rows.filter { $0.mentions > 0 }.count
        )
        var filtered = rows
        if view == "mentions" {
            filtered = filtered.filter { $0.mentions > 0 }
        } else {
            filtered = filtered.filter { $0.unread > 0 || $0.mentions > 0 }
        }
        if let before {
            filtered = filtered.filter { $0.activitySeq < before }
        }
        filtered.sort { left, right in
            if left.activitySeq != right.activitySeq { return left.activitySeq > right.activitySeq }
            return left.target < right.target
        }
        let hasMore = filtered.count > limit
        let page = Array(filtered.prefix(limit))
        let nextBefore = hasMore ? page.last?.activitySeq : nil
        let items = page.map { row -> String in
            let latestAt = row.latestAt.map { jsonString(Self.isoMillis($0)) } ?? "null"
            return "{\"target\":\(jsonString(row.target)),\"kind\":\(jsonString(row.kind)),\"unread\":\(row.unread),\"mentions\":\(row.mentions),\"lastReadSeq\":\(row.lastReadSeq),\"activitySeq\":\(row.activitySeq),\"latestSenderName\":\(jsonString(row.latestSenderName)),\"latestAt\":\(latestAt)}"
        }.joined(separator: ",")
        let nextJSON = nextBefore.map(String.init) ?? "null"
        return Self.json(200, "{\"view\":\(jsonString(view)),\"items\":[\(items)],\"totals\":{\"conversations\":\(totals.conversations),\"dms\":\(totals.dms),\"mentions\":\(totals.mentions)},\"hasMore\":\(hasMore),\"nextBeforeSeq\":\(nextJSON)}")
    }

    func agentHistoryThread(parentId: String, anchorMessageId: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard channel.parentMessageId == anchorMessageId else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    func agentHistoryThreadById(parentId: String, suffix: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard id.hasPrefix(suffix) else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    func agentHistoryThreadByAnchorPrefix(parentId: String, suffix: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard channel.parentMessageId?.hasPrefix(suffix) == true else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    func actionCardTarget(serverId: String, agentId: String, target: String) -> (local: String, storage: String)? {
        guard target.hasPrefix("#") else { return nil }
        let name = String(target.dropFirst())
        lock.lock()
        var local: String?
        for (id, channel) in postableChannels {
            guard channel.serverId == serverId, channel.name == name, channel.deletedAt == nil,
                  channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint"
            else { continue }
            if channel.kind != "channel",
               !channel.memberIds.contains(agentId),
               !oauth.channelAgentIds(channelId: id).contains(agentId) {
                continue
            }
            local = id
            break
        }
        let storage = local.flatMap { id in jointProjections.first { $0.localChannelId == id }?.canonicalChannelId } ?? local
        lock.unlock()
        guard let local, let storage else { return nil }
        return (local, storage)
    }

    /// Third-party text is rendered inert before it reaches agents: agent
    /// markup literals are escaped and `@name` refs become plain `user:name`
    /// labels, so a publisher name cannot fabricate a mention or a result tag.

    /// `@name` outside markdown code becomes the plain `user:name` label;
    /// backticked spans are literal data and keep their shape.



    func marketplaceInstallActionJSON(_ card: MarketplaceInstallCard, includeDraftHint: Bool = true) -> String {
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        let draftHint = includeDraftHint
            ? ",\"draftHint\":\(jsonString("\(card.agentName) requested \(card.clientName), which is public in the Raft Marketplace but is not installed on this Server. Installing is a Server owner/admin action; the Agent cannot install it automatically."))"
            : ""
        let setupUrl = card.setupUrl.map(jsonString) ?? "null"
        return "{\"type\":\"integration:install_marketplace_app\",\"clientId\":\(jsonString(card.clientRecordId)),\"clientKey\":\(jsonString(card.clientKey)),\"clientName\":\(jsonString(card.clientName)),\"clientNameSha256\":\(jsonString(card.clientNameSha256)),\"agentId\":\(jsonString(card.agentId)),\"agentName\":\(jsonString(card.agentName)),\"scopes\":[\(scopes)],\"setupUrl\":\(setupUrl),\"setupRevision\":\(card.setupRevision)\(draftHint)}"
    }

    func marketplaceInstallPresentationJSON(_ card: MarketplaceInstallCard) -> String {
        var items: [String] = []
        items.append("{\"key\":\"clientId\",\"value\":\(jsonString(card.clientRecordId))}")
        items.append("{\"key\":\"clientKey\",\"value\":\(jsonString(card.clientKey))}")
        items.append("{\"key\":\"clientName\",\"value\":\(jsonString(card.clientName))}")
        items.append("{\"key\":\"agentId\",\"value\":\(jsonString(card.agentId))}")
        items.append("{\"key\":\"agentName\",\"value\":\(jsonString(card.agentName))}")
        if !card.scopes.isEmpty {
            let scopes = card.scopes.map(jsonString).joined(separator: ", ")
            items.append("{\"key\":\"scopes\",\"value\":\(jsonString(scopes))}")
        }
        let warning = "This installs the Marketplace app for this Server so @\(card.agentName) can request the listed scopes."
        return "{\"title\":\(jsonString("Install \(card.clientName) on this Server")),\"confirmLabel\":\"Install App\",\"genericApprovalAllowed\":true,\"displayItems\":[\(items.joined(separator: ","))],\"warning\":\(jsonString(warning)),\"riskLevel\":\"elevated\"}"
    }

    func marketplaceInstallMetadataJSON(_ card: MarketplaceInstallCard) -> String {
        let executedAt = card.state == "executed" ? jsonString(ISO8601DateFormatter().string(from: Date())) : "null"
        let executedBy = card.executedByUserId.map(jsonString) ?? "null"
        let result = card.resultJSON ?? "null"
        return "{\"kind\":\"action-card\",\"sourceServerId\":\(jsonString(card.serverId)),\"targetServerName\":\(jsonString(actionCardServerName(card.serverId))),\"action\":\(marketplaceInstallActionJSON(card)),\"presentation\":\(marketplaceInstallPresentationJSON(card)),\"state\":\(jsonString(card.state)),\"executedAt\":\(executedAt),\"executedByUserId\":\(executedBy),\"result\":\(result)}"
    }

    /// The message projection of every prepared card, keyed by message id.
    func actionCardMetadataLocked(messageId: String) -> String? {
        if let card = marketplaceInstallCards[messageId] {
            return marketplaceInstallMetadataJSON(card)
        }
        if let card = integrationRegisterCards[messageId] {
            return integrationRegisterMetadataJSON(card)
        }
        return nil
    }

    func integrationRegisterActionJSON(_ card: IntegrationRegisterCard) -> String {
        var fields: [String] = [
            "\"type\":\"integration:register_app\"",
            "\"name\":\(jsonString(card.name))",
        ]
        if let clientKey = card.clientKey { fields.append("\"clientKey\":\(jsonString(clientKey))") }
        if let homepageUrl = card.homepageUrl { fields.append("\"homepageUrl\":\(jsonString(homepageUrl))") }
        fields.append("\"returnUrl\":\(jsonString(card.returnUrl))")
        if let agentManifestUrl = card.agentManifestUrl {
            fields.append("\"agentManifestUrl\":\(jsonString(agentManifestUrl))")
        }
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        fields.append("\"scopes\":[" + scopes + "]")
        if let setupUrl = card.setupUrl { fields.append("\"setupUrl\":\(jsonString(setupUrl))") }
        if let setupDescription = card.setupDescription { fields.append("\"setupDescription\":\(jsonString(setupDescription))") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    func integrationRegisterPresentationJSON(_ card: IntegrationRegisterCard) -> String {
        var items: [String] = [
            "{\"key\":\"name\",\"value\":\(jsonString(card.name))}",
        ]
        if let clientKey = card.clientKey {
            items.append("{\"key\":\"clientKey\",\"value\":\(jsonString(clientKey))}")
        }
        items.append("{\"key\":\"returnUrl\",\"value\":\(jsonString(card.returnUrl))}")
        if !card.scopes.isEmpty {
            let scopes = card.scopes.map(jsonString).joined(separator: ", ")
            items.append("{\"key\":\"scopes\",\"value\":\(jsonString(scopes))}")
        }
        return "{\"title\":\(jsonString("Register Connected App \(card.name)")),\"confirmLabel\":\"Register App\",\"genericApprovalAllowed\":true,\"displayItems\":[\(items.joined(separator: ","))],\"warning\":\"The requesting agent becomes the initial app owner. No client secret is stored in this card.\",\"riskLevel\":\"elevated\"}"
    }

    func integrationRegisterMetadataJSON(_ card: IntegrationRegisterCard) -> String {
        let executedBy = card.executedByUserId.map(jsonString) ?? "null"
        let result = card.resultJSON ?? "null"
        return "{\"kind\":\"action-card\",\"sourceServerId\":\(jsonString(card.serverId)),\"targetServerName\":\(jsonString(actionCardServerName(card.serverId))),\"action\":\(integrationRegisterActionJSON(card)),\"presentation\":\(integrationRegisterPresentationJSON(card)),\"state\":\(jsonString(card.state)),\"executedByUserId\":\(executedBy),\"result\":\(result)}"
    }

    func prepareIntegrationRegisterCard(
        serverId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        name: String,
        clientKey: String?,
        homepageUrl: String?,
        returnUrl: String,
        agentManifestUrl: String?,
        setupUrl: String? = nil,
        setupDescription: String? = nil,
        scopes: [String],
        target: (local: String, storage: String)
    ) -> String {
        let messageId = UUID().uuidString.lowercased()
        let agentName = agent.displayName.isEmpty ? agent.name : agent.displayName
        let card = IntegrationRegisterCard(
            messageId: messageId,
            serverId: serverId,
            agentId: agent.id,
            agentName: agentName,
            storageChannelId: target.storage,
            localCarrierChannelId: target.local,
            name: name,
            clientKey: clientKey,
            homepageUrl: homepageUrl,
            returnUrl: returnUrl,
            agentManifestUrl: agentManifestUrl,
            setupUrl: setupUrl,
            setupDescription: setupDescription,
            scopes: scopes,
            state: "prepared",
            executedByUserId: nil,
            resultJSON: nil
        )
        let content = "Operation: register Login with Raft app \(name) (\(clientKey ?? "auto-generated client key"))"
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: messageId,
            channelId: target.storage,
            senderId: agent.id,
            content: content,
            randomId: nil,
            messageType: "chat",
            senderType: "agent",
            actionKind: "action-card"
        ))
        integrationRegisterCards[messageId] = card
        lock.unlock()
        return messageId
    }


    func executeIntegrationRegisterCard(
        _ card: IntegrationRegisterCard,
        userId: String,
        serverId: String,
        body: String
    ) -> HTTPReply {
        guard card.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only Server owners and admins can register apps\",\"errorCode\":\"FORBIDDEN\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        if let expectedState = object?["expectedState"] as? String, expectedState != card.state {
            return Self.json(409, "{\"error\":\"The action card state changed\",\"code\":\"STATE_MISMATCH\"}")
        }
        if card.state == "executed" {
            return Self.json(200, "{\"messageId\":\(jsonString(card.messageId)),\"metadata\":\(integrationRegisterMetadataJSON(card))}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: card.agentId), !agent.deleted else {
            return Self.json(409, "{\"error\":\"Requesting agent no longer exists; prepare a fresh request\",\"errorCode\":\"AGENT_BINDING_CHANGED\"}")
        }
        let clientKey = card.clientKey ?? Self.generatedIntegrationClientKey(card.name)
        let created: CreatedOAuthClient
        do {
            created = try oauth.createClient(
                serverId: card.serverId,
                createdByUserId: userId,
                name: card.name,
                clientId: clientKey,
                appType: "server_local",
                homepageUrl: card.homepageUrl,
                returnUrl: card.returnUrl,
                allowedScopes: card.scopes,
                agentManifestUrl: card.agentManifestUrl,
                setupUrl: card.setupUrl,
                setupDescription: card.setupDescription
            )
        } catch let error as OAuthClientRejection {
            return Self.json(409, "{\"error\":\(jsonString(error.message)),\"errorCode\":\"APP_REGISTRATION_REJECTED\"}")
        } catch {
            return Self.json(400, "{\"error\":\"Invalid app registration\",\"errorCode\":\"INVALID_APP_METADATA\"}")
        }
        oauth.addClientMaintainer(clientRecordId: created.id, agentId: card.agentId)
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        let result = "{\"kind\":\"integration-app-registration\",\"mode\":\"register\",\"clientId\":\(jsonString(created.id)),\"clientKey\":\(jsonString(created.clientId)),\"clientName\":\(jsonString(card.name)),\"scopes\":[\(scopes)]}"
        var updated = card
        updated.state = "executed"
        updated.executedByUserId = userId
        updated.resultJSON = result
        lock.lock()
        integrationRegisterCards[card.messageId] = updated
        lock.unlock()
        return Self.json(200, "{\"messageId\":\(jsonString(card.messageId)),\"metadata\":\(integrationRegisterMetadataJSON(updated))}")
    }

    static let oauthClientCategories: Set<String> = [
        "AI & Automation", "Communication", "Productivity & Collaboration",
        "Developer Tools", "Data & Analytics", "Business Ops",
        "Infrastructure", "Content & Creative", "Other",
        "Productivity", "Dev Tools", "Storage", "Scheduling",
        "Business & Operations", "Infrastructure & Operations",
    ]

    public func agentIntegrationAppPrepare(authorization: String?, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("send") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"send\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              (object["mode"] as? String) == "register",
              let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let returnUrl = (object["returnUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !returnUrl.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid app registration request\",\"errorCode\":\"INVALID_APP_METADATA\"}")
        }
        let targetRef = (object["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let resolved = actionCardTarget(serverId: agent.serverId, agentId: agent.id, target: targetRef) else {
            return Self.json(404, "{\"error\":\"Target channel not found\",\"code\":\"TARGET_NOT_FOUND\"}")
        }
        let clientKey = (object["clientKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let homepageUrl = (object["homepageUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentManifestUrl = (object["agentManifestUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = ((object["scopes"] as? [Any]) ?? []).compactMap { $0 as? String }
        let allowedScopes: Set<String> = [
            "openid", "profile", "email", "offline_access", "identity",
            "agent:read", "agent:send", "agent:tasks", "agent:channels",
        ]
        if scopes.contains(where: { !allowedScopes.contains($0) }) {
            return Self.json(400, "{\"error\":\"Scope is not allowed for this service\",\"errorCode\":\"INVALID_SCOPE\"}")
        }
        if let category = object["category"] as? String, !Self.oauthClientCategories.contains(category) {
            return Self.json(400, "{\"error\":\"Category is not allowed\",\"errorCode\":\"INVALID_CATEGORY\"}")
        }
        if object["unsafeDemoUrlOverride"] as? Bool != true {
            for raw in [homepageUrl, returnUrl].compactMap({ $0 }) {
                guard let url = URL(string: raw), let host = url.host else { continue }
                let privateHost = host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
                if privateHost {
                    return Self.json(400, "{\"error\":\"Unsafe demo URL requires the override\",\"errorCode\":\"UNSAFE_DEMO_URL_REQUIRES_OVERRIDE\"}")
                }
            }
        }
        let messageId = prepareIntegrationRegisterCard(
            serverId: agent.serverId,
            agent: agent,
            name: name,
            clientKey: (clientKey?.isEmpty == false) ? clientKey : nil,
            homepageUrl: (homepageUrl?.isEmpty == false) ? homepageUrl : nil,
            returnUrl: returnUrl,
            agentManifestUrl: (agentManifestUrl?.isEmpty == false) ? agentManifestUrl : nil,
            scopes: scopes,
            target: resolved
        )
        var action = "{\"type\":\"integration:register_app\",\"name\":\(jsonString(name)),"
        if let clientKey, !clientKey.isEmpty {
            action += "\"clientKey\":\(jsonString(clientKey)),"
        }
        if let homepageUrl, !homepageUrl.isEmpty {
            action += "\"homepageUrl\":\(jsonString(homepageUrl)),"
        }
        action += "\"returnUrl\":\(jsonString(returnUrl)),\"scopes\":[\(scopes.map(jsonString).joined(separator: ","))]}"
        return Self.json(201, "{\"status\":\"prepared\",\"actionCardMessageId\":\(jsonString(messageId)),\"action\":\(action)}")
    }

    func prepareMarketplaceInstallCard(
        serverId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        client: [String: Any],
        scopes: [String],
        target: (local: String, storage: String)
    ) -> String? {
        guard let recordId = client["id"] as? String,
              let clientKey = client["clientId"] as? String,
              let rawName = client["name"] as? String
        else { return nil }
        let binding = Self.marketplaceAppNameBinding(rawName)
        let declaration = oauth.clientSetupDeclarationForTesting(clientRecordId: recordId)
        let agentName = agent.displayName.isEmpty ? agent.name : agent.displayName
        let messageId = UUID().uuidString.lowercased()
        let card = MarketplaceInstallCard(
            messageId: messageId,
            serverId: serverId,
            clientRecordId: recordId,
            clientKey: clientKey,
            clientName: binding.name,
            clientNameSha256: binding.sha256,
            agentId: agent.id,
            agentName: agentName,
            scopes: scopes,
            storageChannelId: target.storage,
            localCarrierChannelId: target.local,
            state: "prepared",
            executedByUserId: nil,
            resultJSON: nil,
            setupUrl: declaration?.url,
            setupRevision: declaration?.revision ?? 1
        )
        let content = "Operation: install Marketplace app \(binding.name) (\(clientKey)) on this Server"
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: messageId,
            channelId: target.storage,
            senderId: agent.id,
            content: content,
            randomId: nil,
            messageType: "chat",
            senderType: "agent",
            actionKind: "action-card"
        ))
        marketplaceInstallCards[messageId] = card
        lock.unlock()
        return messageId
    }

    func executeMarketplaceInstallCard(
        _ card: MarketplaceInstallCard,
        userId: String,
        serverId: String,
        body: String
    ) -> HTTPReply {
        guard card.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only Server owners and admins can install Marketplace apps\",\"errorCode\":\"FORBIDDEN\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let expectedState = object?["expectedState"] as? String
        if let expectedState, expectedState != card.state {
            return Self.json(409, "{\"error\":\"The action card state changed\",\"code\":\"STATE_MISMATCH\"}")
        }
        if card.state == "executed" {
            return Self.json(200, "{\"messageId\":\(jsonString(card.messageId)),\"metadata\":\(marketplaceInstallMetadataJSON(card))}")
        }
        guard let client = oauth.marketplaceInstallableClient(recordId: card.clientRecordId),
              let clientKey = client["clientId"] as? String,
              clientKey == card.clientKey,
              let rawName = client["name"] as? String
        else {
            return Self.json(409, "{\"error\":\"Marketplace app is no longer installable with this card; prepare a fresh login request\",\"errorCode\":\"MARKETPLACE_APP_CHANGED\"}")
        }
        let binding = Self.marketplaceAppNameBinding(rawName)
        guard binding.sha256 == card.clientNameSha256, binding.name == card.clientName else {
            return Self.json(409, "{\"error\":\"Marketplace app identity changed; prepare a fresh login request\",\"errorCode\":\"MARKETPLACE_APP_CHANGED\"}")
        }
        let declaration = oauth.clientSetupDeclarationForTesting(clientRecordId: card.clientRecordId)
        guard (declaration?.url ?? nil) == card.setupUrl, (declaration?.revision ?? 1) == card.setupRevision else {
            return Self.json(409, "{\"error\":\"The App setup declaration changed; prepare a fresh request\",\"errorCode\":\"APP_SETUP_CHANGED\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: card.agentId), !agent.deleted else {
            return Self.json(409, "{\"error\":\"Requesting agent identity changed; prepare a fresh login request\",\"errorCode\":\"AGENT_BINDING_CHANGED\"}")
        }
        let agentName = agent.displayName.isEmpty ? agent.name : agent.displayName
        guard agentName == card.agentName else {
            return Self.json(409, "{\"error\":\"Requesting agent identity changed; prepare a fresh login request\",\"errorCode\":\"AGENT_BINDING_CHANGED\"}")
        }
        if !oauth.isClientInstalled(serverId: serverId, clientRecordId: card.clientRecordId) {
            _ = oauth.installClient(serverId: serverId, clientRecordId: card.clientRecordId, installedByUserId: userId, groups: [])
        }
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        let setup = oauth.getAppInstallationSetup(clientRecordId: card.clientRecordId, serverId: serverId)
        let setupUrlJSON = setup?.url.map(jsonString) ?? "null"
        let result = "{\"kind\":\"marketplace-app-installation\",\"clientId\":\(jsonString(card.clientRecordId)),\"clientKey\":\(jsonString(card.clientKey)),\"clientName\":\(jsonString(card.clientName)),\"serverId\":\(jsonString(serverId)),\"agentId\":\(jsonString(card.agentId)),\"agentName\":\(jsonString(card.agentName)),\"scopes\":[\(scopes)],\"setupUrl\":\(setupUrlJSON)}"
        var updated = card
        updated.state = "executed"
        updated.executedByUserId = userId
        updated.resultJSON = result
        lock.lock()
        marketplaceInstallCards[card.messageId] = updated
        lock.unlock()
        return Self.json(200, "{\"messageId\":\(jsonString(card.messageId)),\"metadata\":\(marketplaceInstallMetadataJSON(updated))}")
    }

    func prepareAgentCreateCard(
        identity: (agentId: String, serverId: String),
        target: String,
        action: [String: Any]
    ) -> HTTPReply? {
        guard let name = (action["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.count <= 64
        else {
            return Self.json(400, "{\"error\":\"Invalid agent name\",\"code\":\"INVALID_PAYLOAD\"}")
        }
        guard target.hasPrefix("dm:@") else { return nil }
        var raw = String(target.dropFirst("dm:@".count))
        guard let colon = raw.lastIndex(of: ":") else {
            return Self.json(400, "{\"error\":\"Invalid DM thread target\",\"code\":\"INVALID_PAYLOAD\"}")
        }
        let suffix = String(raw[raw.index(after: colon)...])
        raw = String(raw[..<colon])
        guard !raw.isEmpty, !suffix.isEmpty else {
            return Self.json(400, "{\"error\":\"Invalid DM thread target\",\"code\":\"INVALID_PAYLOAD\"}")
        }
        lock.lock()
        let peerId = accounts.values.first(where: { $0.name == raw })?.id
        var dmId = postableChannels.first { _, channel in
            channel.kind == "dm" && channel.memberIds.contains(identity.agentId) && channel.memberIds.contains(peerId ?? "")
        }?.key
        let anchorId = dmId.flatMap { dm in
            oauth.historyMessages(channelId: dm).first { $0.id.hasPrefix(suffix) }?.id
                ?? humanMessageRows.first { $0.channelId == dm && $0.id.hasPrefix(suffix) }?.id
        }
        var threadId = dmId.flatMap { dm in
            anchorId.flatMap { anchor in
                postableChannels.first { _, channel in
                    channel.kind == "thread" && channel.parentChannelId == dm && channel.parentMessageId == anchor
                }?.key
            }
        }
        lock.unlock()
        guard let peerId else {
            return Self.json(404, "{\"error\":\"Target channel not found\",\"code\":\"TARGET_NOT_FOUND\"}")
        }
        if dmId == nil {
            let created = oauth.createDirectChannel(serverId: identity.serverId, firstUserId: identity.agentId, secondUserId: peerId)
            addPostableChannel(serverId: identity.serverId, channelId: created, memberId: identity.agentId, kind: "dm", name: "dm")
            addPostableChannel(serverId: identity.serverId, channelId: created, memberId: peerId, kind: "dm", name: "dm")
            oauth.addChannelHuman(channelId: created, userId: peerId)
            dmId = created
        }
        guard let dmId else {
            return Self.json(404, "{\"error\":\"Target channel not found\",\"code\":\"TARGET_NOT_FOUND\"}")
        }
        guard let anchorId else {
            return Self.json(404, "{\"error\":\"Thread target not found\",\"code\":\"TARGET_NOT_FOUND\"}")
        }
        if threadId == nil {
            let created = oauth.createThreadChannel(parentChannelId: dmId, parentMessageId: anchorId)
            addPostableChannel(serverId: identity.serverId, channelId: created, memberId: identity.agentId, kind: "thread", parentChannelId: dmId, parentMessageId: anchorId, name: "thread")
            addPostableChannel(serverId: identity.serverId, channelId: created, memberId: peerId, kind: "thread", parentChannelId: dmId, parentMessageId: anchorId, name: "thread")
            threadId = created
        }
        guard let threadId, let agent = oauth.agentRuntimeInfo(id: identity.agentId) else {
            return Self.json(404, "{\"error\":\"Target channel not found\",\"code\":\"TARGET_NOT_FOUND\"}")
        }
        let messageId = UUID().uuidString.lowercased()
        let content = "@\(agent.name) proposed creating agent @\(name)"
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: messageId,
            channelId: threadId,
            senderId: identity.agentId,
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "agent",
            actionKind: "action-card"
        ))
        actionCardRecords[messageId] = ActionCardRecord(
            messageId: messageId,
            serverId: identity.serverId,
            requesterAgentId: identity.agentId,
            storageChannelId: threadId,
            localCarrierChannelId: threadId,
            actionType: "agent:create",
            channelName: name,
            visibility: "channel",
            state: "prepared",
            executedByUserId: nil
        )
        lock.unlock()
        let metadata = "{\"kind\":\"action-card\",\"state\":\"prepared\",\"action\":{\"type\":\"agent:create\",\"name\":\(jsonString(name))},\"carrierChannelId\":\(jsonString(threadId))}"
        return Self.json(201, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
    }

    func prepareIntegrationActionCard(
        identity: (agentId: String, serverId: String), target: String, action: [String: Any]
    ) -> HTTPReply? {
        guard let type = action["type"] as? String,
              type == "integration:install_marketplace_app" || type == "integration:register_app"
        else { return nil }
        guard let resolved = actionCardTarget(serverId: identity.serverId, agentId: identity.agentId, target: target) else {
            return Self.json(404, "{\"error\":\"Target channel not found\",\"code\":\"TARGET_NOT_FOUND\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: identity.agentId) else {
            return Self.json(404, "{\"error\":\"Requester agent not found\",\"code\":\"AGENT_NOT_FOUND\"}")
        }
        if type == "integration:install_marketplace_app" {
            let clientRef = action["clientId"] as? String ?? ""
            let client: [String: Any]?
            if let marketplace = oauth.marketplaceInstallableClient(recordId: clientRef) {
                client = marketplace
            } else if let publicClient = oauth.publicIntegrationClient(clientId: action["clientKey"] as? String ?? clientRef) {
                client = publicClient
            } else {
                client = nil
            }
            guard let client, let messageId = prepareMarketplaceInstallCard(
                serverId: identity.serverId, agent: agent, client: client,
                scopes: (action["scopes"] as? [Any])?.compactMap { $0 as? String } ?? [],
                target: resolved
            ) else {
                return Self.json(404, "{\"error\":\"Integration app not found\"}")
            }
            lock.lock()
            let metadata = marketplaceInstallMetadataJSON(marketplaceInstallCards[messageId]!)
            lock.unlock()
            return Self.json(201, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
        }
        let rawScopes = (action["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []
        let allowedScopes: Set<String> = [
            "openid", "profile", "email", "offline_access", "identity",
            "agent:read", "agent:send", "agent:tasks", "agent:channels",
        ]
        if rawScopes.contains(where: { !allowedScopes.contains($0) }) {
            return Self.json(400, "{\"error\":\"Scope is not allowed for this service\",\"errorCode\":\"INVALID_SCOPE\"}")
        }
        if let category = action["category"] as? String, !Self.oauthClientCategories.contains(category) {
            return Self.json(400, "{\"error\":\"Category is not allowed\",\"errorCode\":\"INVALID_CATEGORY\"}")
        }
        if action["unsafeDemoUrlOverride"] as? Bool != true {
            for key in ["homepageUrl", "returnUrl"] {
                guard let raw = action[key] as? String, let url = URL(string: raw), let host = url.host else { continue }
                let privateHost = host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
                if privateHost {
                    return Self.json(400, "{\"error\":\"Unsafe demo URL requires the override\",\"errorCode\":\"UNSAFE_DEMO_URL_REQUIRES_OVERRIDE\"}")
                }
            }
        }
        guard let name = (action["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let returnUrl = (action["returnUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !returnUrl.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid app registration request\",\"errorCode\":\"INVALID_APP_METADATA\"}")
        }
        let setupUrl: String?
        let setupDescription: String?
        do {
            setupUrl = try AppSetupContract.normalizeSetupUrl(action["setupUrl"] as? String)
            setupDescription = try AppSetupContract.normalizeSetupDescription(action["setupDescription"] as? String)
        } catch let error as AppSetupValidationError {
            return Self.json(400, "{\"error\":\(jsonString(error.message)),\"errorCode\":\"INVALID_APP_METADATA\"}")
        } catch {
            return Self.json(400, "{\"error\":\"Invalid app metadata\",\"errorCode\":\"INVALID_APP_METADATA\"}")
        }
        let clientKey = (action["clientKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let messageId = prepareIntegrationRegisterCard(
            serverId: identity.serverId, agent: agent, name: name,
            clientKey: (clientKey?.isEmpty == false) ? clientKey : nil,
            homepageUrl: (action["homepageUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            returnUrl: returnUrl,
            agentManifestUrl: (action["agentManifestUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            setupUrl: setupUrl, setupDescription: setupDescription,
            scopes: rawScopes,
            target: resolved
        )
        lock.lock()
        let metadata = integrationRegisterMetadataJSON(integrationRegisterCards[messageId]!)
        lock.unlock()
        return Self.json(201, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
    }

    public func prepareActionCard(authorization: String?, body: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "send") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String,
              let action = object["action"] as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Invalid action card request\",\"code\":\"INVALID_PAYLOAD\"}")
        }
        if let reply = agentApiIdempotencyReply(agentId: identity.agentId, route: "actionPrepare", object: object) {
            return reply
        }
        if let reply = prepareIntegrationActionCard(identity: identity, target: target, action: action) {
            return reply
        }
        if let type = action["type"] as? String, type.hasPrefix("integration:") {
            return Self.json(400, "{\"error\":\"Integration approval cards must be prepared with the raft integration commands\",\"errorCode\":\"ACTION_TYPE_NOT_PREPARABLE\"}")
        }
        if (action["type"] as? String) == "agent:create" {
            if let reply = prepareAgentCreateCard(identity: identity, target: target, action: action) {
                return reply
            }
        }
        guard (action["type"] as? String) == "channel:create",
              let channelName = action["name"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid action card request\",\"code\":\"INVALID_PAYLOAD\"}")
        }
        if (action["type"] as? String) == "channel:add_member" {
            let channel = action["channel"] as? String ?? ""
            guard ServerScope.isUUID(channel), oauth.channelServerId(channelId: channel) == identity.serverId else {
                return Self.json(400, "{\"error\":\"channel must belong to this server\",\"code\":\"INVALID_PAYLOAD\"}")
            }
            return Self.json(501, "{\"error\":\"channel:add_member cards are not supported\",\"code\":\"NOT_SUPPORTED\"}")
        }
        if let initialAgents = action["initialAgents"] as? [Any] {
            for (index, raw) in initialAgents.enumerated() {
                guard let agentId = raw as? String, ServerScope.isUUID(agentId),
                      oauth.agentRuntimeInfo(id: agentId)?.serverId == identity.serverId else {
                    return Self.json(400, "{\"error\":\"initialAgents[\(index)] is not an agent on this server\",\"code\":\"INVALID_PAYLOAD\"}")
                }
            }
        }
        if let initialHumans = action["initialHumans"] as? [Any] {
            for (index, raw) in initialHumans.enumerated() {
                guard let userId = raw as? String, ServerScope.isUUID(userId),
                      oauth.memberRole(serverId: identity.serverId, userId: userId) != nil else {
                    return Self.json(400, "{\"error\":\"initialHumans[\(index)] is not a member of this server\",\"code\":\"INVALID_PAYLOAD\"}")
                }
            }
        }
        let trimmedName = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64 else {
            return Self.json(400, "{\"error\":\"Invalid channel name\",\"code\":\"INVALID_PAYLOAD\"}")
        }
        let visibility = (action["visibility"] as? String) == "private" ? "private" : "channel"
        let resolved: (local: String, storage: String)
        if ServerScope.isUUID(target) {
            guard oauth.channelServerId(channelId: target) == identity.serverId else {
                return Self.json(404, "{\"error\":\"Target channel not found\",\"code\":\"TARGET_NOT_FOUND\"}")
            }
            let isChannel = oauth.channelKind(channelId: target) == "channel"
            let isMember = oauth.channelAgentIds(channelId: target).contains(identity.agentId)
                || oauth.channelHumanIds(channelId: target).contains(identity.agentId)
            guard isChannel || isMember else {
                return Self.json(403, "{\"error\":\"Target channel is not accessible\",\"code\":\"TARGET_NOT_ACCESSIBLE\"}")
            }
            resolved = (target, target)
        } else {
            guard let byName = actionCardTarget(serverId: identity.serverId, agentId: identity.agentId, target: target) else {
                return Self.json(404, "{\"error\":\"Target channel not found\",\"code\":\"TARGET_NOT_FOUND\"}")
            }
            resolved = byName
        }
        guard let agent = oauth.agentRuntimeInfo(id: identity.agentId) else {
            return Self.json(404, "{\"error\":\"Requester agent not found\",\"code\":\"AGENT_NOT_FOUND\"}")
        }
        let messageId = UUID().uuidString.lowercased()
        let content = "@\(agent.name) proposed creating channel #\(trimmedName)"
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: messageId,
            channelId: resolved.storage,
            senderId: identity.agentId,
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "agent",
            actionKind: "action-card"
        ))
        actionCardRecords[messageId] = ActionCardRecord(
            messageId: messageId,
            serverId: identity.serverId,
            requesterAgentId: identity.agentId,
            storageChannelId: resolved.storage,
            localCarrierChannelId: resolved.local,
            actionType: "channel:create",
            channelName: trimmedName,
            visibility: visibility,
            state: "prepared",
            executedByUserId: nil
        )
        lock.unlock()
        let metadata = "{\"kind\":\"action-card\",\"state\":\"prepared\",\"action\":{\"type\":\"channel:create\",\"name\":\(jsonString(trimmedName)),\"visibility\":\(jsonString(visibility))},\"carrierChannelId\":\(jsonString(resolved.storage))}"
        let idempotentReply = Self.json(201, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
        storeAgentApiIdempotency(agentId: identity.agentId, route: "actionPrepare", object: object, reply: idempotentReply)
        return idempotentReply
    }

    func actionCardServerName(_ serverId: String) -> String {
        oauth.serverProfile(id: serverId)?.name ?? "this Server"
    }

    /// Writes the durable result reply into the card's thread, records the
    /// preparer's unread mention fact, and queues the external-agent event.
    func postActionCardReply(
        card: ActionCardRecord,
        confirmerUserId: String,
        success: Bool,
        resultName: String?,
        failureReason: String?
    ) {
        guard let requester = oauth.agentRuntimeInfo(id: card.requesterAgentId) else { return }
        lock.lock()
        let confirmer = accounts.values.first { $0.id == confirmerUserId }
        let confirmerHandle = confirmer?.name ?? "a human"
        let serverName = oauth.serverProfile(id: card.serverId)?.name ?? "this Server"
        let storageServerId = postableChannels[card.storageChannelId]?.serverId ?? card.serverId
        var canonicalThread = postableChannels.first { _, channel in
            channel.kind == "thread"
                && channel.parentChannelId == card.storageChannelId
                && channel.parentMessageId == card.messageId
        }?.key
        var createdThread = false
        if canonicalThread == nil {
            let threadId = oauth.createThreadChannel(parentChannelId: card.storageChannelId, parentMessageId: card.messageId)
            var thread = postableChannels[threadId] ?? PostableChannel(serverId: storageServerId, memberIds: [])
            thread.serverId = storageServerId
            thread.kind = "thread"
            thread.parentChannelId = card.storageChannelId
            thread.parentMessageId = card.messageId
            thread.name = "thread"
            thread.memberIds.insert(card.requesterAgentId)
            thread.memberIds.insert(confirmerUserId)
            if let parentMembers = postableChannels[card.storageChannelId]?.memberIds {
                thread.memberIds.formUnion(parentMembers)
            }
            postableChannels[threadId] = thread
            canonicalThread = threadId
            createdThread = true
        }
        guard let threadId = canonicalThread else {
            lock.unlock()
            return
        }
        // Give each Joint projection its own thread row pointing at the
        // canonical thread, so either human surface can read the reply.
        for link in jointProjections where link.canonicalChannelId == card.storageChannelId {
            let existing = postableChannels.first { _, channel in
                channel.kind == "thread" && channel.parentChannelId == link.localChannelId && channel.parentMessageId == card.messageId
            }?.key
            let localThreadId: String
            if let existing {
                localThreadId = existing
            } else {
                let created = oauth.createThreadChannel(parentChannelId: link.localChannelId, parentMessageId: card.messageId)
                var thread = postableChannels[created] ?? PostableChannel(serverId: link.serverId, memberIds: [])
                thread.serverId = link.serverId
                thread.kind = "thread"
                thread.parentChannelId = link.localChannelId
                thread.parentMessageId = card.messageId
                thread.name = "thread"
                thread.memberIds.insert(card.requesterAgentId)
                thread.memberIds.insert(confirmerUserId)
                if let parentMembers = postableChannels[link.localChannelId]?.memberIds {
                    thread.memberIds.formUnion(parentMembers)
                }
                postableChannels[created] = thread
                jointProjections.append(JointChannelLink(localChannelId: created, canonicalChannelId: threadId, serverId: link.serverId))
                localThreadId = created
            }
            if localThreadId != threadId {
                postableChannels[localThreadId]?.memberIds.insert(card.requesterAgentId)
                postableChannels[localThreadId]?.memberIds.insert(confirmerUserId)
            }
        }
        _ = createdThread
        let cardRef = "\(card.messageId.prefix(8))"
        let content: String
        if success {
            content = [
                "@\(requester.name) your action card `\(cardRef)` (creating channel #\(card.channelName ?? "")) was executed by @\(confirmerHandle) on \(serverName), acting with @\(confirmerHandle)'s permissions.",
                resultName.map { "Result: created channel #\($0)." },
            ].compactMap { $0 }.joined(separator: "\n")
        } else {
            content = "@\(requester.name) your action card `\(cardRef)` (creating channel #\(card.channelName ?? "")) failed when @\(confirmerHandle) tried to execute it on \(serverName): \(failureReason ?? "the action could not be completed"). The card is still pending and can be retried."
        }
        let replyId = UUID().uuidString.lowercased()
        appendHumanMessageLocked(StoredHumanMessage(
            id: replyId,
            channelId: threadId,
            senderId: "system",
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "system"
        ))
        inboxFactStore.append(StoredInboxFact(
            messageId: replyId,
            receiverType: "agent",
            receiverId: card.requesterAgentId,
            channelId: threadId,
            serverId: card.serverId,
            personalMention: true,
            unreadEligible: true
        ))
        inboxFactStore.append(StoredInboxFact(
            messageId: replyId,
            receiverType: "user",
            receiverId: confirmerUserId,
            channelId: threadId,
            serverId: card.serverId,
            personalMention: true,
            unreadEligible: false
        ))
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: replyId,
            channelId: threadId,
            senderId: "system",
            targetType: "agent",
            targetId: card.requesterAgentId,
            handle: requester.name,
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil
        ))
        if requester.runtime == "external" {
            pendingActionMessageEvents.append((card.requesterAgentId, replyId, content))
        }
        lock.unlock()
        emitRealtime("channel:\(threadId)", "message:new", "{\"id\":\(jsonString(replyId)),\"channelId\":\(jsonString(threadId)),\"content\":\(jsonString(content))}")
    }

    @discardableResult
    public func addActionCardForTesting(
        serverId: String, agentId: String, carrierChannelId: String,
        actionType: String = "channel:create", state: String = "prepared"
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        actionCardRecords[id] = ActionCardRecord(
            messageId: id, serverId: serverId, requesterAgentId: agentId,
            storageChannelId: carrierChannelId, localCarrierChannelId: carrierChannelId,
            actionType: actionType, channelName: "test-card-channel", visibility: "public",
            state: state, executedByUserId: nil
        )
        lock.unlock()
        return id
    }

    public func actionCardStateForTesting(messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return actionCardRecords[messageId]?.state
    }

    func actionCardWriteAuthorization(userId: String, card: ActionCardRecord) -> HTTPReply? {
        guard oauth.memberRole(serverId: card.serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let role = oauth.memberRole(serverId: card.serverId, userId: userId)
        let allowed = role == "owner" || role == "admin"
        lock.lock()
        let channel = postableChannels[card.localCarrierChannelId] ?? postableChannels[card.storageChannelId]
        let isMember = channel?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: card.localCarrierChannelId).contains(userId)
            || oauth.channelHumanIds(channelId: card.storageChannelId).contains(userId)
        let closed = channel.map { $0.kind != "channel" } ?? (oauth.channelKind(channelId: card.localCarrierChannelId) != "channel")
        lock.unlock()
        if allowed || isMember { return nil }
        return closed
            ? Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
            : Self.json(403, "{\"error\":\"Forbidden\"}")
    }

    public func executeActionCard(authorization: String?, serverId: String, messageId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if oauth.memberRole(serverId: serverId, userId: userId) == "guest" {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let installCard = marketplaceInstallCards[messageId]
        let registerCard = integrationRegisterCards[messageId]
        lock.unlock()
        if let installCard {
            return executeMarketplaceInstallCard(installCard, userId: userId, serverId: serverId, body: body)
        }
        if let registerCard {
            return executeIntegrationRegisterCard(registerCard, userId: userId, serverId: serverId, body: body)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let card = actionCardRecords[messageId]
        lock.unlock()
        guard let card else {
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        if let refusal = actionCardWriteAuthorization(userId: userId, card: card) { return refusal }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        if let expected = object?["expectedState"] as? String, expected == "executed", card.state != "executed" {
            return Self.json(409, "{\"error\":\"The action card is not executed\",\"code\":\"STATE_MISMATCH\"}")
        }
        if card.state == "executed" {
            return Self.json(200, "{\"messageId\":\(jsonString(messageId)),\"metadata\":{\"kind\":\"action-card\",\"state\":\"executed\"}}")
        }
        let name = card.channelName ?? ""
        lock.lock()
        let duplicate = postableChannels.values.contains {
            $0.serverId == card.serverId && $0.name == name && $0.deletedAt == nil
                && ($0.kind == "channel" || $0.kind == "private")
        }
        lock.unlock()
        if duplicate {
            let reason = "a channel named #\(name) already exists"
            postActionCardReply(card: card, confirmerUserId: userId, success: false, resultName: nil, failureReason: reason)
            return Self.json(409, "{\"error\":\"\(reason)\",\"code\":\"ACTION_FAILED\",\"reason\":\(jsonString(reason))}")
        }
        let channelId = oauth.createChannel(
            serverId: card.serverId,
            name: name,
            creatorUserId: userId,
            type: card.visibility == "private" ? "private" : "channel"
        )
        addPostableChannel(
            serverId: card.serverId,
            channelId: channelId,
            memberId: userId,
            kind: card.visibility == "private" ? "private" : "channel",
            name: name
        )
        addPostableChannel(serverId: card.serverId, channelId: channelId, memberId: card.requesterAgentId, kind: card.visibility == "private" ? "private" : "channel", name: name)
        oauth.addChannelHuman(channelId: channelId, userId: userId)
        oauth.addChannelAgent(channelId: channelId, agentId: card.requesterAgentId)
        lock.lock()
        if var updated = actionCardRecords[messageId] {
            updated.state = "executed"
            updated.executedByUserId = userId
            actionCardRecords[messageId] = updated
        }
        lock.unlock()
        postActionCardReply(card: card, confirmerUserId: userId, success: true, resultName: name, failureReason: nil)
        let metadata = "{\"kind\":\"action-card\",\"state\":\"executed\",\"action\":{\"type\":\"channel:create\",\"name\":\(jsonString(name))},\"result\":{\"kind\":\"channel\",\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name))}}"
        return Self.json(200, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
    }

    /// `POST /api/actions/:messageId/mark-executed`: a human records an action
    /// card as already carried out. Guests are read-only and cannot mark it.
    public func markActionCardExecuted(authorization: String?, serverId: String, messageId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if oauth.memberRole(serverId: serverId, userId: userId) == "guest" {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let stored = actionCardRecords[messageId]
        lock.unlock()
        guard let stored else {
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        if let refusal = actionCardWriteAuthorization(userId: userId, card: stored) { return refusal }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let result = object["result"] as? [String: Any], let kind = result["kind"] as? String else {
            return Self.json(400, "{\"error\":\"A result is required\",\"code\":\"INVALID_RESULT\"}")
        }
        if stored.actionType == "channel:create", kind != "channel" {
            return Self.json(409, "{\"error\":\"The result kind does not match this action\",\"code\":\"INCOMPATIBLE_RESULT\"}")
        }
        lock.lock()
        guard var card = actionCardRecords[messageId] else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        if card.state != "executed" {
            card.state = "executed"
            card.executedByUserId = userId
            actionCardRecords[messageId] = card
        }
        let metadata = actionCardMetadataLocked(messageId: messageId) ?? "{\"kind\":\"action-card\",\"state\":\"executed\"}"
        lock.unlock()
        return Self.json(200, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
    }

}
