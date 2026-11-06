import Crypto
import Foundation
import RaftShared

/// The typed outcome of the action-card write policy shared by the execute and
/// mark-executed routes.
enum ActionCardWriteDecision: Sendable, Equatable {
    case allowed
    case notMember
    case forbidden
    case notFound
}

/// The closure dependencies of the action-card integration-register domain
/// that still live in not-yet-migrated domains.
///
/// Everything else is a store or the OAuth ledger: the marketplace target
/// resolver, the integration-card preparer and the card projections are owned
/// by this service (`ActionCardMetadataProjection`). `appendHumanMessage` is the directory-lock message append (sequence stamp +
/// OAuth mirror); `emitRealtime` is the realtime relay; `sessionUserId` is the
/// human session ledger; `agentCredential` is the agent credential lookup that
/// records `lastUsedAt`.
struct ActionCardIntegrationRegisterDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var agentCredential: @Sendable (String?) -> (agentId: String, scopes: [String])?
    var identityResolution: @Sendable (String?, String) -> FeedbackLocatorService.IdentityResolution
    var appendHumanMessage: @Sendable (StoredHumanMessage) -> Int
    var addPostableChannel: @Sendable (
        _ serverId: String,
        _ channelId: String,
        _ memberId: String,
        _ kind: String,
        _ parentChannelId: String?,
        _ parentMessageId: String?,
        _ name: String?
    ) -> Void
    var emitRealtime: @Sendable (String, String, String?) -> Void
    var marketplaceInstallableClient: @Sendable (String) -> MarketplaceClientIdentity?
    var publicIntegrationClient: @Sendable (String) -> MarketplaceClientIdentity?
}

/// Integration-marketplace registration, generic action-card prepare
/// (`channel:create`, `agent:create`, the integration card types) and
/// action-card execute.
///
/// The service owns the orchestration and the published error shapes. Card
/// rows live in `ManagedMCPAndCardsStore`, thread carriers in
/// `ServersAndChannelsStore`, reply messages/mentions in
/// `MessagesAndThreadsStore`, inbox facts in `InboxFactStore`, accounts in
/// `AuthProfileStore`, credentials in `AgentsRuntimeStore`, and server/client
/// records in the `OAuthLedger`. Every read-modify-write of one store's rows is
/// a single store method.
public struct ActionCardIntegrationRegisterService: Sendable {
    /// Categories the integration app registration accepts.
    static let oauthClientCategories: Set<String> = [
        "AI & Automation", "Communication", "Productivity & Collaboration",
        "Developer Tools", "Data & Analytics", "Business Ops",
        "Infrastructure", "Content & Creative", "Other",
        "Productivity", "Dev Tools", "Storage", "Scheduling",
        "Business & Operations", "Infrastructure & Operations",
    ]

    /// Scopes an agent may request on a prepared card.
    static let allowedScopes: Set<String> = [
        "openid", "profile", "email", "offline_access", "identity",
        "agent:read", "agent:send", "agent:tasks", "agent:channels",
    ]

    private let cards: ManagedMCPAndCardsStore
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let inboxFacts: InboxFactStore
    private let accounts: AuthProfileStore
    private let agents: AgentsRuntimeStore
    private let oauth: OAuthLedger
    private let dependencies: ActionCardIntegrationRegisterDependencies
    private let now: @Sendable () -> Date
    private let makeId: @Sendable () -> String

    init(
        cards: ManagedMCPAndCardsStore,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        inboxFacts: InboxFactStore,
        accounts: AuthProfileStore,
        agents: AgentsRuntimeStore,
        oauth: OAuthLedger,
        dependencies: ActionCardIntegrationRegisterDependencies,
        now: @escaping @Sendable () -> Date = { Date() },
        makeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.cards = cards
        self.channels = channels
        self.messages = messages
        self.inboxFacts = inboxFacts
        self.accounts = accounts
        self.agents = agents
        self.oauth = oauth
        self.dependencies = dependencies
        self.now = now
        self.makeId = makeId
    }

    // MARK: - `POST /internal/agent-api/integrations/app/prepare`

