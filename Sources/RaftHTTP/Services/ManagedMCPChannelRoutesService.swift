import Foundation

/// `PATCH /api/channels/:id` and `POST /api/channels`.
///
/// The service owns the orchestration and returns the published
/// `ManagedMCPChannelRouteResponse`; every refusal is a `ManagedMCPOAuthError`.
/// The guest-flag write, the visibility write and the joint-channel pair are one
/// `ServersAndChannelsStore` critical section each; the follow cleanup a private
/// switch needs is one `MessagesAndThreadsStore` section.
///
/// The session lookup and the channel-visibility predicate belong to other
/// domains and enter as closures.
public struct ManagedMCPChannelRoutesService: Sendable {
    private let sessionUserId: @Sendable (String?) -> String?
    private let channelActorCanSee: @Sendable (_ channelId: String, _ userId: String) -> Bool
    private let oauth: OAuthLedger
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let profiles: AuthProfileStore

    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        channelActorCanSee: @escaping @Sendable (String, String) -> Bool,
        oauth: OAuthLedger,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        profiles: AuthProfileStore
    ) {
        self.sessionUserId = sessionUserId
        self.channelActorCanSee = channelActorCanSee
        self.oauth = oauth
        self.channels = channels
        self.messages = messages
        self.profiles = profiles
    }

    private func validChannelName(_ name: String) -> Bool {
        name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil
    }

    // MARK: - PATCH /api/channels/:id

    public func patchChannel(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: LenientJSONObjectRequest?
    ) throws -> ManagedMCPChannelRouteResponse {
        guard let userId = sessionUserId(authorization) else { throw ManagedMCPOAuthError.unauthorized }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil,
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else { throw ManagedMCPOAuthError.channelNotFound }
        guard oauth.channelArchivedAt(id: channelId) == nil else { throw ManagedMCPOAuthError.channelArchived }
        guard channelActorCanSee(channelId, userId) else { throw ManagedMCPOAuthError.channelNotFound }
        guard let object = body else { throw ManagedMCPOAuthError.invalidChannelUpdate }
        if object["guestVisible"] != nil || object["guestJoinable"] != nil {
            guard let role = oauth.memberRole(serverId: serverId, userId: userId),
                  role == "owner" || role == "admin"
            else { throw ManagedMCPOAuthError.forbidden }
            let flags = channels.applyGuestFlags(
                channelId: channelId,
                visible: object["guestVisible"]?.legacyBool,
                joinable: object["guestJoinable"]?.legacyBool
            )
            return .guestFlags(id: channelId, guestVisible: flags.visible, guestJoinable: flags.joinable)
        }
        if let rawVisibility = object["visibility"] {
            guard let visibility = rawVisibility.legacyString, ["private", "public"].contains(visibility) else {
                throw ManagedMCPOAuthError.invalidChannelVisibility
            }
            if oauth.allChannelId(serverId: serverId) == channelId {
                throw ManagedMCPOAuthError.allChannelVisibilityManaged
            }
            guard let role = oauth.memberRole(serverId: serverId, userId: userId),
                  role == "owner" || role == "admin"
            else { throw ManagedMCPOAuthError.forbidden }
            guard channels.isPostableMember(channelId: channelId, userId: userId)
                || oauth.isChannelParticipant(channelId: channelId, userId: userId)
            else { throw ManagedMCPOAuthError.channelMembershipRequired }
            let kind = visibility == "private" ? "private" : "channel"
            _ = oauth.setChannelType(id: channelId, type: kind)
            let change = channels.applyChannelVisibility(channelId: channelId, kind: kind)
            if visibility == "private" {
                messages.removeThreadFollows(inThreads: change.threadChannelIds, exceptUsers: change.memberIds)
            }
            return .visibility(id: channelId, visibility: visibility)
        }
        let serverRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        let actorChannelRole = channels.channelHumanRole(channelId: channelId, userId: userId)
        let jointLinks = channels.jointLinkIds(channelId: channelId)
        let actorName = profiles.account(userId: userId)?.name ?? "Someone"
        guard actorChannelRole == "admin" || serverRole == "owner" || serverRole == "admin" else {
            throw ManagedMCPOAuthError.forbidden
        }
        if !jointLinks.isEmpty {
            if object["archived"] != nil { throw ManagedMCPOAuthError.jointChannelAdminLimited }
            let jointName = object["name"]?.legacyString
            let jointDescription = object["description"]?.legacyString
            if let jointName, !validChannelName(jointName) { throw ManagedMCPOAuthError.invalidChannelName }
            var systemSeq: Int?
            for linkId in jointLinks {
                let seq = oauth.updateChannel(id: linkId, name: jointName, description: jointDescription, systemMessage: nil)
                systemSeq = seq ?? systemSeq
                if let jointName { channels.setPostableName(channelId: linkId, name: jointName) }
            }
            let latest = oauth.channelInfo(id: channelId)
            return .updated(
                id: channelId,
                name: latest?.name ?? channel.name,
                description: latest?.description,
                systemMessageSeq: systemSeq
            )
        }
        var newName: String?
        if let name = object["name"]?.legacyString, name != channel.name {
            guard validChannelName(name) else { throw ManagedMCPOAuthError.invalidChannelName }
            newName = name
        }
        let newDescription = object["description"]?.legacyString
        let systemMessage = newName.map { "@\(actorName) renamed this channel from #\(channel.name) to #\($0)." }
        let seq = oauth.updateChannel(
            id: channelId, name: newName, description: newDescription, systemMessage: systemMessage
        )
        let latest = oauth.channelInfo(id: channelId)
        return .updated(
            id: channelId,
            name: latest?.name ?? channel.name,
            description: latest?.description,
            systemMessageSeq: seq
        )
    }

    // MARK: - POST /api/channels

    public func createChannel(
        authorization: String?,
        serverId: String,
        body: ManagedMCPChannelCreateRequest?
    ) throws -> ManagedMCPChannelRouteResponse {
        guard let userId = sessionUserId(authorization) else { throw ManagedMCPOAuthError.unauthorized }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ManagedMCPOAuthError.notAMember
        }
        guard role != "guest" else { throw ManagedMCPOAuthError.forbidden }
        guard let object = body, let name = object.name, validChannelName(name), name != "all" else {
            throw ManagedMCPOAuthError.invalidChannel
        }
        if object.visibility == "joint" {
            guard let targetSlug = object.targetServerSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let targetServerId = oauth.serverIdForSlug(targetSlug),
                  targetServerId != serverId,
                  let targetServer = oauth.serverDetailsValue(id: targetServerId)
            else { throw ManagedMCPOAuthError.targetServerSlugRequired }
            let invited = object.invitedPeople ?? []
            let inviteHandle = invited.first.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 } ?? ""
            let targetOwnerId = profiles.firstAccount(caseInsensitiveName: inviteHandle)?.id
            guard let targetOwnerId, oauth.memberRole(serverId: targetServerId, userId: targetOwnerId) != nil else {
                throw ManagedMCPOAuthError.invitedPersonMustBelong
            }
            let hostChannelId = oauth.createChannel(serverId: serverId, name: name, creatorUserId: userId)
            _ = oauth.setChannelType(id: hostChannelId, type: "joint")
            let targetChannelId = oauth.createChannel(serverId: targetServerId, name: name, creatorUserId: targetOwnerId)
            _ = oauth.setChannelType(id: targetChannelId, type: "joint")
            let inviteId = UUID().uuidString.lowercased()
            channels.createJointChannelPair(
                hostServerId: serverId,
                hostChannelId: hostChannelId,
                hostUserId: userId,
                targetServerId: targetServerId,
                targetChannelId: targetChannelId,
                targetOwnerId: targetOwnerId,
                name: name,
                inviteId: inviteId
            )
            return .jointCreated(id: hostChannelId, name: name, targetServerSlug: targetServer.slug, inviteId: inviteId)
        }
        if let canUnarchive = channels.channelNameCollision(serverId: serverId, name: name, userId: userId) {
            throw ManagedMCPOAuthError.channelNameExists(name: name, canUnarchive: canUnarchive)
        }
        let channelId = oauth.createChannel(
            serverId: serverId, name: name, creatorUserId: userId, description: object.description
        )
        channels.insertOwnedChannel(channelId: channelId, serverId: serverId, userId: userId, name: name)
        return .created(id: channelId, name: name)
    }
}
