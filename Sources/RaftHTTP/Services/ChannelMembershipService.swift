import Foundation

/// Domain failure for channel archive, self-service join and agent leave.
///
/// Every case is one published refusal; `Respond.swift` renders the body from
/// `errorMessage` and `errorCode`.
public enum ChannelMembershipError: DomainError, Equatable {
    /// The human routes' `PublicVisits.authRequired` refusal (`no-store`).
    case authRequired(bearerPresent: Bool)
    case agentAuthorizationMissing
    case agentTokenInvalid
    case notAMember
    case channelNotFound
    case channelArchived
    case forbidden
    case jointArchiveAdminLimited
    case privateChannelInviteOnly
    case privateChannelNeedsInvitation
    case jointChannelNeedsInvitation
    case serverRoleCannotJoin
    case guestJoinNotAllowed
    case cannotLeaveAllChannel
    case threadMembersManagedByFollow

    public var status: UInt {
        switch self {
        case .authRequired, .agentAuthorizationMissing, .agentTokenInvalid:
            401
        case .notAMember, .forbidden, .jointArchiveAdminLimited, .privateChannelInviteOnly,
             .privateChannelNeedsInvitation, .jointChannelNeedsInvitation, .serverRoleCannotJoin,
             .guestJoinNotAllowed, .cannotLeaveAllChannel:
            403
        case .channelNotFound:
            404
        case .channelArchived:
            409
        case .threadMembersManagedByFollow:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .authRequired(let bearerPresent):
            bearerPresent ? "Invalid or expired token" : "Missing or invalid Authorization header"
        case .agentAuthorizationMissing:
            "Missing or invalid Authorization header"
        case .agentTokenInvalid:
            "Invalid or expired token"
        case .notAMember:
            "Not a member of this server"
        case .channelNotFound:
            "Channel not found"
        case .channelArchived:
            "This channel is archived"
        case .forbidden:
            "Forbidden"
        case .jointArchiveAdminLimited:
            "Only a server admin can archive a joint channel"
        case .privateChannelInviteOnly:
            "Private channels are invite-only"
        case .privateChannelNeedsInvitation:
            "Private channels require an invitation"
        case .jointChannelNeedsInvitation:
            "Joint channels require an invitation"
        case .serverRoleCannotJoin:
            "Server role cannot join public channels"
        case .guestJoinNotAllowed:
            "This channel does not allow guest joins"
        case .cannotLeaveAllChannel:
            "Cannot leave the #all channel"
        case .threadMembersManagedByFollow:
            "Thread members are managed with follow/unfollow"
        }
    }

    public var errorCode: String? {
        switch self {
        case .authRequired, .agentAuthorizationMissing, .agentTokenInvalid:
            "auth_required"
        case .channelArchived:
            "channel_archived"
        case .jointArchiveAdminLimited:
            "joint_channel_admin_limited"
        case .notAMember, .channelNotFound, .forbidden, .privateChannelInviteOnly,
             .privateChannelNeedsInvitation, .jointChannelNeedsInvitation, .serverRoleCannotJoin,
             .guestJoinNotAllowed, .cannotLeaveAllChannel, .threadMembersManagedByFollow:
            nil
        }
    }

    /// Only the human auth refusal kept `Cache-Control: no-store`.
    public var responseHeaders: [String: String] {
        switch self {
        case .authRequired:
            ["Cache-Control": "no-store"]
        default:
            [:]
        }
    }
}