    /// Prepares an `integration:register_app` action card from an agent
    /// credential.
    ///
    /// Published order: authorization (401), `send` capability (403), body
    /// (400), target resolution (404), scope allow-list, category, unsafe-URL
    /// check, then the `201`. The body must be `mode == "register"` with a
    /// non-empty trimmed name and return URL.
    public func agentIntegrationAppPrepare(
        authorization: String?,
        body: IntegrationAppPrepareRequest?
    ) throws -> IntegrationAppPrepareResponse {
        guard let credential = dependencies.agentCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw ActionCardIntegrationRegisterError.invalidOrExpiredToken
        }
        guard credential.scopes.contains("send") else {
            throw ActionCardIntegrationRegisterError.capabilityNotAuthorized(capability: "send")
        }
        let request = body ?? IntegrationAppPrepareRequest()
        let name = (request.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let returnUrl = (request.returnUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.mode == "register", !name.isEmpty, !returnUrl.isEmpty else {
            throw ActionCardIntegrationRegisterError.invalidAppRegistrationRequest
        }
        let targetRef = (request.target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = actionCardTarget(serverId: agent.serverId, agentId: agent.id, target: targetRef) else {
            throw ActionCardIntegrationRegisterError.targetChannelNotFound
        }
        let clientKey = request.clientKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let homepageUrl = request.homepageUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let agentManifestUrl = request.agentManifestUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = request.scopes
        guard scopes.allSatisfy({ Self.allowedScopes.contains($0) }) else {
            throw ActionCardIntegrationRegisterError.scopeNotAllowed
        }
        if let category = request.category, !Self.oauthClientCategories.contains(category) {
            throw ActionCardIntegrationRegisterError.categoryNotAllowed
        }
        if !request.unsafeDemoUrlOverride {
            for raw in [homepageUrl, returnUrl].compactMap({ $0 }) {
                guard let url = URL(string: raw), let host = url.host else { continue }
                if Self.isPrivateHost(host) {
                    throw ActionCardIntegrationRegisterError.unsafeDemoUrlRequiresOverride
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
            setupUrl: nil,
            setupDescription: nil,
            scopes: scopes,
            target: resolved
        )
        return IntegrationAppPrepareResponse(
            actionCardMessageId: messageId,
            action: IntegrationAppPrepareAction(
                name: name,
                clientKey: (clientKey?.isEmpty == false) ? clientKey : nil,
                homepageUrl: (homepageUrl?.isEmpty == false) ? homepageUrl : nil,
                returnUrl: returnUrl,
                scopes: scopes
            )
        )
    }

    // MARK: - `POST /internal/agent-api/prepare-action`

    /// Prepares one action card for the calling agent.
    ///
    /// The published order is authorization, body shape, the idempotency
    /// lookup, the two integration card types, `agent:create`, then the
    /// `channel:create` validation sequence. An idempotent replay returns the
    /// first reply's stored bytes unchanged.
    public func prepareActionCard(
        authorization: String?,
        body: ActionCardPrepareRequest?
    ) throws -> ActionCardPrepareResponse {
        let identity: (agentId: String, serverId: String)
        switch dependencies.identityResolution(authorization, "send") {
        case .success(let agentId, let serverId):
            identity = (agentId, serverId)
        case .missingAuthorization:
            throw ActionCardIntegrationRegisterError.missingAuthorization
        case .invalidAccessToken:
            throw ActionCardIntegrationRegisterError.invalidAccessToken
        case .capabilityNotAuthorized(let capability):
            throw ActionCardIntegrationRegisterError.capabilityNotAuthorized(capability: capability)
        case .invalidAgentCredential:
            throw ActionCardIntegrationRegisterError.invalidAgentCredential
        }
        let request = body ?? ActionCardPrepareRequest()
        guard let target = request.target, let action = request.action else {
            throw ActionCardIntegrationRegisterError.invalidActionCardRequest
        }
        if let replay = try idempotentPrepareReplay(agentId: identity.agentId, request: request) {
            return replay
        }
        if let prepared = try prepareIntegrationActionCard(
            identity: identity,
            target: target,
            action: action
        ) {
            return storePrepareIdempotency(
                agentId: identity.agentId,
                request: request,
                response: prepared
            )
        }
        if let type = action["type"]?.legacyString, type.hasPrefix("integration:") {
            throw ActionCardIntegrationRegisterError.integrationApprovalNotPreparable
        }
        if action["type"]?.legacyString == "agent:create",
           let prepared = try prepareAgentCreateCard(
               identity: identity,
               target: target,
               action: action
           ) {
            return storePrepareIdempotency(
                agentId: identity.agentId,
                request: request,
                response: prepared
            )
        }
        guard action["type"]?.legacyString == "channel:create",
              let rawChannelName = action["name"]?.legacyString
        else {
            throw ActionCardIntegrationRegisterError.invalidActionCardRequest
        }
        if let initialAgents = action["initialAgents"], case .array(let rawAgents) = initialAgents {
            for (index, raw) in rawAgents.enumerated() {
                guard let agentId = raw.legacyString, ServerScope.isUUID(agentId),
                      oauth.agentRuntimeInfo(id: agentId)?.serverId == identity.serverId
                else {
                    throw ActionCardIntegrationRegisterError.initialAgentInvalid(index: index)
                }
            }
        }
        if let initialHumans = action["initialHumans"], case .array(let rawHumans) = initialHumans {
            for (index, raw) in rawHumans.enumerated() {
                guard let userId = raw.legacyString, ServerScope.isUUID(userId),
                      oauth.memberRole(serverId: identity.serverId, userId: userId) != nil
                else {
                    throw ActionCardIntegrationRegisterError.initialHumanInvalid(index: index)
                }
            }
        }
        let trimmedName = rawChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64 else {
            throw ActionCardIntegrationRegisterError.invalidChannelName
        }
        let visibility = action["visibility"]?.legacyString == "private" ? "private" : "channel"
        let resolved: (local: String, storage: String)
        if ServerScope.isUUID(target) {
            guard oauth.channelServerId(channelId: target) == identity.serverId else {
                throw ActionCardIntegrationRegisterError.targetChannelNotFound
            }
            let isChannel = oauth.channelKind(channelId: target) == "channel"
            let isMember = oauth.channelAgentIds(channelId: target).contains(identity.agentId)
                || oauth.channelHumanIds(channelId: target).contains(identity.agentId)
            guard isChannel || isMember else {
                throw ActionCardIntegrationRegisterError.targetNotAccessible
            }
            resolved = (target, target)
        } else {
            guard let byName = actionCardTarget(
                serverId: identity.serverId,
                agentId: identity.agentId,
                target: target
            ) else {
                throw ActionCardIntegrationRegisterError.targetChannelNotFound
            }
            resolved = byName
        }
        guard let agent = oauth.agentRuntimeInfo(id: identity.agentId) else {
            throw ActionCardIntegrationRegisterError.requesterAgentNotFound
        }
        let messageId = makeId()
        let content = "@\(agent.name) proposed creating channel #\(trimmedName)"
        _ = dependencies.appendHumanMessage(StoredHumanMessage(
            id: messageId,
            channelId: resolved.storage,
            senderId: identity.agentId,
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "agent",
            actionKind: "action-card"
        ))
        cards.insertActionCardRecord(ActionCardRecord(
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
        ))
        let metadata = OrderedJSON.object([
            OrderedJSONField("kind", "action-card"),
            OrderedJSONField("state", "prepared"),
            OrderedJSONField("action", .object([
                OrderedJSONField("type", "channel:create"),
                OrderedJSONField("name", trimmedName),
                OrderedJSONField("visibility", visibility),
            ])),
            OrderedJSONField("carrierChannelId", resolved.storage),
        ]).render()
        return storePrepareIdempotency(
            agentId: identity.agentId,
            request: request,
            response: ActionCardPrepareResponse(messageId: messageId, metadataJSON: metadata)
        )
    }

    // MARK: - `POST /api/actions/:messageId/execute`

    /// Executes one prepared action card as the calling human.
    ///
    /// The published order is authorization (401), guest (403), the three card
    /// stores, membership (403), the shared write policy, the state checks
    /// (409/200), the duplicate-channel check, then the channel create and the
    /// thread reply.
    public func executeActionCard(
        authorization: String?,
        serverId: String,
        messageId: String,
        body: ActionCardExecuteRequest?
    ) throws -> ActionCardExecuteResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ActionCardIntegrationRegisterError.unauthorized
        }
        if oauth.memberRole(serverId: serverId, userId: userId) == "guest" {
            throw ActionCardIntegrationRegisterError.forbidden
        }
        if let installCard = cards.marketplaceInstallCard(messageId: messageId) {
            return try executeMarketplaceInstallCard(
                installCard,
                userId: userId,
                serverId: serverId,
                expectedState: body?.expectedState
            )
        }
        if let registerCard = cards.integrationRegisterCard(messageId: messageId) {
            return try executeIntegrationRegisterCard(
                registerCard,
                userId: userId,
                serverId: serverId,
                expectedState: body?.expectedState
            )
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ActionCardIntegrationRegisterError.notAMember
        }
        guard let card = cards.actionCard(messageId: messageId) else {
            throw ActionCardIntegrationRegisterError.actionCardNotFound
        }
        switch actionCardWriteDecision(userId: userId, card: card) {
        case .allowed:
            break
        case .notMember:
            throw ActionCardIntegrationRegisterError.notAMember
        case .forbidden:
            throw ActionCardIntegrationRegisterError.forbidden
        case .notFound:
            throw ActionCardIntegrationRegisterError.actionCardNotFound
        }
        if let expected = body?.expectedState, expected == "executed", card.state != "executed" {
            throw ActionCardIntegrationRegisterError.notExecuted
        }
        if card.state == "executed" {
            return ActionCardExecuteResponse(
                messageId: messageId,
                metadataJSON: "{\"kind\":\"action-card\",\"state\":\"executed\"}"
            )
        }
        let name = card.channelName ?? ""
        if channels.isDuplicateActionCardChannelName(serverId: card.serverId, name: name) {
            let reason = "a channel named #\(name) already exists"
            postActionCardReply(
                card: card,
                confirmerUserId: userId,
                success: false,
                resultName: nil,
                failureReason: reason
            )
            throw ActionCardIntegrationRegisterError.duplicateChannel(reason: reason)
        }
        let kind = card.visibility == "private" ? "private" : "channel"
        let channelId = oauth.createChannel(
            serverId: card.serverId,
            name: name,
            creatorUserId: userId,
            type: kind
        )
        dependencies.addPostableChannel(card.serverId, channelId, userId, kind, nil, nil, name)
        dependencies.addPostableChannel(
            card.serverId,
            channelId,
            card.requesterAgentId,
            kind,
            nil,
            nil,
            name
        )
        oauth.addChannelHuman(channelId: channelId, userId: userId)
        oauth.addChannelAgent(channelId: channelId, agentId: card.requesterAgentId)
        _ = cards.markActionCardExecuted(messageId: messageId, userId: userId)
        postActionCardReply(
            card: card,
            confirmerUserId: userId,
            success: true,
            resultName: name,
            failureReason: nil
        )
        let metadata = OrderedJSON.object([
            OrderedJSONField("kind", "action-card"),
            OrderedJSONField("state", "executed"),
            OrderedJSONField("action", .object([
                OrderedJSONField("type", "channel:create"),
                OrderedJSONField("name", name),
            ])),
            OrderedJSONField("result", .object([
                OrderedJSONField("kind", "channel"),
                OrderedJSONField("id", channelId),
                OrderedJSONField("name", name),
            ])),
        ]).render()
        return ActionCardExecuteResponse(messageId: messageId, metadataJSON: metadata)
    }

    // MARK: - Card preparation helpers

    /// The integration card types. `nil` means "not an integration card"; a
    /// thrown error is a published refusal.
    private func prepareIntegrationActionCard(
        identity: (agentId: String, serverId: String),
        target: String,
        action: [String: JSONValue]
    ) throws -> ActionCardPrepareResponse? {
        guard let type = action["type"]?.legacyString,
              type == "integration:install_marketplace_app"
                || type == "integration:register_app"
        else {
            return nil
        }
        guard let resolved = actionCardTarget(
            serverId: identity.serverId,
            agentId: identity.agentId,
            target: target
        ) else {
            throw ActionCardIntegrationRegisterError.targetChannelNotFound
        }
        guard let agent = oauth.agentRuntimeInfo(id: identity.agentId) else {
            throw ActionCardIntegrationRegisterError.requesterAgentNotFound
        }
        if type == "integration:install_marketplace_app" {
            let clientRef = action["clientId"]?.legacyString ?? ""
            let client: MarketplaceClientIdentity?
            if let marketplace = dependencies.marketplaceInstallableClient(clientRef) {
                client = marketplace
            } else if let publicClient = dependencies.publicIntegrationClient(
                action["clientKey"]?.legacyString ?? clientRef
            ) {
                client = publicClient
            } else {
                client = nil
            }
            guard let client,
                  let messageId = prepareMarketplaceInstallCard(
                      serverId: identity.serverId,
                      agent: agent,
                      client: client,
                      scopes: action["scopes"]?.legacyStringArray ?? [],
                      target: resolved
                  )
            else {
                throw ActionCardIntegrationRegisterError.integrationAppNotFound
            }
            let metadata = cards.marketplaceInstallCard(messageId: messageId)
                .map { metadataProjection.marketplaceInstall($0) } ?? "null"
            return ActionCardPrepareResponse(messageId: messageId, metadataJSON: metadata)
        }
        let rawScopes = action["scopes"]?.legacyStringArray ?? []
        guard rawScopes.allSatisfy({ Self.allowedScopes.contains($0) }) else {
            throw ActionCardIntegrationRegisterError.scopeNotAllowed
        }
        if let category = action["category"]?.legacyString,
           !Self.oauthClientCategories.contains(category) {
            throw ActionCardIntegrationRegisterError.categoryNotAllowed
        }
        if action["unsafeDemoUrlOverride"]?.legacyBool != true {
            for key in ["homepageUrl", "returnUrl"] {
                guard let raw = action[key]?.legacyString,
                      let url = URL(string: raw),
                      let host = url.host
                else { continue }
                if Self.isPrivateHost(host) {
                    throw ActionCardIntegrationRegisterError.unsafeDemoUrlRequiresOverride
                }
            }
        }
        let name = (action["name"]?.legacyString ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let returnUrl = (action["returnUrl"]?.legacyString ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !returnUrl.isEmpty else {
            throw ActionCardIntegrationRegisterError.invalidAppRegistrationRequest
        }
        let setupUrl: String?
        let setupDescription: String?
        do {
            setupUrl = try AppSetupContract.normalizeSetupUrl(action["setupUrl"]?.legacyString)
            setupDescription = try AppSetupContract.normalizeSetupDescription(
                action["setupDescription"]?.legacyString
            )
        } catch let error as AppSetupValidationError {
            throw ActionCardIntegrationRegisterError.invalidAppMetadata(error.message)
        } catch {
            throw ActionCardIntegrationRegisterError.invalidAppMetadata("Invalid app metadata")
        }
        let clientKey = action["clientKey"]?.legacyString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let messageId = prepareIntegrationRegisterCard(
            serverId: identity.serverId,
            agent: agent,
            name: name,
            clientKey: (clientKey?.isEmpty == false) ? clientKey : nil,
            homepageUrl: action["homepageUrl"]?.legacyString?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            returnUrl: returnUrl,
            agentManifestUrl: action["agentManifestUrl"]?.legacyString?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            setupUrl: setupUrl,
            setupDescription: setupDescription,
            scopes: rawScopes,
            target: resolved
        )
        let metadata = cards.integrationRegisterCard(messageId: messageId)
            .map { metadataProjection.integrationRegister($0) } ?? "null"
        return ActionCardPrepareResponse(messageId: messageId, metadataJSON: metadata)
    }

    /// `agent:create` over a `dm:@peer:shortId` target. `nil` means the target
    /// is not a DM thread target, so the caller falls through to the channel
    /// validation path.
    private func prepareAgentCreateCard(
        identity: (agentId: String, serverId: String),
        target: String,
        action: [String: JSONValue]
    ) throws -> ActionCardPrepareResponse? {
        let name = (action["name"]?.legacyString ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else {
            throw ActionCardIntegrationRegisterError.invalidActionCardRequest
        }
        guard target.hasPrefix("dm:@") else { return nil }
        var raw = String(target.dropFirst("dm:@".count))
        guard let colon = raw.lastIndex(of: ":") else {
            throw ActionCardIntegrationRegisterError.invalidActionCardRequest
        }
        let suffix = String(raw[raw.index(after: colon)...])
        raw = String(raw[..<colon])
        guard !raw.isEmpty, !suffix.isEmpty else {
            throw ActionCardIntegrationRegisterError.invalidActionCardRequest
        }
        let peer = accounts.firstAccount(exactName: raw)
        var dmId = peer.flatMap { account in
            channels.actionCardDMChannel(agentId: identity.agentId, peerId: account.id)
        }
        let anchorId = dmId.flatMap { dm -> String? in
            if let fromLedger = oauth.historyMessages(channelId: dm)
                .first(where: { $0.id.hasPrefix(suffix) })?.id {
                return fromLedger
            }
            return messages.humanMessageId(channelId: dm, idPrefix: suffix)
        }
        var threadId = dmId.flatMap { dm -> String? in
            anchorId.flatMap { anchor in
                channels.actionCardThreadChannel(
                    parentChannelId: dm,
                    parentMessageId: anchor
                )
            }
        }
        guard let peerId = peer?.id else {
            throw ActionCardIntegrationRegisterError.targetChannelNotFound
        }
        if dmId == nil {
            let created = oauth.createDirectChannel(
                serverId: identity.serverId,
                firstUserId: identity.agentId,
                secondUserId: peerId
            )
            dependencies.addPostableChannel(
                identity.serverId, created, identity.agentId, "dm", nil, nil, "dm"
            )
            dependencies.addPostableChannel(
                identity.serverId, created, peerId, "dm", nil, nil, "dm"
            )
            oauth.addChannelHuman(channelId: created, userId: peerId)
            dmId = created
        }
        guard let dmId else {
            throw ActionCardIntegrationRegisterError.targetChannelNotFound
        }
        guard let anchorId else {
            throw ActionCardIntegrationRegisterError.targetChannelNotFound
        }
        if threadId == nil {
            let created = oauth.createThreadChannel(
                parentChannelId: dmId,
                parentMessageId: anchorId
            )
            dependencies.addPostableChannel(
                identity.serverId, created, identity.agentId, "thread", dmId, anchorId, "thread"
            )
            dependencies.addPostableChannel(
                identity.serverId, created, peerId, "thread", dmId, anchorId, "thread"
            )
            threadId = created
        }
        guard let threadId, let agent = oauth.agentRuntimeInfo(id: identity.agentId) else {
            throw ActionCardIntegrationRegisterError.targetChannelNotFound
        }
        let messageId = makeId()
        let content = "@\(agent.name) proposed creating agent @\(name)"
        _ = dependencies.appendHumanMessage(StoredHumanMessage(
            id: messageId,
            channelId: threadId,
            senderId: identity.agentId,
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "agent",
            actionKind: "action-card"
        ))
        cards.insertActionCardRecord(ActionCardRecord(
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
        ))
        let metadata = OrderedJSON.object([
            OrderedJSONField("kind", "action-card"),
            OrderedJSONField("state", "prepared"),
            OrderedJSONField("action", .object([
                OrderedJSONField("type", "agent:create"),
                OrderedJSONField("name", name),
            ])),
            OrderedJSONField("carrierChannelId", threadId),
        ]).render()
        return ActionCardPrepareResponse(messageId: messageId, metadataJSON: metadata)
    }

    /// Prepares one `integration:install_marketplace_app` card. The caller
    /// already resolved the target and the client; `nil` means the client
    /// record lost a required member.
    @discardableResult
    func prepareMarketplaceInstallCard(
        serverId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        client: MarketplaceClientIdentity,
        scopes: [String],
        target: (local: String, storage: String)
    ) -> String? {
        let binding = ThirdPartyText.marketplaceAppNameBinding(client.name)
        let declaration = oauth.clientSetupDeclaration(clientRecordId: client.recordId)
        let agentName = agent.displayName.isEmpty ? agent.name : agent.displayName
        let messageId = makeId()
        let card = MarketplaceInstallCard(
            messageId: messageId,
            serverId: serverId,
            clientRecordId: client.recordId,
            clientKey: client.clientKey,
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
        let content = "Operation: install Marketplace app \(binding.name) (\(client.clientKey)) on this Server"
        _ = dependencies.appendHumanMessage(StoredHumanMessage(
            id: messageId,
            channelId: target.storage,
            senderId: agent.id,
            content: content,
            randomId: nil,
            messageType: "chat",
            senderType: "agent",
            actionKind: "action-card"
        ))
        cards.insertMarketplaceInstallCard(card)
        return messageId
    }

    // MARK: - Card execution helpers

    private func executeMarketplaceInstallCard(
        _ card: MarketplaceInstallCard,
        userId: String,
        serverId: String,
        expectedState: String?
    ) throws -> ActionCardExecuteResponse {
        guard card.serverId == serverId else {
            throw ActionCardIntegrationRegisterError.actionCardNotFound
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ActionCardIntegrationRegisterError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw ActionCardIntegrationRegisterError.onlyAdminsCanInstall
        }
        if let expectedState, expectedState != card.state {
            throw ActionCardIntegrationRegisterError.stateChanged
        }
        if card.state == "executed" {
            return ActionCardExecuteResponse(
                messageId: card.messageId,
                metadataJSON: metadataProjection.marketplaceInstall(card)
            )
        }
        guard let client = dependencies.marketplaceInstallableClient(card.clientRecordId),
              client.clientKey == card.clientKey
        else {
            throw ActionCardIntegrationRegisterError.marketplaceAppChanged
        }
        let binding = ThirdPartyText.marketplaceAppNameBinding(client.name)
        guard binding.sha256 == card.clientNameSha256, binding.name == card.clientName else {
            throw ActionCardIntegrationRegisterError.marketplaceAppIdentityChanged
        }
        let declaration = oauth.clientSetupDeclaration(clientRecordId: card.clientRecordId)
        guard (declaration?.url ?? nil) == card.setupUrl,
              (declaration?.revision ?? 1) == card.setupRevision
        else {
            throw ActionCardIntegrationRegisterError.appSetupChanged
        }
        guard let agent = oauth.agentRuntimeInfo(id: card.agentId), !agent.deleted else {
            throw ActionCardIntegrationRegisterError.agentBindingChanged
        }
        let agentName = agent.displayName.isEmpty ? agent.name : agent.displayName
        guard agentName == card.agentName else {
            throw ActionCardIntegrationRegisterError.agentBindingChanged
        }
        if !oauth.isClientInstalled(serverId: serverId, clientRecordId: card.clientRecordId) {
            _ = oauth.installClient(
                serverId: serverId,
                clientRecordId: card.clientRecordId,
                installedByUserId: userId,
                groups: []
            )
        }
        let setup = oauth.getAppInstallationSetup(
            clientRecordId: card.clientRecordId,
            serverId: serverId
        )
        let result = OrderedJSON.object([
            OrderedJSONField("kind", "marketplace-app-installation"),
            OrderedJSONField("clientId", card.clientRecordId),
            OrderedJSONField("clientKey", card.clientKey),
            OrderedJSONField("clientName", card.clientName),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("agentId", card.agentId),
            OrderedJSONField("agentName", card.agentName),
            OrderedJSONField("scopes", .array(card.scopes.map { .string($0) })),
            OrderedJSONField("setupUrl", OrderedJSON.stringOrNull(setup?.url)),
        ]).render()
        guard let updated = cards.markMarketplaceInstallCardExecuted(
            messageId: card.messageId,
            userId: userId,
            resultJSON: result
        ) else {
            throw ActionCardIntegrationRegisterError.actionCardNotFound
        }
        return ActionCardExecuteResponse(
            messageId: card.messageId,
            metadataJSON: metadataProjection.marketplaceInstall(updated)
        )
    }

    private func executeIntegrationRegisterCard(
        _ card: IntegrationRegisterCard,
        userId: String,
        serverId: String,
        expectedState: String?
    ) throws -> ActionCardExecuteResponse {
        guard card.serverId == serverId else {
            throw ActionCardIntegrationRegisterError.actionCardNotFound
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ActionCardIntegrationRegisterError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw ActionCardIntegrationRegisterError.onlyAdminsCanRegister
        }
        if let expectedState, expectedState != card.state {
            throw ActionCardIntegrationRegisterError.stateChanged
        }
        if card.state == "executed" {
            return ActionCardExecuteResponse(
                messageId: card.messageId,
                metadataJSON: metadataProjection.integrationRegister(card)
            )
        }
        guard let agent = oauth.agentRuntimeInfo(id: card.agentId), !agent.deleted else {
            throw ActionCardIntegrationRegisterError.registerAgentBindingChanged
        }
        let clientKey = card.clientKey
            ?? ThirdPartyText.generatedIntegrationClientKey(card.name)
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
            throw ActionCardIntegrationRegisterError.agentRegistrationRejected(error.message)
        } catch {
            throw ActionCardIntegrationRegisterError.invalidAppRegistration
        }
        oauth.addClientMaintainer(clientRecordId: created.id, agentId: card.agentId)
        let result = OrderedJSON.object([
            OrderedJSONField("kind", "integration-app-registration"),
            OrderedJSONField("mode", "register"),
            OrderedJSONField("clientId", created.id),
            OrderedJSONField("clientKey", created.clientId),
            OrderedJSONField("clientName", card.name),
            OrderedJSONField("scopes", .array(card.scopes.map { .string($0) })),
        ]).render()
        guard let updated = cards.markIntegrationRegisterCardExecuted(
            messageId: card.messageId,
            userId: userId,
            resultJSON: result
        ) else {
            throw ActionCardIntegrationRegisterError.actionCardNotFound
        }
        return ActionCardExecuteResponse(
            messageId: card.messageId,
            metadataJSON: metadataProjection.integrationRegister(updated)
        )
    }

    // MARK: - Shared action-card policy

    /// The card metadata projections (`kind: "action-card"`).
    var metadataProjection: ActionCardMetadataProjection {
        ActionCardMetadataProjection(cards: cards, oauth: oauth, now: now)
    }

    /// Resolves a `#channel` target to the local carrier and its storage
    /// channel: a live named channel on the server that the agent can post to
    /// (a plain channel, or a private/joint one the agent belongs to). The
    /// storage channel is the joint canonical one when the local channel is a
    /// joint projection.
    func actionCardTarget(
        serverId: String,
        agentId: String,
        target: String
    ) -> (local: String, storage: String)? {
        guard target.hasPrefix("#") else { return nil }
        let name = String(target.dropFirst())
        let snapshot = channels.state
        var local: String?
        for (id, channel) in snapshot.postableChannels {
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
        let storage = local.flatMap { id in
            snapshot.jointProjections.first { $0.localChannelId == id }?.canonicalChannelId
        } ?? local
        guard let local, let storage else { return nil }
        return (local, storage)
    }

    /// Creates the carrier message and the prepared `integration:register_app`
    /// card. The card is stored first so any reader that can see the carrier
    /// message also sees its card (the legacy append and card write were one
    /// directory-lock section).
    func prepareIntegrationRegisterCard(
        serverId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        name: String,
        clientKey: String?,
        homepageUrl: String?,
        returnUrl: String,
        agentManifestUrl: String?,
        setupUrl: String?,
        setupDescription: String?,
        scopes: [String],
        target: (local: String, storage: String)
    ) -> String {
        let messageId = makeId()
        let agentName = agent.displayName.isEmpty ? agent.name : agent.displayName
        cards.insertIntegrationRegisterCard(IntegrationRegisterCard(
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
        ))
        _ = dependencies.appendHumanMessage(StoredHumanMessage(
            id: messageId,
            channelId: target.storage,
            senderId: agent.id,
            content: "Operation: register Login with Raft app \(name) (\(clientKey ?? "auto-generated client key"))",
            randomId: nil,
            messageType: "chat",
            senderType: "agent",
            actionKind: "action-card"
        ))
        return messageId
    }

    /// The write policy without an HTTP reply: owner/admin or a carrier-channel
    /// member may execute; a non-member gets `notFound` for a thread carrier
    /// and `forbidden` for a live channel.
    func actionCardWriteDecision(userId: String, card: ActionCardRecord) -> ActionCardWriteDecision {
        guard oauth.memberRole(serverId: card.serverId, userId: userId) != nil else {
            return .notMember
        }
        let role = oauth.memberRole(serverId: card.serverId, userId: userId)
        let allowed = role == "owner" || role == "admin"
        let channel = channels.postableChannel(id: card.localCarrierChannelId)
            ?? channels.postableChannel(id: card.storageChannelId)
        let isMember = channel?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: card.localCarrierChannelId).contains(userId)
            || oauth.channelHumanIds(channelId: card.storageChannelId).contains(userId)
        let closed = channel.map { $0.kind != "channel" }
            ?? (oauth.channelKind(channelId: card.localCarrierChannelId) != "channel")
        if allowed || isMember { return .allowed }
        return closed ? .notFound : .forbidden
    }

    /// Writes the durable result reply into the card's thread, records the
    /// preparer's unread mention fact, and queues the external-agent event.
    private func postActionCardReply(
        card: ActionCardRecord,
        confirmerUserId: String,
        success: Bool,
        resultName: String?,
        failureReason: String?
    ) {
        guard let requester = oauth.agentRuntimeInfo(id: card.requesterAgentId) else { return }
        let confirmerHandle = accounts.account(userId: confirmerUserId)?.name ?? "a human"
        let serverName = oauth.serverProfile(id: card.serverId)?.name ?? "this Server"
        guard let threadId = channels.findOrCreateActionCardReplyThread(
            storageChannelId: card.storageChannelId,
            messageId: card.messageId,
            requesterAgentId: card.requesterAgentId,
            confirmerUserId: confirmerUserId,
            fallbackServerId: card.serverId,
            createThread: { parentChannelId, parentMessageId in
                oauth.createThreadChannel(
                    parentChannelId: parentChannelId,
                    parentMessageId: parentMessageId
                )
            }
        ) else { return }
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
        let replyId = makeId()
        _ = dependencies.appendHumanMessage(StoredHumanMessage(
            id: replyId,
            channelId: threadId,
            senderId: "system",
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "system"
        ))
        inboxFacts.append(StoredInboxFact(
            messageId: replyId,
            receiverType: "agent",
            receiverId: card.requesterAgentId,
            channelId: threadId,
            serverId: card.serverId,
            personalMention: true,
            unreadEligible: true
        ))
        inboxFacts.append(StoredInboxFact(
            messageId: replyId,
            receiverType: "user",
            receiverId: confirmerUserId,
            channelId: threadId,
            serverId: card.serverId,
            personalMention: true,
            unreadEligible: false
        ))
        messages.appendMention(StoredMention(
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
            cards.appendPendingActionMessageEvent(
                agentId: card.requesterAgentId,
                messageId: replyId,
                content: content
            )
        }
        let payload = OrderedJSON.object([
            OrderedJSONField("id", replyId),
            OrderedJSONField("channelId", threadId),
            OrderedJSONField("content", content),
        ]).render()
        dependencies.emitRealtime("channel:\(threadId)", "message:new", payload)
    }

    // MARK: - Idempotency

    /// The idempotent replay of a prepared card, keyed by `(agent, route, key)`.
    ///
    /// The lookup and the fingerprint check are one store critical section. A
    /// mismatched fingerprint reuses the legacy fixed 409 body.
    private func idempotentPrepareReplay(
        agentId: String,
        request: ActionCardPrepareRequest
    ) throws -> ActionCardPrepareResponse? {
        guard let raw = request.raw,
              let key = raw.legacyObject?["idempotencyKey"]?.legacyString?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            return nil
        }
        switch cards.agentApiIdempotencyLookup(
            agentId: agentId,
            route: "actionPrepare",
            key: key,
            fingerprint: Self.fingerprint(raw),
            now: now()
        ) {
        case .none:
            return nil
        case .replay(_, let body):
            // This route only stores 201 replies under its own route key, so a
            // replay republishes the first `201` with its stored bytes.
            return ActionCardPrepareResponse(
                messageId: "",
                metadataJSON: "",
                idempotentReplayBody: body
            )
        case .mismatch:
            throw ActionCardIntegrationRegisterError.idempotencyKeyReused
        }
    }

    /// Stores the first `201` reply for an idempotency key. The body is the
    /// rendered DTO, so a replay reproduces the same bytes.
    private func storePrepareIdempotency(
        agentId: String,
        request: ActionCardPrepareRequest,
        response: ActionCardPrepareResponse
    ) -> ActionCardPrepareResponse {
        guard let raw = request.raw,
              let key = raw.legacyObject?["idempotencyKey"]?.legacyString?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            return response
        }
        cards.storeAgentApiIdempotency(
            agentId: agentId,
            route: "actionPrepare",
            key: key,
            fingerprint: Self.fingerprint(raw),
            status: 201,
            body: response.jsonBody.render(),
            now: now()
        )
        return response
    }

    /// A canonical sorted-key rendering of the decoded request body. Two
    /// bodies that differ only in member order fingerprint the same, which is
    /// the legacy `canonicalJSON` contract the idempotency lookup compares.
    private static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .object(let members):
            let keys = members.keys.sorted()
            let body = keys.map { key in
                jsonString(key) + ":" + canonicalJSON(members[key] ?? .null)
            }.joined(separator: ",")
            return "{" + body + "}"
        case .array(let values):
            return "[" + values.map(canonicalJSON).joined(separator: ",") + "]"
        case .string(let value):
            return jsonString(value)
        case .integer(let value):
            return String(value)
        case .number(let value):
            return value.isFinite ? value.description : "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static func fingerprint(_ value: JSONValue) -> String {
        let digest = SHA256.hash(data: Data(canonicalJSON(value).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The legacy unsafe-demo-URL rule: loopback or a private IPv6 prefix.
    private static func isPrivateHost(_ host: String) -> Bool {
        host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
    }
}
