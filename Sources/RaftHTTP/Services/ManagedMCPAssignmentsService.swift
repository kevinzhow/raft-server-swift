import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Service

/// Channel membership, thread creation and the human task routes.
///
/// The service owns the orchestration and returns the published `Codable` /
/// `JSONBodyConvertible` DTOs; every refusal is a `ChannelMembershipError` (the
/// shared channel refusals) or a `ManagedMCPAssignmentsError`. It builds no
/// HTTP reply. Each state change that used to run under the directory lock is
/// one store critical section: the member-set writes and the role/authority
/// bump (`ServersAndChannelsStore`), the find-or-create of a thread, the task
/// claim/unclaim/status writes and the converted-task append
/// (`TasksAndRemindersStore`), and the follow rows of a created thread
/// (`MessagesAndThreadsStore`).
public struct ManagedMCPAssignmentsService: Sendable {
    private let channels: ServersAndChannelsStore
    private let messages: MessagesAndThreadsStore
    private let tasks: TasksAndRemindersStore
    private let agents: AgentsRuntimeStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let auth: AuthCoreService
    private let ownership: AssistantOwnershipQuery
    private let probe: ChannelProbeAccessQuery
    private let notices: SystemNoticeAppender
    private let membership: ChannelMembershipService
    private let catalog: TaskCatalogService
    /// The canonical human-send pipeline for a thread's first reply. Upstream's
    /// thread route posts it through `broadcastAndDeliver`, so the commit,
    /// mention rows, agent delivery and realtime frames are the ordinary
    /// message path rather than a private append.
    private let createThreadFirstReply: @Sendable (_ serverId: String, _ channelId: String,
        _ userId: String, _ content: String) throws -> Void
    private let now: @Sendable () -> Date
    private let publishTaskUpdated: @Sendable (String) -> Void

    /// Explicit production owners and domain capabilities. The outbound task
    /// frame remains a sink that receives the claimed task's published JSON.
    init(
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        tasks: TasksAndRemindersStore,
        agents: AgentsRuntimeStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        auth: AuthCoreService,
        ownership: AssistantOwnershipQuery,
        probe: ChannelProbeAccessQuery,
        notices: SystemNoticeAppender,
        membership: ChannelMembershipService,
        catalog: TaskCatalogService,
        createThreadFirstReply: @escaping @Sendable (_ serverId: String, _ channelId: String,
            _ userId: String, _ content: String) throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        publishTaskUpdated: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.channels = channels
        self.messages = messages
        self.tasks = tasks
        self.agents = agents
        self.profiles = profiles
        self.oauth = oauth
        self.auth = auth
        self.ownership = ownership
        self.probe = probe
        self.notices = notices
        self.membership = membership
        self.catalog = catalog
        self.createThreadFirstReply = createThreadFirstReply
        self.now = now
        self.publishTaskUpdated = publishTaskUpdated
    }

    public func bindingTaskPublication(
        publishTaskUpdated: @escaping @Sendable (String) -> Void
    ) -> Self {
        Self(
            channels: channels, messages: messages, tasks: tasks, agents: agents,
            profiles: profiles, oauth: oauth, auth: auth, ownership: ownership,
            probe: probe, notices: notices, membership: membership, catalog: catalog,
            createThreadFirstReply: createThreadFirstReply,
            now: now, publishTaskUpdated: publishTaskUpdated
        )
    }

    /// Rebinds the first-reply pipeline to the execution-bound human create
    /// service the HTTP composition owns.
    public func bindingFirstThreadReply(
        _ createThreadFirstReply: @escaping @Sendable (_ serverId: String, _ channelId: String,
            _ userId: String, _ content: String) throws -> Void
    ) -> Self {
        Self(
            channels: channels, messages: messages, tasks: tasks, agents: agents,
            profiles: profiles, oauth: oauth, auth: auth, ownership: ownership,
            probe: probe, notices: notices, membership: membership, catalog: catalog,
            createThreadFirstReply: createThreadFirstReply,
            now: now, publishTaskUpdated: publishTaskUpdated
        )
    }

    private func taskFragment(_ task: TaskRecord, _ channelName: String, _ channelType: String, _ summary: Bool, channelId: String) throws -> String {
        if summary {
            return try catalog.summaryTaskJSON(task, channelName: channelName, channelType: channelType, channelId: channelId)
        }
        return try catalog.fullTaskJSON(task, channelName: channelName, channelType: channelType, channelId: channelId)
    }

