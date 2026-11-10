import Foundation

/// The two not-yet-migrated domains the join-link surface still needs: the
/// human session lookup in `AuthCoreService` and the realtime room emitter.
///
/// Everything else this service reads lives in a store or the OAuth ledger, so
/// the service owns the orchestration and the stores own their state.
public struct JoinLinksAndInvitesDependencies: Sendable {
    public var sessionUserId: @Sendable (String?) -> String?
    public var emitRealtime: @Sendable (String, String, String?) -> Void
    /// Account-global survey/onboarding facts, read and written through the Auth
    /// account owner. The production assembly supplies
    /// `AuthProfileSetupAccountFacts`; tests supply fixed answers.
    public var setupAccountFacts: any SetupAccountFacts
    /// Best-effort Cindy briefing after the "Let's Go" acknowledgment is retained.
    /// The upstream onboarding-briefing service is not part of this port, so the
    /// default hook is a no-op. The receipt is stored before this runs and is
    /// never derived from delivery: a briefing that fails here does not reopen
    /// the handoff.
    public var triggerOnboardingBriefing: @Sendable (String, String) -> Void

    public init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        emitRealtime: @escaping @Sendable (String, String, String?) -> Void,
        setupAccountFacts: any SetupAccountFacts,
        triggerOnboardingBriefing: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) {
        self.sessionUserId = sessionUserId
        self.emitRealtime = emitRealtime
        self.setupAccountFacts = setupAccountFacts
        self.triggerOnboardingBriefing = triggerOnboardingBriefing
    }
}

/// Domain failure for the join-link, invite, server-setup and agent-profile
/// operations.
///
/// Every case publishes the bytes the retired handler built: the canonical
/// `{"error": …}` body, the same object plus `code` when the domain has one, or
/// an explicit `errorBody` where the upstream object carries more keys or a
/// different member order. The feature layer only copies `status`, the body and
/// `errorHeaders`.
public enum JoinLinksAndInvitesError: DomainError, Equatable {
    case authRequired(bearerPresent: Bool)
    case unauthorized
    case forbiddenCreateJoinLinks
    case forbiddenViewJoinLinks
    case forbiddenRevokeJoinLinks
    case forbiddenRevokeInvites
    case notAMember
    case forbidden
    case inviteNotFound
    case invalidInvite
    case invalidExpiresAt
    case invalidMaxUses
    case seatLimit(String)
    case invalidEmail
    case invalidInviteRole
    case guestAccessDisabled
    case ownerCannotLeave
    case insufficientPermission
    case serverNotFound
    case serverIdRequired
    case missingHeaderServerId
    case mismatchedHeaderServerId
    case guestsCannotAccessServerManagementData
    case invalidSetupAction
    case officialOnboardingAgentNotUsable
    case serverAlreadySetUp
    case invalidProfileUpdate
    case profileNotFound
    case agentAuthRequired
    case missingAuthorizationHeader
    case capabilityNotAuthorized(String?)
    case hostedAgentDescriptionHumanOnly
    case agreementRequired(ServerAgreementDTO)
    case agreementChanged(ServerAgreementDTO)

    public var status: UInt {
        switch self {
        case .authRequired, .unauthorized, .agentAuthRequired, .missingAuthorizationHeader:
            401
        case .forbiddenCreateJoinLinks, .forbiddenViewJoinLinks, .forbiddenRevokeJoinLinks,
             .forbiddenRevokeInvites, .notAMember, .forbidden, .insufficientPermission,
             .capabilityNotAuthorized, .hostedAgentDescriptionHumanOnly,
             .guestsCannotAccessServerManagementData:
            403
        case .inviteNotFound, .serverNotFound, .profileNotFound:
            404
        case .invalidInvite, .invalidExpiresAt, .invalidMaxUses, .seatLimit, .invalidEmail,
             .invalidInviteRole, .guestAccessDisabled, .ownerCannotLeave, .invalidSetupAction,
             .invalidProfileUpdate, .serverIdRequired, .missingHeaderServerId,
             .mismatchedHeaderServerId:
            400
        case .serverAlreadySetUp, .agreementRequired, .agreementChanged, .officialOnboardingAgentNotUsable:
            409
        }
    }

    public var responseHeaders: [String: String] {
        switch self {
        case .authRequired:
            ["Cache-Control": "no-store"]
        default:
            [:]
        }
    }

