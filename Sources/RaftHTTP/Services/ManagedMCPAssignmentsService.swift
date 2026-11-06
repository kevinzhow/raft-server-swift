import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Injected dependencies

/// Every cross-domain decision the assignment service needs, as injected
/// closures. The channel rows, read state and task rows are the stores the
/// service owns; the session lookup, the assistant-owner lookup, the channel
/// probe, the serialized system-notice append, the agent leave and the task
/// catalog projections belong to domains that have not migrated (or whose
/// service another slice owns) and stay behind these closures. `live(directory:)`
/// wires them to the existing directory entry points at the composition root.
struct ManagedMCPAssignmentsDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var assistantOwner: @Sendable (_ agentId: String) -> String?
    var channelProbeAccess: @Sendable (_ channelId: String, _ serverId: String, _ userId: String) -> ChannelProbeAccess
    /// Appends one human-message row and its ledger mirror in the same
    /// Messages transaction, returning its server-wide sequence.
    var appendSystemNotice: @Sendable (_ message: StoredHumanMessage, _ bornReadAgentId: String?) -> Int
    var leaveChannelAsAgent: @Sendable (_ agentId: String, _ serverId: String, _ channelId: String) throws -> OkResponse
    var orderedTasks: @Sendable (_ serverId: String, _ userId: String, _ status: String?) -> [(task: TaskRecord, channelName: String, channelType: String)]
    var taskFragment: @Sendable (_ task: TaskRecord, _ channelName: String, _ channelType: String, _ summary: Bool) -> String
    var now: @Sendable () -> Date

    static func live(
        directory source: EmailLoginDirectory,
        appendSystemNotice: @escaping @Sendable (StoredHumanMessage, String?) -> Int
    ) -> ManagedMCPAssignmentsDependencies {
        let catalog = source.taskCatalog
        let ownership = AssistantOwnershipQuery(agents: source.agentsRuntimeStore, oauth: source.oauth)
        return ManagedMCPAssignmentsDependencies(
            sessionUserId: { source.sessionUserId(authorization: $0) },
            assistantOwner: { ownership.rawOwner(agentId: $0) },
            channelProbeAccess: { channelId, serverId, userId in
                source.channelProbeAccessLocked(channelId: channelId, serverId: serverId, userId: userId)
            },
            appendSystemNotice: appendSystemNotice,
            leaveChannelAsAgent: { agentId, serverId, channelId in
                try source.channelMembership.leaveChannel(agentId: agentId, serverId: serverId, channelId: channelId)
            },
            orderedTasks: { serverId, userId, status in
                catalog.orderedTasks(serverId: serverId, userId: userId, status: status)
            },
            taskFragment: { task, channelName, channelType, summary in
                summary
                    ? catalog.summaryTaskJSON(task, channelName: channelName, channelType: channelType)
                    : catalog.fullTaskJSON(task, channelName: channelName, channelType: channelType)
            },
            now: { Date() }
        )
    }
}

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
    private let dependencies: ManagedMCPAssignmentsDependencies
    private let publishTaskUpdated: @Sendable (String) -> Void

    /// Production wiring. The `task:updated` realtime frame is published by the
    /// channel-messaging domain, so its sink enters as a closure that takes the
    /// claimed task's published JSON.
    init(
        directory source: EmailLoginDirectory,
        appendSystemNotice: @escaping @Sendable (StoredHumanMessage, String?) -> Int,
        publishTaskUpdated: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            channels: source.serversAndChannelsStore,
            messages: source.messagesAndThreadsStore,
            tasks: source.tasksAndRemindersStore,
            agents: source.agentsRuntimeStore,
            profiles: source.authProfileStore,
            oauth: source.oauth,
            dependencies: .live(directory: source, appendSystemNotice: appendSystemNotice),
            publishTaskUpdated: publishTaskUpdated
        )
    }

    init(
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        tasks: TasksAndRemindersStore,
        agents: AgentsRuntimeStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        dependencies: ManagedMCPAssignmentsDependencies,
        publishTaskUpdated: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.channels = channels
        self.messages = messages
        self.tasks = tasks
        self.agents = agents
        self.profiles = profiles
        self.oauth = oauth
        self.dependencies = dependencies
        self.publishTaskUpdated = publishTaskUpdated
    }

    private var visibility: ManagedMCPChannelVisibility {
        ManagedMCPChannelVisibility(oauth: oauth, channels: channels)
    }

    // MARK: - Shared checks

    /// The human routes' `PublicVisits.authRequired` refusal.
    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ChannelMembershipError.authRequired(bearerPresent: authorization?.hasPrefix("Bearer ") == true)
        }
        return userId
    }

    /// The roster and task routes' plain missing-session refusal.
    private func requireSession(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
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
        _ = dependencies.appendSystemNotice(
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
        return try dependencies.leaveChannelAsAgent(agent.id, agent.serverId, channelId)
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
        for agentId in body.agentIds where dependencies.assistantOwner(agentId) != nil {
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
        let probeAccess = dependencies.channelProbeAccess(channelId, serverId, userId)
        if probeAccess == .residue { throw ChannelMembershipError.forbidden }
        guard probeAccess == .allowed else { throw ChannelMembershipError.channelNotFound }
        try requireNotArchived(channelId)
        guard let parentMessageId = body?.parentMessageId else {
            throw ManagedMCPAssignmentsError.parentMessageIdRequired
        }
        let rows = messages.humanMessageRows
        guard rows.contains(where: { $0.id == parentMessageId && $0.channelId == channelId }) else {
            throw ManagedMCPAssignmentsError.parentMessageNotFound
        }
        let outcome = channels.findOrCreateThread(
            serverId: serverId,
            parentChannelId: channelId,
            parentMessageId: parentMessageId,
            creatorId: userId,
            createChannel: {
                oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parentMessageId)
            }
        )
        switch outcome {
        case .existing(let threadId):
            let replies = messages.humanMessageRows.filter { $0.channelId == threadId }
            return .existing(
                threadChannelId: threadId,
                replyCount: replies.count,
                lastReplyAt: replies.last.map { ISO8601DateFormatter().string(from: $0.createdAt) },
                participantIds: Array(Set(replies.map(\.senderId))).sorted()
            )
        case .created(let threadId):
            var messageId: String?
            if let content = body?.content, !content.isEmpty {
                let id = UUID().uuidString.lowercased()
                _ = dependencies.appendSystemNotice(
                    StoredHumanMessage(id: id, channelId: threadId, senderId: userId, content: content, randomId: nil),
                    nil
                )
                messageId = id
            }
            if messageId != nil {
                let parentAuthorId = rows.first(where: { $0.id == parentMessageId })?.senderId
                var followedParentAuthor: String?
                if let parentAuthorId, parentAuthorId != userId, parentAuthorId != "system",
                   accountName(parentAuthorId) != nil,
                   oauth.memberRole(serverId: serverId, userId: parentAuthorId) != nil {
                    followedParentAuthor = parentAuthorId
                }
                messages.followCreatedThread(
                    serverId: serverId,
                    userId: userId,
                    threadChannelId: threadId,
                    parentMessageId: parentMessageId,
                    parentAuthorId: followedParentAuthor
                )
            }
            return .created(threadChannelId: threadId, messageId: messageId)
        }
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
            if dependencies.assistantOwner(agentId) != nil {
                throw ManagedMCPAssignmentsError.assistantChannelForbidden
            }
            oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            // A human adding an agent is shared channel activity: announce it,
            // and keep it born-read for the acting human only. The added agent
            // stays unread on every transport.
            let noticeSeq = dependencies.appendSystemNotice(
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
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              visibility.actorCanSee(channelId: channelId, userId: userId)
        else {
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
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              oauth.isChannelParticipant(channelId: channelId, userId: userId)
                  || oauth.channelType(id: channelId) == "channel"
        else {
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
    private func requireTaskWriteAccess(serverId: String, task: TaskRecord, userId: String, missing: ManagedMCPAssignmentsError = .taskNotFound) throws {
        switch TasksAndLabsService.channelAccess(oauth: oauth, serverId: serverId, channelId: task.channelId, userId: userId) {
        case .missing: throw missing
        case .readOnly: throw ManagedMCPAssignmentsError.joinChannelToChangeTasks
        case .write: break
        }
    }

    // DELETE /api/tasks/:taskId
    public func deleteTask(authorization: String?, serverId: String, taskId: String) throws -> OkResponse {
        let userId = try requireSession(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ChannelMembershipError.notAMember
        }
        guard let task = tasks.task(id: taskId) else { throw ManagedMCPAssignmentsError.taskNotFound }
        try requireTaskWriteAccess(serverId: serverId, task: task, userId: userId)
        if role != "owner" && role != "admin" && task.creatorId != userId {
            throw ManagedMCPAssignmentsError.onlyCreatorCanDeleteTask
        }
        if let removed = tasks.removeTask(id: taskId), removed.hasHostMessage {
            messages.clearTaskShadow(messageId: removed.messageId)
        }
        return OkResponse()
    }

    // PATCH /api/tasks/:taskId/claim
    public func claimTask(authorization: String?, serverId: String, taskId: String) throws -> ActionCardTaskPayload {
        let userId = try requireSession(authorization)
        guard let task = tasks.task(id: taskId) else { throw ManagedMCPAssignmentsError.taskNotFound }
        try requireTaskWriteAccess(serverId: serverId, task: task, userId: userId)
        switch tasks.claimForUser(
            taskId: taskId,
            userId: userId,
            channelDeleted: { channels.postableChannel(id: $0)?.deletedAt != nil },
            now: dependencies.now()
        ) {
        case .notFound:
            throw ManagedMCPAssignmentsError.taskNotFound
        case .channelDeleted:
            throw ManagedMCPAssignmentsError.channelDeletedClaimForbidden
        case .claimed(let claimed):
            let payload = ActionCardTaskPayload(claimed)
            publishTaskUpdated(payload.jsonBody.render())
            return payload
        }
    }

    // PATCH /api/tasks/:taskId/unclaim
    public func unclaimTask(authorization: String?, serverId: String, taskId: String) throws -> ActionCardTaskPayload {
        let userId = try requireSession(authorization)
        guard let task = tasks.task(id: taskId) else { throw ManagedMCPAssignmentsError.taskNotFound }
        try requireTaskWriteAccess(serverId: serverId, task: task, userId: userId)
        guard let unclaimed = tasks.unclaimForUser(taskId: taskId, userId: userId) else {
            throw ManagedMCPAssignmentsError.taskNotFound
        }
        return ActionCardTaskPayload(unclaimed)
    }

    // PATCH /api/tasks/:taskId/status
    public func updateTaskStatus(
        authorization: String?,
        serverId: String,
        taskId: String,
        body: TaskStatusRequest?
    ) throws -> ActionCardTaskPayload {
        let userId = try requireSession(authorization)
        guard let status = body?.status, TaskCatalogPolicy.validTaskStatuses.contains(status) else {
            throw ManagedMCPAssignmentsError.invalidTaskStatus
        }
        guard let task = tasks.task(id: taskId) else { throw ManagedMCPAssignmentsError.taskNotFound }
        try requireTaskWriteAccess(serverId: serverId, task: task, userId: userId)
        switch tasks.applyHumanStatus(
            taskId: taskId,
            status: status,
            userId: userId,
            channelDeleted: { channels.postableChannel(id: $0)?.deletedAt != nil },
            now: dependencies.now()
        ) {
        case .notFound:
            throw ManagedMCPAssignmentsError.taskNotFound
        case .channelDeletedTerminalOnly:
            throw ManagedMCPAssignmentsError.channelDeletedTerminalOnly
        case .onlyAssigneeCanReturnToTodo:
            throw ManagedMCPAssignmentsError.onlyAssigneeCanReturnToTodo
        case .updated(let updated):
            return ActionCardTaskPayload(updated)
        }
    }

    // POST /api/tasks/convert-message
    public func convertMessageToTask(
        authorization: String?,
        serverId: String,
        body: TaskConvertRequest?
    ) throws -> TaskConvertResponse {
        let userId = try requireSession(authorization)
        guard let messageId = body?.messageId else { throw ManagedMCPAssignmentsError.messageNotFound }
        let storedChannelId = oauth.messageChannelId(messageId)
            ?? messages.humanMessageRows.first { $0.id == messageId }?.channelId
        guard let channelId = storedChannelId else { throw ManagedMCPAssignmentsError.messageNotFound }
        switch TasksAndLabsService.channelAccess(oauth: oauth, serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: throw ManagedMCPAssignmentsError.messageNotFound
        case .readOnly: throw ManagedMCPAssignmentsError.joinChannelToChangeTasks
        case .write: break
        }
        let id = tasks.appendConvertedMessageTask(channelId: channelId, messageId: messageId, creatorId: userId)
        return TaskConvertResponse(taskIds: [id])
    }

    // MARK: - GET /api/tasks/server

    /// Above this many body bytes a paginated/summary answer logs a warning.
    static let tasksServerResponseWarnBytes = 8 * 1024 * 1024

    public func listServerTasks(
        authorization: String?,
        serverId: String,
        rawQuery: String?
    ) throws -> ServerTasksResponse {
        let userId = try requireSession(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ChannelMembershipError.notAMember
        }
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
            let ordered = dependencies.orderedTasks(serverId, userId, status)
            return ServerTasksResponse(
                taskFragments: ordered.map { dependencies.taskFragment($0.task, $0.channelName, $0.channelType, false) },
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
        let ordered = dependencies.orderedTasks(serverId, userId, status)
        var startIndex = 0
        if let cursor {
            guard let index = ordered.firstIndex(where: {
                $0.task.channelId == cursor.channelId && $0.task.taskNumber == cursor.taskNumber
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
                nextCursor = TaskCatalogPolicy.encodeCursor(channelId: last.task.channelId, taskNumber: last.task.taskNumber)
            }
        }
        let response = ServerTasksResponse(
            taskFragments: page.map {
                dependencies.taskFragment($0.task, $0.channelName, $0.channelType, detail == "summary")
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
