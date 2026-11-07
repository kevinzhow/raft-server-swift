import Foundation

/// Domain failure for the integration setup, marketplace install, agent grant
/// and agent app event routes.
///
/// Every case is one published refusal. The retired handlers built each body by
/// hand; `Respond.swift` renders them from `errorMessage` and `errorBody`, so
/// the status and bytes are unchanged. Only the app-metadata refusal carries a
/// second key (`errorCode`), which is why it supplies its own `errorBody`.
public enum IntegrationsAndAppAccessError: DomainError, Equatable {
    case unauthorized
    case notAMember
    case activeInstallationNotFound
    case onlyOwnersAndAdminsCanChangeSetup
    case onlyOwnersAndAdminsCanInstall
    case onlyOwnersAndAdminsCanUninstall
    case invalidRequestBody
    case integrationAppNotFound
    /// `{"error": <message>, "errorCode": "INVALID_APP_METADATA"}`.
    case invalidAppMetadata(String)
    case setupReportNeedsAppCredentials
    case invalidSetupReport
    case invalidSetupStatus
    case invalidClientCredentials
    case setupDeclarationChanged
    case accessRequestNotFound
    case clientIdRequired
    case agentNotFound
    case cannotManageAgentAppAccess
    case integrationAppNotFoundForServer
    case invalidScope
    case grantNotFound
    case invalidLimit
    case invalidBeforeCursor
    case eventNotFound

    public var status: UInt {
        switch self {
        case .unauthorized, .setupReportNeedsAppCredentials, .invalidClientCredentials:
            401
        case .notAMember, .onlyOwnersAndAdminsCanChangeSetup, .onlyOwnersAndAdminsCanInstall,
             .onlyOwnersAndAdminsCanUninstall, .cannotManageAgentAppAccess:
            403
        case .activeInstallationNotFound, .integrationAppNotFound, .accessRequestNotFound,
             .agentNotFound, .integrationAppNotFoundForServer, .grantNotFound, .eventNotFound:
            404
        case .setupDeclarationChanged:
            409
        case .invalidRequestBody, .invalidAppMetadata, .invalidSetupReport, .invalidSetupStatus,
             .clientIdRequired, .invalidScope, .invalidLimit, .invalidBeforeCursor:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .notAMember:
            "Not a member of this server"
        case .activeInstallationNotFound:
            "Active installation not found"
        case .onlyOwnersAndAdminsCanChangeSetup:
            "Only server owners and admins can change app setup"
        case .onlyOwnersAndAdminsCanInstall:
            "Only server owners and admins can install apps"
        case .onlyOwnersAndAdminsCanUninstall:
            "Only server owners and admins can uninstall apps"
        case .invalidRequestBody:
            "Invalid request body"
        case .integrationAppNotFound:
            "Integration app not found"
        case .invalidAppMetadata(let message):
            message
        case .setupReportNeedsAppCredentials:
            "Installation setup reports require App credentials"
        case .invalidSetupReport:
            "Invalid setup report"
        case .invalidSetupStatus:
            "status must be pending or complete"
        case .invalidClientCredentials:
            "Invalid client credentials"
        case .setupDeclarationChanged:
            "Setup declaration changed; read current setup state before reporting completion"
        case .accessRequestNotFound:
            "Access request not found"
        case .clientIdRequired:
            "clientId is required"
        case .agentNotFound:
            "Agent not found"
        case .cannotManageAgentAppAccess:
            "You cannot manage this agent's app access"
        case .integrationAppNotFoundForServer:
            "Integration app not found for this server"
        case .invalidScope:
            "invalid_scope"
        case .grantNotFound:
            "Grant not found"
        case .invalidLimit:
            "limit must be a positive integer"
        case .invalidBeforeCursor:
            "before is not a valid cursor"
        case .eventNotFound:
            "Event not found"
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .invalidAppMetadata(let message):
            .object([
                OrderedJSONField("error", message),
                OrderedJSONField("errorCode", "INVALID_APP_METADATA"),
            ])
        case .unauthorized, .notAMember, .activeInstallationNotFound,
             .onlyOwnersAndAdminsCanChangeSetup, .onlyOwnersAndAdminsCanInstall,
             .onlyOwnersAndAdminsCanUninstall, .invalidRequestBody, .integrationAppNotFound,
             .setupReportNeedsAppCredentials, .invalidSetupReport, .invalidSetupStatus,
             .invalidClientCredentials, .setupDeclarationChanged, .accessRequestNotFound,
             .clientIdRequired, .agentNotFound, .cannotManageAgentAppAccess,
             .integrationAppNotFoundForServer, .invalidScope, .grantNotFound, .invalidLimit,
             .invalidBeforeCursor, .eventNotFound:
            nil
        }
    }
}