    public var errorMessage: String {
        switch self {
        case .authRequired(let bearerPresent):
            bearerPresent
                ? "Invalid or expired token"
                : "Missing or invalid Authorization header"
        case .unauthorized:
            "Unauthorized"
        case .forbiddenCreateJoinLinks:
            "Only server owners and admins can create join links"
        case .forbiddenViewJoinLinks:
            "Only server owners and admins can view join links"
        case .forbiddenRevokeJoinLinks:
            "Only server owners and admins can revoke join links"
        case .forbiddenRevokeInvites:
            "Only server owners and admins can revoke invites"
        case .notAMember:
            "Not a member of this server"
        case .forbidden:
            "Forbidden"
        case .inviteNotFound:
            "Invite not found"
        case .invalidInvite:
            "Invalid invite"
        case .invalidExpiresAt:
            "expiresAt must be a valid date"
        case .invalidMaxUses:
            "maxUses must be a positive integer"
        case .seatLimit(let message):
            message
        case .invalidEmail:
            "Enter a valid email address"
        case .invalidInviteRole:
            "role must be one of: member, guest"
        case .guestAccessDisabled:
            "Guest access is not enabled for this server"
        case .ownerCannotLeave:
            "The owner cannot leave the server"
        case .insufficientPermission:
            "INSUFFICIENT_PERMISSION"
        case .serverNotFound:
            "Server not found"
        case .serverIdRequired:
            "Server id is required"
        case .missingHeaderServerId:
            "Missing X-Server-Id header"
        case .mismatchedHeaderServerId:
            "X-Server-Id must match server id in URL"
        case .guestsCannotAccessServerManagementData:
            "Guests cannot access server management data"
        case .invalidSetupAction:
            "INVALID_SETUP_ACTION"
        case .officialOnboardingAgentNotUsable:
            "OFFICIAL_ONBOARDING_AGENT_NOT_USABLE"
        case .serverAlreadySetUp:
            "SERVER_ALREADY_SET_UP"
        case .invalidProfileUpdate:
            "Invalid profile update"
        case .profileNotFound:
            "Profile not found"
        case .agentAuthRequired:
            "Invalid or expired token"
        case .missingAuthorizationHeader:
            "Missing or invalid Authorization header"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .hostedAgentDescriptionHumanOnly:
            "Hosted agents cannot change their own description"
        case .agreementRequired:
            "agreement_required"
        case .agreementChanged:
            "agreement_changed"
        }
    }

    /// The machine-readable `code` the published object appends after `error`.
    /// A case published through `errorBody` contributes its `code` there.
    public var errorCode: String? {
        switch self {
        case .authRequired, .agentAuthRequired, .missingAuthorizationHeader:
            "auth_required"
        case .capabilityNotAuthorized:
            "capability_not_authorized"
        case .hostedAgentDescriptionHumanOnly:
            "hosted_agent_description_human_only"
        default:
            nil
        }
    }

    /// Published bodies the canonical `error`/`code` pair cannot express: the
    /// capability scope, the hosted-agent hint and the two agreement objects.
    public var errorBody: OrderedJSON? {
        switch self {
        case .capabilityNotAuthorized(let required):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "capability_not_authorized")
            body.append("requiredCapability", ifPresent: required)
            return body.json
        case .hostedAgentDescriptionHumanOnly:
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "hosted_agent_description_human_only")
            body.append(
                "suggestedNextAction",
                "Ask a human owner or admin to edit it in your Profile tab in Raft. Nothing was changed."
            )
            return body.json
        case .agreementRequired(let agreement):
            return Self.agreementBody(error: "agreement_required", agreement: agreement)
        case .agreementChanged(let agreement):
            return Self.agreementBody(error: "agreement_changed", agreement: agreement)
        default:
            return nil
        }
    }

    private static func agreementBody(error: String, agreement: ServerAgreementDTO) -> OrderedJSON {
        .object([
            OrderedJSONField("error", error),
            OrderedJSONField("agreement", agreement),
        ])
    }
}

