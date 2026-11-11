import Foundation

/// Domain failure for the agent integration-app routes.
///
/// The retired handlers answered with two key shapes: the default
/// `{"error":…,"code":…}` for credential and lookup refusals, and
/// `{"error":…,"errorCode":…}` for app-metadata and scope refusals. The second
/// shape, and the `requiredCapability` member, are supplied through `errorBody`.
public enum AgentIntegrationAppsError: DomainError, Equatable {
    case authRequired
    /// `requiredCapability` is published for the read-scoped routes only.
    case capabilityNotAuthorized(requiredCapability: String?)
    case clientKeyRequired
    case integrationAppNotFound
    case invalidAppMetadata(String)
    case exactlyOneOfCardOrClient
    case invalidMarketplaceLimit
    case registeredServiceNotFound
    case scopeNotAllowed
    case installTargetNotFound

    public var status: UInt {
        switch self {
        case .authRequired:
            401
        case .capabilityNotAuthorized:
            403
        case .integrationAppNotFound, .registeredServiceNotFound, .installTargetNotFound:
            404
        case .clientKeyRequired, .invalidAppMetadata, .exactlyOneOfCardOrClient,
             .invalidMarketplaceLimit, .scopeNotAllowed:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .authRequired:
            "Invalid or expired token"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .clientKeyRequired:
            "clientKey is required"
        case .integrationAppNotFound:
            "Integration app not found"
        case .invalidAppMetadata(let message):
            message
        case .exactlyOneOfCardOrClient:
            "Exactly one of card or client is required"
        case .invalidMarketplaceLimit:
            "limit must be between 1 and 50"
        case .registeredServiceNotFound:
            "Registered service not found"
        case .scopeNotAllowed:
            "Scope is not allowed for this service"
        case .installTargetNotFound:
            "Install target not found or not visible to this agent"
        }
    }

    public var errorCode: String? {
        switch self {
        case .authRequired:
            "auth_required"
        case .registeredServiceNotFound:
            "integration_not_found"
        case .capabilityNotAuthorized, .clientKeyRequired, .integrationAppNotFound,
             .invalidAppMetadata, .exactlyOneOfCardOrClient, .invalidMarketplaceLimit,
             .scopeNotAllowed, .installTargetNotFound:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .capabilityNotAuthorized(let requiredCapability):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "capability_not_authorized")
            body.append("requiredCapability", ifPresent: requiredCapability)
            return body.json
        case .clientKeyRequired:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "INVALID_APP_METADATA"),
            ])
        case .invalidAppMetadata(let message):
            return .object([
                OrderedJSONField("error", message),
                OrderedJSONField("errorCode", "INVALID_APP_METADATA"),
            ])
        case .scopeNotAllowed:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "INVALID_SCOPE"),
            ])
        case .authRequired, .integrationAppNotFound, .exactlyOneOfCardOrClient,
             .invalidMarketplaceLimit, .registeredServiceNotFound, .installTargetNotFound:
            return nil
        }
    }
}

// MARK: - Injected dependencies

/// The not-yet-migrated decisions the agent app routes need: the agent
/// credential lookup, and the Marketplace install card. The card closure bundles
/// the action-card target resolution and the card write, which both belong to the
/// action-card domain; it answers nil when the target cannot be resolved or the
/// client record lost a member, which is the one refusal the route publishes.
struct AgentIntegrationAppsDependencies: Sendable {
    var agentCredential: @Sendable (String?) -> (agentId: String, scopes: [String])?
    var prepareMarketplaceInstallCard: @Sendable (
        _ agent: OAuthLedger.AgentRuntimeInfo,
        _ client: MarketplaceClientIdentity,
        _ scopes: [String],
        _ target: String
    ) -> String?
    /// `getAppUrl()`: the origin a private share link is published under.
    var appURL: @Sendable () -> String
}

extension AgentIntegrationAppsDependencies {
    init(lookup: AgentCredentialLookup, register: ActionCardIntegrationRegisterService) {
        self.init(
            agentCredential: lookup.agentCredentialAgent,
            prepareMarketplaceInstallCard: register.prepareMarketplaceInstallCardForReference,
            appURL: { WebCORS.appURL(environment: ProcessInfo.processInfo.environment) }
        )
    }
}

