import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftShared

/// Domain failure for the action-card prepare, agent-context and app-config
/// routes.
///
/// Every case names the published error object the route answers with; the
/// feature layer only projects `status`, `errorBody` and headers through
/// `Respond.swift`. The bodies keep the legacy member order
/// (`error`, then `code`/`errorCode`, then `requiredCapability`/`currentRevision`).
public enum ActionCardPrepareError: DomainError, Equatable {
    case unauthorized
    case notAMember
    case invalidExpectedRevision
    case appNotFound
    case permissionRevisionStale
    case notOwnerOrAdmin
    case appNotOnServer
    case agentJWTFixed
    case missingAgentAuthorization
    case invalidAccessToken
    case invalidAgentCredential
    case capabilityNotAuthorized(capability: String)
    case missingRequiredCapability(capability: String)
    case serverNotFound
    case appConfigUnknownApp
    case appConfigInvalid
    case appConfigInvalidValue(key: String)
    case appConfigUnknownKey
    case appConfigRevisionStale(currentRevision: Int)

    public var status: UInt {
        switch self {
        case .unauthorized, .missingAgentAuthorization, .invalidAccessToken,
             .invalidAgentCredential:
            401
        case .notAMember, .notOwnerOrAdmin, .capabilityNotAuthorized,
             .missingRequiredCapability:
            403
        case .invalidExpectedRevision, .appConfigInvalid, .appConfigInvalidValue,
             .appConfigUnknownKey:
            400
        case .appNotFound, .appNotOnServer, .serverNotFound, .appConfigUnknownApp:
            404
        case .permissionRevisionStale, .appConfigRevisionStale:
            409
        case .agentJWTFixed:
            410
        }
    }

    /// The legacy Agent-JWT settings routes attach `Cache-Control: private,
    /// no-store` to their 403/404/410 replies (the 401 reads do not).
    public var responseHeaders: [String: String] {
        switch self {
        case .notOwnerOrAdmin, .appNotOnServer, .agentJWTFixed:
            ["Cache-Control": "private, no-store"]
        default:
            [:]
        }
    }

    /// The single published failure object: `error` first, then at most one of
    /// `code`/`errorCode`, then at most one of
    /// `requiredCapability`/`currentRevision`. That is the legacy member order
    /// for every branch this domain publishes.
    public var errorBody: OrderedJSON? {
        let published = publishedFields
        var body = OrderedJSONObject()
        body.append("error", published.error)
        body.append("code", ifPresent: published.code)
        body.append("errorCode", ifPresent: published.errorCode)
        body.append("requiredCapability", ifPresent: published.requiredCapability)
        body.append("currentRevision", ifPresent: published.currentRevision)
        return body.json
    }

    public var errorMessage: String { publishedFields.error }

    /// The legacy fields each case publishes, in published order.
    private var publishedFields: (
        error: String,
        code: String?,
        errorCode: String?,
        requiredCapability: String?,
        currentRevision: Int?
    ) {
        switch self {
        case .unauthorized:
            ("Unauthorized", nil, nil, nil, nil)
        case .notAMember:
            ("Not a member of this server", nil, nil, nil, nil)
        case .invalidExpectedRevision:
            (
                "expected_revision_id must be a revision UUID",
                "invalid_expected_revision_id", nil, nil, nil
            )
        case .appNotFound:
            ("App not found", nil, nil, nil, nil)
        case .permissionRevisionStale:
            (
                "The permission request changed since it was displayed",
                "permission_revision_stale", nil, nil, nil
            )
        case .notOwnerOrAdmin:
            ("Only server owners and admins can read Agent JWT access", nil, nil, nil, nil)
        case .appNotOnServer:
            ("App not found on this Server", nil, nil, nil, nil)
        case .agentJWTFixed:
            (
                "Agent JWT is built in for every App; there is no setting to change",
                nil, nil, nil, nil
            )
        case .missingAgentAuthorization:
            ("Missing or invalid Authorization header", "auth_required", nil, nil, nil)
        case .invalidAccessToken:
            ("Invalid or expired token", "auth_required", nil, nil, nil)
        case .invalidAgentCredential:
            ("Invalid agent credential", "auth_required", nil, nil, nil)
        case .capabilityNotAuthorized(let capability):
            (
                "Agent credential is not authorized for this capability",
                "capability_not_authorized", nil, capability, nil
            )
        case .missingRequiredCapability(let capability):
            ("missing required capability", nil, nil, capability, nil)
        case .serverNotFound:
            ("Server not found", nil, nil, nil, nil)
        case .appConfigUnknownApp:
            ("Unknown app", nil, "RAP_APP_CONFIG_APP_UNKNOWN", nil, nil)
        case .appConfigInvalid:
            ("Invalid config request", nil, "RAP_APP_CONFIG_INVALID", nil, nil)
        case .appConfigInvalidValue(let key):
            ("Invalid value for \(key)", nil, "RAP_APP_CONFIG_INVALID", nil, nil)
        case .appConfigUnknownKey:
            ("Unknown config key", nil, "RAP_APP_CONFIG_INVALID", nil, nil)
        case .appConfigRevisionStale(let currentRevision):
            (
                "Config revision is stale; current revision is \(currentRevision)",
                nil, "RAP_APP_CONFIG_REVISION_STALE", nil, currentRevision
            )
        }
    }
}