/// App setup declarations, Marketplace installs, installation credentials,
/// agent grants and the agent app event feed.
///
/// All state lives in the OAuth ledger (its own lock; each call below is one
/// ledger critical section or a read). The one cross-domain dependency is the
/// human session lookup, which belongs to the not-yet-migrated auth domain and
/// enters at `init`. Every operation returns a published DTO or throws its
/// surface's typed domain error; no HTTP reply is built here.
public struct IntegrationsAndAppAccessService: Sendable {
    private let oauth: OAuthLedger
    private let sessionUserId: @Sendable (String?) -> String?

    public init(
        oauth: OAuthLedger,
        sessionUserId: @escaping @Sendable (String?) -> String?
    ) {
        self.oauth = oauth
        self.sessionUserId = sessionUserId
    }

    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = sessionUserId(authorization) else {
            throw IntegrationsAndAppAccessError.unauthorized
        }
        return userId
    }

    // MARK: - Installation credentials

    /// `POST /api/oauth/installation-token`. The compatibility parser owns
    /// Basic/body precedence and form/JSON spelling; the owner makes the live
    /// eligibility decision and issues the token in one transaction.
    public func issueInstallationCredential(
        authorization: String?, body: String
    ) throws -> OAuthInstallationTokenResponse {
        let noStore = "private, no-store"
        let fields = OAuthRequestParsing.tokenFields(body)
        guard let credentials = OAuthRequestParsing.clientCredentials(authorization: authorization, fields: fields) else {
            throw OAuthLedgerError(.clientCredentialsRequired, cacheControl: noStore)
        }
        let installationId = fields["installation_id"] ?? fields["installationId"] ?? ""
        guard !installationId.isEmpty else {
            throw OAuthLedgerError(.installationIdRequired, cacheControl: noStore)
        }
        let attempt = InstallationMintAttempt(
            clientId: credentials.clientId, clientSecret: credentials.clientSecret, installationId: installationId
        )
        switch oauth.mintInstallationCredential(attempt) {
        case .invalidClient:
            throw OAuthLedgerError(.invalidClientCredentials, cacheControl: noStore)
        case .installationUnavailable:
            throw OAuthLedgerError(.activeInstallationNotFound, cacheControl: noStore)
        case .noEffectiveGroups:
            throw OAuthLedgerError(.noEffectiveReadGroups, cacheControl: noStore)
        case .issued(let receipt):
            return OAuthInstallationTokenResponse(
                accessToken: receipt.accessToken, installationId: receipt.installationId,
                serverId: receipt.serverId, grantRevision: receipt.grantRevision, groups: receipt.groups
            )
        }
    }

    /// `GET /api/app-installation/server`. Credential validation releases its
    /// lock before the group gate and the second, live server projection read.
    public func installationServer(authorization: String?) throws -> OAuthAppInstallationServerResponse {
        let credential = try requireInstallationCredential(authorization)
        guard credential.groups.contains("server") else {
            throw OAuthLedgerError(.lacksServerReadAuthority, cacheControl: "private, no-store")
        }
        guard let server = oauth.liveInstallationServer(id: credential.serverId) else {
            throw OAuthLedgerError(.serverNotFound, cacheControl: "private, no-store")
        }
        return OAuthAppInstallationServerResponse(
            installationId: credential.installationId, serverId: server.id, name: server.name, slug: server.slug
        )
    }

    /// `GET /api/app-installation/channels`. The channel authority is separate;
    /// this surface publishes an empty list and does not require a live server.
    public func installationChannels(authorization: String?) throws -> OAuthAppInstallationChannelsResponse {
        let credential = try requireInstallationCredential(authorization)
        guard credential.groups.contains("channel") else {
            throw OAuthLedgerError(.lacksChannelReadAuthority, cacheControl: "private, no-store")
        }
        return OAuthAppInstallationChannelsResponse(installationId: credential.installationId)
    }

    private func requireInstallationCredential(_ authorization: String?) throws -> InstallationCredentialFacts {
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.installationBearerRequired)
        }
        guard let credential = oauth.verifiedInstallationCredential(rawToken: raw) else {
            throw OAuthLedgerError(.invalidInstallationCredential)
        }
        return credential
    }

    // MARK: - Setup declaration

    /// `GET /api/integrations/clients/:clientId/setup`. Reading or visiting the
    /// setup link never completes setup and never changes grants; only
    /// owner/admin see the destination URL.
    public func integrationClientSetup(
        authorization: String?,
        serverId: String,
        clientId: String
    ) throws -> IntegrationSetupStateResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw IntegrationsAndAppAccessError.notAMember
        }
        guard let recordId = oauth.setupClientRecordId(serverId: serverId, clientKey: clientId),
              let state = oauth.getAppInstallationSetup(clientRecordId: recordId, serverId: serverId)
        else {
            throw IntegrationsAndAppAccessError.activeInstallationNotFound
        }
        let canConfigure = role == "owner" || role == "admin"
        return IntegrationSetupStateResponse(
            status: state.status.rawValue,
            url: canConfigure ? state.url : nil,
            description: canConfigure ? state.description : nil,
            revision: state.revision,
            completedAt: state.completedAt,
            canConfigure: canConfigure
        )
    }

    /// `PATCH /api/integrations/clients/:clientId`: the owning App's Server
    /// owner/admin edits the setup declaration. A changed setup URL is a new
    /// revision; wording-only changes do not require configuration again. A
    /// member that is not a string reads as absent and clears the field.
    public func updateIntegrationClientSetup(
        authorization: String?,
        serverId: String,
        clientId: String,
        body: IntegrationRequestBody?
    ) throws -> IntegrationClientSetupUpdate {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            throw IntegrationsAndAppAccessError.onlyOwnersAndAdminsCanChangeSetup
        }
        guard let body else { throw IntegrationsAndAppAccessError.invalidRequestBody }
        guard let recordId = oauth.setupClientRecordId(serverId: serverId, clientKey: clientId) else {
            throw IntegrationsAndAppAccessError.integrationAppNotFound
        }
        do {
            try oauth.updateClientSetupDeclaration(
                clientRecordId: recordId,
                setupUrl: body.string("setupUrl"),
                setupDescription: body.string("setupDescription")
            )
        } catch let error as AppSetupValidationError {
            throw IntegrationsAndAppAccessError.invalidAppMetadata(error.message)
        } catch {
            throw IntegrationsAndAppAccessError.invalidAppMetadata("Invalid app metadata")
        }
        let declaration = oauth.clientSetupDeclaration(clientRecordId: recordId)
        return IntegrationClientSetupUpdate(
            clientId: clientId,
            setupUrl: declaration?.url,
            setupDescription: declaration?.description,
            setupRevision: declaration?.revision ?? 1
        )
    }

    /// `PUT /api/oauth/installations/:installationId/setup`. Only the owning
    /// App's backend can report; human login is not App authentication.
    public func reportInstallationSetup(
        authorization: String?,
        installationId: String,
        body: IntegrationRequestBody?
    ) throws -> IntegrationSetupStateResponse {
        if let authorization, !authorization.isEmpty {
            throw IntegrationsAndAppAccessError.setupReportNeedsAppCredentials
        }
        guard let body,
              let clientKey = body.string("clientId"),
              let clientSecret = body.string("clientSecret"),
              let revision = body.int("revision"),
              let status = body.string("status")
        else {
            throw IntegrationsAndAppAccessError.invalidSetupReport
        }
        guard status == "pending" || status == "complete" else {
            throw IntegrationsAndAppAccessError.invalidSetupStatus
        }
        guard let recordId = oauth.verifyClientSecret(clientKey: clientKey, clientSecret: clientSecret) else {
            throw IntegrationsAndAppAccessError.invalidClientCredentials
        }
        let state: AppSetupState?
        do {
            state = try oauth.updateAppInstallationSetup(
                clientRecordId: recordId, installationId: installationId, revision: revision, status: status
            )
        } catch is OAuthLedger.AppSetupConflictError {
            throw IntegrationsAndAppAccessError.setupDeclarationChanged
        } catch {
            throw IntegrationsAndAppAccessError.invalidSetupReport
        }
        guard let state else { throw IntegrationsAndAppAccessError.activeInstallationNotFound }
        return IntegrationSetupStateResponse(
            status: state.status.rawValue,
            url: state.url,
            description: state.description,
            revision: state.revision,
            completedAt: state.completedAt,
            canConfigure: nil
        )
    }

    // MARK: - Marketplace install

    /// `POST /api/integrations/marketplace/:clientId/install` for the target Server.
    public func installMarketplaceClient(
        authorization: String?,
        serverId: String,
        clientId: String
    ) throws -> MarketplaceInstallResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            throw IntegrationsAndAppAccessError.onlyOwnersAndAdminsCanInstall
        }
        let recordId: String
        if oauth.marketplaceInstallableClientIdentity(recordId: clientId) != nil {
            recordId = clientId
        } else if let direct = oauth.clientRecordIdForServer(serverId: serverId, clientKey: clientId) {
            recordId = direct
        } else {
            throw IntegrationsAndAppAccessError.integrationAppNotFound
        }
        let installationId = oauth.installClient(
            serverId: serverId, clientRecordId: recordId, installedByUserId: userId, groups: []
        )
        let state = oauth.getAppInstallationSetup(clientRecordId: recordId, serverId: serverId)
        return MarketplaceInstallResponse(
            id: installationId,
            setupStatus: state?.status.rawValue ?? "not_required",
            setupRevision: state?.revision ?? 1
        )
    }

    /// `DELETE /api/integrations/marketplace/:clientId/install`.
    public func uninstallMarketplaceClient(
        authorization: String?,
        serverId: String,
        clientId: String
    ) throws -> OkResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            throw IntegrationsAndAppAccessError.onlyOwnersAndAdminsCanUninstall
        }
        guard let recordId = oauth.setupClientRecordId(serverId: serverId, clientKey: clientId) else {
            throw IntegrationsAndAppAccessError.integrationAppNotFound
        }
        _ = oauth.uninstallClient(serverId: serverId, clientRecordId: recordId)
        return OkResponse()
    }

    // MARK: - Agent grants

    /// `POST /api/integrations/requests/:requestId/approve`. A body that does
    /// not parse reads as no `remember`.
    public func approveAgentAccessRequest(
        authorization: String?,
        requestId: String,
        body: IntegrationRequestBody?
    ) throws -> AgentAccessDecisionResponse {
        let userId = try requireUser(authorization)
        switch oauth.approveAgentAccessRequest(
            userId: userId, requestId: requestId, remember: body?.bool("remember") ?? false
        ) {
        case nil:
            throw IntegrationsAndAppAccessError.accessRequestNotFound
        case .forbidden?:
            throw IntegrationsAndAppAccessError.cannotManageAgentAppAccess
        case .done?:
            return AgentAccessDecisionResponse(status: "approved")
        }
    }

    /// `POST /api/integrations/agents/:agentId/grants`.
    public func createAgentGrant(
        authorization: String?,
        agentId: String,
        body: IntegrationRequestBody?
    ) throws -> AgentGrantCreatedResponse {
        let userId = try requireUser(authorization)
        guard let body, let clientRecordId = body.string("clientId") else {
            throw IntegrationsAndAppAccessError.clientIdRequired
        }
        let scopes = body.stringElements("scopes") ?? []
        guard let result = oauth.createAgentGrant(
            userId: userId, agentId: agentId, clientRecordId: clientRecordId, scopes: scopes
        ) else {
            throw IntegrationsAndAppAccessError.agentNotFound
        }
        switch result.status {
        case 403: throw IntegrationsAndAppAccessError.cannotManageAgentAppAccess
        case 404: throw IntegrationsAndAppAccessError.integrationAppNotFoundForServer
        case 400: throw IntegrationsAndAppAccessError.invalidScope
        default:
            return AgentGrantCreatedResponse(
                status: UInt(result.status), grantId: result.grantId, created: result.created
            )
        }
    }

    /// `POST /api/integrations/grants/:grantId/revoke`.
    public func revokeAgentGrant(authorization: String?, grantId: String) throws -> AgentAccessDecisionResponse {
        let userId = try requireUser(authorization)
        switch oauth.revokeAgentGrant(userId: userId, grantId: grantId) {
        case nil:
            throw IntegrationsAndAppAccessError.grantNotFound
        case .forbidden?:
            throw IntegrationsAndAppAccessError.cannotManageAgentAppAccess
        case .done?:
            return AgentAccessDecisionResponse(status: "revoked")
        }
    }

    /// `GET /api/integrations/agents/:agentId/grants`.
    public func agentGrantList(authorization: String?, agentId: String) throws -> AgentGrantListResponse {
        let userId = try requireUser(authorization)
        guard let rows = oauth.agentGrantListVisible(userId: userId, agentId: agentId) else {
            throw IntegrationsAndAppAccessError.agentNotFound
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId),
              oauth.agentRole(serverId: agent.serverId, agentId: agentId) != nil
        else {
            throw IntegrationsAndAppAccessError.agentNotFound
        }
        if rows.isEmpty, oauth.memberRole(serverId: agent.serverId, userId: userId) == nil,
           agent.creatorUserId != userId {
            throw IntegrationsAndAppAccessError.cannotManageAgentAppAccess
        }
        return AgentGrantListResponse(rows: rows)
    }

    /// `GET /api/integrations/agents/:agentId/grantable-apps`.
    public func agentGrantableApps(authorization: String?, agentId: String) throws -> AgentGrantableAppsResponse {
        let userId = try requireUser(authorization)
        guard let apps = oauth.grantableApps(userId: userId, agentId: agentId) else {
            throw IntegrationsAndAppAccessError.agentNotFound
        }
        if apps.isEmpty, let agent = oauth.agentRuntimeInfo(id: agentId),
           oauth.memberRole(serverId: agent.serverId, userId: userId) == nil,
           agent.creatorUserId != userId {
            throw IntegrationsAndAppAccessError.cannotManageAgentAppAccess
        }
        return AgentGrantableAppsResponse(apps: apps)
    }

    // MARK: - Agent app events

    /// `GET /api/integrations/agents/:agentId/events`.
    public func agentAppEvents(
        authorization: String?,
        agentId: String,
        limit: String?,
        before: String?
    ) throws -> AgentAppEventPageResponse {
        let userId = try requireUser(authorization)
        let parsedLimit: Int
        if let limit, !limit.isEmpty {
            guard let value = Int(limit), value > 0 else {
                throw IntegrationsAndAppAccessError.invalidLimit
            }
            parsedLimit = value
        } else {
            parsedLimit = 50
        }
        switch oauth.agentAppEvents(userId: userId, agentId: agentId, limit: parsedLimit, before: before) {
        case .forbidden:
            throw IntegrationsAndAppAccessError.cannotManageAgentAppAccess
        case .notFound:
            throw IntegrationsAndAppAccessError.agentNotFound
        case .invalidLimit:
            throw IntegrationsAndAppAccessError.invalidLimit
        case .invalidCursor:
            throw IntegrationsAndAppAccessError.invalidBeforeCursor
        case .events(let rows, let nextCursor):
            return AgentAppEventPageResponse(events: rows, nextCursor: nextCursor)
        }
    }

    /// `GET /api/integrations/agents/:agentId/events/:eventId`.
    public func agentAppEventDetail(
        authorization: String?,
        agentId: String,
        eventId: String
    ) throws -> AgentAppEventDetailResponse {
        let userId = try requireUser(authorization)
        switch oauth.agentAppEventDetail(userId: userId, agentId: agentId, eventId: eventId) {
        case .forbidden:
            throw IntegrationsAndAppAccessError.cannotManageAgentAppAccess
        case .notFound:
            throw IntegrationsAndAppAccessError.eventNotFound
        case .event(let event):
            return AgentAppEventDetailResponse(event: event)
        }
    }
}