// MARK: - Service

/// The agent-facing integration app surface: the Apps an agent may manage, one
/// app's status, the metadata update, the public Marketplace listing and the
/// agent's login into an installed service.
///
/// The ledger owns the app rows; the only state this service writes is the
/// login record, through one `ManagedMCPAndCardsStore` critical section
/// (`recordAgentIntegrationLogin`) so two concurrent first logins cannot both
/// report `logged_in`.
public struct AgentIntegrationAppsService: Sendable {
    private let oauth: OAuthLedger
    private let logins: ManagedMCPAndCardsStore
    private let dependencies: AgentIntegrationAppsDependencies

    init(
        oauth: OAuthLedger,
        logins: ManagedMCPAndCardsStore,
        dependencies: AgentIntegrationAppsDependencies
    ) {
        self.oauth = oauth
        self.logins = logins
        self.dependencies = dependencies
    }

    private func requireAgent(
        _ authorization: String?,
        requireRead: Bool
    ) throws -> OAuthLedger.AgentRuntimeInfo {
        guard let credential = dependencies.agentCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentIntegrationAppsError.authRequired
        }
        if requireRead, !credential.scopes.contains("read") {
            throw AgentIntegrationAppsError.capabilityNotAuthorized(requiredCapability: "read")
        }
        return agent
    }

    private func isAdmin(_ agent: OAuthLedger.AgentRuntimeInfo) -> Bool {
        oauth.agentRole(serverId: agent.serverId, agentId: agent.id) == "admin"
    }

    // MARK: Update

    /// `POST /internal/agent-api/integrations/app/update`.
    public func agentIntegrationAppUpdate(
        authorization: String?,
        body: IntegrationRequestBody?
    ) throws -> AgentIntegrationAppUpdatedResponse {
        let agent = try requireAgent(authorization, requireRead: false)
        guard let body,
              let clientKey = body.string("clientKey")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientKey.isEmpty
        else {
            throw AgentIntegrationAppsError.clientKeyRequired
        }
        let admin = isAdmin(agent)
        guard oauth.ownedIntegrationApp(
            serverId: agent.serverId, agentId: agent.id, clientKey: clientKey, admin: admin
        ) != nil else {
            throw AgentIntegrationAppsError.integrationAppNotFound
        }
        guard let recordId = oauth.clientRecordId(serverId: agent.serverId, clientKey: clientKey) else {
            throw AgentIntegrationAppsError.integrationAppNotFound
        }
        var updatedFields: [String] = []
        if body.has("setupUrl") || body.has("setupDescription") {
            let current = oauth.clientSetupDeclaration(clientRecordId: recordId)
            do {
                try oauth.updateClientSetupDeclaration(
                    clientRecordId: recordId,
                    setupUrl: body.string("setupUrl") ?? current?.url,
                    setupDescription: body.string("setupDescription") ?? current?.description
                )
            } catch {
                throw AgentIntegrationAppsError.invalidAppMetadata("Invalid app metadata")
            }
            if body.has("setupUrl") { updatedFields.append("setupUrl") }
            if body.has("setupDescription") { updatedFields.append("setupDescription") }
        }
        if body.has("whenToUse") {
            let normalized: String?
            do {
                normalized = try Self.normalizedWhenToUse(body.string("whenToUse"))
            } catch let error as WhenToUseError {
                throw AgentIntegrationAppsError.invalidAppMetadata(error.message)
            } catch {
                throw AgentIntegrationAppsError.invalidAppMetadata("Invalid app metadata")
            }
            oauth.setClientWhenToUse(clientRecordId: recordId, whenToUse: normalized)
            updatedFields.append("whenToUse")
        }
        let app = oauth.ownedIntegrationApp(
            serverId: agent.serverId, agentId: agent.id, clientKey: clientKey, admin: admin
        )
        return AgentIntegrationAppUpdatedResponse(
            clientId: recordId,
            clientKey: clientKey,
            clientName: app?.name ?? "",
            updatedFields: updatedFields
        )
    }

    enum WhenToUseError: Error {
        case tooLong
        case notSingleLine
        case bareScopedPackage

        var message: String {
            switch self {
            case .tooLong: "whenToUse must be at most 160 characters"
            case .notSingleLine: "whenToUse must be a single line without control characters"
            case .bareScopedPackage:
                "whenToUse must not contain a bare scoped package name like @scope/pkg; wrap it in backticks like `@scope/pkg`"
            }
        }
    }

    /// `whenToUse` is prompt material: one line, at most 160 code points, and
    /// no bare `@scope/pkg` outside inline code.
    static func normalizedWhenToUse(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.unicodeScalars.count <= 160 else {
            throw WhenToUseError.tooLong
        }
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw WhenToUseError.notSingleLine
        }
        var outsideCode = value
        outsideCode = outsideCode.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " ",
            options: .regularExpression
        )
        outsideCode = outsideCode.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        let bare = try! NSRegularExpression(pattern: "(^|[\\s(])@[a-z0-9][a-z0-9-]*/[a-z0-9._-]+", options: [.caseInsensitive])
        let range = NSRange(location: 0, length: (outsideCode as NSString).length)
        if bare.firstMatch(in: outsideCode, options: [], range: range) != nil {
            throw WhenToUseError.bareScopedPackage
        }
        return value
    }

    // MARK: List and status

    /// `GET /internal/agent-api/integrations/app`.
    public func agentIntegrationAppList(authorization: String?) throws -> AgentIntegrationAppListResponse {
        let agent = try requireAgent(authorization, requireRead: true)
        return AgentIntegrationAppListResponse(apps: oauth.ownedIntegrationApps(
            serverId: agent.serverId, agentId: agent.id, admin: isAdmin(agent)
        ))
    }

    /// `GET /internal/agent-api/integrations/app/status`.
    public func agentIntegrationAppStatus(
        authorization: String?,
        client: String?,
        card: String?
    ) throws -> AgentIntegrationAppStatusResponse {
        let agent = try requireAgent(authorization, requireRead: true)
        let clientKey = (client ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cardRef = (card ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientKey.isEmpty != cardRef.isEmpty else {
            throw AgentIntegrationAppsError.exactlyOneOfCardOrClient
        }
        if !cardRef.isEmpty {
            // Registration cards are the only card-backed app state; until a
            // prepared card exists the reference is simply unknown.
            throw AgentIntegrationAppsError.integrationAppNotFound
        }
        guard let app = oauth.ownedIntegrationApp(
            serverId: agent.serverId, agentId: agent.id, clientKey: clientKey, admin: isAdmin(agent)
        ) else {
            throw AgentIntegrationAppsError.integrationAppNotFound
        }
        return AgentIntegrationAppStatusResponse(app: app)
    }

    // MARK: Marketplace

    /// `GET /internal/agent-api/integrations/marketplace`.
    public func agentIntegrationMarketplace(
        authorization: String?,
        query: String?,
        limit: String?
    ) throws -> AgentIntegrationMarketplaceResponse {
        let agent = try requireAgent(authorization, requireRead: false)
        var pageLimit = 20
        if let limit, !limit.isEmpty {
            guard let parsed = Int(limit), parsed >= 1, parsed <= 50 else {
                throw AgentIntegrationAppsError.invalidMarketplaceLimit
            }
            pageLimit = parsed
        }
        let trimmedQuery = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = oauth.marketplaceClients(serverId: agent.serverId, query: trimmedQuery).prefix(pageLimit)
        return AgentIntegrationMarketplaceResponse(
            query: trimmedQuery.isEmpty ? nil : trimmedQuery,
            apps: Array(apps)
        )
    }

    // MARK: Login

    /// `POST /internal/agent-api/integrations/login`.
    public func agentIntegrationLogin(
        authorization: String?,
        body: IntegrationRequestBody?
    ) throws -> AgentIntegrationLoginResponse {
        let agent = try requireAgent(authorization, requireRead: false)
        guard let body, let serviceRef = body.string("service"), !serviceRef.isEmpty else {
            throw AgentIntegrationAppsError.registeredServiceNotFound
        }
        let installedService = oauth.integrationLoginServiceRow(serverId: agent.serverId, clientId: serviceRef)
        let publicService = installedService == nil ? oauth.publicIntegrationServiceRow(clientId: serviceRef) : nil
        guard let service = installedService ?? publicService else {
            throw AgentIntegrationAppsError.registeredServiceNotFound
        }
        let defaultScopes: [String] = service.allowedScopes == nil ? ["identity", "openid", "profile"] : ["openid"]
        let requestedScopes = body.stringElements("scopes") ?? []
        if !requestedScopes.isEmpty, !Set(requestedScopes).isSubset(of: Set(defaultScopes)) {
            throw AgentIntegrationAppsError.scopeNotAllowed
        }
        let effectiveScopes = requestedScopes.isEmpty ? defaultScopes : requestedScopes
        if installedService == nil {
            let profile = oauth.serverProfile(id: agent.serverId)
            let requestedTarget = (body.string("target") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var actionCardMessageId: String?
            if !requestedTarget.isEmpty {
                guard let messageId = dependencies.prepareMarketplaceInstallCard(
                    agent,
                    MarketplaceClientIdentity(recordId: service.id, clientKey: service.clientId, name: service.name),
                    effectiveScopes,
                    requestedTarget
                ) else {
                    throw AgentIntegrationAppsError.installTargetNotFound
                }
                actionCardMessageId = messageId
            }
            return .installRequired(
                service: service.snapshot,
                scopes: effectiveScopes,
                serverSlug: profile?.slug ?? "",
                serverName: profile?.name ?? "",
                marketplaceUrl: "/marketplace?marketplace_app=\(service.id)",
                target: requestedTarget.isEmpty ? nil : requestedTarget,
                actionCardMessageId: actionCardMessageId
            )
        }
        let key = "\(agent.serverId)\n\(agent.id)\n\(service.id)"
        let existed = logins.recordAgentIntegrationLogin(
            key: key,
            record: AgentIntegrationLoginRecord(
                serverId: agent.serverId,
                agentId: agent.id,
                clientId: service.id,
                scopes: effectiveScopes,
                loggedInAt: Date()
            )
        )
        return .loggedIn(
            status: existed ? "already_logged_in" : "logged_in",
            requestId: UUID().uuidString.lowercased(),
            service: service.snapshot,
            scopes: effectiveScopes
        )
    }

    // MARK: - Logo, manage, rotate-secret and transfer-owner

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func managedClient(
        _ agent: OAuthLedger.AgentRuntimeInfo,
        clientKey: String,
        authorityMessage: String
    ) throws -> OAuthLedger.AgentManagedIntegrationClient {
        let trimmed = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentIntegrationAppManageError.clientKeyRequired }
        guard let client = oauth.agentManagedIntegrationClient(serverId: agent.serverId, clientKey: trimmed) else {
            throw AgentIntegrationAppManageError.integrationAppNotFound
        }
        guard oauth.isAgentIntegrationAppManager(
            serverId: agent.serverId, agentId: agent.id, clientRecordId: client.id
        ) else {
            throw AgentIntegrationAppManageError.manageAuthorityRequired(message: authorityMessage)
        }
        return client
    }

    /// `POST /internal/agent-api/integrations/app/logo`.
    public func agentIntegrationAppLogo(
        authorization: String?,
        clientKey: String,
        file: AttachmentUploadContent?
    ) throws -> AgentIntegrationAppLogoResponse {
        let agent = try requireAgent(authorization, requireRead: true)
        let client = try managedClient(
            agent,
            clientKey: clientKey,
            authorityMessage: "Only this app's owner or a current server admin can update its logo"
        )
        guard let file else { throw AgentIntegrationAppManageError.noLogoFile }
        _ = try AgentAvatarUploadError.validatedMimeType(file.mimeType)
        guard file.bytes.count > 0 else { throw AgentIntegrationAppManageError.noLogoFile }
        guard file.bytes.count <= AgentAvatarUploadError.maximumBytes else {
            throw AgentPrivateSurfaceError.avatarTooLarge(maxBytes: AgentAvatarUploadError.maximumBytes)
        }
        let key = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let logoUrl = "/api/integration-logos/\(client.id)/\(key).webp"
        oauth.setAgentManagedIntegrationClientLogo(clientRecordId: client.id, logoUrl: logoUrl)
        oauth.recordAgentManagedIntegrationAudit(
            serverId: agent.serverId,
            clientRecordId: client.id,
            installationId: "",
            eventType: "app.logo_updated"
        )
        return AgentIntegrationAppLogoResponse(
            clientId: client.id,
            clientKey: client.clientKey,
            clientName: client.name,
            logoUrl: logoUrl
        )
    }

    /// `POST /internal/agent-api/integrations/app/rotate-secret`.
    public func agentIntegrationAppRotateSecret(
        authorization: String?,
        clientKey: String
    ) throws -> AgentIntegrationAppRotateSecretResponse {
        let agent = try requireAgent(authorization, requireRead: true)
        let client = try managedClient(
            agent,
            clientKey: clientKey,
            authorityMessage: "Only this app's owner, delegated rotate maintainer, or a current server admin can rotate its secret"
        )
        guard let secret = oauth.rotateAgentManagedIntegrationClientSecret(clientRecordId: client.id) else {
            throw AgentIntegrationAppManageError.integrationAppNotFound
        }
        oauth.recordAgentManagedIntegrationAudit(
            serverId: agent.serverId,
            clientRecordId: client.id,
            installationId: "",
            eventType: "client.secret_rotated"
        )
        return AgentIntegrationAppRotateSecretResponse(
            clientId: client.id,
            clientKey: client.clientKey,
            clientName: client.name,
            clientSecret: secret
        )
    }

    /// `POST /internal/agent-api/integrations/app/transfer-owner`.
    public func agentIntegrationAppTransferOwner(
        authorization: String?,
        clientKey: String,
        targetAgent: String
    ) throws -> AgentIntegrationAppTransferOwnerResponse {
        let agent = try requireAgent(authorization, requireRead: true)
        let targetName = targetAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !targetName.isEmpty else { throw AgentIntegrationAppManageError.clientKeyAndTargetRequired }
        guard let target = oauth.serverAgents(serverId: agent.serverId).first(where: {
            !$0.deleted && $0.name == targetName
        }) else {
            throw AgentIntegrationAppManageError.targetAgentNotFound
        }
        let client = try managedClient(
            agent,
            clientKey: clientKey,
            authorityMessage: "Only this app's owner or a current server admin can transfer it"
        )
        guard let transfer = oauth.transferAgentManagedIntegrationClient(
            clientRecordId: client.id, to: target.id
        ) else {
            throw AgentIntegrationAppManageError.manageAuthorityRequired(
                message: "Only this app's owner or a current server admin can transfer it"
            )
        }
        let auditEventId = oauth.recordAgentManagedIntegrationAudit(
            serverId: agent.serverId,
            clientRecordId: client.id,
            installationId: "",
            eventType: "app.owner_transferred"
        )
        return AgentIntegrationAppTransferOwnerResponse(
            clientId: client.id,
            clientKey: client.clientKey,
            clientName: client.name,
            ownerAgentId: target.id,
            ownerAgentName: target.name,
            ownershipOutcome: transfer.outcome,
            auditEventId: auditEventId
        )
    }

    /// `POST /internal/agent-api/integrations/app/manage`.
    public func agentIntegrationAppManage(
        authorization: String?,
        clientKey: String,
        action: String,
        expiresInDays: Int?
    ) throws -> AgentIntegrationAppManageResponse {
        let agent = try requireAgent(authorization, requireRead: true)
        let client = try managedClient(
            agent,
            clientKey: clientKey,
            authorityMessage: "Only this app's owner or a current server admin can manage it"
        )
        switch action {
        case "share_link_get":
            let link = oauth.activeAgentManagedIntegrationShareLink(clientRecordId: client.id)
            return AgentIntegrationAppManageResponse(
                action: action,
                clientId: client.id,
                clientKey: client.clientKey,
                clientName: client.name,
                link: link.map(Self.shareLinkView),
                linkPresent: true
            )
        case "share_link_create":
            guard let created = oauth.createAgentManagedIntegrationShareLink(
                serverId: agent.serverId,
                clientRecordId: client.id,
                actorAgentId: agent.id,
                actorUserId: nil,
                expiresInDays: expiresInDays
            ) else {
                throw AgentIntegrationAppManageError.shareLinkNotCreatable
            }
            oauth.recordAgentManagedIntegrationAudit(
                serverId: agent.serverId,
                clientRecordId: client.id,
                installationId: "",
                eventType: "private_share.link_created"
            )
            // `encodeURIComponent`: unreserved marks stay literal, `_` included.
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~!*'()")
            let encoded = created.token.addingPercentEncoding(withAllowedCharacters: allowed) ?? created.token
            return AgentIntegrationAppManageResponse(
                action: action,
                clientId: client.id,
                clientKey: client.clientKey,
                clientName: client.name,
                shareUrl: dependencies.appURL() + "/integration-invites/" + encoded,
                link: Self.shareLinkView(created.link),
                linkPresent: true
            )
        case "share_link_revoke":
            guard let revoked = oauth.revokeAgentManagedIntegrationShareLink(clientRecordId: client.id) else {
                throw AgentIntegrationAppManageError.shareLinkNotFound
            }
            oauth.recordAgentManagedIntegrationAudit(
                serverId: agent.serverId,
                clientRecordId: client.id,
                installationId: "",
                eventType: "private_share.link_revoked"
            )
            return AgentIntegrationAppManageResponse(
                action: action,
                clientId: client.id,
                clientKey: client.clientKey,
                clientName: client.name,
                link: Self.shareLinkView(revoked),
                linkPresent: true
            )
        case "request_publish":
            let description = (client.descriptionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { throw AgentIntegrationAppManageError.descriptionRequired }
            guard oauth.requestAgentManagedIntegrationClientPublish(
                clientRecordId: client.id, status: "publish_requested"
            ) else {
                throw AgentIntegrationAppManageError.publishNotRequestable
            }
            oauth.recordAgentManagedIntegrationAudit(
                serverId: agent.serverId,
                clientRecordId: client.id,
                installationId: "",
                eventType: "app.publish_requested"
            )
            return AgentIntegrationAppManageResponse(
                action: action,
                clientId: client.id,
                clientKey: client.clientKey,
                clientName: client.name,
                publishStatus: "publish_requested"
            )
        case "request_unpublish":
            guard oauth.requestAgentManagedIntegrationClientPublish(
                clientRecordId: client.id, status: "unpublish_requested"
            ) else {
                throw AgentIntegrationAppManageError.unpublishNotPublished
            }
            oauth.recordAgentManagedIntegrationAudit(
                serverId: agent.serverId,
                clientRecordId: client.id,
                installationId: "",
                eventType: "app.offline_requested"
            )
            return AgentIntegrationAppManageResponse(
                action: action,
                clientId: client.id,
                clientKey: client.clientKey,
                clientName: client.name,
                publishStatus: "unpublish_requested"
            )
        case "clear_logo":
            oauth.setAgentManagedIntegrationClientLogo(clientRecordId: client.id, logoUrl: nil)
            return AgentIntegrationAppManageResponse(
                action: action,
                clientId: client.id,
                clientKey: client.clientKey,
                clientName: client.name,
                logoUrl: nil,
                logoUrlPresent: true
            )
        case "delete":
            guard oauth.deleteAgentManagedIntegrationClient(clientRecordId: client.id) else {
                throw AgentIntegrationAppManageError.deletePublished
            }
            oauth.recordAgentManagedIntegrationAudit(
                serverId: agent.serverId,
                clientRecordId: nil,
                installationId: "",
                eventType: "app.deleted"
            )
            return AgentIntegrationAppManageResponse(
                action: action,
                clientId: client.id,
                clientKey: client.clientKey,
                clientName: client.name
            )
        default:
            throw AgentIntegrationAppManageError.clientKeyRequired
        }
    }

    private static func shareLinkView(_ link: OAuthLedger.ClientShareLink) -> AgentIntegrationAppShareLinkView {
        AgentIntegrationAppShareLinkView(
            id: link.id,
            expiresAt: link.expiresAt.map(Self.isoString),
            revokedAt: link.revokedAt.map(Self.isoString),
            lastUsedAt: link.lastUsedAt.map(Self.isoString),
            createdAt: Self.isoString(link.createdAt),
            updatedAt: Self.isoString(link.updatedAt)
        )
    }
}