/// Channel archive/unarchive, human self-service join and the agent join/leave
/// of a plain channel.
///
/// The channel posting rows live in `ServersAndChannelsStore`; the session
/// lookup, the channel-visibility policy and the serialized system-notice
/// append belong to domains that have not migrated and enter as closures. The
/// join notice and the actor's born-read cursor are written by one
/// `appendSystemNotice` call, which keeps them under the same lock as before.
public struct ChannelMembershipService: Sendable {
    private let sessionUserId: @Sendable (String?) -> String?
    private let oauth: OAuthLedger
    private let channels: ServersAndChannelsStore
    private let agents: AgentsRuntimeStore
    private let feedbackLocators: FeedbackLocatorService
    private let channelActorCanSee: @Sendable (_ channelId: String, _ userId: String) -> Bool
    private let appendSystemNotice: @Sendable (_ message: StoredHumanMessage, _ bornReadAgentId: String?) -> Int
    private let now: @Sendable () -> Date

    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        oauth: OAuthLedger,
        channels: ServersAndChannelsStore,
        agents: AgentsRuntimeStore,
        feedbackLocators: FeedbackLocatorService,
        channelActorCanSee: @escaping @Sendable (String, String) -> Bool,
        appendSystemNotice: @escaping @Sendable (StoredHumanMessage, String?) -> Int,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionUserId = sessionUserId
        self.oauth = oauth
        self.channels = channels
        self.agents = agents
        self.feedbackLocators = feedbackLocators
        self.channelActorCanSee = channelActorCanSee
        self.appendSystemNotice = appendSystemNotice
        self.now = now
    }

    // MARK: - Shared checks

    /// An archived channel refuses writes.
    func requireNotArchived(_ channelId: String) throws {
        guard oauth.channelArchivedAt(id: channelId) == nil else {
            throw ChannelMembershipError.channelArchived
        }
    }

    /// A thread's members are managed with follow/unfollow, never directly.
    private func requireNotThread(_ channelId: String) throws {
        let kind = channels.postableChannel(id: channelId)?.kind ?? oauth.channelType(id: channelId)
        guard kind != "thread" else { throw ChannelMembershipError.threadMembersManagedByFollow }
    }

    private func authRequired(_ authorization: String?) -> ChannelMembershipError {
        .authRequired(bearerPresent: authorization?.hasPrefix("Bearer ") == true)
    }

    // MARK: - POST /api/channels/:channelId/(un)archive

    public func setChannelArchived(
        authorization: String?,
        serverId: String,
        channelId: String,
        archived: Bool
    ) throws -> ChannelArchivedResponse {
        guard let userId = sessionUserId(authorization) else { throw authRequired(authorization) }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.notAMember
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        guard channelActorCanSee(channelId, userId) else { throw ChannelMembershipError.channelNotFound }
        let policy = channels.archivePolicy(channelId: channelId, userId: userId)
        guard role == "owner" || role == "admin" || policy.channelAdmin else {
            throw ChannelMembershipError.forbidden
        }
        if policy.jointArchive, role != "owner", role != "admin" {
            throw ChannelMembershipError.jointArchiveAdminLimited
        }
        if archived {
            if oauth.channelArchivedAt(id: channelId) == nil {
                oauth.setChannelArchived(id: channelId, archivedAt: now())
            }
        } else {
            oauth.setChannelArchived(id: channelId, archivedAt: nil)
        }
        channels.setArchived(channelId: channelId, archived: archived)
        guard let date = oauth.channelArchivedAt(id: channelId) else {
            return ChannelArchivedResponse(archivedAt: nil)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ChannelArchivedResponse(archivedAt: formatter.string(from: date))
    }

    // MARK: - POST /api/channels/:channelId/join

    public func joinChannel(
        authorization: String?,
        serverId: String,
        channelId: String
    ) throws -> OkResponse {
        guard let userId = sessionUserId(authorization) else { throw authRequired(authorization) }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        try requireNotArchived(channelId)
        try requireNotThread(channelId)
        if oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return OkResponse()
        }
        guard oauth.channelType(id: channelId) == "channel" else {
            throw ChannelMembershipError.privateChannelInviteOnly
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.serverRoleCannotJoin
        }
        if role == "guest", !channels.isGuestJoinable(channelId: channelId) {
            throw ChannelMembershipError.guestJoinNotAllowed
        }
        oauth.addChannelHuman(channelId: channelId, userId: userId)
        return OkResponse()
    }

    // MARK: - POST /internal/agent-api/channels/:channelId/join

    public func agentJoinChannel(authorization: String?, channelId: String) throws -> OkResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ChannelMembershipError.agentAuthorizationMissing
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredential(token: token),
              credential.scopes.contains("channels"),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw ChannelMembershipError.agentTokenInvalid
        }
        return try joinPublicChannel(agentId: agent.id, serverId: agent.serverId, channelId: channelId)
    }

    /// Self-service join of a visible plain channel. Private and joint channels
    /// are invitation-only, archived channels refuse writes, and the join posts
    /// a system notice that is born-read for the joining agent.
    func joinPublicChannel(agentId: String, serverId: String, channelId: String) throws -> OkResponse {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        try requireNotArchived(channelId)
        if oauth.channelAgentIds(channelId: channelId).contains(agentId) {
            return OkResponse()
        }
        switch oauth.channelType(id: channelId) ?? "channel" {
        case "private":
            throw ChannelMembershipError.privateChannelNeedsInvitation
        case "joint":
            throw ChannelMembershipError.jointChannelNeedsInvitation
        default:
            break
        }
        switch feedbackLocators.grantDecision(agentId: agentId, scope: "channel:join") {
        case .allowed: break
        case .missingScope(let scope): throw FeedbackLocatorError.missingScope(scope: scope)
        }
        guard oauth.agentRole(serverId: serverId, agentId: agentId) != nil else {
            throw ChannelMembershipError.serverRoleCannotJoin
        }
        oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        let name = oauth.agentRuntimeInfo(id: agentId)?.name ?? agentId
        _ = appendSystemNotice(
            StoredHumanMessage(
                id: UUID().uuidString.lowercased(),
                channelId: channelId,
                senderId: "system",
                content: "@\(name) joined this channel.",
                randomId: nil,
                messageType: "system",
                senderType: "system"
            ),
            agentId
        )
        return OkResponse()
    }

    // MARK: - Agent leave

    /// Self-service leave. The virtual #all audience cannot be left; a private
    /// or joint channel with no humans and no agents left is soft-deleted.
    func leaveChannel(agentId: String, serverId: String, channelId: String) throws -> OkResponse {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        if oauth.allChannelId(serverId: serverId) == channelId {
            throw ChannelMembershipError.cannotLeaveAllChannel
        }
        try requireNotArchived(channelId)
        oauth.removeChannelAgent(channelId: channelId, agentId: agentId)
        let kind = channels.removeAgentMember(channelId: channelId, agentId: agentId)
        if kind == "private" || kind == "joint" {
            let humans = oauth.channelHumanIds(channelId: channelId)
            let agents = oauth.channelAgentIds(channelId: channelId)
            if humans.isEmpty && agents.isEmpty {
                channels.markChannelDeleted(channelId: channelId, now: now())
            }
        }
        return OkResponse()
    }
}
