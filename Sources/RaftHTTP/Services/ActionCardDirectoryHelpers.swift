import Foundation
import RaftShared

extension EmailLoginDirectory {
    // Task credential/channel/freshness forwarders for the services that have
    // not migrated yet. The policy lives in `ActionCardExecuteService`; these
    // only keep the legacy signatures those callers already hold.

    func agentTaskAuth(authorization: String?, legacyAgentId: String?) -> AgentTaskAuthResult {
        do {
            let identity = try actionCardExecute.taskAuth(
                authorization: authorization,
                legacyAgentId: legacyAgentId
            )
            return .ok(agentId: identity.agentId, serverId: identity.serverId)
        } catch let error as any DomainError {
            return .refused(Self.json(Int(error.status), error.publishedErrorBody.render()))
        } catch {
            return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
    }

    func agentTaskWriter(_ authorization: String?, legacyAgentId: String?) -> (agentId: String, serverId: String)? {
        actionCardExecute.taskWriter(authorization: authorization, legacyAgentId: legacyAgentId)
    }

    func agentTaskChannel(serverId: String, agentId: String, reference: String) -> String? {
        actionCardExecute.taskChannel(serverId: serverId, agentId: agentId, reference: reference)
    }

    func taskWriteFreshnessHold(
        agentId: String,
        channelId: String,
        seenUpToSeq: Int?,
        actionKey: String
    ) -> AgentTaskWriteHoldResponse? {
        actionCardExecute.taskWriteHold(
            agentId: agentId,
            channelId: channelId,
            seenUpToSeq: seenUpToSeq,
            actionKey: actionKey
        )
    }

    /// Thin forwarder for the metadata projections below: the live server name
    /// is published by the action-card integration-register service now.
    func actionCardServerName(_ serverId: String) -> String {
        actionCardIntegrationRegister.actionCardServerName(serverId)
    }

    // MARK: - Action-card and thread helpers
    //
    // Shared lookups and card projections that unmigrated callers still use
    // (managed-MCP control plane, integrations/app access, inbox, search and
    // the integration-register service's dependency closures). Moved here
    // unchanged from the marketplace slice's `extension EmailLoginDirectory`.

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

    // MARK: - Service accessors

    /// Agent task create/convert/delete/assign/resource-receipt and the agent
    /// inbox conversation list. The directory supplies the domain stores and
    /// the OAuth ledger; the idempotency ledger (managed-MCP catalog) and the
    /// message-append policy (messaging) are not-yet-migrated dependencies and
    /// enter as the two closures below.
    public var actionCardMarketplace: ActionCardMarketplaceService {
        ActionCardMarketplaceService(
            tasks: tasksAndRemindersStore,
            messages: messagesAndThreadsStore,
            inboxFacts: inboxFactStore,
            channels: serversAndChannelsStore,
            accounts: authProfileStore,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            cards: managedMCPAndCardsStore,
            oauth: oauth,
            locator: FeedbackLocatorService(directory: self),
            idempotency: ActionCardTaskIdempotency(
                lookup: { [self] agentId, route, rawBody in
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(rawBody.utf8))) as? [String: Any],
                          let reply = agentApiIdempotencyReply(agentId: agentId, route: route, object: object)
                    else { return .miss }
                    if reply.status == 409 { return .conflict(body: reply.body) }
                    return .replay(body: reply.body)
                },
                store: { [self] agentId, route, rawBody, body in
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(rawBody.utf8))) as? [String: Any]
                    else { return }
                    storeAgentApiIdempotency(
                        agentId: agentId,
                        route: route,
                        object: object,
                        reply: HTTPReply(status: 200, headers: [:], body: body)
                    )
                }
            ),
            appendHumanMessage: { [self] message in
                lock.lock()
                let seq = appendHumanMessageLocked(message)
                lock.unlock()
                return seq
            },
            serializeReceipt: { payload in
                guard let object = legacyJSONObject(payload) as? [String: Any] else { return "{}" }
                return EmailLoginDirectory.serializeJSON(object)
            }
        )
    }

    /// Action-card prepare/execute and the integration app-registration
    /// surface. The directory supplies the stores and the OAuth ledger; the
    /// marketplace target resolver, the integration-card preparer and the two
    /// card projections belong to the not-yet-migrated action-card marketplace
    /// module and enter as closures, as do the human session ledger, the
    /// message append that stamps a server sequence, the channel roster write
    /// and the realtime relay.
    public var actionCardIntegrationRegister: ActionCardIntegrationRegisterService {
        ActionCardIntegrationRegisterService(
            cards: managedMCPAndCardsStore,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            inboxFacts: inboxFactStore,
            accounts: authProfileStore,
            agents: agentsRuntimeStore,
            oauth: oauth,
            dependencies: ActionCardIntegrationRegisterDependencies(
                sessionUserId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                agentCredential: { [self] authorization in
                    agentCredentialAgent(authorization)
                },
                identityResolution: { [self] authorization, capability in
                    FeedbackLocatorService(
                        feedback: feedbackStore,
                        agents: agentsRuntimeStore,
                        channels: serversAndChannelsStore,
                        cards: managedMCPAndCardsStore,
                        oauth: oauth
                    ).identityResolution(authorization: authorization, capability: capability)
                },
                appendHumanMessage: { [self] message in
                    lock.lock()
                    let seq = appendHumanMessageLocked(message)
                    lock.unlock()
                    return seq
                },
                addPostableChannel: { [self] serverId, channelId, memberId, kind, parentChannelId, parentMessageId, name in
                    addPostableChannel(
                        serverId: serverId,
                        channelId: channelId,
                        memberId: memberId,
                        kind: kind,
                        parentChannelId: parentChannelId,
                        parentMessageId: parentMessageId,
                        name: name
                    )
                },
                emitRealtime: { [self] room, event, payload in
                    emitRealtime(room, event, payload)
                },
                actionCardTarget: { [self] serverId, agentId, target in
                    self.actionCardTarget(serverId: serverId, agentId: agentId, target: target)
                },
                prepareIntegrationRegisterCard: { [self] serverId, agent, name, clientKey, homepageUrl, returnUrl, agentManifestUrl, setupUrl, setupDescription, scopes, target in
                    prepareIntegrationRegisterCard(
                        serverId: serverId,
                        agent: agent,
                        name: name,
                        clientKey: clientKey,
                        homepageUrl: homepageUrl,
                        returnUrl: returnUrl,
                        agentManifestUrl: agentManifestUrl,
                        setupUrl: setupUrl,
                        setupDescription: setupDescription,
                        scopes: scopes,
                        target: target
                    )
                },
                marketplaceInstallMetadata: { [self] card in
                    marketplaceInstallMetadataJSON(card)
                },
                integrationRegisterMetadata: { [self] card in
                    integrationRegisterMetadataJSON(card)
                },
                marketplaceInstallableClient: { [self] recordId in
                    oauth.marketplaceInstallableClientIdentity(recordId: recordId)
                },
                publicIntegrationClient: { [self] clientId in
                    oauth.publicIntegrationClientIdentity(clientId: clientId)
                }
            )
        )
    }
}

/// Bridges a decoded `JSONValue` back to the `Any` tree the legacy
/// `serializeJSON` helper expects. Only the resource-receipt notes field uses
/// it; the value was produced by the same JSON decoder the raw parser fed.
private func legacyJSONObject(_ value: JSONValue) -> Any {
    switch value {
    case .object(let members):
        return members.mapValues(legacyJSONObject)
    case .array(let values):
        return values.map(legacyJSONObject)
    case .string(let string):
        return string
    case .number(let number):
        return number
    case .integer(let integer):
        return integer
    case .bool(let boolean):
        return boolean
    case .null:
        return NSNull()
    }
}