/// Join links, server invites, membership acceptance, the server setup
/// projection and the agent-profile routes.
///
/// The row state lives in `ServersAndChannelsStore`, `AgentsRuntimeStore`,
/// `MachinesAndComputersStore` and `AuthProfileStore`; every read-modify-write
/// that used to run under the directory lock is one store critical section.
/// This type returns `Codable` DTOs whose `jsonBody: OrderedJSON` keeps the
/// upstream member order, and throws `JoinLinksAndInvitesError` instead of
/// building a reply.
public struct JoinLinksAndInvitesService: Sendable {
    private let store: ServersAndChannelsStore
    private let accounts: AuthProfileStore
    private let agents: AgentsRuntimeStore
    private let computers: MachinesAndComputersStore
    private let oauth: OAuthLedger
    private let dependencies: JoinLinksAndInvitesDependencies
    private let now: @Sendable () -> Date

    init(
        store: ServersAndChannelsStore,
        accounts: AuthProfileStore,
        agents: AgentsRuntimeStore,
        computers: MachinesAndComputersStore,
        oauth: OAuthLedger,
        dependencies: JoinLinksAndInvitesDependencies,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.accounts = accounts
        self.agents = agents
        self.computers = computers
        self.oauth = oauth
        self.dependencies = dependencies
        self.now = now
    }

    // MARK: - POST /api/servers/:id/join-links

