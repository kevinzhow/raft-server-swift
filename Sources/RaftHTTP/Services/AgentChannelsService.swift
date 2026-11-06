import Foundation

/// Domain failure for the agent channel and server management routes.
///
/// Every case is one published refusal. The capability refusals carry their own
/// ordered bodies; the credential and grant refusals shared with the rest of the
/// agent API are `FeedbackLocatorError`s thrown unchanged.
public enum AgentChannelsError: DomainError, Equatable {
    case invalidToken
    /// A write the agent's server role does not allow; the message names the
    /// missing capability.
    case capabilityDenied(String)
    /// The create route's refusal for an agent that holds no server role.
    case createChannelsRoleRequired
    case channelNotFound
    case userNotFound
    case agentNotFound
    case serverNotFound
    case invalidChannelUpdate
    case invalidChannelMember
    case invalidServerUpdate
    case invalidChannel
    case invalidChannelVisibility
    case invalidTarget
    case channelRefRequired
    case jointVisibilityImmutable
    case allChannelVisibilityManagedSeparately
    case channelMembershipRequired

    public var status: UInt {
        switch self {
        case .invalidToken:
            401
        case .capabilityDenied, .createChannelsRoleRequired, .jointVisibilityImmutable,
             .allChannelVisibilityManagedSeparately, .channelMembershipRequired:
            403
        case .channelNotFound, .userNotFound, .agentNotFound, .serverNotFound:
            404
        case .invalidChannelUpdate, .invalidChannelMember, .invalidServerUpdate, .invalidChannel,
             .invalidChannelVisibility, .invalidTarget, .channelRefRequired:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidToken:
            "Invalid or expired token"
        case .capabilityDenied(let message):
            message
        case .createChannelsRoleRequired:
            "Agent requires createChannels capability to create channels"
        case .channelNotFound:
            "Channel not found"
        case .userNotFound:
            "User not found"
        case .agentNotFound:
            "Agent not found"
        case .serverNotFound:
            "Server not found"
        case .invalidChannelUpdate:
            "Invalid channel update"
        case .invalidChannelMember:
            "Invalid channel member"
        case .invalidServerUpdate:
            "Invalid server update"
        case .invalidChannel:
            "Invalid channel"
        case .invalidChannelVisibility:
            "Invalid channel visibility"
        case .invalidTarget:
            "Invalid target"
        case .channelRefRequired:
            "channel is required"
        case .jointVisibilityImmutable:
            "Joint channel visibility cannot be changed"
        case .allChannelVisibilityManagedSeparately:
            "Only a human can do it, from channel settings or server settings"
        case .channelMembershipRequired:
            "You must be a channel member"
        }
    }

    public var errorCode: String? {
        switch self {
        case .invalidToken:
            "auth_required"
        case .capabilityDenied, .createChannelsRoleRequired:
            "server_role_required"
        case .jointVisibilityImmutable:
            "joint_visibility_immutable"
        case .allChannelVisibilityManagedSeparately:
            "all_channel_visibility_managed_separately"
        case .channelMembershipRequired:
            "channel_membership_required"
        case .channelNotFound, .userNotFound, .agentNotFound, .serverNotFound,
             .invalidChannelUpdate, .invalidChannelMember, .invalidServerUpdate, .invalidChannel,
             .invalidChannelVisibility, .invalidTarget, .channelRefRequired:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .capabilityDenied(let message):
            .object([
                OrderedJSONField("error", message),
                OrderedJSONField("code", "server_role_required"),
                OrderedJSONField("currentRole", "member"),
                OrderedJSONField(
                    "suggestedNextAction",
                    "Ask a server owner or admin to grant the capability; your role is member."
                ),
            ])
        case .createChannelsRoleRequired:
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "server_role_required"),
                OrderedJSONField(
                    "suggestedNextAction",
                    "To create channels you need the member role on this server; you are not a member of this server. Ask a server owner or admin to do it, or to change your role."
                ),
                OrderedJSONField("requiredCapabilities", .array([.string("createChannels")])),
                OrderedJSONField("requiredRole", "member"),
                OrderedJSONField("currentRole", .null),
            ])
        case .invalidToken, .channelNotFound, .userNotFound, .agentNotFound, .serverNotFound,
             .invalidChannelUpdate, .invalidChannelMember, .invalidServerUpdate, .invalidChannel,
             .invalidChannelVisibility, .invalidTarget, .channelRefRequired,
             .jointVisibilityImmutable, .allChannelVisibilityManagedSeparately,
             .channelMembershipRequired:
            nil
        }
    }
}

