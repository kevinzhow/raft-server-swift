import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Channel membership, thread creation and server task routes.
/// Migrated verbatim from the second half of `EmailLogin+ManagedMCP1.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ManagedMCPAssignmentsService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {
    public func leaveChannel(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(userId)
        lock.unlock()
        _ = oauth.removeChannelHuman(channelId: channelId, userId: userId)
        return Self.json(200, "{\"ok\":true}")
    }

    public func agentLeaveChannel(authorization: String?, channelId: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        return leaveChannelForAgent(agentId: agent.id, serverId: agent.serverId, channelId: channelId)
    }

    public func addChannelMembersBatch(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard role == "owner" || role == "admin" || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel members\"}")
        }
        let rawUserIds = (object["userIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let rawAgentIds = (object["agentIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        var seenUsers = Set<String>()
        var seenAgents = Set<String>()
        let uniqueUserIds = rawUserIds.filter { seenUsers.insert($0).inserted }
        let invalidUserIds = uniqueUserIds.filter { oauth.memberRole(serverId: serverId, userId: $0) == nil }
        if !invalidUserIds.isEmpty {
            let invalid = invalidUserIds.map { jsonString($0) }.joined(separator: ",")
            return Self.json(400, "{\"error\":\"One or more users are not members of this server\",\"code\":\"users_not_in_server\",\"invalidUserIds\":[\(invalid)]}")
        }
        var addedUsers: [String] = []
        var addedAgents: [String] = []
        var alreadyUsers: [String] = []
        var alreadyAgents: [String] = []
        for agentId in rawAgentIds where assistantOwnerRaw(agentId) != nil {
            return Self.json(403, "{\"code\":\"assistant_channel_forbidden\",\"error\":\"An assistant can only be in its DM with its owner\"}")
        }
        for target in uniqueUserIds {
            guard oauth.memberRole(serverId: serverId, userId: target) != nil else { continue }
            if oauth.channelHumanIds(channelId: channelId).contains(target) {
                alreadyUsers.append(target)
            } else {
                accountsForInvite(userId: target, serverId: serverId, channelId: channelId)
                let name = accounts.values.first { $0.id == target }?.name ?? target
                recordBatchMembershipNotice(channelId: channelId, name: name)
                addedUsers.append(target)
            }
        }
        for agentId in rawAgentIds where seenAgents.insert(agentId).inserted {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else { continue }
            if oauth.channelAgentIds(channelId: channelId).contains(agentId) {
                alreadyAgents.append(agentId)
            } else {
                oauth.addChannelAgent(channelId: channelId, agentId: agentId)
                addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "channel")
                let name = oauth.agentRuntimeInfo(id: agentId)?.name ?? agentId
                recordBatchMembershipNotice(channelId: channelId, name: name)
                addedAgents.append(agentId)
            }
        }
        func array(_ values: [String]) -> String {
            values.map { jsonString($0) }.joined(separator: ",")
        }
        return Self.json(200, "{\"ok\":true,\"added\":{\"userIds\":[\("\(array(addedUsers))")],\"agentIds\":[\("\(array(addedAgents))")]},\"alreadyMembers\":{\"userIds\":[\("\(array(alreadyUsers))")],\"agentIds\":[\("\(array(alreadyAgents))")]}}")
    }

    func recordBatchMembershipNotice(channelId: String, name: String) {
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            senderId: "system",
            content: "@\(name) was added to this channel.",
            randomId: nil,
            messageType: "system",
            senderType: "system"
        ))
        lock.unlock()
    }

    func accountsForInvite(userId: String, serverId: String, channelId: String) {
        lock.lock()
        postableChannels[channelId, default: PostableChannel(serverId: serverId, memberIds: [])].memberIds.insert(userId)
        lock.unlock()
        oauth.addChannelHuman(channelId: channelId, userId: userId)
    }

    public func createThreadFromChannel(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let probeAccess = channelProbeAccessLocked(channelId: channelId, serverId: serverId, userId: userId)
        lock.unlock()
        if probeAccess == .residue {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard probeAccess == .allowed else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let parentMessageId = object["parentMessageId"] as? String
        else {
            return Self.json(400, "{\"error\":\"parentMessageId is required\"}")
        }
        lock.lock()
        guard humanMessageRows.contains(where: { $0.id == parentMessageId && $0.channelId == channelId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Parent message not found\"}")
        }
        if let existing = postableChannels.first(where: { _, candidate in
            candidate.serverId == serverId && candidate.kind == "thread"
                && candidate.parentChannelId == channelId && candidate.parentMessageId == parentMessageId
                && candidate.deletedAt == nil
        }) {
            let replies = humanMessageRows.filter { $0.channelId == existing.key }
            let participants = Array(Set(replies.map(\.senderId))).sorted()
            lock.unlock()
            let participantJSON = participants.map { jsonString($0) }.joined(separator: ",")
            return Self.json(200, "{\"threadChannelId\":\(jsonString(existing.key)),\"replyCount\":\(replies.count),\"lastReplyAt\":\(replies.last.map { jsonString(ISO8601DateFormatter().string(from: $0.createdAt)) } ?? "null"),\"participantIds\":[\(participantJSON)]}")
        }
        let threadId = oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parentMessageId)
        postableChannels[threadId] = PostableChannel(
            serverId: serverId,
            memberIds: [userId],
            kind: "thread",
            parentChannelId: channelId,
            parentMessageId: parentMessageId,
            name: "thread"
        )
        threadOrder.append(threadId)
        var messageId: String?
        if let content = object["content"] as? String, !content.isEmpty {
            let id = UUID().uuidString.lowercased()
            appendHumanMessageLocked(StoredHumanMessage(
                id: id,
                channelId: threadId,
                senderId: userId,
                content: content,
                randomId: nil
            ))
            messageId = id
        }
        let parentAuthorId = humanMessageRows.first(where: { $0.id == parentMessageId })?.senderId
        lock.unlock()
        if messageId != nil {
            threadFollows["\(serverId)\n\(userId)\n\(threadId)"] = (serverId, userId, threadId, parentMessageId)
            if let parentAuthorId, parentAuthorId != userId,
               parentAuthorId != "system",
               accounts.values.contains(where: { $0.id == parentAuthorId }),
               oauth.memberRole(serverId: serverId, userId: parentAuthorId) != nil {
                threadFollows["\(serverId)\n\(parentAuthorId)\n\(threadId)"] = (serverId, parentAuthorId, threadId, parentMessageId)
            }
        }
        let messageJSON = messageId.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"threadChannelId\":\(jsonString(threadId)),\"messageId\":\(messageJSON),\"replyCount\":0,\"lastReplyAt\":null,\"participantIds\":[]}")
    }

    public func addChannelMember(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        if let reply = archivedChannelReply(channelId) { return reply }
        lock.lock()
        let actorChannelAdmin = channelHumanRoles["\(channelId)\n\(userId)"] == "admin"
        lock.unlock()
        if role != "owner" && role != "admin" && !actorChannelAdmin {
            if !oauth.isChannelParticipant(channelId: channelId, userId: userId) {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel member\"}")
        }
        if let agentId = object["agentId"] as? String {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
                return Self.json(400, "{\"error\":\"Invalid agent\"}")
            }
            if assistantOwnerRaw(agentId) != nil {
                return Self.json(403, "{\"code\":\"assistant_channel_forbidden\",\"error\":\"An assistant can only be in its DM with its owner\"}")
            }
            oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            // A human adding an agent is shared channel activity: announce it,
            // and keep it born-read for the acting human only. The added agent
            // stays unread on every transport (its own actions are the only
            // ones born-read for it).
            lock.lock()
            let noticeSeq = appendHumanMessageLocked(StoredHumanMessage(
                id: UUID().uuidString.lowercased(),
                channelId: channelId,
                senderId: "system",
                content: "@\(agent.name) was added to this channel.",
                randomId: nil,
                messageType: "system",
                senderType: "system"
            ))
            oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: noticeSeq)
            lock.unlock()
            return Self.json(200, "{\"ok\":true}")
        }
        if let targetUserId = object["userId"] as? String {
            guard oauth.memberRole(serverId: serverId, userId: targetUserId) != nil else {
                return Self.json(400, "{\"error\":\"Invalid member\"}")
            }
            accountsForInvite(userId: targetUserId, serverId: serverId, channelId: channelId)
            return Self.json(200, "{\"ok\":true}")
        }
        return Self.json(400, "{\"error\":\"Invalid channel member\"}")
    }

    public func removeChannelHuman(authorization: String?, serverId: String, channelId: String, memberId: String) -> HTTPReply {
        if let authorization, let userId = sessionUserId(authorization: authorization) {
            lock.lock()
            let jointRemove = jointProjections.contains { $0.localChannelId == channelId }
            lock.unlock()
            let actorServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
            if jointRemove, actorServerRole != "owner", actorServerRole != "admin" {
                return Self.json(403, "{\"error\":\"Only a server admin can remove joint channel members\",\"code\":\"joint_channel_admin_limited\"}")
            }
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let actorChannelAdmin = channelHumanRoles["\(channelId)\n\(userId)"] == "admin"
        lock.unlock()
        guard role == "owner" || role == "admin" || actorChannelAdmin || userId == memberId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(memberId)
        lock.unlock()
        _ = oauth.removeChannelHuman(channelId: channelId, userId: memberId)
        return Self.json(200, "{\"ok\":true}")
    }

    public func removeChannelMember(authorization: String?, serverId: String, channelId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard role == "owner" || role == "admin" || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        oauth.removeChannelAgent(channelId: channelId, agentId: agentId)
        return Self.json(200, "{\"ok\":true}")
    }

    func threadMemberMutationReply(_ channelId: String) -> HTTPReply? {
        lock.lock()
        let kind = postableChannels[channelId]?.kind ?? oauth.channelType(id: channelId)
        lock.unlock()
        guard kind == "thread" else { return nil }
        return Self.json(400, "{\"error\":\"Thread members are managed with follow/unfollow\"}")
    }

    func channelActorCanSee(channelId: String, userId: String) -> Bool {
        lock.lock()
        let postable = postableChannels[channelId]
        lock.unlock()
        if let postable {
            return postable.kind == "channel" || postable.memberIds.contains(userId)
        }
        return oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId)
    }

    /// Guests may only see channels they explicitly joined; a hidden public
    /// channel must stay cloaked for the guest role.
    func guestDeniedHiddenChannel(channelId: String, serverId: String, userId: String) -> Bool {
        guard oauth.memberRole(serverId: serverId, userId: userId) == "guest" else { return false }
        return !oauth.channelHumanIds(channelId: channelId).contains(userId)
    }

    public func channelAgentsRoute(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              channelActorCanSee(channelId: channelId, userId: userId)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let agents = oauth.channelAgentIds(channelId: channelId).map { agentId -> String in
            let info = oauth.agentRuntimeInfo(id: agentId)
            let activity = agentActivities[agentId] ?? (activity: "offline", detail: "")
            return "{\"id\":\(jsonString(agentId)),\"name\":\(jsonString(info?.name ?? "")),\"activity\":\(jsonString(activity.activity)),\"activityDetail\":\(jsonString(activity.detail))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"agents\":[\("\(agents)")]}")
    }

    public func updateChannelHumanRole(authorization: String?, serverId: String, channelId: String, memberId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              oauth.isChannelParticipant(channelId: channelId, userId: userId)
                  || oauth.channelType(id: channelId) == "channel"
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        lock.lock()
        let actorRole = channelHumanRoles["\(channelId)\n\(userId)"]
        lock.unlock()
        let actorServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        guard actorRole == "admin" || actorServerRole == "owner" || actorServerRole == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let role = object["role"] as? String, role == "admin" || role == "member"
        else {
            return Self.json(400, "{\"error\":\"Invalid channel role\"}")
        }
        guard let targetRoleValue = oauth.memberRole(serverId: serverId, userId: memberId) else {
            return Self.json(404, "{\"error\":\"Member not found\"}")
        }
        let targetServerRole = targetRoleValue
        if targetServerRole == "owner" || targetServerRole == "admin" {
            return Self.json(403, "{\"error\":\"Server role is managed separately\",\"code\":\"protected_server_role\"}")
        }
        if userId == memberId, role == "member" {
            return Self.json(409, "{\"error\":\"A channel admin cannot demote themselves\",\"code\":\"channel_admin_self_demote_forbidden\"}")
        }
        lock.lock()
        channelHumanRoles["\(channelId)\n\(memberId)"] = role
        let revision = (channelAuthorityRevisions[channelId] ?? 1) + 1
        channelAuthorityRevisions[channelId] = revision
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"authorityRevision\":\(revision)}")
    }

    public func channelMembers(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              oauth.isChannelParticipant(channelId: channelId, userId: userId)
                  || oauth.channelType(id: channelId) == "channel"
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let scopeChannelId: String = {
            if let channel = postableChannels[channelId], channel.kind == "thread", let parentId = channel.parentChannelId {
                return parentId
            }
            return channelId
        }()
        lock.unlock()
        let agents = oauth.channelAgentIds(channelId: scopeChannelId).map { agentId -> String in
            let info = oauth.agentRuntimeInfo(id: agentId)
            let name = info?.name ?? ""
            let activity = agentActivities[agentId] ?? (activity: "offline", detail: "")
            return "{\"id\":\(jsonString(agentId)),\"name\":\(jsonString(name)),\"activity\":\(jsonString(activity.activity)),\"activityDetail\":\(jsonString(activity.detail))}"
        }.joined(separator: ",")
        let viewerServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        lock.lock()
        let viewerLocalRole = channelHumanRoles["\(channelId)\n\(userId)"]
        lock.unlock()
        let viewerIsChannelAdmin = viewerLocalRole == "admin" || viewerServerRole == "owner" || viewerServerRole == "admin"
        lock.lock()
        var rosterHumanIds = oauth.channelHumanIds(channelId: scopeChannelId)
        if let canonical = jointProjections.first(where: { $0.localChannelId == scopeChannelId })?.canonicalChannelId {
            var seen = Set(rosterHumanIds)
            for link in jointProjections where link.canonicalChannelId == canonical {
                for humanId in oauth.channelHumanIds(channelId: link.localChannelId) where seen.insert(humanId).inserted {
                    rosterHumanIds.append(humanId)
                }
            }
        }
        let rosterIds = rosterHumanIds
        lock.unlock()
        let humans = rosterIds.map { humanId -> String in
            let targetServerRole = oauth.memberRole(serverId: serverId, userId: humanId) ?? "member"
            let isLocalMember = oauth.memberRole(serverId: serverId, userId: humanId) != nil
            lock.lock()
            let targetLocalRole = channelHumanRoles["\(channelId)\n\(humanId)"]
            let displayName = accounts.values.first { $0.id == humanId }?.name ?? humanId
            lock.unlock()
            let basis: String? = targetLocalRole == "admin" ? "channel_role"
                : ((targetServerRole == "owner" || targetServerRole == "admin") ? "server_role" : nil)
            let effectiveRole = basis == nil ? "member" : "admin"
            let canChange = viewerIsChannelAdmin && isLocalMember && targetServerRole != "owner" && targetServerRole != "admin" && humanId != userId
            return "{\"id\":\(jsonString(humanId)),\"name\":\(jsonString(displayName)),\"serverRole\":\(jsonString(targetServerRole)),\"effectiveChannelRole\":\(jsonString(effectiveRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"canChangeChannelRole\":\(canChange)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"agents\":[\("\(agents)")],\"humans\":[\("\(humans)")]}")
    }

    public func deleteTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        let creatorId = taskRecords[index].creatorId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        if role != "owner" && role != "admin" && creatorId != userId {
            return Self.json(403, "{\"error\":\"Only the task creator can delete it\"}")
        }
        lock.lock()
        let removed = taskRecords.remove(at: index)
        if removed.hasHostMessage,
           let shadow = humanMessageRows.firstIndex(where: { $0.id == removed.messageId }) {
            humanMessageRows[shadow].taskStatus = nil
            humanMessageRows[shadow].taskNumber = nil
            humanMessageRows[shadow].taskAssigneeType = nil
            humanMessageRows[shadow].taskAssigneeId = nil
            humanMessageRows[shadow].taskClaimedAt = nil
            humanMessageRows[shadow].taskCompletedAt = nil
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func claimTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        guard postableChannels[channelId]?.deletedAt == nil else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"This channel was deleted; the task can only be closed\",\"code\":\"channel_deleted_terminal_only\"}")
        }
        taskRecords[index].assigneeId = userId
        taskRecords[index].assigneeType = "user"
        taskRecords[index].claimedAt = Date()
        taskRecords[index].revision += 1
        if taskRecords[index].status == "todo" { taskRecords[index].status = "in_progress" }
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func unclaimTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        let previousAssigneeId = taskRecords[index].assigneeId
        let previousAssigneeType = taskRecords[index].assigneeType
        taskRecords[index].assigneeId = nil
        taskRecords[index].assigneeType = nil
        taskRecords[index].claimedAt = nil
        taskRecords[index].revision += 1
        assigneeChangeEvents.append((
            taskId: taskId, assigneeId: nil, assigneeType: nil,
            previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType,
            actorType: "user", actorId: userId
        ))
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func updateTaskStatus(authorization: String?, serverId: String, taskId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let status = object["status"] as? String, Self.validTaskStatuses.contains(status)
        else {
            return Self.json(400, "{\"error\":\"Invalid task status\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        let current = taskRecords[index]
        if postableChannels[channelId]?.deletedAt != nil,
           !["done", "closed", "cancelled"].contains(status) {
            lock.unlock()
            return Self.json(409, "{\"error\":\"This channel was deleted; only terminal task statuses are allowed\",\"code\":\"channel_deleted_terminal_only\"}")
        }
        if status == "todo", current.status == "in_progress", current.assigneeId != userId {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Only the current assignee can return this task to todo\"}")
        }
        taskRecords[index].status = status
        if status == "done", taskRecords[index].completedAt == nil {
            taskRecords[index].completedAt = Date()
        }
        if status == "closed" || status == "cancelled" {
            taskRecords[index].closedAt = Date()
        }
        if status == "in_progress", taskRecords[index].claimedAt == nil {
            taskRecords[index].claimedAt = Date()
        }
        if status == "todo" {
            taskRecords[index].claimedAt = nil
        }
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func convertMessageToTask(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageId = object["messageId"] as? String
        else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        let storedChannelId: String?
        if let known = oauth.messageChannelId(messageId) {
            storedChannelId = known
        } else {
            lock.lock()
            storedChannelId = humanMessageRows.first { $0.id == messageId }?.channelId
            lock.unlock()
        }
        guard let channelId = storedChannelId else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Message not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        let ids = addTasks(channelId: channelId, titles: ["Converted message"], creatorId: userId)
        lock.lock()
        for index in taskRecords.indices where ids.contains(taskRecords[index].id) {
            taskRecords[index].messageId = messageId
        }
        lock.unlock()
        return Self.json(200, "{\"taskIds\":[\("\(ids.map { jsonString($0) }.joined(separator: ","))")]}")
    }

    @discardableResult
    public func addTaskWithDescriptionForTesting(channelId: String, title: String, description: String) -> String {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        let id = UUID().uuidString.lowercased()
        taskRecords.append(TaskRecord(
            id: id, channelId: channelId, title: title, description: description,
            status: "todo", taskNumber: taskNumber, messageId: UUID().uuidString.lowercased(),
            createdAt: Date()
        ))
        lock.unlock()
        return id
    }

    public func lastTaskServerQueryForTesting() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastTaskServerQuery
    }

    public func lastTaskServerWarningForTesting() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastTaskServerWarning
    }

    static let tasksServerResponseWarnBytes = 8 * 1024 * 1024

    func taskServerReply(_ body: String, serverId: String, newShape: Bool) -> HTTPReply {
        let bytes = Data(body.utf8).count
        if newShape, bytes > Self.tasksServerResponseWarnBytes {
            let warning = "[tasks/server] paginated/summary response for server \(serverId) is \(bytes) bytes"
            lock.lock()
            lastTaskServerWarning = warning
            lock.unlock()
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        return HTTPReply(status: 200, headers: [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(bytes),
            "x-response-bytes": String(bytes),
        ], body: body)
    }

    public func listServerTasks(authorization: String?, serverId: String, rawQuery: String?) -> HTTPReply {
        lock.lock()
        lastTaskServerQuery = rawQuery
        lock.unlock()
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        func repeated(_ name: String) -> Bool {
            guard let rawQuery else { return false }
            return rawQuery.split(separator: "&").filter { $0.hasPrefix(name + "=") }.count > 1
        }
        if ["limit", "cursor", "detail", "status"].contains(where: repeated) {
            return Self.json(400, "{\"error\":\"Repeated query parameter\"}")
        }
        let status: String?
        switch Self.taskStatusFilter(rawQuery) {
        case .invalid(let reply): return reply
        case .valid(let value): status = value
        }
        guard let rawQuery else {
            let body = legacyTasksBody(serverId: serverId, userId: userId, status: status)
            return taskServerReply(body, serverId: serverId, newShape: false)
        }
        var params: [String: String] = [:]
        for pair in rawQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        let detail = params["detail"] ?? "full"
        guard detail == "full" || detail == "summary" else {
            return Self.json(400, "{\"error\":\"detail must be full or summary\"}")
        }
        var limit: Int?
        if let rawLimit = params["limit"] {
            guard let value = Int(rawLimit), (1...500).contains(value) else {
                return Self.json(400, "{\"error\":\"limit must be between 1 and 500\"}")
            }
            limit = value
        }
        var cursor: (channelId: String, taskNumber: Int)?
        if let rawCursor = params["cursor"] {
            guard limit != nil else {
                return Self.json(400, "{\"error\":\"cursor requires limit\"}")
            }
            guard let decoded = Self.decodeCursor(rawCursor) else {
                return Self.json(400, "{\"error\":\"Invalid cursor\"}")
            }
            cursor = decoded
        }
        let ordered = orderedTasks(serverId: serverId, userId: userId, status: status)
        var startIndex = 0
        if let cursor {
            guard let index = ordered.firstIndex(where: {
                $0.task.channelId == cursor.channelId && $0.task.taskNumber == cursor.taskNumber
            }) else {
                return Self.json(400, "{\"error\":\"Invalid cursor\"}")
            }
            startIndex = index + 1
        }
        var page = ordered
        var nextCursor: String?
        if let limit {
            let slice = Array(ordered.dropFirst(startIndex).prefix(limit))
            page = slice
            if let last = slice.last, startIndex + slice.count < ordered.count {
                nextCursor = Self.encodeCursor(channelId: last.task.channelId, taskNumber: last.task.taskNumber)
            }
        } else {
            page = Array(ordered.dropFirst(0))
        }
        let items = page.map { entry in
            detail == "summary"
                ? summaryTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
                : fullTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
        }.joined(separator: ",")
        if limit == nil {
            return taskServerReply("{\"tasks\":[\("\(items)")]}", serverId: serverId, newShape: true)
        }
        let cursorJSON = nextCursor.map { jsonString($0) } ?? "null"
        return taskServerReply("{\"tasks\":[\("\(items)")],\"next_cursor\":\(cursorJSON)}", serverId: serverId, newShape: true)
    }

}
