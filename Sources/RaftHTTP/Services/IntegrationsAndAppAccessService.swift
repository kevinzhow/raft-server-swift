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
    case onlyOwnersAndAdminsCanManageIntegrations
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
    case oauthClientNotFound
    case noLogoFile
    case logoTooLarge
    case logoBadFormat
    case logoUploadFailed
    case logoClearFailed

    public var status: UInt {
        switch self {
        case .unauthorized, .setupReportNeedsAppCredentials, .invalidClientCredentials:
            401
        case .notAMember, .onlyOwnersAndAdminsCanChangeSetup, .onlyOwnersAndAdminsCanInstall,
             .onlyOwnersAndAdminsCanUninstall, .onlyOwnersAndAdminsCanManageIntegrations,
             .cannotManageAgentAppAccess:
            403
        case .activeInstallationNotFound, .integrationAppNotFound, .accessRequestNotFound,
             .agentNotFound, .integrationAppNotFoundForServer, .grantNotFound, .eventNotFound,
             .oauthClientNotFound:
            404
        case .setupDeclarationChanged:
            409
        case .invalidRequestBody, .invalidAppMetadata, .invalidSetupReport, .invalidSetupStatus,
             .clientIdRequired, .invalidScope, .invalidLimit, .invalidBeforeCursor,
             .noLogoFile, .logoTooLarge, .logoBadFormat:
            400
        case .logoUploadFailed, .logoClearFailed:
            500
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
        case .onlyOwnersAndAdminsCanManageIntegrations:
            "Only server owners and admins can manage integrations"
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
        case .oauthClientNotFound:
            "OAuth client not found"
        case .noLogoFile:
            "No logo file provided"
        case .logoTooLarge:
            "Avatar image must be 5 MB or smaller"
        case .logoBadFormat:
            "Only image files are allowed (JPEG, PNG, GIF, WebP)"
        case .logoUploadFailed:
            "Failed to upload OAuth client logo"
        case .logoClearFailed:
            "Failed to clear OAuth client logo"
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
             .onlyOwnersAndAdminsCanUninstall, .onlyOwnersAndAdminsCanManageIntegrations,
             .invalidRequestBody, .integrationAppNotFound,
             .setupReportNeedsAppCredentials, .invalidSetupReport, .invalidSetupStatus,
             .invalidClientCredentials, .setupDeclarationChanged, .accessRequestNotFound,
             .clientIdRequired, .agentNotFound, .cannotManageAgentAppAccess,
             .integrationAppNotFoundForServer, .invalidScope, .grantNotFound, .invalidLimit,
             .invalidBeforeCursor, .eventNotFound, .oauthClientNotFound, .noLogoFile,
             .logoTooLarge, .logoBadFormat, .logoUploadFailed, .logoClearFailed:
            nil
        }
    }
}