    /// Creates one member join link. The upstream order is authorization
    /// (401), owner/admin (403, one message for a non-member too), then the
    /// `expiresAt` and `maxUses` shape checks.
    public func createJoinLink(
        authorization: String?,
        serverId: String,
        body: CreateJoinLinkRequest
    ) throws -> JoinLinkCreateResponseDTO {
        let userId = try authenticatedUserId(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role == "owner" || role == "admin"
        else {
            throw JoinLinksAndInvitesError.forbiddenCreateJoinLinks
        }
        var expiresAt: Date?
        if let raw = body.expiresAt, !raw.isEmpty {
            guard let parsed = DateText.isoDate(raw) else {
                throw JoinLinksAndInvitesError.invalidExpiresAt
            }
            expiresAt = parsed
        }
        let maxUses: Int?
        switch body.maxUses {
        case .unspecified, .unlimited:
            maxUses = nil
        case .limited(let value):
            maxUses = value
        case .invalid:
            throw JoinLinksAndInvitesError.invalidMaxUses
        }
        let timestamp = now()
        let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let link = JoinLinkRecord(
            id: UUID().uuidString.lowercased(),
            token: token,
            serverId: serverId,
            role: "member",
            createdAt: timestamp,
            expiresAt: expiresAt,
            maxUses: maxUses,
            useCount: 0,
            revokedAt: nil
        )
        store.insertJoinLink(link)
        return JoinLinkCreateResponseDTO(
            token: token,
            link: JoinLinkPayloadDTO(link),
            maxUses: maxUses,
            expiresAt: expiresAt.map(DateText.isoString)
        )
    }

    // MARK: - GET /api/servers/:id/join-links

    public func listJoinLinks(authorization: String?, serverId: String) throws -> JoinLinkListResponseDTO {
        let userId = try authenticatedUserId(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role == "owner" || role == "admin"
        else {
            throw JoinLinksAndInvitesError.forbiddenViewJoinLinks
        }
        return JoinLinkListResponseDTO(
            links: store.activeJoinLinks(serverId: serverId, now: now()).map(JoinLinkPayloadDTO.init)
        )
    }

    // MARK: - DELETE /api/servers/:id/join-links/:linkId

    public func revokeJoinLink(
        authorization: String?,
        serverId: String,
        linkId: String
    ) throws -> JoinLinksOkResponseDTO {
        let userId = try authenticatedUserId(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role == "owner" || role == "admin"
        else {
            throw JoinLinksAndInvitesError.forbiddenRevokeJoinLinks
        }
        store.revokeJoinLink(id: linkId, serverId: serverId, now: now())
        return JoinLinksOkResponseDTO()
    }

    // MARK: - GET /api/auth/invite-info

    /// The public invite preview. A missing, unknown, revoked, expired or
    /// exhausted token all publish the same 404.
    public func inviteInfo(token: String?) throws -> InviteInfoResponseDTO {
        guard let token, !token.isEmpty else {
            throw JoinLinksAndInvitesError.inviteNotFound
        }
        if let link = store.joinLink(token: token.lowercased()) {
            guard link.revokedAt == nil,
                  !Self.joinLinkExpired(link, now: now()),
                  !Self.joinLinkExhausted(link),
                  let profile = oauth.serverProfile(id: link.serverId)
            else {
                throw JoinLinksAndInvitesError.inviteNotFound
            }
            return try inviteInfoResponse(profile: profile, message: seatLimitMessage(serverId: link.serverId))
        }
        let hash = AuthTokenCodec.sha256(token)
        guard let invite = store.inviteRecord(tokenHash: hash),
              let profile = oauth.serverProfile(id: invite.serverId)
        else {
            throw JoinLinksAndInvitesError.inviteNotFound
        }
        return try inviteInfoResponse(profile: profile, message: seatLimitMessage(serverId: invite.serverId))
    }

    // MARK: - POST /api/auth/accept-invite

    /// Accepts a join link or an email invite.
    ///
    /// The link path spends the use count in a store critical section before
    /// the membership write; the email path removes the invite in the same
    /// section as the seat and agreement decision. Both then add the member and
    /// queue `server.member_added`.
    public func acceptInvite(
        authorization: String?,
        body: JoinLinkAcceptRequest?
    ) throws -> JoinLinkAcceptResponseDTO {
        let userId = try authenticatedUserId(authorization)
        guard let body, let rawToken = body.token else {
            throw JoinLinksAndInvitesError.invalidInvite
        }
        if store.joinLink(token: rawToken.lowercased()) != nil {
            switch store.acceptJoinLink(
                token: rawToken,
                userId: userId,
                requestedAgreementId: body.agreementId,
                now: now(),
                admission: admission
            ) {
            case .invalid:
                throw JoinLinksAndInvitesError.invalidInvite
            case .seatLimit(let message):
                throw JoinLinksAndInvitesError.seatLimit(message)
            case .agreementRequired(let agreement):
                throw JoinLinksAndInvitesError.agreementRequired(agreement)
            case .agreementChanged(let agreement):
                throw JoinLinksAndInvitesError.agreementChanged(agreement)
            case .accepted(let serverId, let role):
                oauth.addMember(serverId: serverId, userId: userId, role: role)
                store.appendServerMemberEvent(
                    serverId: serverId,
                    eventType: "server.member_added",
                    subjectType: "member",
                    subjectId: userId,
                    provenanceJSON: Self.joinedProvenance(role: role)
                )
                return JoinLinkAcceptResponseDTO(serverId: serverId)
            }
        }
        guard let email = accounts.accountEmail(id: userId)?.lowercased() else {
            throw JoinLinksAndInvitesError.invalidInvite
        }
        switch store.acceptServerInvite(
            tokenHash: AuthTokenCodec.sha256(rawToken),
            userEmail: email,
            userId: userId,
            requestedAgreementId: body.agreementId,
            admission: admission
        ) {
        case .invalid:
            throw JoinLinksAndInvitesError.invalidInvite
        case .seatLimit(let message):
            throw JoinLinksAndInvitesError.seatLimit(message)
        case .agreementRequired(let agreement):
            throw JoinLinksAndInvitesError.agreementRequired(agreement)
        case .agreementChanged(let agreement):
            throw JoinLinksAndInvitesError.agreementChanged(agreement)
        case .accepted(let serverId, let role):
            oauth.addMember(serverId: serverId, userId: userId, role: role)
            store.appendServerMemberEvent(
                serverId: serverId,
                eventType: "server.member_added",
                subjectType: "member",
                subjectId: userId,
                provenanceJSON: Self.joinedProvenance(role: role)
            )
            return JoinLinkAcceptResponseDTO(serverId: serverId)
        }
    }

    // MARK: - Email invites

    public func listServerInvites(
        authorization: String?,
        serverId: String
    ) throws -> ServerInviteListResponseDTO {
        let userId = try authenticatedUserId(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw JoinLinksAndInvitesError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw JoinLinksAndInvitesError.forbidden
        }
        return ServerInviteListResponseDTO(
            invites: store.serverInviteRows(serverId: serverId).map {
                ServerInviteRowDTO(id: $0.id, invitedEmail: $0.email, email: $0.email, role: $0.role)
            }
        )
    }

    public func createServerInvite(
        authorization: String?,
        serverId: String,
        body: CreateServerInviteRequest?
    ) throws -> ServerInviteCreateResponseDTO {
        let userId = try authenticatedUserId(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw JoinLinksAndInvitesError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw JoinLinksAndInvitesError.forbidden
        }
        guard let body, let rawEmail = body.email else {
            throw JoinLinksAndInvitesError.invalidEmail
        }
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.wholeMatch(of: /^[^\s@]+@[^\s@]+\.[^\s@]+$/) != nil else {
            throw JoinLinksAndInvitesError.invalidEmail
        }
        let inviteRole = body.role ?? "member"
        guard ["member", "guest"].contains(inviteRole) else {
            throw JoinLinksAndInvitesError.invalidInviteRole
        }
        if inviteRole == "guest" {
            guard store.isGuestRoleEnabled(serverId: serverId) else {
                throw JoinLinksAndInvitesError.guestAccessDisabled
            }
        }
        if inviteRole == "member", let message = seatLimitMessage(serverId: serverId) {
            throw JoinLinksAndInvitesError.seatLimit(message)
        }
        let id = UUID().uuidString.lowercased()
        store.insertServerInvite(id: id, serverId: serverId, email: email, role: inviteRole)
        return ServerInviteCreateResponseDTO(id: id, invitedEmail: email, email: email, role: inviteRole)
    }

    public func revokeServerInvite(
        authorization: String?,
        serverId: String,
        inviteId: String
    ) throws -> JoinLinksOkResponseDTO {
        let userId = try authenticatedUserId(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role == "owner" || role == "admin"
        else {
            throw JoinLinksAndInvitesError.forbiddenRevokeInvites
        }
        store.removeServerInvite(id: inviteId, serverId: serverId)
        return JoinLinksOkResponseDTO()
    }

    // MARK: - POST /api/servers/:id/leave

    public func leaveServer(authorization: String?, serverId: String) throws -> JoinLinksOkResponseDTO {
        let userId = try authenticatedUserId(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw JoinLinksAndInvitesError.notAMember
        }
        if role == "owner", oauth.ownerCount(serverId: serverId) <= 1 {
            throw JoinLinksAndInvitesError.ownerCannotLeave
        }
        oauth.removeMember(serverId: serverId, userId: userId)
        store.markMemberLeft(
            serverId: serverId,
            userId: userId,
            provenanceJSON: Self.leftProvenance(role: role)
        )
        return JoinLinksOkResponseDTO()
    }

    // MARK: - Server setup scope

    /// The pre-handler `requireServerMatchesParam` funnel plus the guest-hidden
    /// surface rule shared by the three setup routes.
    ///
    /// `app.ts:483` mounts `/api/servers` behind `requireAuth` + `requireVerified`,
    /// so authentication precedes the `routes/servers.ts:1005` UUID/header
    /// checks. The membership read joins the live server row, so an unknown or
    /// soft-deleted server refuses exactly like a non-member. A guest reaches
    /// the handler (which answers its owner-only refusal) unless the route is in
    /// the guest-hidden surface list.
    private func setupScope(
        authorization: String?,
        serverId: String,
        headerServerId: String?,
        hidesGuests: Bool
    ) throws -> (userId: String, role: String) {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw JoinLinksAndInvitesError.unauthorized
        }
        switch ServerScope.validate(serverId: serverId, headerServerId: headerServerId) {
        case nil:
            break
        case .serverIdRequired:
            throw JoinLinksAndInvitesError.serverIdRequired
        case .serverNotFound:
            throw JoinLinksAndInvitesError.serverNotFound
        case .missingHeader:
            throw JoinLinksAndInvitesError.missingHeaderServerId
        case .headerMismatch:
            throw JoinLinksAndInvitesError.mismatchedHeaderServerId
        }
        guard oauth.serverProfile(id: serverId) != nil,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            throw JoinLinksAndInvitesError.notAMember
        }
        if hidesGuests, role == "guest" {
            throw JoinLinksAndInvitesError.guestsCannotAccessServerManagementData
        }
        return (userId, role)
    }

    // MARK: - Server setup projection

    public func serverSetupProjection(
        authorization: String?,
        serverId: String,
        headerServerId: String?
    ) throws -> SetupProjectionResponseDTO {
        let actor = try setupScope(
            authorization: authorization,
            serverId: serverId,
            headerServerId: headerServerId,
            hidesGuests: true
        )
        return setupProjectionService()
            .project(serverId: serverId, userId: actor.userId, role: actor.role)
    }

    public func serverSetupTransition(
        authorization: String?,
        serverId: String,
        headerServerId: String?,
        body: ServerSetupTransitionRequest?
    ) throws -> SetupProjectionResponseDTO {
        let actor = try setupScope(
            authorization: authorization,
            serverId: serverId,
            headerServerId: headerServerId,
            hidesGuests: false
        )
        guard let body, let action = body.action, action == "start" || action == "complete" else {
            throw JoinLinksAndInvitesError.invalidSetupAction
        }
        guard actor.role == "owner" else { throw JoinLinksAndInvitesError.insufficientPermission }
        let projection = setupProjectionService()
        // A completion by any owner is terminal for the whole server. Neither a
        // late start nor a repeated complete may rewind it or recheck liveness.
        let current = projection.project(serverId: serverId, userId: actor.userId, role: actor.role)
        if current.phase == "complete" { return current }
        if action == "complete" {
            guard projection.canComplete(serverId: serverId) else {
                throw JoinLinksAndInvitesError.officialOnboardingAgentNotUsable
            }
            // The phase and its `normal` provenance are one Store mutation
            // (services/serverSetupStateService.ts:555-571). A terminal retry
            // reaches the early return above and writes nothing.
            store.completeSetup(serverId: serverId, userId: actor.userId)
        } else {
            store.startSetup(serverId: serverId, userId: actor.userId)
        }
        return projection.project(serverId: serverId, userId: actor.userId, role: actor.role)
    }

    /// `POST /api/servers/:id/setup-reset`. The router-wide lockdown runs
    /// first; the handler then owns reset authority. `setup-reset` is not in
    /// the guest-hidden surface list, so a live Guest reaches this owner-only
    /// refusal instead of the management-data 403.
    public func serverSetupReset(
        authorization: String?,
        serverId: String,
        headerServerId: String?
    ) throws -> SetupProjectionResponseDTO {
        let actor = try setupScope(
            authorization: authorization,
            serverId: serverId,
            headerServerId: headerServerId,
            hidesGuests: false
        )
        guard actor.role == "owner" else {
            throw JoinLinksAndInvitesError.insufficientPermission
        }
        guard !agents.hasServerAgent(serverId: serverId) else {
            throw JoinLinksAndInvitesError.serverAlreadySetUp
        }
        let revokedComputers = computers.revokeComputers(serverId: serverId, now: now())
        store.clearSetupState(serverId: serverId)
        return setupProjectionService()
            .project(serverId: serverId, userId: actor.userId, role: actor.role, revokedComputers: revokedComputers)
    }

    /// "Let's Go": the PRIMARY owner accepts the handoff.
    ///
    /// Upstream `routes/servers.ts:1407-1446` and `serverService.ts:1530-1571`:
    /// a missing server is 404, a caller who is not `server.ownerId` — including
    /// a co-owner whose member role is `owner` — is 403 `INSUFFICIENT_PERMISSION`
    /// before any write, the first acknowledgment is stamped and retained, and the
    /// best-effort briefing runs only after that stamp. Acknowledgment is not
    /// delivery: a briefing that never reaches Cindy does not reopen the handoff.
    public func serverSetupHandoff(
        authorization: String?,
        serverId: String,
        headerServerId: String?
    ) throws -> SetupProjectionResponseDTO {
        let actor = try setupScope(
            authorization: authorization,
            serverId: serverId,
            headerServerId: headerServerId,
            hidesGuests: false
        )
        guard let server = oauth.serverProfile(id: serverId) else {
            throw JoinLinksAndInvitesError.serverNotFound
        }
        // Binding the command to `server.ownerId` is the whole authorization:
        // role `owner` is not enough (co-owners cannot accept the owner's handoff).
        guard server.ownerId == actor.userId else {
            throw JoinLinksAndInvitesError.insufficientPermission
        }
        let acknowledgedAt = now()
        let receipt = store.acknowledgeSetupHandoff(
            serverId: serverId,
            originalOwnerId: server.ownerId,
            at: acknowledgedAt
        )
        // Account-global, first-time-only facts are retained by the Auth
        // account owner after the member receipt and before any briefing.
        dependencies.setupAccountFacts.recordFirstOnboarding(
            userId: server.ownerId,
            at: acknowledgedAt,
            sessionFamilyId: liveSessionFamilyId(authorization)
        )
        // Best-effort, deliberately after the retained receipt: delivery never
        // speaks for the user. The upstream Cindy briefing service is not part
        // of this port, so the default hook is a no-op; the retained receipt,
        // not the briefing, is what the projection reads.
        dependencies.triggerOnboardingBriefing(serverId, receipt.originalOwnerId)
        return setupProjectionService()
            .project(serverId: serverId, userId: actor.userId, role: actor.role)
    }

    private func setupProjectionService() -> ServerSetupProjectionService {
        ServerSetupProjectionService(
            store: store,
            agents: agents,
            computers: computers,
            oauth: oauth,
            accountFacts: dependencies.setupAccountFacts
        )
    }

    /// The live session family of the caller's bearer, or nil for a legacy
    /// familyless token. This is the family the account-global first-onboarding
    /// record retains, not a value derived from the request body.
    private func liveSessionFamilyId(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return accounts.activeSessionPrincipal(accessToken: token)?.familyId
    }

    // MARK: - Agent profile

    /// `GET /internal/agent-api/profile`.
    ///
    /// Without a target the reply is the calling agent; with one it resolves an
    /// agent or a human by handle. A hidden human directory only exposes people
    /// who share a channel with the agent.
    public func agentProfileShow(
        authorization: String?,
        target: String?
    ) throws -> AgentProfileShowResponse {
        let userIdToken = try bearerToken(authorization)
        guard let credential = agents.useAgentCredential(token: userIdToken, now: now()),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId),
              !agent.deleted
        else {
            throw JoinLinksAndInvitesError.agentAuthRequired
        }
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .agent(AgentProfileResponseDTO(agent))
        }
        guard credential.scopes.contains("read") else {
            throw JoinLinksAndInvitesError.capabilityNotAuthorized(nil)
        }
        let handle = target.hasPrefix("@") ? String(target.dropFirst()) : target
        let lowered = handle.lowercased()
        let agentMatch = oauth.serverAgents(serverId: agent.serverId).first {
            !$0.deleted && ($0.name.lowercased() == lowered || $0.displayName.lowercased() == lowered)
        }
        let accountMatch = accounts.accountsMatching(name: lowered).first {
            oauth.memberRole(serverId: agent.serverId, userId: $0.id) != nil
        }
        let hiddenDirectory = store.hideHumans(serverId: agent.serverId)
        if let agentMatch {
            return .agent(AgentProfileResponseDTO(agentMatch))
        }
        guard let accountMatch else {
            throw JoinLinksAndInvitesError.profileNotFound
        }
        if hiddenDirectory {
            let shared = oauth.channelsForServer(serverId: agent.serverId, userId: accountMatch.id).contains { channel in
                oauth.channelAgentIds(channelId: channel.id).contains(agent.id)
            }
            guard shared else {
                throw JoinLinksAndInvitesError.profileNotFound
            }
        }
        return .human(AgentHumanProfileResponseDTO(accountMatch))
    }