    private var visibility: ManagedMCPChannelVisibility {
        ManagedMCPChannelVisibility(oauth: oauth, channels: channels)
    }

    // MARK: - Shared checks

    /// The human routes' `PublicVisits.authRequired` refusal.
    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = try? auth.authenticate(authorization) else {
            throw ChannelMembershipError.authRequired(bearerPresent: authorization?.hasPrefix("Bearer ") == true)
        }
        return userId
    }

    /// The roster and task routes' plain missing-session refusal.
    private func requireSession(_ authorization: String?) throws -> String {
        guard let userId = try? auth.authenticate(authorization) else {
            throw ManagedMCPAssignmentsError.unauthorized
        }
        return userId
    }

    private func requireNotArchived(_ channelId: String) throws {
        guard oauth.channelArchivedAt(id: channelId) == nil else {
            throw ChannelMembershipError.channelArchived
        }
    }

    /// A thread's members are managed with follow/unfollow, never directly.
    private func requireNotThread(_ channelId: String) throws {
        let kind = channels.postableChannel(id: channelId)?.kind ?? oauth.channelType(id: channelId)
        guard kind != "thread" else { throw ChannelMembershipError.threadMembersManagedByFollow }
    }

    private func requireChannel(serverId: String, channelId: String) throws {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
    }

    private func announceMembership(channelId: String, name: String) {
        _ = notices.append(
            StoredHumanMessage(
                id: UUID().uuidString.lowercased(),
                channelId: channelId,
                senderId: "system",
                content: "@\(name) was added to this channel.",
                randomId: nil,
                messageType: "system",
                senderType: "system"
            ),
            nil
        )
    }

    private func inviteHuman(userId: String, serverId: String, channelId: String) {
        channels.insertPostableMember(serverId: serverId, channelId: channelId, memberId: userId)
        oauth.addChannelHuman(channelId: channelId, userId: userId)
    }

    private func accountName(_ userId: String) -> String? {
        profiles.accounts.values.first { $0.id == userId }?.name
    }

    private func agentRows(channelId: String) -> [ChannelAgentRowDTO] {
        let activities = agents.agentActivities
        return oauth.channelAgentIds(channelId: channelId).map { agentId in
            let activity = activities[agentId] ?? (activity: "offline", detail: "")
            return ChannelAgentRowDTO(
                id: agentId,
                name: oauth.agentRuntimeInfo(id: agentId)?.name ?? "",
                activity: activity.activity,
                activityDetail: activity.detail
            )
        }
    }

    // MARK: - POST /api/channels/:channelId/leave

    public func leaveChannel(authorization: String?, serverId: String, channelId: String) throws -> OkResponse {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ChannelMembershipError.notAMember
        }
        try requireChannel(serverId: serverId, channelId: channelId)
        try requireNotArchived(channelId)
        try requireNotThread(channelId)
        channels.removePostableMember(channelId: channelId, memberId: userId)
        oauth.removeChannelHuman(channelId: channelId, userId: userId)
        return OkResponse()
    }

    // MARK: - POST /internal/agent-api/channels/:channelId/leave

    public func agentLeaveChannel(authorization: String?, channelId: String) throws -> OkResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ChannelMembershipError.agentAuthorizationMissing
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let credential = agents.agentCredentials[token],
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw ChannelMembershipError.agentTokenInvalid
        }
        return try membership.leaveChannel(agentId: agent.id, serverId: agent.serverId, channelId: channelId)
    }

    // MARK: - POST /api/channels/:channelId/members/batch

    public func addChannelMembersBatch(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: ChannelMembersBatchRequest?
    ) throws -> ChannelMembersBatchResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.notAMember
        }
        try requireChannel(serverId: serverId, channelId: channelId)
        try requireNotArchived(channelId)
        try requireNotThread(channelId)
        guard visibility.actorCanSee(channelId: channelId, userId: userId) else {
            throw ChannelMembershipError.channelNotFound
        }
        guard role == "owner" || role == "admin" || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
            throw ChannelMembershipError.forbidden
        }
        guard let body else { throw ManagedMCPAssignmentsError.invalidChannelMembers }
        var seenUsers = Set<String>()
        var seenAgents = Set<String>()
        let uniqueUserIds = body.userIds.filter { seenUsers.insert($0).inserted }
        let invalidUserIds = uniqueUserIds.filter { oauth.memberRole(serverId: serverId, userId: $0) == nil }
        if !invalidUserIds.isEmpty {
            throw ManagedMCPAssignmentsError.usersNotInServer(invalidUserIds: invalidUserIds)
        }
        for agentId in body.agentIds where ownership.rawOwner(agentId: agentId) != nil {
            throw ManagedMCPAssignmentsError.assistantChannelForbidden
        }
        var addedUsers: [String] = []
        var addedAgents: [String] = []
        var alreadyUsers: [String] = []
        var alreadyAgents: [String] = []
        for target in uniqueUserIds {
            guard oauth.memberRole(serverId: serverId, userId: target) != nil else { continue }
            if oauth.channelHumanIds(channelId: channelId).contains(target) {
                alreadyUsers.append(target)
            } else {
                inviteHuman(userId: target, serverId: serverId, channelId: channelId)
                announceMembership(channelId: channelId, name: accountName(target) ?? target)
                addedUsers.append(target)
            }
        }
        for agentId in body.agentIds where seenAgents.insert(agentId).inserted {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else { continue }
            if oauth.channelAgentIds(channelId: channelId).contains(agentId) {
                alreadyAgents.append(agentId)
            } else {
                oauth.addChannelAgent(channelId: channelId, agentId: agentId)
                channels.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "channel")
                announceMembership(channelId: channelId, name: oauth.agentRuntimeInfo(id: agentId)?.name ?? agentId)
                addedAgents.append(agentId)
            }
        }
        return ChannelMembersBatchResponse(
            addedUserIds: addedUsers,
            addedAgentIds: addedAgents,
            alreadyUserIds: alreadyUsers,
            alreadyAgentIds: alreadyAgents
        )
    }

    // MARK: - POST /api/channels/:channelId/threads

    public func createThreadFromChannel(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: ChannelThreadRequest?
    ) throws -> ChannelThreadResponse {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ChannelMembershipError.notAMember
        }
        try requireChannel(serverId: serverId, channelId: channelId)
        let probeAccess = probe.access(channelId: channelId, serverId: serverId, userId: userId)
        if probeAccess == .residue { throw ChannelMembershipError.forbidden }
        guard probeAccess == .allowed else { throw ChannelMembershipError.channelNotFound }
        // Nested threads are reported only to a caller who can already see the
        // channel, before the archive and first-reply gates.
        let kind = channels.postableChannel(id: channelId)?.kind ?? oauth.channelType(id: channelId)
        guard kind != "thread" else { throw ManagedMCPAssignmentsError.threadInsideThread }
        try requireNotArchived(channelId)
        guard let parentMessageId = body?.parentMessageId else {
            throw ManagedMCPAssignmentsError.parentMessageIdRequired
        }
        let rows = messages.humanMessageRows
        guard rows.contains(where: { $0.id == parentMessageId && $0.channelId == channelId }) else {
            throw ManagedMCPAssignmentsError.parentMessageNotFound
        }
        // Upstream treats a first reply as an ordinary message post: its
        // length and post-authority gates run before the thread is
        // materialized, so a refused first reply leaves no thread behind.
        let firstReply: String? = {
            guard let content = body?.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return content
        }()
        if let firstReply {
            if firstReply.utf16.count > 32_000 {
                throw HumanMessageCreateError.messageTooLong
            }
            guard channels.postableChannel(id: channelId)?.memberIds.contains(userId) == true else {
                throw HumanMessageCreateError.mustJoinChannel
            }
        }

        let outcome = channels.findOrCreateThread(
            serverId: serverId,
            parentChannelId: channelId,
            parentMessageId: parentMessageId,
            creatorId: userId,
            threadChannels: ThreadChannelCommand(oauth: oauth)
        )
        let threadId: String
        switch outcome {
        case .existing(let id), .created(let id):
            threadId = id
        }
        if let firstReply {
            try createThreadFirstReply(serverId, threadId, userId, firstReply)
        }
        // `getThreadInfoForChannel` runs after the optional post, so the reply
        // count/last reply/participants include the first reply.
        let replies = messages.humanMessageRows.filter { $0.channelId == threadId }
        return ChannelThreadResponse(
            threadChannelId: threadId,
            replyCount: replies.count,
            lastReplyAt: replies.map(\.createdAt).max().map { ISO8601DateFormatter().string(from: $0) },
            participantIds: Array(Set(replies.map(\.senderId))).sorted()
        )
    }

    // MARK: - POST /api/channels/:channelId/members

    public func addChannelMember(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: ChannelMemberRequest?
    ) throws -> OkResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.notAMember
        }
        try requireChannel(serverId: serverId, channelId: channelId)
        try requireNotThread(channelId)
        try requireNotArchived(channelId)
        let actorChannelAdmin = channels.channelHumanRole(channelId: channelId, userId: userId) == "admin"
        if role != "owner" && role != "admin" && !actorChannelAdmin {
            if !oauth.isChannelParticipant(channelId: channelId, userId: userId) {
                throw ChannelMembershipError.channelNotFound
            }
            throw ChannelMembershipError.forbidden
        }
        guard let body else { throw ManagedMCPAssignmentsError.invalidChannelMember }
        if let agentId = body.agentId {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
                throw ManagedMCPAssignmentsError.invalidAgent
            }
            if ownership.rawOwner(agentId: agentId) != nil {
                throw ManagedMCPAssignmentsError.assistantChannelForbidden
            }
            oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            // A human adding an agent is shared channel activity: announce it,
            // and keep it born-read for the acting human only. The added agent
            // stays unread on every transport.
            let noticeSeq = notices.append(
                StoredHumanMessage(
                    id: UUID().uuidString.lowercased(),
                    channelId: channelId,
                    senderId: "system",
                    content: "@\(agent.name) was added to this channel.",
                    randomId: nil,
                    messageType: "system",
                    senderType: "system"
                ),
                nil
            )
            oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: noticeSeq)
            return OkResponse()
        }
        if let targetUserId = body.userId {
            guard oauth.memberRole(serverId: serverId, userId: targetUserId) != nil else {
                throw ManagedMCPAssignmentsError.invalidMember
            }
            inviteHuman(userId: targetUserId, serverId: serverId, channelId: channelId)
            return OkResponse()
        }
        throw ManagedMCPAssignmentsError.invalidChannelMember
    }

    // MARK: - DELETE /api/channels/:channelId/members/user/:memberId

    public func removeChannelHuman(
        authorization: String?,
        serverId: String,
        channelId: String,
        memberId: String
    ) throws -> OkResponse {
        let userId = try requireUser(authorization)
        let actorServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        let jointRemove = channels.jointProjections.contains { $0.localChannelId == channelId }
        if jointRemove, actorServerRole != "owner", actorServerRole != "admin" {
            throw ManagedMCPAssignmentsError.jointChannelAdminLimited
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.notAMember
        }
        try requireChannel(serverId: serverId, channelId: channelId)
        try requireNotArchived(channelId)
        try requireNotThread(channelId)
        guard visibility.actorCanSee(channelId: channelId, userId: userId) else {
            throw ChannelMembershipError.channelNotFound
        }
        let actorChannelAdmin = channels.channelHumanRole(channelId: channelId, userId: userId) == "admin"
        guard role == "owner" || role == "admin" || actorChannelAdmin || userId == memberId else {
            throw ChannelMembershipError.forbidden
        }
        channels.removePostableMember(channelId: channelId, memberId: memberId)
        oauth.removeChannelHuman(channelId: channelId, userId: memberId)
        return OkResponse()
    }

    // MARK: - DELETE /api/channels/:channelId/members/agent/:agentId

    public func removeChannelMember(
        authorization: String?,
        serverId: String,
        channelId: String,
        agentId: String
    ) throws -> OkResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.notAMember
        }
        try requireChannel(serverId: serverId, channelId: channelId)
        try requireNotArchived(channelId)
        try requireNotThread(channelId)
        guard visibility.actorCanSee(channelId: channelId, userId: userId) else {
            throw ChannelMembershipError.channelNotFound
        }
        guard role == "owner" || role == "admin" || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
            throw ChannelMembershipError.forbidden
        }
        oauth.removeChannelAgent(channelId: channelId, agentId: agentId)
        return OkResponse()
    }

    // MARK: - GET /api/channels/:channelId/agents

    public func channelAgents(
        authorization: String?,
        serverId: String,
        channelId: String
    ) throws -> ChannelAgentsResponse {
        let userId = try requireSession(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ChannelMembershipError.notAMember
        }
        if visibility.guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            throw ChannelMembershipError.channelNotFound
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        // A thread has no membership of its own; its readers are the parent
        // channel's. The same parent resolution `GET /members` and
        // `GET /api/channels/:id` use applies here.
        let type = oauth.channelType(id: channelId) ?? "channel"
        let threadParentId = type == "thread" ? oauth.channelParentChannelId(id: channelId) : nil
        let canSee = threadParentId.map { parentId in
            oauth.channelInfo(id: parentId)?.serverId == serverId
                && visibility.actorCanSee(channelId: parentId, userId: userId)
        } ?? visibility.actorCanSee(channelId: channelId, userId: userId)
        guard canSee else {
            throw ChannelMembershipError.channelNotFound
        }
        return ChannelAgentsResponse(agents: agentRows(channelId: channelId))
    }

    // MARK: - PATCH /api/channels/:channelId/members/user/:memberId/role

    public func updateChannelHumanRole(
        authorization: String?,
        serverId: String,
        channelId: String,
        memberId: String,
        body: ChannelRoleRequest?
    ) throws -> ChannelRoleUpdateResponse {
        let userId = try requireSession(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ChannelMembershipError.notAMember
        }
        try requireNotThread(channelId)
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              oauth.isChannelParticipant(channelId: channelId, userId: userId)
                  || oauth.channelType(id: channelId) == "channel"
        else {
            throw ChannelMembershipError.channelNotFound
        }
        try requireNotArchived(channelId)
        let actorRole = channels.channelHumanRole(channelId: channelId, userId: userId)
        let actorServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        guard actorRole == "admin" || actorServerRole == "owner" || actorServerRole == "admin" else {
            throw ChannelMembershipError.forbidden
        }
        guard let role = body?.role, role == "admin" || role == "member" else {
            throw ManagedMCPAssignmentsError.invalidChannelRole
        }
        guard let targetServerRole = oauth.memberRole(serverId: serverId, userId: memberId) else {
            throw ManagedMCPAssignmentsError.memberNotFound
        }
        if targetServerRole == "owner" || targetServerRole == "admin" {
            throw ManagedMCPAssignmentsError.protectedServerRole
        }
        if userId == memberId, role == "member" {
            throw ManagedMCPAssignmentsError.channelAdminSelfDemote
        }
        let revision = channels.setChannelHumanRole(channelId: channelId, memberId: memberId, role: role)
        return ChannelRoleUpdateResponse(authorityRevision: revision)
    }

    // MARK: - GET /api/channels/:channelId/members

    public func channelMembers(
        authorization: String?,
        serverId: String,
        channelId: String
    ) throws -> ChannelMembersResponse {
        let userId = try requireSession(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ChannelMembershipError.notAMember
        }
        if visibility.guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            throw ChannelMembershipError.channelNotFound
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ChannelMembershipError.channelNotFound
        }
        // Threads inherit their parent's read policy: a thread row has no
        // membership of its own, so testing only the thread id denied the
        // parent channel's members (and its owner) even though GET
        // /api/channels/:id resolves the same thread through its parent.
        let type = oauth.channelType(id: channelId) ?? "channel"
        let threadParentId = type == "thread" ? oauth.channelParentChannelId(id: channelId) : nil
        let canSee = threadParentId.map { parentId in
            oauth.channelInfo(id: parentId)?.serverId == serverId
                && visibility.actorCanSee(channelId: parentId, userId: userId)
        } ?? visibility.actorCanSee(channelId: channelId, userId: userId)
        guard canSee else {
            throw ChannelMembershipError.channelNotFound
        }
        let snapshot = channels.state
        let scopeChannelId: String = {
            if let channel = snapshot.postableChannels[channelId], channel.kind == "thread",
               let parentId = channel.parentChannelId {
                return parentId
            }
            return channelId
        }()
        let agentRows = agentRows(channelId: scopeChannelId)
        let viewerServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        let viewerLocalRole = snapshot.channelHumanRoles["\(channelId)\n\(userId)"]
        let viewerIsChannelAdmin = viewerLocalRole == "admin" || viewerServerRole == "owner" || viewerServerRole == "admin"
        var rosterHumanIds = oauth.channelHumanIds(channelId: scopeChannelId)
        if let canonical = snapshot.jointProjections.first(where: { $0.localChannelId == scopeChannelId })?.canonicalChannelId {
            var seen = Set(rosterHumanIds)
            for link in snapshot.jointProjections where link.canonicalChannelId == canonical {
                for humanId in oauth.channelHumanIds(channelId: link.localChannelId) where seen.insert(humanId).inserted {
                    rosterHumanIds.append(humanId)
                }
            }
        }
        let accounts = profiles.accounts
        let humans = rosterHumanIds.map { humanId -> ChannelHumanRowDTO in
            let targetServerRole = oauth.memberRole(serverId: serverId, userId: humanId) ?? "member"
            let isLocalMember = oauth.memberRole(serverId: serverId, userId: humanId) != nil
            let targetLocalRole = snapshot.channelHumanRoles["\(channelId)\n\(humanId)"]
            let displayName = accounts.values.first { $0.id == humanId }?.name ?? humanId
            let basis: String? = targetLocalRole == "admin" ? "channel_role"
                : ((targetServerRole == "owner" || targetServerRole == "admin") ? "server_role" : nil)
            let canChange = viewerIsChannelAdmin && isLocalMember && targetServerRole != "owner"
                && targetServerRole != "admin" && humanId != userId
            return ChannelHumanRowDTO(
                id: humanId,
                name: displayName,
                serverRole: targetServerRole,
                effectiveChannelRole: basis == nil ? "member" : "admin",
                channelAdminBasis: basis,
                canChangeChannelRole: canChange
            )
        }
        return ChannelMembersResponse(agents: agentRows, humans: humans)
    }

    // MARK: - Human task routes

    /// The caller's write access to the task's channel: a missing task and an
    /// invisible channel answer `Task not found`, a read-only one asks the
    /// caller to join.
    private func requireTaskUser(_ authorization: String?, serverId: String) throws -> String {
        let userId = try requireSession(authorization)
        guard !serverId.isEmpty else { throw MessageSendError.missingServerId }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.notAMember
        }
        return userId
    }

    private func requireTaskWriteAccess(serverId: String, task: TaskRecord, userId: String,
        missing: ManagedMCPAssignmentsError = .taskNotFound) throws -> TaskExecutionSurface {
        guard let local = catalog.taskSurface(task, serverId: serverId, userId: userId) else { throw missing }
        guard oauth.memberRole(serverId: serverId, userId: userId) != "guest" else {
            throw ManagedMCPAssignmentsError.joinChannelToChangeTasks
        }
        if channels.postableChannel(id: local.channelId)?.deletedAt == nil {
            guard oauth.isChannelParticipant(channelId: local.channelId, userId: userId) else {
                throw ManagedMCPAssignmentsError.joinChannelToChangeTasks
            }
            try requireNotArchived(local.channelId)
        }
        return local
    }

    // DELETE /api/tasks/:taskId
    public func deleteTask(authorization: String?, serverId: String, taskId: String) throws -> OkResponse {
        let userId = try requireTaskUser(authorization, serverId: serverId)
        guard let task = tasks.task(id: taskId) else { throw ManagedMCPAssignmentsError.taskNotFound }
        _ = try requireTaskWriteAccess(serverId: serverId, task: task, userId: userId)
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        if role != "owner" && role != "admin" && task.creatorId != userId {
            throw ManagedMCPAssignmentsError.onlyCreatorCanDeleteTask
        }
        if let removed = tasks.removeTask(id: taskId), removed.hasHostMessage { messages.clearTaskShadow(messageId: removed.messageId) }
        return OkResponse()
    }

    private func mutationResponse(_ task: TaskRecord, surface: TaskExecutionSurface) throws -> ChannelTaskResponse {
        let projection = try catalog.readProjection(task, channelId: surface.channelId)
        // Preserve the existing bound publisher for every actual local target;
        // HTTP alone adds its envelope around the caller-local projection.
        for target in catalog.taskUpdateProjections(task) {
            publishTaskUpdated(target.jsonBody.render())
        }
        return ChannelTaskResponse(task: projection)
    }

    public func claimTask(authorization: String?, serverId: String, taskId: String) throws -> ChannelTaskResponse {
        let userId = try requireTaskUser(authorization, serverId: serverId)
        guard let task = tasks.task(id: taskId) else { throw ManagedMCPAssignmentsError.taskNotFound }
        let local = try requireTaskWriteAccess(serverId: serverId, task: task, userId: userId)
        guard local.type != "thread" else { throw ManagedMCPAssignmentsError.taskConflict("Thread messages cannot be claimed as tasks") }
        switch tasks.claimForUser(taskId: taskId, userId: userId, channelDeletion: TaskChannelDeletionQuery(channels: channels), now: now()) {
        case .notFound: throw ManagedMCPAssignmentsError.taskNotFound
        case .channelDeleted: throw ManagedMCPAssignmentsError.channelDeletedClaimForbidden
        case .rejected(let reason): throw ManagedMCPAssignmentsError.taskConflict(reason)
        case .alreadyAssigned(let observed):
            let name = observed.assigneeId.flatMap { id in
                observed.assigneeType == "agent" ? oauth.agentRuntimeInfo(id: id)?.name : profiles.account(userId: id)?.name
            }
            throw ManagedMCPAssignmentsError.taskConflict(name.map { "already assigned to @\($0)" } ?? "already assigned to <unresolved>")
        case .claimed(let claimed): return try mutationResponse(claimed, surface: local)
        }
    }

    public func unclaimTask(authorization: String?, serverId: String, taskId: String) throws -> ChannelTaskResponse {
        let userId = try requireTaskUser(authorization, serverId: serverId)
        guard let task = tasks.task(id: taskId) else { throw ManagedMCPAssignmentsError.taskNotFound }
        let local = try requireTaskWriteAccess(serverId: serverId, task: task, userId: userId)
        guard channels.postableChannel(id: local.channelId)?.deletedAt == nil else {
            throw ManagedMCPAssignmentsError.channelDeletedTerminalOnly
        }
        switch tasks.unclaimForUser(taskId: taskId, userId: userId, now: now()) {
        case .notFound: throw ManagedMCPAssignmentsError.taskNotFound
        case .done: throw ManagedMCPAssignmentsError.taskConflict("task is done")
        case .unassigned: throw ManagedMCPAssignmentsError.taskConflict("task is not assigned")
        case .unclaimed(let task): return try mutationResponse(task, surface: local)
        }
    }

    public func updateTaskStatus(authorization: String?, serverId: String, taskId: String, body: TaskStatusRequest?) throws -> ChannelTaskResponse {
        let userId = try requireTaskUser(authorization, serverId: serverId)
        guard let status = body?.status, TaskCatalogPolicy.validTaskStatuses.contains(status) else {
            throw ManagedMCPAssignmentsError.invalidTaskStatus
        }
        guard let task = tasks.task(id: taskId) else { throw ManagedMCPAssignmentsError.taskNotFound }
        let local = try requireTaskWriteAccess(serverId: serverId, task: task, userId: userId)
        if channels.postableChannel(id: local.channelId)?.deletedAt != nil {
            guard ["done", "closed"].contains(status) else { throw ManagedMCPAssignmentsError.channelDeletedTerminalOnly }
            let role = oauth.memberRole(serverId: serverId, userId: userId)
            guard role == "owner" || role == "admin" else { throw ManagedMCPAssignmentsError.onlyAdminsCanCloseDeletedTask }
        }
        switch tasks.applyHumanStatus(taskId: taskId, status: status, userId: userId,
            channelDeletion: TaskChannelDeletionQuery(channels: channels), now: now()) {
        case .notFound: throw ManagedMCPAssignmentsError.taskNotFound
        case .channelDeletedTerminalOnly: throw ManagedMCPAssignmentsError.channelDeletedTerminalOnly
        case .onlyAssigneeCanReturnToTodo: throw ManagedMCPAssignmentsError.onlyAssigneeCanReturnToTodo
        case .resourceReceiptRequired: throw ActionCardExecuteError.resourceReceiptRequired
        case .updated(let updated): return try mutationResponse(updated, surface: local)
        }
    }

    public func convertMessageToTask(authorization: String?, serverId: String, body: TaskConvertRequest?) throws -> ChannelTaskResponse {
        let userId = try requireTaskUser(authorization, serverId: serverId)
        guard let messageId = body?.messageId,
              let message = messages.humanMessageRows.first(where: { $0.id == messageId }),
              let local = catalog.conversionSurface(channelId: message.channelId, serverId: serverId, userId: userId)
        else { throw ManagedMCPAssignmentsError.messageNotFound }
        guard local.type != "thread" else { throw ManagedMCPAssignmentsError.taskConflict("Thread messages cannot be claimed as tasks") }
        guard oauth.memberRole(serverId: serverId, userId: userId) != "guest",
              oauth.isChannelParticipant(channelId: local.channelId, userId: userId)
        else { throw ManagedMCPAssignmentsError.joinChannelToChangeTasks }
        try requireNotArchived(local.channelId)
        guard message.senderType != "external_projection" else {
            throw ManagedMCPAssignmentsError.taskConflict("external projection messages cannot be claimed as tasks")
        }
        guard message.messageType != "system" else {
            throw ManagedMCPAssignmentsError.taskConflict("system messages cannot be claimed as tasks — if the message describes an action you should take, just do it; otherwise ignore it. Don't claim.")
        }
        guard message.taskStatus == nil else { throw ManagedMCPAssignmentsError.taskConflict("already converted") }
        let legacyMax = messages.humanMessageRows.filter { $0.channelId == message.channelId }.compactMap(\.taskNumber).max() ?? 0
        switch tasks.appendConvertedMessageTask(channelId: message.channelId, messageId: messageId, title: message.content,
            creatorId: userId, legacyMessageMaxNumber: legacyMax, now: now()) {
        case .alreadyConverted: throw ManagedMCPAssignmentsError.taskConflict("already converted")
        case .created(let task):
            let projection = try catalog.readProjection(task, channelId: local.channelId)
            do { try catalog.publishConvertedTask(task, surface: local) }
            catch { DeferredEffects.markRollbackOnly(); throw error }
            return ChannelTaskResponse(task: projection)
        }
    }

    // MARK: - GET /api/tasks/server

    /// Above this many body bytes a paginated/summary answer logs a warning.
    static let tasksServerResponseWarnBytes = 8 * 1024 * 1024

    public func listServerTasks(
        authorization: String?,
        serverId: String,
        rawQuery: String?
    ) throws -> ServerTasksResponse {
        let userId = try requireTaskUser(authorization, serverId: serverId)
        func repeated(_ name: String) -> Bool {
            guard let rawQuery else { return false }
            return rawQuery.split(separator: "&").filter { $0.hasPrefix(name + "=") }.count > 1
        }
        if ["limit", "cursor", "detail", "status"].contains(where: repeated) {
            throw ManagedMCPAssignmentsError.repeatedQueryParameter
        }
        let status: String?
        switch TasksAndLabsService.statusFilter(rawQuery) {
        case .invalid: throw TasksAndLabsError.invalidTaskStatus
        case .valid(let value): status = value
        }
        guard let rawQuery else {
            let ordered = catalog.orderedTasks(serverId: serverId, userId: userId, status: status)
            return ServerTasksResponse(
                taskFragments: try ordered.map { try taskFragment($0.task, $0.channelName, $0.channelType, false, channelId: $0.channelId) },
                paginated: false,
                nextCursor: nil
            )
        }
        var params: [String: String] = [:]
        for pair in rawQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        let detail = params["detail"] ?? "full"
        guard detail == "full" || detail == "summary" else {
            throw ManagedMCPAssignmentsError.detailMustBeFullOrSummary
        }
        var limit: Int?
        if let rawLimit = params["limit"] {
            guard let value = Int(rawLimit), (1...500).contains(value) else {
                throw ManagedMCPAssignmentsError.limitOutOfRange
            }
            limit = value
        }
        var cursor: (channelId: String, taskNumber: Int)?
        if let rawCursor = params["cursor"] {
            guard limit != nil else { throw ManagedMCPAssignmentsError.cursorRequiresLimit }
            guard let decoded = TaskCatalogPolicy.decodeCursor(rawCursor) else {
                throw ManagedMCPAssignmentsError.invalidCursor
            }
            cursor = decoded
        }
        let ordered = catalog.orderedTasks(serverId: serverId, userId: userId, status: status)
        var startIndex = 0
        if let cursor {
            guard let index = ordered.firstIndex(where: {
                $0.channelId == cursor.channelId && $0.task.taskNumber == cursor.taskNumber
            }) else {
                throw ManagedMCPAssignmentsError.invalidCursor
            }
            startIndex = index + 1
        }
        var page = ordered
        var nextCursor: String?
        if let limit {
            let slice = Array(ordered.dropFirst(startIndex).prefix(limit))
            page = slice
            if let last = slice.last, startIndex + slice.count < ordered.count {
                nextCursor = TaskCatalogPolicy.encodeCursor(channelId: last.channelId, taskNumber: last.task.taskNumber)
            }
        }
        let response = ServerTasksResponse(
            taskFragments: try page.map {
                try taskFragment($0.task, $0.channelName, $0.channelType, detail == "summary", channelId: $0.channelId)
            },
            paginated: limit != nil,
            nextCursor: nextCursor
        )
        let bytes = response.responseBytes
        if bytes > Self.tasksServerResponseWarnBytes {
            let warning = "[tasks/server] paginated/summary response for server \(serverId) is \(bytes) bytes"
            tasks.lastTaskServerWarning = warning
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        return response
    }
}