/// App setup declarations, Marketplace installs, installation credentials,
/// App-initiated access requests, agent grants and the agent app event feed.
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
            description: state.description,
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

    // MARK: - App-initiated agent access

    /// `POST /api/oauth/requests/agent`. This endpoint accepts a JSON object,
    /// with the original Basic/body credential precedence. Pure shape parsing
    /// never refuses a selector or scope before the owner's live-state gates.
    public func requestAgentAccess(
        authorization: String?, body: String
    ) throws -> OAuthAgentAccessRequestResponse {
        let object = OAuthRequestBody.parse(body)
        var fields: [String: String] = [:]
        for key in ["client_id", "clientId", "client_secret", "clientSecret"] {
            if let value = object?.string(key) { fields[key] = value }
        }
        guard let credentials = OAuthRequestParsing.clientCredentials(authorization: authorization, fields: fields) else {
            throw OAuthLedgerError(.clientCredentialsRequired)
        }
        let serverSlug = (object?.string("serverSlug") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let selector: AppAgentAccessSelector
        if let rawId = object?.string("agentId"), !rawId.isEmpty {
            if rawId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil {
                selector = .id(rawId.lowercased())
            } else {
                selector = .invalidId
            }
        } else {
            selector = .name((object?.string("agentName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let scopeCandidates: [String]? = {
            guard case .array(let list)? = object?.value("scopes") else { return nil }
            var strings: [String] = []
            for item in list {
                guard case .string(let text) = item else { return nil }
                strings.append(text)
            }
            return strings
        }()
        let attempt = AppAgentAccessRequestAttempt(
            clientId: credentials.clientId, clientSecret: credentials.clientSecret,
            serverSlug: serverSlug, selector: selector, scopeCandidates: scopeCandidates,
            initiatedByAgent: object?.bool("initiatedByAgent") == true
        )
        switch oauth.submitAgentAccessRequest(attempt) {
        case .invalidClient:
            throw OAuthLedgerError(.invalidClientCredentials)
        case .serverUnavailable:
            throw OAuthLedgerError(.serverNotFound)
        case .agentUnavailable:
            throw OAuthLedgerError(.agentNotFound)
        case .appUnavailableOnServer:
            throw OAuthLedgerError(.clientNotFoundForServer)
        case .invalidScopes:
            throw OAuthLedgerError(.invalidScopeBare)
        case .completed(let receipt):
            return OAuthAgentAccessRequestResponse(
                requestId: receipt.requestId, status: receipt.status,
                client: OAuthClientSummary(clientId: receipt.clientId, appType: receipt.clientAppType, name: receipt.clientName),
                agentId: receipt.agentId, agentName: receipt.agentName, agentDisplayName: receipt.agentDisplayName,
                serverId: receipt.serverId, serverSlug: receipt.serverSlug, scopes: receipt.scopes
            )
        }
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

    /// `POST /api/oauth/agent-events`. Only missing Bearer admission refuses
    /// before the owner transaction. Malformed fields remain markers so invalid
    /// token/principal/resource/scope/target failures retain their precedence.
    public func postAgentEvent(authorization: String?, body: String) throws -> OAuthAgentEventResponse {
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.missingBearerToken)
        }
        let object = OAuthRequestBody.parse(body)
        let summary = (object?.string("summary") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let attempt = AppAgentEventAttempt(
            bearerToken: raw,
            kind: AppAgentEventKind(rawValue: object?.string("kind") ?? ""),
            target: object?.string("agentId") ?? object?.string("agent_id"),
            summary: !summary.isEmpty && summary.count <= 500 ? summary : nil,
            payloadJSON: object?.payloadJSON,
            externalEventId: (object?.string("externalEventId") ?? object?.string("external_event_id"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        let completion: (receipt: AppAgentEventReceipt, status: String, deduped: Bool)
        switch oauth.ingestAgentEvent(attempt) {
        case .invalidToken:
            throw OAuthLedgerError(.invalidOrExpiredAccessToken)
        case .agentTokenRequired:
            throw OAuthLedgerError(.agentTokenRequired)
        case .resourceRequired(let resource):
            throw OAuthLedgerError(.resourceBoundTokenRequired(resource: resource))
        case .invalidKind:
            throw OAuthLedgerError(.eventKindInvalid)
        case .insufficientScope(let scope):
            throw OAuthLedgerError(.insufficientScope(requiredScope: scope))
        case .crossAgentTarget:
            throw OAuthLedgerError(.crossAgentTarget)
        case .summaryRequired:
            throw OAuthLedgerError(.eventSummaryRequired)
        case .invalidPayload:
            throw OAuthLedgerError(.eventPayloadNotObject)
        case .created(let receipt):
            completion = (receipt, "queued", false)
        case .reclaimed(let receipt):
            completion = (receipt, "queued", true)
        case .duplicate(let receipt):
            completion = (receipt, "duplicate", true)
        }
        return OAuthAgentEventResponse(
            id: completion.receipt.id,
            status: completion.status,
            deduped: completion.deduped,
            expiresAt: ISO8601DateFormatter().string(from: completion.receipt.expiresAt),
            payloadHash: completion.receipt.payloadHash
        )
    }

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

    // MARK: - Integration logos

    /// `POST /api/integrations/clients/:clientId/logo`. Owner/admin of the
    /// owning Server only; a cross-Server or built-in App is indistinguishable
    /// from a missing one. The response is the same row projection
    /// `GET /api/integrations/clients` publishes.
    public func uploadIntegrationClientLogo(
        authorization: String?,
        serverId: String,
        clientId: String,
        contentType: String?,
        body: Data
    ) async throws -> IntegrationSettingsClient {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            throw IntegrationsAndAppAccessError.onlyOwnersAndAdminsCanManageIntegrations
        }
        guard UUID(uuidString: clientId) != nil else { throw IntegrationRouteError.appMissing }
        // Upstream reads the multipart file before the App lookup, so an
        // unknown App with no file publishes the file refusal first.
        guard let file = FormPayload.multipartFilePart(named: "logo", contentType: contentType, body: body) else {
            throw IntegrationsAndAppAccessError.noLogoFile
        }
        guard let recordId = oauth.userManagedClientRecordId(serverId: serverId, clientKey: clientId) else {
            throw IntegrationsAndAppAccessError.oauthClientNotFound
        }
        let service = AvatarService(storage: oauth.assets, oauth: oauth)
        let stored: AvatarStoredFile
        do {
            stored = try await service.storeIntegrationLogo(clientRecordId: recordId, file: file)
        } catch let error as AvatarStoreError {
            switch error {
            case .tooLarge: throw IntegrationsAndAppAccessError.logoTooLarge
            case .badFormat: throw IntegrationsAndAppAccessError.logoBadFormat
            case .notAnImage, .storageNotConfigured, .storageFailure:
                throw IntegrationsAndAppAccessError.logoUploadFailed
            }
        }
        oauth.setClientLogo(clientRecordId: recordId, logoUrl: stored.url, logoStorageKey: stored.objectKey)
        guard let updated = oauth.integrationSettingsClient(clientRecordId: recordId) else {
            throw IntegrationsAndAppAccessError.oauthClientNotFound
        }
        return updated
    }

    /// `DELETE /api/integrations/clients/:clientId/logo`.
    public func clearIntegrationClientLogo(
        authorization: String?,
        serverId: String,
        clientId: String
    ) async throws -> IntegrationSettingsClient {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            throw IntegrationsAndAppAccessError.onlyOwnersAndAdminsCanManageIntegrations
        }
        guard UUID(uuidString: clientId) != nil else { throw IntegrationRouteError.appMissing }
        guard let recordId = oauth.userManagedClientRecordId(serverId: serverId, clientKey: clientId) else {
            throw IntegrationsAndAppAccessError.oauthClientNotFound
        }
        let previousKey = oauth.clearClientLogo(clientRecordId: recordId)
        if let previousKey {
            await AvatarService(storage: oauth.assets, oauth: oauth).deleteStoredObject(previousKey)
        }
        guard let updated = oauth.integrationSettingsClient(clientRecordId: recordId) else {
            throw IntegrationsAndAppAccessError.oauthClientNotFound
        }
        return updated
    }
}