    /// `POST /internal/agent-api/profile`.
    public func updateAgentProfile(
        authorization: String?,
        body: AgentProfileUpdateRequest?
    ) throws -> AgentProfileUpdateResponseDTO {
        let token = try bearerToken(authorization, missingHeader: true)
        if agents.agentCredentialLacksScope(token: token, required: "send") {
            throw JoinLinksAndInvitesError.capabilityNotAuthorized("send")
        }
        guard let agentId = agents.agentId(forCredentialToken: token),
              let agent = oauth.agentRuntimeInfo(id: agentId),
              !agent.deleted
        else {
            throw JoinLinksAndInvitesError.agentAuthRequired
        }
        guard let body else {
            throw JoinLinksAndInvitesError.invalidProfileUpdate
        }
        if agents.isHostedAgent(agent.id), body.description != nil {
            throw JoinLinksAndInvitesError.hostedAgentDescriptionHumanOnly
        }
        if let description = body.description {
            oauth.updateAgentDescription(id: agent.id, description: description)
        }
        if let displayName = body.displayName,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            oauth.updateAgentDisplayName(
                id: agent.id,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let latest = oauth.agentRuntimeInfo(id: agent.id)
        let displayJSON = latest.map { jsonString($0.displayName) } ?? "null"
        dependencies.emitRealtime(
            "server:\(agent.serverId)",
            "agent:updated",
            "{\"agentId\":\(jsonString(agent.id)),\"displayName\":\(displayJSON)}"
        )
        return AgentProfileUpdateResponseDTO(
            agentId: agent.id,
            displayName: latest?.displayName,
            description: latest?.description
        )
    }

    // MARK: - Slack bridge

    /// The Slack bridge is not available in this build; all four routes answer
    /// the published 503 body.
    public func slackBridgeUnavailable() -> SlackBridgeUnavailableResponseDTO {
        SlackBridgeUnavailableResponseDTO()
    }

    // MARK: - Helpers

    /// The human session behind a normal access token. The published 401 keeps
    /// its two messages and the `Cache-Control: no-store` header.
    private func authenticatedUserId(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw JoinLinksAndInvitesError.authRequired(
                bearerPresent: authorization?.hasPrefix("Bearer ") == true
            )
        }
        return userId
    }

