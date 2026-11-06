import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Integration marketplace registration, `prepare-action` and action-card execute.
/// Migrated verbatim from the second half of `EmailLogin+ActionCards2.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ActionCardIntegrationRegisterService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {
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
        let declaration = oauth.clientSetupDeclaration(clientRecordId: recordId)
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
        let declaration = oauth.clientSetupDeclaration(clientRecordId: card.clientRecordId)
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
}