/// Action-card preparation, the agent context / app-config surface, and the
/// shared agent-target projections other (not-yet-migrated) domain extensions
/// call while they hold the directory lock.
///
/// The service owns no state: app config lives in `ManagedMCPAndCardsStore`,
/// feature flags and agent credentials in `AgentsRuntimeStore`, channels in
/// `ServersAndChannelsStore`, accounts in `AuthProfileStore`, messages in
/// `MessagesAndThreadsStore`, and the marketplace reviewer override in
/// `FeedbackStore`. Every compare-and-set write is one store critical section.
/// Two dependencies are still owned by unmigrated domains, so they enter as
/// closures: `sessionUserId` (the session ledger) and `assistantOwner` (the
/// assistant-owner policy in `AgentPrivateSurfaceService`).
public struct ActionCardPrepareService: Sendable {
    /// Config keys the app accepts, in the order the reply renders them.
    private static let appConfigKeyOrder = ["enabled", "threshold_bytes", "interval_seconds"]
    private static let appConfigKeys = Set(appConfigKeyOrder)
    private static let systemCleaner = "system.cleaner"

    private let oauth: OAuthLedger
    private let cards: ManagedMCPAndCardsStore
    private let feedback: FeedbackStore
    private let agents: AgentsRuntimeStore
    private let channels: ServersAndChannelsStore
    private let accounts: AuthProfileStore
    private let messages: MessagesAndThreadsStore
    private let sessionUserId: @Sendable (String?) -> String?
    private let assistantOwner: @Sendable (String, String) -> String?
    private let environment: @Sendable (String) -> String?

    /// The account ledger the shared task-channel resolver matches DM peer
    /// names against. Exposed read-only so the execute service can construct
    /// the same `AgentTaskCredentials` policy without a second account store.
    var accountStore: AuthProfileStore { accounts }

    init(
        oauth: OAuthLedger,
        cards: ManagedMCPAndCardsStore,
        feedback: FeedbackStore,
        agents: AgentsRuntimeStore,
        channels: ServersAndChannelsStore,
        accounts: AuthProfileStore,
        messages: MessagesAndThreadsStore,
        sessionUserId: @escaping @Sendable (String?) -> String?,
        assistantOwner: @escaping @Sendable (String, String) -> String?,
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) {
        self.oauth = oauth
        self.cards = cards
        self.feedback = feedback
        self.agents = agents
        self.channels = channels
        self.accounts = accounts
        self.messages = messages
        self.sessionUserId = sessionUserId
        self.assistantOwner = assistantOwner
        self.environment = environment
    }

    // MARK: - Integration marketplace (`GET /api/integrations/marketplace`)

