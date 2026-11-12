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
    private let flags: AgentsRuntimeStore

    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        channelActorCanSee: @escaping @Sendable (String, String) -> Bool,
        oauth: OAuthLedger,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        profiles: AuthProfileStore,
        flags: AgentsRuntimeStore
    ) {
        self.sessionUserId = sessionUserId
        self.channelActorCanSee = channelActorCanSee
        self.oauth = oauth
        self.channels = channels
        self.messages = messages
        self.profiles = profiles
        self.flags = flags
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
        if let visibility = object.visibility, !["public", "private", "joint"].contains(visibility) {
            throw ChannelCreationError.invalidVisibility
        }
        let selectedAgents = Set(object.agentIds)
        let selectedUsers = Set(object.userIds)
        for id in selectedAgents {
            guard let agent = oauth.agentRuntimeInfo(id: id), agent.serverId == serverId, !agent.deleted else {
                throw ChannelCreationError.agentOutsideServer
            }
        }
        for id in selectedUsers where oauth.memberRole(serverId: serverId, userId: id) == nil {
            throw ChannelCreationError.userOutsideServer
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
        let kind = object.visibility == "private" ? "private" : "channel"
        let channelId = oauth.createChannel(
            serverId: serverId, name: name, creatorUserId: userId, type: kind, description: object.description
        )
        for id in selectedUsers.union([userId]) { oauth.addChannelHuman(channelId: channelId, userId: id) }
        for id in selectedAgents { oauth.addChannelAgent(channelId: channelId, agentId: id) }
        channels.insertOwnedChannel(channelId: channelId, serverId: serverId, userId: userId,
            name: name, kind: kind, userIds: selectedUsers, agentIds: selectedAgents)
        let receiptsEnabled = flags.evaluateFeatureFlag(
            key: "read_receipts_v0", userId: "", serverId: serverId, platform: nil,
            client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        ).enabled
        return .created(try ChannelRowFacts(oauth: oauth, messages: messages).createdRegularChannel(
            channelId: channelId, userId: userId, serverRole: role,
            snapshot: channels.state, readReceiptsEnabled: receiptsEnabled
        ))
    }

    // MARK: - POST /api/channels/:id/joint-invites

    /// Invites one target server's admins to an existing joint channel. The
    /// route-level checks (slug/people, channel, joint type, visibility, admin)
    /// run in upstream order; validation refusals keep their extra keys.
    ///
    /// Deviation: the pinned implementation also emails each invitee, supports
    /// the multi-target `jointInvites` body, per-target entitlement/limit
    /// admission and the `sameAdmin` auto-accept. This port records the pending
    /// rows only; the target server projection is created here (the accept
    /// route admits the target admin into it).
    public func inviteServerToJointChannel(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: JointChannelInviteRequest?
    ) throws -> JointChannelInviteResponse {
        guard let userId = sessionUserId(authorization) else { throw ManagedMCPOAuthError.unauthorized }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ManagedMCPOAuthError.notAMember
        }
        let slug = (body?.targetServerSlug ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { throw JointChannelRouteError.slugRequired }

        var people: [String] = []
        var seenPeople = Set<String>()
        for raw in body?.invitedPeople ?? [] {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key: String
            if value.hasPrefix("@"), !value.dropFirst().contains("@") {
                key = String(value.dropFirst()).lowercased()
            } else {
                key = value.lowercased()
            }
            if seenPeople.insert(key).inserted { people.append(value) }
        }
        guard people.count <= 20 else { throw JointChannelRouteError.invitedPeopleLimit(20) }
        guard !people.isEmpty else { throw JointChannelRouteError.invitedPeopleRequired }

        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw JointChannelRouteError.channelNotFound
        }
        guard oauth.channelType(id: channelId) == "joint" else {
            throw JointChannelRouteError.onlyJointInvite
        }
        guard channelActorCanSee(channelId, userId) else {
            throw JointChannelRouteError.channelNotFound
        }
        guard role == "owner" || role == "admin" else {
            throw JointChannelRouteError.adminInvite
        }

        guard let targetServerId = oauth.serverIdForSlug(slug),
              let targetServer = oauth.serverDetailsValue(id: targetServerId)
        else {
            throw JointChannelRouteError.targetServerInvalid(message: "Target server not found", slug: slug)
        }
        guard targetServerId != serverId else {
            throw JointChannelRouteError.targetServerInvalid(message: "Cannot invite the current server", slug: slug)
        }

        var invitees: [String] = []
        var seenInvitees = Set<String>()
        for (index, person) in people.enumerated() {
            let account: Account?
            if person.contains("@"), !person.hasPrefix("@") {
                account = profiles.accounts.values.first {
                    $0.email.caseInsensitiveCompare(person) == .orderedSame
                }
            } else {
                let lookup = person.hasPrefix("@") ? String(person.dropFirst()) : person
                account = profiles.firstAccount(caseInsensitiveName: lookup)
            }
            guard let account else {
                throw JointChannelRouteError.inviteeNotFound(person, slug, index)
            }
            guard let targetRole = oauth.memberRole(serverId: targetServerId, userId: account.id),
                  targetRole == "owner" || targetRole == "admin"
            else {
                throw JointChannelRouteError.inviteeNotAdmin(person, slug, index)
            }
            if seenInvitees.insert(account.id).inserted {
                invitees.append(account.id)
            }
        }
        guard !invitees.isEmpty else { throw JointChannelRouteError.invitedPeopleRequired }

        let now = Date()
        let ttl: TimeInterval = 14 * 24 * 60 * 60
        let invites = invitees.map { (inviteId: UUID().uuidString.lowercased(), userId: $0) }
        if let targetChannelId = channels.jointLocalChannel(channelId: channelId, serverId: targetServerId) {
            channels.addJointInvites(
                hostChannelId: channelId,
                hostServerId: serverId,
                targetServerId: targetServerId,
                targetChannelId: targetChannelId,
                invitedByUserId: userId,
                invites: invites,
                now: now,
                ttl: ttl
            )
        } else {
            let targetChannelId = oauth.createChannel(
                serverId: targetServerId,
                name: channel.name,
                creatorUserId: invitees[0],
                description: channel.description
            )
            _ = oauth.setChannelType(id: targetChannelId, type: "joint")
            channels.addJointServerProjection(
                hostChannelId: channelId,
                hostServerId: serverId,
                targetServerId: targetServerId,
                targetChannelId: targetChannelId,
                invitedByUserId: userId,
                name: channel.name,
                invites: invites,
                now: now,
                ttl: ttl
            )
        }

        let origin = oauth.serverDetailsValue(id: serverId)
        let canonical = channels.jointCanonicalChannelId(channelId: channelId) ?? channelId
        let rows = invites.map { invite in
            JointInviteRow(
                id: invite.inviteId,
                jointChannelId: canonical,
                fromServerId: serverId,
                fromServerName: origin?.name ?? "",
                fromServerSlug: origin?.slug ?? "",
                channelName: channel.name,
                channelDescription: channel.description,
                invitedByUserId: userId,
                invitedUserId: invite.userId,
                expiresAt: now.addingTimeInterval(ttl),
                createdAt: now
            )
        }
        return JointChannelInviteResponse(
            id: channelId,
            serverId: serverId,
            name: channel.name,
            description: channel.description,
            type: "joint",
            createdAt: oauth.channelCreatedAt(id: channelId),
            joined: true,
            invites: rows
        )
    }
}