    /// Bearer token of an agent credential. `missingHeader` selects the
    /// published 401 body for the profile update, whose first check is the
    /// scope gate rather than the header shape.
    private func bearerToken(_ authorization: String?, missingHeader: Bool = false) throws -> String {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw missingHeader
                ? JoinLinksAndInvitesError.missingAuthorizationHeader
                : JoinLinksAndInvitesError.agentAuthRequired
        }
        return String(authorization.dropFirst("Bearer ".count))
    }

    private func inviteInfoResponse(
        profile: OAuthLedger.ServerProfile,
        message: String?
    ) throws -> InviteInfoResponseDTO {
        let hidden = store.hideHumans(serverId: profile.id)
        return InviteInfoResponseDTO(
            serverId: profile.id,
            serverName: profile.name,
            serverSlug: profile.slug,
            humanSeatLimitReached: message != nil,
            humanSeatLimitMessage: message,
            memberCount: hidden ? 0 : oauth.memberRoles(serverId: profile.id).count,
            agentCount: hidden ? 0 : oauth.serverAgents(serverId: profile.id).count,
            insideCountsHidden: hidden,
            agreement: oauth.activeServerAgreement(serverId: profile.id).map(ServerAgreementDTO.init)
        )
    }

    private var admission: ServerAdmissionQuery {
        ServerAdmissionQuery(oauth: oauth)
    }

    private func seatLimitMessage(serverId: String) -> String? {
        store.seatLimitMessage(serverId: serverId, admission: admission)
    }

    private static func joinedProvenance(role: String) -> String {
        "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"joined\",\"role\":\(jsonString(role)),\"source\":\"server_service\"}"
    }

    private static func leftProvenance(role: String) -> String {
        "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"left\",\"role\":\(jsonString(role)),\"source\":\"server_service\"}"
    }

    private static func joinLinkExpired(_ link: JoinLinkRecord, now: Date) -> Bool {
        if let expiresAt = link.expiresAt, expiresAt <= now { return true }
        return false
    }

    private static func joinLinkExhausted(_ link: JoinLinkRecord) -> Bool {
        if let maxUses = link.maxUses, link.useCount >= maxUses { return true }
        return false
    }
}

// MARK: - Directory entry point

extension EmailLoginDirectory {
    /// Join links, email invites, the server setup projection and the agent
    /// profile surface. The service is stateless; the directory supplies its
    /// stores and the two not-yet-migrated bridges (session lookup and the
    /// realtime room emitter).
    public var joinLinksAndInvites: JoinLinksAndInvitesService {
        JoinLinksAndInvitesService(
            store: serversAndChannelsStore,
            accounts: authProfileStore,
            agents: agentsRuntimeStore,
            computers: machinesAndComputersStore,
            oauth: oauth,
            dependencies: JoinLinksAndInvitesDependencies(
                sessionUserId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                emitRealtime: { [self] room, event, payload in
                    realtimeRelay.emit(room, event, payload)
                },
                // The survey answer and the account-global first-onboarding
                // pair live on the Auth account row; this seam reads and writes
                // them through the profile store instead of copying state.
                setupAccountFacts: AuthProfileSetupAccountFacts(accounts: authProfileStore)
            )
        )
    }
}