    /// Lists the apps that can publish app-notification permission requests.
    public func integrationMarketplace(
        authorization: String?,
        serverId: String
    ) throws -> IntegrationMarketplaceListing {
        guard let userId = sessionUserId(authorization) else {
            throw ActionCardPrepareError.unauthorized
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ActionCardPrepareError.notAMember
        }
        let reviewers = marketplaceReviewerIds()
        let rows = oauth.appPermissionReviewRows(serverId: serverId).map { row in
            IntegrationMarketplaceRow(
                id: row.id,
                clientId: row.clientId,
                name: row.name,
                pendingGroups: row.pendingGroups,
                pendingRevisionId: row.pendingRevisionId,
                canReviewAppNotifications: reviewers.contains(userId)
            )
        }
        return IntegrationMarketplaceListing(rows: rows)
    }

    // MARK: - App-notification permission review

    /// Approves the displayed permission revision.
    ///
    /// The caller passes `nil` when the request body did not decode. The legacy
    /// handler authorized before parsing, so the service checks the session and
    /// membership first and only then answers the body-shaped 400.
    public func reviewAppNotificationPermissions(
        authorization: String?,
        serverId: String,
        clientId: String,
        body: ReviewAppNotificationPermissionsRequest?
    ) throws -> ReviewAppNotificationPermissionsResponse {
        guard let userId = sessionUserId(authorization) else {
            throw ActionCardPrepareError.unauthorized
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ActionCardPrepareError.notAMember
        }
        guard let raw = body?.expectedRevisionId, ServerScope.isUUID(raw) else {
            throw ActionCardPrepareError.invalidExpectedRevision
        }
        do {
            let groups = try oauth.approveAppOutboundPermission(
                clientRecordId: clientId,
                expectedRevisionId: raw
            )
            return ReviewAppNotificationPermissionsResponse(groups: groups)
        } catch OAuthLedger.AppPermissionReviewError.notFound {
            throw ActionCardPrepareError.appNotFound
        } catch {
            throw ActionCardPrepareError.permissionRevisionStale
        }
    }

    // MARK: - Legacy Agent-JWT settings