/// The agent-principal channel and server management surface: update a channel,
/// add or remove channel members, rename the server, read the member list and
/// the server overview, resolve a `#name` and create a channel.
///
/// The service reads the channel/agent/machine/profile stores and the OAuth
/// ledger. The serialized system-notice append belongs to the unmigrated message
/// domain and enters as one closure, so the notice and the acting agent's
/// born-read cursor stay under the lock that guards them.
public struct AgentChannelsService: Sendable {
    private let oauth: OAuthLedger
    private let channels: ServersAndChannelsStore
    private let agents: AgentsRuntimeStore
    private let machines: MachinesAndComputersStore
    private let profiles: AuthProfileStore
    private let feedbackLocators: FeedbackLocatorService
    private let appendSystemNotice: @Sendable (_ message: StoredHumanMessage, _ bornReadAgentId: String?) -> Int
    private let now: @Sendable () -> Date

    init(
        oauth: OAuthLedger,
        channels: ServersAndChannelsStore,
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore,
        profiles: AuthProfileStore,
        feedbackLocators: FeedbackLocatorService,
        appendSystemNotice: @escaping @Sendable (StoredHumanMessage, String?) -> Int,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.oauth = oauth
        self.channels = channels
        self.agents = agents
        self.machines = machines
        self.profiles = profiles
        self.feedbackLocators = feedbackLocators
        self.appendSystemNotice = appendSystemNotice
        self.now = now
    }

    // MARK: - Identity

    /// Identity for the agent channel/server management routes: an `sk_agent_*`
    /// credential must carry the scopes, a legacy machine key uses the path agent
    /// id. A revoked credential falls through to the machine paths, as before.
    func writerAndRole(
        authorization: String?,
        legacyAgentId: String?,
        scopes: [String]
    ) -> (agent: OAuthLedger.AgentRuntimeInfo, role: String?)? {
        let token = authorization?.hasPrefix("Bearer ") == true
            ? String(authorization!.dropFirst("Bearer ".count))
            : ""
        let credential = agents.agentCredential(token: token)
        let machineCredential = machines.machineCredential(apiKey: token, agentId: nil)
        if let credential, credential.revokedAt == nil {
            guard scopes.allSatisfy({ credential.scopes.contains($0) }),
                  let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
            else { return nil }
            return (agent, oauth.agentRole(serverId: agent.serverId, agentId: agent.id))
        }
        if let machine = machineCredential.machine, let legacyAgentId, !legacyAgentId.isEmpty,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return (agent, oauth.agentRole(serverId: agent.serverId, agentId: agent.id))
        }
        if let legacy = machineCredential.legacy,
           let agent = oauth.agentRuntimeInfo(id: legacy.agentId), !agent.deleted,
           legacy.serverId == agent.serverId {
            return (agent, oauth.agentRole(serverId: agent.serverId, agentId: agent.id))
        }
        return nil
    }

    private func authorizedWriter(
        authorization: String?,
        legacyAgentId: String?,
        scopes: [String]
    ) throws -> (agent: OAuthLedger.AgentRuntimeInfo, role: String?) {
        guard let writer = writerAndRole(
            authorization: authorization, legacyAgentId: legacyAgentId, scopes: scopes
        ), let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            throw AgentChannelsError.invalidToken
        }
        return (agent, writer.role)
    }

    private static func isOwnerOrAdmin(_ role: String?) -> Bool {
        role == "owner" || role == "admin"
    }

    // MARK: - PATCH /internal/agent-api/channels/:channelId

    public func updateChannel(
        authorization: String?,
        channelId: String,
        body: AgentChannelUpdateRequest?,
        legacyAgentId: String? = nil
    ) throws -> AgentChannelUpdateResponse {
        let writer = try authorizedWriter(
            authorization: authorization, legacyAgentId: legacyAgentId, scopes: ["channels"]
        )
        let agent = writer.agent
        guard Self.isOwnerOrAdmin(writer.role) else {
            throw AgentChannelsError.capabilityDenied(
                "Agent requires editChannelMetadata or changeChannelVisibility capability to update channels"
            )
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            throw AgentChannelsError.channelNotFound
        }
        guard let body else { throw AgentChannelsError.invalidChannelUpdate }
        let jointLinkIds = channels.jointLinkIds(channelId: channelId)
        if !jointLinkIds.isEmpty {
            if body.visibilityPresent { throw AgentChannelsError.jointVisibilityImmutable }
            if let archived = body.archived {
                for linkId in jointLinkIds {
                    oauth.setChannelArchived(id: linkId, archivedAt: archived ? now() : nil)
                    channels.setArchivedFlag(channelId: linkId, archived: archived)
                }
                return .jointArchived(id: channelId, archived: archived)
            }
            if let raw = body.name {
                let newName = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                for linkId in jointLinkIds {
                    _ = oauth.renameChannel(id: linkId, name: newName)
                    channels.setPostableName(channelId: linkId, name: newName)
                }
                return .jointRenamed(id: channelId, name: newName)
            }
        }
        if body.visibilityPresent, oauth.allChannelId(serverId: agent.serverId) == channelId {
            throw AgentChannelsError.allChannelVisibilityManagedSeparately
        }
        if body.visibilityPresent {
            let isMember = channels.postableChannel(id: channelId)?.memberIds.contains(agent.id) == true
                || agents.isChannelAgentMember(channelId: channelId, agentId: agent.id)
                || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
            guard isMember || oauth.isChannelParticipant(channelId: channelId, userId: agent.id) else {
                throw AgentChannelsError.channelMembershipRequired
            }
        }
        var name = channel.name
        if let raw = body.name {
            name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        }
        var description = channel.description
        if let raw = body.description {
            description = raw
        }
        var type = oauth.channelType(id: channelId) ?? "channel"
        if let visibility = body.visibility {
            guard ["public", "private"].contains(visibility) else {
                throw AgentChannelsError.invalidChannelVisibility
            }
            type = visibility == "private" ? "private" : "channel"
        }
        _ = oauth.renameChannel(id: channelId, name: name)
        var updatedType = type
        if let current = oauth.channelInfo(id: channelId),
           current.description != description || type != (oauth.channelType(id: channelId) ?? "channel") {
            _ = oauth.updateChannel(id: channelId, name: nil, description: description, systemMessage: nil)
            if oauth.setChannelType(id: channelId, type: type) { updatedType = type }
        }
        channels.updatePostable(channelId: channelId, name: name, kind: updatedType)
        return .updated(id: channelId, name: name, description: description, type: updatedType)
    }

    // MARK: - POST|DELETE …/channels/:channelId/members

    public func writeChannelMember(
        authorization: String?,
        channelId: String,
        body: AgentChannelMemberRequest?,
        remove: Bool,
        legacyAgentId: String? = nil
    ) throws -> AgentChannelMemberWriteResponse {
        let writer = try authorizedWriter(
            authorization: authorization, legacyAgentId: legacyAgentId, scopes: ["channels"]
        )
        let agent = writer.agent
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            throw AgentChannelsError.channelNotFound
        }
        if remove && !Self.isOwnerOrAdmin(writer.role) {
            throw AgentChannelsError.capabilityDenied(
                "Agent requires removeChannelMembers capability to remove channel members"
            )
        }
        guard let body else { throw AgentChannelsError.invalidChannelMember }
        if let rawUser = body.user {
            return try writeHumanMember(
                rawUser: rawUser, agent: agent, channelId: channelId, remove: remove
            )
        }
        if let agentName = body.agent {
            let target = oauth.activeAgentIds(serverId: agent.serverId).first {
                oauth.agentRuntimeInfo(id: $0)?.name == agentName || $0 == agentName
            }
            guard let target else { throw AgentChannelsError.agentNotFound }
            if remove {
                let wasMember = oauth.channelAgentIds(channelId: channelId).contains(target)
                oauth.removeChannelAgent(channelId: channelId, agentId: target)
                return AgentChannelMemberWriteResponse(
                    change: .removed(wasMember: wasMember), memberType: "agent", memberName: agentName
                )
            }
            let already = oauth.channelAgentIds(channelId: channelId).contains(target)
            if !already {
                oauth.addChannelAgent(channelId: channelId, agentId: target)
            }
            return AgentChannelMemberWriteResponse(
                change: .added(alreadyMember: already), memberType: "agent", memberName: agentName
            )
        }
        throw AgentChannelsError.invalidChannelMember
    }

    private func writeHumanMember(
        rawUser: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        channelId: String,
        remove: Bool
    ) throws -> AgentChannelMemberWriteResponse {
        let userName = rawUser.hasPrefix("@") ? String(rawUser.dropFirst()) : rawUser
        let target = profiles.accounts.values.first { $0.name == userName || $0.id == userName }?.id
        guard let target, oauth.memberRole(serverId: agent.serverId, userId: target) != nil else {
            throw AgentChannelsError.userNotFound
        }
        if remove {
            let wasMember = oauth.channelHumanIds(channelId: channelId).contains(target)
            channels.removeMember(channelId: channelId, memberId: target)
            _ = oauth.removeChannelHuman(channelId: channelId, userId: target)
            return AgentChannelMemberWriteResponse(
                change: .removed(wasMember: wasMember), memberType: "human", memberName: userName
            )
        }
        let already = oauth.channelHumanIds(channelId: channelId).contains(target)
        if !already {
            channels.insertMember(channelId: channelId, serverId: agent.serverId, userId: target)
            oauth.addChannelHuman(channelId: channelId, userId: target)
            // The acting agent made this notice: it is born-read for the actor
            // while the added human keeps it unread.
            _ = appendSystemNotice(
                StoredHumanMessage(
                    id: UUID().uuidString.lowercased(),
                    channelId: channelId,
                    senderId: "system",
                    content: "@\(userName) was added to this channel.",
                    randomId: nil,
                    messageType: "system",
                    senderType: "system"
                ),
                agent.id
            )
        }
        return AgentChannelMemberWriteResponse(
            change: .added(alreadyMember: already), memberType: "human", memberName: userName
        )
    }

    // MARK: - PATCH /internal/agent-api/server

    public func updateServer(
        authorization: String?,
        body: AgentServerUpdateRequest?,
        legacyAgentId: String? = nil
    ) throws -> AgentServerUpdateResponse {
        let writer = try authorizedWriter(
            authorization: authorization, legacyAgentId: legacyAgentId, scopes: ["server"]
        )
        guard Self.isOwnerOrAdmin(writer.role) else {
            throw AgentChannelsError.capabilityDenied(
                "Agent requires editServerSettings capability to edit the server profile"
            )
        }
        guard let name = body?.name else { throw AgentChannelsError.invalidServerUpdate }
        oauth.updateServerName(id: writer.agent.serverId, name: name)
        return AgentServerUpdateResponse(id: writer.agent.serverId, name: name)
    }

    // MARK: - GET …/channel-members

    public func channelMembers(
        authorization: String?,
        agentId: String?,
        channelRef: String?,
        legacyAgentId: String? = nil
    ) throws -> AgentChannelMembersResponse {
        let writer = try authorizedWriter(
            authorization: authorization, legacyAgentId: legacyAgentId ?? agentId, scopes: []
        )
        let agent = writer.agent
        let reference = (channelRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.hasPrefix("#") else { throw AgentChannelsError.channelRefRequired }
        let raw = String(reference.dropFirst())
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? raw
        let shortId = parts.count > 1 ? parts[1] : nil
        let snapshot = channels.state
        let postable = snapshot.postableChannels
        let parent = postable.first { _, channel in
            channel.serverId == agent.serverId && channel.name == name
                && (channel.kind == "channel" || channel.kind == "joint") && channel.deletedAt == nil
        }?.key
        var targetId = parent
        var type = "channel"
        if let shortId, let parent {
            targetId = postable.first { _, channel in
                channel.serverId == agent.serverId && channel.kind == "thread"
                    && channel.parentChannelId == parent
                    && (channel.parentMessageId?.hasPrefix(shortId) ?? false)
            }?.key
            type = targetId == nil ? "channel" : "thread"
        }
        guard let targetId, let parentId = type == "thread" ? postable[targetId]?.parentChannelId : targetId else {
            throw AgentChannelsError.channelNotFound
        }
        let links = snapshot.jointProjections
        let jointCanonical = links.first { $0.localChannelId == parentId }?.canonicalChannelId
        let jointLinks = jointCanonical.map { canonical in
            links.filter { $0.canonicalChannelId == canonical }
        } ?? []
        var humanIds = oauth.channelHumanIds(channelId: parentId)
        var agentIds = oauth.channelAgentIds(channelId: parentId)
        for link in jointLinks {
            humanIds = Array(Set(humanIds).union(oauth.channelHumanIds(channelId: link.localChannelId)))
            agentIds = Array(Set(agentIds).union(oauth.channelAgentIds(channelId: link.localChannelId)))
        }
        let accounts = profiles.accounts.values
        func badges(for userId: String) -> [AgentChannelMembersResponse.ServerBadge]? {
            guard !jointLinks.isEmpty else { return nil }
            var rows: [AgentChannelMembersResponse.ServerBadge] = []
            for link in jointLinks {
                guard oauth.channelHumanIds(channelId: link.localChannelId).contains(userId),
                      let details = oauth.serverDetailsValue(id: link.serverId)
                else { continue }
                rows.append(.init(name: details.name, slug: details.slug, yours: link.serverId == agent.serverId))
            }
            rows.sort { $0.yours && !$1.yours }
            guard !rows.isEmpty, rows.contains(where: { !$0.yours }) else { return nil }
            return rows
        }
        let humans = humanIds.map { id in
            AgentChannelMembersResponse.Human(
                id: id,
                name: accounts.first { $0.id == id }?.name ?? id,
                role: oauth.memberRole(serverId: agent.serverId, userId: id) ?? "member",
                servers: badges(for: id)
            )
        }
        let agentRows = agentIds.map { id in
            AgentChannelMembersResponse.Agent(id: id, name: oauth.agentRuntimeInfo(id: id)?.name ?? "")
        }
        return AgentChannelMembersResponse(ref: reference, type: type, humans: humans, agents: agentRows)
    }

    // MARK: - GET …/server

    public func serverInfo(
        authorization: String?,
        legacyAgentId: String? = nil
    ) throws -> AgentServerInfoResponse {
        let writer = try authorizedWriter(
            authorization: authorization, legacyAgentId: legacyAgentId, scopes: []
        )
        let agent = writer.agent
        guard let profile = oauth.serverProfile(id: agent.serverId) else {
            throw AgentChannelsError.serverNotFound
        }
        let role = oauth.agentRole(serverId: agent.serverId, agentId: agent.id)
        let facts = agents.runtimeFacts(agentId: agent.id)
        let machine = facts.machineId.flatMap { machines.machine(id: $0) }
        let channelRows = channels.state.postableChannels
            .filter {
                $0.value.serverId == agent.serverId
                    && $0.value.deletedAt == nil
                    && !$0.value.archived
                    && oauth.channelArchivedAt(id: $0.key) == nil
                    && $0.value.kind != "dm"
                    && $0.value.kind != "thread"
            }
            .compactMap { id, channel -> AgentServerInfoResponse.Channel? in
                let joined = channel.memberIds.contains(agent.id)
                    || oauth.channelAgentIds(channelId: id).contains(agent.id)
                // Private and joint surfaces stay invisible without membership;
                // public channels are listed too, with their join state.
                if !joined && (channel.kind == "private" || channel.kind == "joint") { return nil }
                let type = channel.kind == "private" || channel.kind == "joint" ? channel.kind : "channel"
                let mute = oauth.notificationPrefs(channelId: id, userId: agent.id)
                return AgentServerInfoResponse.Channel(
                    id: id, name: channel.name, type: type, joined: joined,
                    muteFromSeq: mute.activityMuted ? mute.muteFromSeq : nil
                )
            }
            .sorted { $0.id < $1.id }
        let agentRows = oauth.activeAgentIds(serverId: agent.serverId).map { otherId in
            let otherFacts = agents.runtimeFacts(agentId: otherId)
            return AgentServerInfoResponse.Agent(
                id: otherId,
                name: oauth.agentRuntimeInfo(id: otherId)?.name ?? "",
                role: oauth.agentRole(serverId: agent.serverId, agentId: otherId),
                activity: otherFacts.activity,
                activityDetail: otherFacts.detail
            )
        }
        return AgentServerInfoResponse(
            id: profile.id,
            name: profile.name,
            slug: profile.slug,
            runtimeContext: .init(
                agentId: agent.id,
                runtime: agent.runtime,
                serverId: agent.serverId,
                machineId: machine?.id,
                machineName: machine?.name,
                machineDescription: machine?.description
            ),
            serverRole: role,
            channels: channelRows,
            agents: agentRows
        )
    }

    // MARK: - POST /internal/agent-api/resolve-channel

    public func resolveChannel(
        authorization: String?,
        body: AgentResolveChannelRequest?
    ) throws -> AgentResolveChannelResponse {
        switch feedbackLocators.capabilityDecision(authorization: authorization, capability: "send") {
        case .allowed: break
        case .denied(let capability):
            throw FeedbackLocatorError.capabilityNotAuthorized(capability: capability)
        }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AgentChannelsError.invalidToken
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.useAgentCredential(token: token, now: now()),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AgentChannelsError.invalidToken
        }
        guard let target = body?.target, target.hasPrefix("#") else {
            throw AgentChannelsError.invalidTarget
        }
        let name = String(target.dropFirst())
        guard let resolved = channels.postableChannel(serverId: agent.serverId, name: name),
              oauth.channelInfo(id: resolved.id) != nil
        else {
            throw AgentChannelsError.channelNotFound
        }
        let type = oauth.channelType(id: resolved.id) ?? "channel"
        let joined = resolved.channel.memberIds.contains(agent.id)
            || oauth.channelAgentIds(channelId: resolved.id).contains(agent.id)
        guard type == "channel" || joined else { throw AgentChannelsError.channelNotFound }
        return AgentResolveChannelResponse(channelId: resolved.id, type: type)
    }

    // MARK: - POST /internal/agent-api/channels

    public func createChannel(
        authorization: String?,
        body: AgentCreateChannelRequest?,
        legacyAgentId: String? = nil
    ) throws -> AgentCreateChannelResponse {
        let writer = try authorizedWriter(
            authorization: authorization, legacyAgentId: legacyAgentId, scopes: ["channels"]
        )
        let agent = writer.agent
        guard let rawName = body?.name else { throw AgentChannelsError.invalidChannel }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil else {
            throw AgentChannelsError.invalidChannel
        }
        let visibility = body?.visibility ?? "public"
        guard ["public", "private"].contains(visibility) else {
            throw AgentChannelsError.invalidChannelVisibility
        }
        guard writer.role != nil else { throw AgentChannelsError.createChannelsRoleRequired }
        let description = body?.description
        let type = visibility == "private" ? "private" : "channel"
        let channelId = oauth.createChannel(
            serverId: agent.serverId, name: name, creatorUserId: agent.id, type: type, description: description
        )
        oauth.removeChannelHuman(channelId: channelId, userId: agent.id)
        oauth.addChannelAgent(channelId: channelId, agentId: agent.id)
        channels.insertCreatedChannel(channelId: channelId, serverId: agent.serverId, kind: type, name: name)
        return AgentCreateChannelResponse(
            id: channelId, name: name, type: type, description: description, createdByAgentId: agent.id
        )
    }
}