    /// `GET /api/integrations/clients/:clientId/agent-jwt`.
    public func legacyAppAgentJWTSettings(
        authorization: String?,
        serverId: String,
        clientRecordId: String
    ) throws -> LegacyAppAgentJWTResponse {
        guard let userId = sessionUserId(authorization) else {
            throw ActionCardPrepareError.unauthorized
        }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            throw ActionCardPrepareError.notOwnerOrAdmin
        }
        guard let client = oauth.legacyAgentJWTClient(clientRecordId: clientRecordId) else {
            throw ActionCardPrepareError.appNotOnServer
        }
        let source = client.serverId == serverId
        let installationStatus = oauth.legacyAgentJWTInstallationStatus(
            clientRecordId: clientRecordId,
            serverId: serverId
        )
        if !source, client.appType != "third_party_global" || installationStatus == nil {
            throw ActionCardPrepareError.appNotOnServer
        }
        let scopesOK = client.allowedScopes.contains("openid")
            && client.allowedScopes.contains("profile")
        let installationOK = installationStatus == nil || installationStatus == "active"
        let effective = client.enabled && scopesOK && installationOK
            && (client.appType == "server_local" || installationStatus == "active")
        return LegacyAppAgentJWTResponse(
            scope: source ? "app" : "installation",
            effectiveEnabled: effective,
            audience: client.clientKey
        )
    }

    /// `PUT /api/integrations/clients/:clientId/agent-jwt` always answers 410.
    public func refuseLegacyAppAgentJWTWrite() throws -> LegacyAppAgentJWTResponse {
        throw ActionCardPrepareError.agentJWTFixed
    }

    // MARK: - Agent context (`GET /internal/agent-api/context`)

    public func agentContext(authorization: String?) throws -> AgentContextResponse {
        let identity: (agentId: String, serverId: String, scopes: [String])
        switch agentIdentity(authorization: authorization, capability: "read") {
        case .success(let agentId, let serverId, let scopes):
            identity = (agentId, serverId, scopes)
        case .missingAuthorization:
            throw ActionCardPrepareError.missingAgentAuthorization
        case .invalidAccessToken, .invalidAgentCredential:
            // The context route collapses a missing/deleted agent into the same
            // expired-token reply the legacy handler published.
            throw ActionCardPrepareError.invalidAccessToken
        case .capabilityNotAuthorized(let capability):
            throw ActionCardPrepareError.capabilityNotAuthorized(capability: capability)
        }
        guard let agent = oauth.agentRuntimeInfo(id: identity.agentId) else {
            throw ActionCardPrepareError.invalidAccessToken
        }
        guard let server = oauth.serverProfile(id: identity.serverId) else {
            throw ActionCardPrepareError.serverNotFound
        }
        let role = oauth.agentRole(serverId: agent.serverId, agentId: agent.id) ?? "member"
        let external = agent.runtime == "external"
        let prompt: AgentContextPrompt?
        if external {
            let text = """
            # Raft CLI operating guide

            You are "\(agent.displayName)" (@\(agent.name)), an external AI agent in the Raft server "\(server.name)".

            Your server role is \(role). Permission checks always use your current role.

            Initial role: \(agent.description ?? "No initial role was provided.").

            reminders_unsupported_for_external_agents — external agents cannot create reminders; ask a human instead.
            """
            prompt = AgentContextPrompt(text: text)
        } else {
            prompt = nil
        }
        let assistant = assistantOwner(agent.id, agent.serverId)
        return AgentContextResponse(
            agent: AgentContextAgent(
                id: agent.id,
                name: agent.name,
                displayName: agent.displayName,
                description: agent.description,
                runtime: agent.runtime,
                external: external,
                assistantOf: assistant,
                serverRole: role
            ),
            server: AgentContextServer(id: server.id, slug: server.slug, name: server.name),
            capabilities: identity.scopes,
            prompt: prompt,
            features: AgentContextFeatures(
                reminderApp: agents.featureFlagEnabled(key: "reminder_app", serverId: server.id),
                vaultApp: agents.featureFlagEnabled(key: "vault_app", serverId: server.id)
            )
        )
    }

    // MARK: - Agent app config

    /// `GET /internal/agent-api/apps/:appId/config`.
    public func agentAppConfig(
        authorization: String?,
        appId: String
    ) throws -> AgentAppConfigResponse {
        let agentId: String
        switch agentIdentity(authorization: authorization, capability: "read") {
        case .success(let id, _, _):
            agentId = id
        case .missingAuthorization:
            throw ActionCardPrepareError.missingAgentAuthorization
        case .invalidAccessToken:
            throw ActionCardPrepareError.invalidAccessToken
        case .invalidAgentCredential:
            throw ActionCardPrepareError.invalidAgentCredential
        case .capabilityNotAuthorized(let capability):
            throw ActionCardPrepareError.capabilityNotAuthorized(capability: capability)
        }
        guard appId == Self.systemCleaner else {
            throw ActionCardPrepareError.appConfigUnknownApp
        }
        return appConfigResponse(
            appId: appId,
            snapshot: cards.appConfigSnapshot(agentId: agentId, appId: appId)
        )
    }

    /// `PATCH /internal/agent-api/apps/:appId/config`.
    ///
    /// The body is `nil` when the request body did not decode. Authorization,
    /// the capability gate and the app lookup run before the published
    /// `Invalid config request` 400, matching the legacy handler's order.
    public func patchAgentAppConfig(
        authorization: String?,
        appId: String,
        body: AgentAppConfigPatchRequest?
    ) throws -> AgentAppConfigResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ActionCardPrepareError.missingAgentAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredentials[token], credential.revokedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw ActionCardPrepareError.invalidAccessToken
        }
        guard credential.scopes.contains("tasks") else {
            throw ActionCardPrepareError.missingRequiredCapability(capability: "tasks")
        }
        guard appId == Self.systemCleaner else {
            throw ActionCardPrepareError.appConfigUnknownApp
        }
        guard let body else {
            throw ActionCardPrepareError.appConfigInvalid
        }
        var normalized: [String: AppConfigValue] = [:]
        for (key, value) in body.set.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "enabled":
                guard let boolean = Self.legacyBoolean(value) else {
                    throw ActionCardPrepareError.appConfigInvalidValue(key: key)
                }
                normalized[key] = .boolean(boolean)
            case "threshold_bytes", "interval_seconds":
                guard let integer = Self.legacyConfigInteger(value) else {
                    throw ActionCardPrepareError.appConfigInvalidValue(key: key)
                }
                if key == "threshold_bytes", integer < 4096 || integer > 1_073_741_824 {
                    throw ActionCardPrepareError.appConfigInvalidValue(key: key)
                }
                if key == "interval_seconds", integer < 900 || integer > 604_800 {
                    throw ActionCardPrepareError.appConfigInvalidValue(key: key)
                }
                normalized[key] = .integer(integer)
            default:
                throw ActionCardPrepareError.appConfigUnknownKey
            }
        }
        for key in body.unset where !Self.appConfigKeys.contains(key) {
            throw ActionCardPrepareError.appConfigUnknownKey
        }
        switch cards.patchAppConfig(
            agentId: agent.id,
            appId: appId,
            expectedRevision: body.expectedRevision,
            set: normalized,
            unset: body.unset
        ) {
        case .applied(let snapshot):
            return appConfigResponse(appId: appId, snapshot: snapshot)
        case .revisionStale(let current):
            throw ActionCardPrepareError.appConfigRevisionStale(currentRevision: current)
        }
    }

    // MARK: - Shared agent-target projections
    //
    // These helpers still belong to the execute/send domains, which call them
    // while holding the directory lock. They live on the service type, so this
    // file carries no directory extension; each one reads stores through their
    // locked accessors.

    /// Resolves one `dm:@name[~kind]` target.
    ///
    /// A migration-receipt DM has no peer account: its only member is the
    /// migrated agent, and only that agent may name it.
    func resolveDMPeer(
        serverId: String,
        agentId: String,
        name rawName: String,
        kind rawKind: String?
    ) -> DMPeerResolution {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = rawKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let kind, kind != "agent", kind != "human" {
            return .invalidKind(kind, name)
        }
        if kind == nil, name.hasPrefix("migration-receipt-") {
            let postable = channels.postableChannels
            let owned = postable.first { id, channel in
                channel.serverId == serverId && channel.deletedAt == nil
                    && channel.kind == "dm" && channel.name == name && channel.memberIds == [agentId]
                    && oauth.channelAgentIds(channelId: id) == [agentId]
                    && oauth.channelHumanIds(channelId: id).isEmpty
            }
            guard let owned else { return .notFound }
            return .resolved(peerId: agentId, peerKind: "agent", name: name)
        }
        let accounts = self.accounts.accounts
        let humans = accounts.values.filter {
            ($0.name.caseInsensitiveCompare(name) == .orderedSame
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

    /// Finds the live DM channel between an agent and a peer.
    func dmChannelId(serverId: String, agentId: String, peerId: String, peerKind: String, peerName: String? = nil) -> String? {
        if peerKind == "agent", peerId == agentId {
            // A receipt is a retained named singleton surface, not a self DM.
            // Resolve only its verified original identity; never manufacture one.
            guard let peerName, peerName.hasPrefix("migration-receipt-") else { return nil }
            return channels.postableChannels.first { id, channel in
                channel.serverId == serverId && channel.deletedAt == nil && channel.kind == "dm"
                    && channel.name == peerName && channel.memberIds == [agentId]
                    && oauth.channelAgentIds(channelId: id) == [agentId]
                    && oauth.channelHumanIds(channelId: id).isEmpty
            }?.key
        }
        guard let id = oauth.directChannelId(serverId: serverId, firstUserId: agentId,
            secondUserId: peerId, firstKind: .agent, secondKind: peerKind == "agent" ? .agent : .human),
              let channel = channels.postableChannel(id: id), channel.serverId == serverId,
              channel.kind == "dm", channel.deletedAt == nil,
              channel.memberIds.contains(agentId), channel.memberIds.contains(peerId) else { return nil }
        return id
    }

    /// The peer card exists only when the peer has a profile description or a
    /// timezone on their latest message.
    func peerCardJSON(channelId: String, agentId: String) -> String? {
        let channels = self.channels.postableChannels
        guard let channel = channels[channelId] else { return nil }
        let baseId: String
        if channel.kind == "dm" {
            baseId = channelId
        } else if channel.kind == "thread", let parentId = channel.parentChannelId,
                  channels[parentId]?.kind == "dm" {
            baseId = parentId
        } else {
            return nil
        }
        guard let peerId = oauth.channelHumanIds(channelId: baseId).first,
              let account = accounts.accounts.values.first(where: { $0.id == peerId })
        else { return nil }
        let timezone = messages.humanMessageRows.last {
            $0.channelId == baseId && $0.senderType == "user" && $0.senderId == peerId && ($0.senderTimezone?.isEmpty == false)
        }?.senderTimezone
        let description = account.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (description?.isEmpty == false) || timezone != nil else { return nil }
        var fields = "\"kind\":\"human\",\"name\":\(jsonString(account.name))"
        if let description, !description.isEmpty {
            fields += ",\"description\":\(jsonString(description))"
        }
        if let timezone { fields += ",\"timezone\":\(jsonString(timezone))" }
        return "{\(fields)}"
    }

    /// The card an agent sees for a channel; a thread shows its parent.
    func channelCardSnapshot(channelId: String) -> AgentChannelCardSnapshot? {
        let channels = self.channels.postableChannels
        guard let channel = channels[channelId], channel.kind != "dm" else { return nil }
        let cardId: String
        if channel.kind == "thread", let parentId = channel.parentChannelId {
            cardId = parentId
        } else {
            cardId = channelId
        }
        guard let info = oauth.channelInfo(id: cardId) else { return nil }
        let type = oauth.channelType(id: cardId) ?? "channel"
        let archived = oauth.channelArchivedAt(id: cardId) != nil || channels[cardId]?.archived == true
        return AgentChannelCardSnapshot(
            id: cardId,
            name: info.name,
            type: type,
            description: info.description,
            archived: archived
        )
    }

    /// Which attested-send freshness interface this server/agent runs under.
    /// The upstream default is on; `off` disables the interface entirely and
    /// `allowlist` enables it only for the listed server/agent ids (or `*`).
    func sendFreshnessMode() -> String {
        let configured = messages.sendFreshnessModeOverride
            ?? environment("SLOCK_ATTESTED_SEND_MODE")
            ?? "on"
        return configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func sendFreshnessInterfaceEnabled(serverId: String, agentId: String) -> Bool {
        let mode = sendFreshnessMode()
        switch mode {
        case "on", "force", "1", "true":
            return true
        case "allowlist":
            func listed(_ key: String) -> Set<String> {
                Set((environment(key) ?? "")
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

    /// The conversation identity the agent sees for the target, so held
    /// messages keep a reply target instead of being dropped by clients.
    func heldConversationIdentity(channelId: String, agentId: String) -> String {
        let channels = self.channels.postableChannels
        guard let channel = channels[channelId] else {
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
                : (channel.parentChannelId.flatMap { channels[$0]?.kind == "dm" ? $0 : nil })
            if let dmId {
                if let humanId = oauth.channelHumanIds(channelId: dmId).first {
                    peerName = accounts.accounts.values.first { $0.id == humanId }?.name
                } else if let peerId = oauth.channelAgentIds(channelId: dmId).first(where: { $0 != agentId }) {
                    peerName = oauth.agentRuntimeInfo(id: peerId)?.name
                }
            }
        }
        let channelName = channel.kind == "dm" ? (peerName ?? channel.name) : channel.name
        var json = "{\"channel_id\":\(jsonString(channelId)),\"channel_type\":\(jsonString(channelType)),\"channel_name\":\(jsonString(channelName))"
        if channel.kind == "thread", let parentId = channel.parentChannelId,
           let parent = channels[parentId] {
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
    /// agent-facing snake_case identity and sender fields.
    func heldFreshnessMessageJSON(
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
        let nativeSenderName = message.senderType == "agent"
            ? oauth.agentRuntimeInfo(id: message.senderId)?.name
            : accounts.accounts.values.first { $0.id == message.senderId }?.name
        let senderName = message.externalSenderName ?? nativeSenderName
            ?? (message.senderId == "system" ? "system" : message.senderId)
        let timestamp = DateText.isoString(message.createdAt)
        let identityFields = String(conversationIdentity.dropFirst().dropLast())
        var json = "{\"id\":\(jsonString(message.id)),\"message_id\":\(jsonString(message.id)),\"channelId\":\(jsonString(message.channelId)),\"seq\":\(seq),\"content\":\(jsonString(message.content)),\"sender_id\":\(jsonString(message.senderId)),\"sender_name\":\(jsonString(senderName)),\"senderName\":\(jsonString(senderName)),\"sender_type\":\(jsonString(senderType)),\"senderType\":\(jsonString(senderType)),\"createdAt\":\(jsonString(timestamp)),\"timestamp\":\(jsonString(timestamp))"
        if !identityFields.isEmpty {
            json += ",\(identityFields)"
        }
        json += "}"
        return json
    }

    // MARK: - Identity

    /// The credential/capability outcome without an HTTP projection.
    ///
    /// Mirrors `FeedbackLocatorService.IdentityResolution`: the app-config and
    /// context routes map the cases to their published refusals.
    private enum AgentIdentity {
        case success(agentId: String, serverId: String, scopes: [String])
        case missingAuthorization
        case invalidAccessToken
        case capabilityNotAuthorized(capability: String)
        case invalidAgentCredential
    }

    private func agentIdentity(authorization: String?, capability: String) -> AgentIdentity {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .missingAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredentials[token], credential.revokedAt == nil else {
            return .invalidAccessToken
        }
        guard credential.scopes.contains(capability) else {
            return .capabilityNotAuthorized(capability: capability)
        }
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return .invalidAgentCredential
        }
        return .success(
            agentId: credential.agentId,
            serverId: agent.serverId,
            scopes: credential.scopes.sorted()
        )
    }

    // MARK: - App config projection

    private func appConfigResponse(
        appId: String,
        snapshot: AppConfigSnapshot
    ) -> AgentAppConfigResponse {
        var members: [OrderedJSONField] = []
        var effective: [OrderedJSONField] = []
        for key in Self.appConfigKeyOrder {
            if let value = snapshot.overrides[key] {
                members.append(OrderedJSONField(key, Self.jsonBody(value)))
            }
            if let current = snapshot.overrides[key] ?? Self.defaultValue(for: key) {
                effective.append(OrderedJSONField(key, Self.jsonBody(current)))
            }
        }
        return AgentAppConfigResponse(
            appId: appId,
            revision: snapshot.revision,
            overrides: members,
            effective: effective
        )
    }

    private static func defaultValue(for key: String) -> AppConfigValue? {
        switch key {
        case "enabled": .boolean(true)
        case "threshold_bytes": .integer(65_536)
        case "interval_seconds": .integer(3600)
        default: nil
        }
    }

    private static func jsonBody(_ value: AppConfigValue) -> OrderedJSON {
        switch value {
        case .boolean(let flag): .bool(flag)
        case .integer(let integer): .int(integer)
        }
    }

    /// Foundation's `NSNumber` bridging: `0`/`1` (either integer or double)
    /// also read as a boolean, which is what the legacy `value is Bool` check
    /// accepted.
    private static func legacyBoolean(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let flag):
            return flag
        case .integer(let integer) where integer == 0 || integer == 1:
            return integer == 1
        case .number(let number) where number == 0 || number == 1:
            return number == 1
        default:
            return nil
        }
    }

    /// The legacy integer branch rejects booleans but accepts any other
    /// `NSNumber` through `intValue`.
    private static func legacyConfigInteger(_ value: JSONValue) -> Int? {
        switch value {
        case .integer(let integer):
            return Int(integer)
        case .number(let number):
            if number >= Double(Int.max) { return Int.max }
            if number <= Double(Int.min) { return Int.min }
            return Int(number)
        default:
            return nil
        }
    }

    // MARK: - Marketplace reviewers

    private func marketplaceReviewerIds() -> Set<String> {
        if let override = feedback.marketplaceReviewerOverride { return override }
        let raw = environment("SLOCK_MARKETPLACE_REVIEWER_USER_IDS") ?? ""
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}
