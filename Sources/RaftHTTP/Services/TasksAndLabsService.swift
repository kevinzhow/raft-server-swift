import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Server tasks, assignee routing, lab enrollment and workspace analytics.
///
/// These handlers were lifted from `EmailLogin+ServerMembersAndTasks2.swift`.
/// They stay on `EmailLoginDirectory` because the directory owns the lock and
/// the task/lab ledgers; `TasksAndLabsService` is the named, `Sendable` handle
/// for the domain.
public struct TasksAndLabsService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {


    public func listChannelTasks(authorization: String?, serverId: String, channelId: String, rawQuery: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let status: String?
        switch Self.taskStatusFilter(rawQuery) {
        case .invalid(let reply): return reply
        case .valid(let value): status = value
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Channel not found\"}")
        case .readOnly, .write: break
        }
        lock.lock()
        let rows = taskRecords.filter {
            $0.channelId == channelId && (status == nil || $0.status == status)
        }
        lock.unlock()
        let items = rows.map { taskJSON($0) }.joined(separator: ",")
        return Self.json(200, "{\"tasks\":[\("\(items)")]}")
    }

    public func getChannelTaskByNumber(authorization: String?, serverId: String, channelId: String, taskNumber: Int) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Channel not found\"}")
        case .readOnly, .write: break
        }
        lock.lock()
        let task = taskRecords.first { $0.channelId == channelId && $0.taskNumber == taskNumber }
        lock.unlock()
        guard let task else { return Self.json(404, "{\"error\":\"Task not found\"}") }
        return Self.json(200, "{\"task\":\(taskJSON(task))}")
    }

    public func agentTasksAmend(authorization: String?, legacyAgentId: String?, body: String) -> HTTPReply {
        let auth: (agentId: String, serverId: String)
        switch agentTaskAuth(authorization: authorization, legacyAgentId: legacyAgentId) {
        case .refused(let reply): return reply
        case .ok(let agentId, let serverId): auth = (agentId, serverId)
        }
        if let reply = agentGrantDenial(agentId: auth.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: auth.serverId, agentId: auth.agentId, reference: channelRef),
              let taskNumber = (object["task_number"] as? NSNumber)?.intValue,
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid task request\"}")
        }
        let description = object["description"] as? String
        if let hold = taskWriteFreshnessHold(
            agentId: auth.agentId, channelId: channelId,
            seenUpToSeq: object["seenUpToSeq"] as? Int, actionKey: "amend:\(taskNumber)"
        ) { return hold }
        if let hold = taskWriteFreshnessHold(
            agentId: auth.agentId, channelId: channelId,
            seenUpToSeq: object["seenUpToSeq"] as? Int, actionKey: "amend:\(taskNumber)"
        ) { return hold }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        taskRecords[index].title = title
        if let description { taskRecords[index].description = description }
        taskRecords[index].revision += 1
        taskRecords[index].updatedAt = Date()
        taskRecords[index].amendedAt = Date()
        taskRecords[index].amendedByType = "agent"
        taskRecords[index].amendedByName = oauth.agentRuntimeInfo(id: auth.agentId)?.name ?? "agent"
        taskRecords[index].superseded = true
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func assignTask(authorization: String?, serverId: String, taskId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid assignment\"}")
        }
        guard object["assignee"] != nil else {
            return Self.json(400, "{\"error\":\"Invalid assignment\"}")
        }
        let assignee: (type: String, id: String)?
        if object["assignee"] is NSNull {
            assignee = nil
        } else if let raw = object["assignee"] as? [String: Any],
                  let type = raw["type"] as? String, type == "user" || type == "agent",
                  let id = raw["id"] as? String, !id.isEmpty {
            assignee = (type, id)
        } else {
            return Self.json(400, "{\"error\":\"Invalid assignment\"}")
        }
        var expectedRevision: Int?
        if let rawRevision = object["expectedRevision"], !(rawRevision is NSNull) {
            guard let parsed = rawRevision as? Int else {
                return Self.json(400, "{\"error\":\"expectedRevision must be an integer\"}")
            }
            expectedRevision = parsed
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if (oauth.channelType(id: channelId) ?? "channel") != "channel",
           !oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        if let assignee {
            if assignee.type == "user" {
                guard oauth.isChannelParticipant(channelId: channelId, userId: assignee.id),
                      oauth.memberRole(serverId: serverId, userId: assignee.id) != nil
                else {
                    return Self.json(409, "{\"error\":\"Assignee is not in this channel\"}")
                }
            } else {
                guard let agent = oauth.agentRuntimeInfo(id: assignee.id), agent.serverId == serverId, !agent.deleted else {
                    return Self.json(409, "{\"error\":\"Assignee is not in this channel\"}")
                }
            }
        }
        lock.lock()
        guard taskRecords[index].status != "done" else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"A done task cannot be reassigned\"}")
        }
        let currentRevision = taskRecords[index].revision
        if let expectedRevision, expectedRevision != currentRevision {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Task changed concurrently\",\"currentRevision\":\(currentRevision)}")
        }
        let sameAssignee = taskRecords[index].assigneeId == assignee?.id
            && taskRecords[index].assigneeType == assignee?.type
        if sameAssignee {
            let task = taskRecords[index]
            lock.unlock()
            return Self.json(200, taskJSON(task))
        }
        let previousAssigneeId = taskRecords[index].assigneeId
        let previousAssigneeType = taskRecords[index].assigneeType
        taskRecords[index].assigneeId = assignee?.id
        taskRecords[index].assigneeType = assignee?.type
        taskRecords[index].claimedAt = nil
        taskRecords[index].revision += 1
        assigneeChangeEvents.append((
            taskId: taskId, assigneeId: assignee?.id, assigneeType: assignee?.type,
            previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType,
            actorType: "user", actorId: userId
        ))
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    func archivedChannelReply(_ channelId: String) -> HTTPReply? {
        guard oauth.channelArchivedAt(id: channelId) != nil else { return nil }
        return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
    }

    public func setChannelArchivedRoute(authorization: String?, serverId: String, channelId: String, archived: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let channelAdmin = channelHumanRoles["\(channelId)\n\(userId)"] == "admin"
        let jointArchive = jointProjections.contains { $0.localChannelId == channelId }
        lock.unlock()
        guard role == "owner" || role == "admin" || channelAdmin else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if jointArchive, role != "owner", role != "admin" {
            return Self.json(403, "{\"error\":\"Only a server admin can archive a joint channel\",\"code\":\"joint_channel_admin_limited\"}")
        }
        let existing = oauth.channelArchivedAt(id: channelId)
        if archived {
            if existing == nil {
                let now = Date()
                oauth.setChannelArchived(id: channelId, archivedAt: now)
            }
            lock.lock()
            postableChannels[channelId]?.archived = true
            for (id, var postable) in postableChannels where postable.parentChannelId == channelId {
                postable.archived = true
                postableChannels[id] = postable
            }
            lock.unlock()
        } else {
            oauth.setChannelArchived(id: channelId, archivedAt: nil)
            lock.lock()
            postableChannels[channelId]?.archived = false
            for (id, var postable) in postableChannels where postable.parentChannelId == channelId {
                postable.archived = false
                postableChannels[id] = postable
            }
            lock.unlock()
        }
        if let date = oauth.channelArchivedAt(id: channelId) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return Self.json(200, "{\"archivedAt\":\(jsonString(formatter.string(from: date)))}")
        }
        return Self.json(200, "{\"archivedAt\":null}")
    }

    /// Self-service join of a visible plain channel. Private and joint channels
    /// are invitation-only, archived channels refuse writes, and the join posts
    /// a system notice that is born-read for the joining agent.
    func joinPublicChannelForAgent(agentId: String, serverId: String, channelId: String) -> HTTPReply {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if oauth.channelAgentIds(channelId: channelId).contains(agentId) {
            return Self.json(200, "{\"ok\":true}")
        }
        switch oauth.channelType(id: channelId) ?? "channel" {
        case "private":
            return Self.json(403, "{\"error\":\"Private channels require an invitation\"}")
        case "joint":
            return Self.json(403, "{\"error\":\"Joint channels require an invitation\"}")
        default:
            break
        }
        if let reply = agentGrantDenial(agentId: agentId, scope: "channel:join") { return reply }
        guard oauth.agentRole(serverId: serverId, agentId: agentId) != nil else {
            return Self.json(403, "{\"error\":\"Server role cannot join public channels\"}")
        }
        oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        lock.lock()
        let name = oauth.agentRuntimeInfo(id: agentId)?.name ?? agentId
        let seq = appendHumanMessageLocked(StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            senderId: "system",
            content: "@\(name) joined this channel.",
            randomId: nil,
            messageType: "system",
            senderType: "system"
        ))
        let key = "\(channelId)\n\(agentId)"
        let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
        agentChannelReadCursors[key] = (max(previous.seq, seq), previous.version + 1)
        lock.unlock()
        _ = channel
        return Self.json(200, "{\"ok\":true}")
    }

    /// Self-service leave. The virtual #all audience cannot be left; a private
    /// or joint channel with no humans and no agents left is soft-deleted.
    func leaveChannelForAgent(agentId: String, serverId: String, channelId: String) -> HTTPReply {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if oauth.allChannelId(serverId: serverId) == channelId {
            return Self.json(403, "{\"error\":\"Cannot leave the #all channel\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        oauth.removeChannelAgent(channelId: channelId, agentId: agentId)
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(agentId)
        let kind = postableChannels[channelId]?.kind ?? "channel"
        lock.unlock()
        if kind == "private" || kind == "joint" {
            let humans = oauth.channelHumanIds(channelId: channelId)
            let agents = oauth.channelAgentIds(channelId: channelId)
            if humans.isEmpty && agents.isEmpty {
                lock.lock()
                postableChannels[channelId]?.deletedAt = Date()
                lock.unlock()
            }
        }
        _ = channel
        return Self.json(200, "{\"ok\":true}")
    }

    public func agentJoinChannel(authorization: String?, channelId: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.scopes.contains("channels"),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        return joinPublicChannelForAgent(agentId: agent.id, serverId: agent.serverId, channelId: channelId)
    }

    public func joinChannel(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        if oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return Self.json(200, "{\"ok\":true}")
        }
        guard oauth.channelType(id: channelId) == "channel" else {
            return Self.json(403, "{\"error\":\"Private channels are invite-only\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Server role cannot join public channels\"}")
        }
        if oauth.memberRole(serverId: serverId, userId: userId) == "guest" {
            lock.lock()
            let joinable = guestJoinableChannels[channelId] ?? false
            lock.unlock()
            guard joinable else {
                return Self.json(403, "{\"error\":\"This channel does not allow guest joins\"}")
            }
        }
        oauth.addChannelHuman(channelId: channelId, userId: userId)
        return Self.json(200, "{\"ok\":true}")
    }

    func agentCredentialAgent(_ authorization: String?) -> (agentId: String, scopes: [String])? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        guard let credential = agentCredentials[token], credential.revokedAt == nil else { return nil }
        agentCredentials[token]?.lastUsedAt = Date()
        return (credential.agentId, Array(credential.scopes))
    }

    func agentCapabilityDenied(_ error: String) -> HTTPReply {
        Self.json(403, "{\"error\":\(jsonString(error)),\"code\":\"server_role_required\",\"currentRole\":\"member\",\"suggestedNextAction\":\"Ask a server owner or admin to grant the capability; your role is member.\"}")
    }

    /// Identity for the agent channel/server management routes: an
    /// `sk_agent_*` credential must carry the scopes, a legacy machine key uses
    /// the path agent id.
    func agentWriterAndRole(
        authorization: String?,
        legacyAgentId: String?,
        scopes: [String]
    ) -> (agent: OAuthLedger.AgentRuntimeInfo, role: String?)? {
        lock.lock()
        let token = authorization?.hasPrefix("Bearer ") == true ? String(authorization!.dropFirst("Bearer ".count)) : ""
        let credential = agentCredentials[token]
        let machine = machines.first { $0.apiKey == token }
        let legacyMachineKeys = machineKeys
        lock.unlock()
        if let credential, credential.revokedAt == nil {
            guard scopes.allSatisfy({ credential.scopes.contains($0) }),
                  let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
            else { return nil }
            return (agent, oauth.agentRole(serverId: agent.serverId, agentId: agent.id))
        }
        if let machine, let legacyAgentId, !legacyAgentId.isEmpty,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return (agent, oauth.agentRole(serverId: agent.serverId, agentId: agent.id))
        }
        if let legacy = legacyMachineKeys[token],
           let agent = oauth.agentRuntimeInfo(id: legacy.agentId), !agent.deleted,
           legacy.serverId == agent.serverId {
            return (agent, oauth.agentRole(serverId: agent.serverId, agentId: agent.id))
        }
        return nil
    }

    func agentAndRole(_ authorization: String?, scopes: [String]) -> (agent: OAuthLedger.AgentRuntimeInfo, role: String?)? {
        lock.lock()
        let token = authorization?.hasPrefix("Bearer ") == true ? String(authorization!.dropFirst("Bearer ".count)) : ""
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, scopes.allSatisfy({ credential.scopes.contains($0) }),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return nil }
        return (agent, oauth.agentRole(serverId: agent.serverId, agentId: agent.id))
    }

    public func agentUpdateChannel(authorization: String?, channelId: String, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        guard let writer = agentWriterAndRole(authorization: authorization, legacyAgentId: legacyAgentId, scopes: ["channels"]),
              let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let role = writer.role
        guard role == "owner" || role == "admin" else {
            return agentCapabilityDenied("Agent requires editChannelMetadata or changeChannelVisibility capability to update channels")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel update\"}")
        }
        lock.lock()
        let jointCanonical = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId
        let jointLinkIds = jointCanonical.map { canonical in
            jointProjections.filter { $0.canonicalChannelId == canonical }.map(\.localChannelId)
        } ?? []
        lock.unlock()
        if !jointLinkIds.isEmpty {
            if object["visibility"] != nil {
                return Self.json(403, "{\"error\":\"Joint channel visibility cannot be changed\",\"code\":\"joint_visibility_immutable\"}")
            }
            if let archived = object["archived"] as? Bool {
                for linkId in jointLinkIds {
                    oauth.setChannelArchived(id: linkId, archivedAt: archived ? Date() : nil)
                    lock.lock()
                    postableChannels[linkId]?.archived = archived
                    lock.unlock()
                }
                return Self.json(200, "{\"id\":\(jsonString(channelId)),\"archived\":\(archived ? "true" : "false")}")
            }
            if let raw = object["name"] as? String {
                let newName = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                for linkId in jointLinkIds {
                    _ = oauth.renameChannel(id: linkId, name: newName)
                    lock.lock()
                    postableChannels[linkId]?.name = newName
                    lock.unlock()
                }
                return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(newName)),\"type\":\"joint\"}")
            }
        }
        if object["visibility"] != nil, oauth.allChannelId(serverId: agent.serverId) == channelId {
            return Self.json(403, "{\"error\":\"Only a human can do it, from channel settings or server settings\",\"code\":\"all_channel_visibility_managed_separately\"}")
        }
        if object["visibility"] != nil {
            lock.lock()
            let isMember = postableChannels[channelId]?.memberIds.contains(agent.id) == true
                || channelAgentMembers[channelId]?.contains(agent.id) == true
                || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
            lock.unlock()
            guard isMember || oauth.isChannelParticipant(channelId: channelId, userId: agent.id) else {
                return Self.json(403, "{\"error\":\"You must be a channel member\",\"code\":\"channel_membership_required\"}")
            }
        }
        var name = channel.name
        if let raw = object["name"] as? String {
            name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        }
        var description = channel.description
        if let raw = object["description"] as? String {
            description = raw
        }
        var type = oauth.channelType(id: channelId) ?? "channel"
        if let visibility = object["visibility"] as? String {
            guard ["public", "private"].contains(visibility) else {
                return Self.json(400, "{\"error\":\"Invalid channel visibility\"}")
            }
            type = visibility == "private" ? "private" : "channel"
        }
        _ = oauth.renameChannel(id: channelId, name: name)
        var updatedType = type
        if let current = oauth.channelInfo(id: channelId), current.description != description || type != (oauth.channelType(id: channelId) ?? "channel") {
            _ = oauth.updateChannel(id: channelId, name: nil, description: description, systemMessage: nil)
            if oauth.setChannelType(id: channelId, type: type) { updatedType = type }
        }
        lock.lock()
        postableChannels[channelId]?.name = name
        postableChannels[channelId]?.kind = updatedType
        lock.unlock()
        let descriptionJSON = description.map(jsonString) ?? "null"
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name)),\"description\":\(descriptionJSON),\"type\":\(jsonString(updatedType))}")
    }

    public func agentChannelMemberWrite(authorization: String?, channelId: String, body: String, remove: Bool, legacyAgentId: String? = nil) -> HTTPReply {
        guard let writer = agentWriterAndRole(authorization: authorization, legacyAgentId: legacyAgentId, scopes: ["channels"]),
              let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let role = writer.role
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if remove && role != "owner" && role != "admin" {
            return agentCapabilityDenied("Agent requires removeChannelMembers capability to remove channel members")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel member\"}")
        }
        if let rawUser = object["user"] as? String {
            let userName = rawUser.hasPrefix("@") ? String(rawUser.dropFirst()) : rawUser
            lock.lock()
            let target = accounts.values.first { $0.name == userName || $0.id == userName }?.id
            lock.unlock()
            guard let target, oauth.memberRole(serverId: agent.serverId, userId: target) != nil else {
                return Self.json(404, "{\"error\":\"User not found\"}")
            }
            if remove {
                let wasMember = oauth.channelHumanIds(channelId: channelId).contains(target)
                lock.lock()
                postableChannels[channelId]?.memberIds.remove(target)
                lock.unlock()
                _ = oauth.removeChannelHuman(channelId: channelId, userId: target)
                return Self.json(200, "{\"ok\":true,\"wasMember\":\(wasMember),\"member\":{\"type\":\"human\",\"name\":\(jsonString(userName))}\(memberAttentionJSON)}")
            }
            let already = oauth.channelHumanIds(channelId: channelId).contains(target)
            if !already {
                accountsForInvite(userId: target, serverId: agent.serverId, channelId: channelId)
                lock.lock()
                let noticeSeq = appendHumanMessageLocked(StoredHumanMessage(
                    id: UUID().uuidString.lowercased(),
                    channelId: channelId,
                    senderId: "system",
                    content: "@\(userName) was added to this channel.",
                    randomId: nil,
                    messageType: "system",
                    senderType: "system"
                ))
                // The acting agent made this notice: it is born-read for the
                // actor while the added human keeps it unread.
                let actorKey = "\(channelId)\n\(agent.id)"
                let previous = agentChannelReadCursors[actorKey] ?? (seq: 0, version: 0)
                agentChannelReadCursors[actorKey] = (max(previous.seq, noticeSeq), previous.version + 1)
                lock.unlock()
            }
            return Self.json(200, "{\"ok\":true,\"alreadyMember\":\(already),\"member\":{\"type\":\"human\",\"name\":\(jsonString(userName))}}")
        }
        if let agentName = object["agent"] as? String {
            let target = oauth.activeAgentIds(serverId: agent.serverId).first { oauth.agentRuntimeInfo(id: $0)?.name == agentName || $0 == agentName }
            guard let target else {
                return Self.json(404, "{\"error\":\"Agent not found\"}")
            }
            if remove {
                let wasMember = oauth.channelAgentIds(channelId: channelId).contains(target)
                oauth.removeChannelAgent(channelId: channelId, agentId: target)
                return Self.json(200, "{\"ok\":true,\"wasMember\":\(wasMember),\"member\":{\"type\":\"agent\",\"name\":\(jsonString(agentName))}\(memberAttentionJSON)}")
            }
            let already = oauth.channelAgentIds(channelId: channelId).contains(target)
            if !already {
                oauth.addChannelAgent(channelId: channelId, agentId: target)
            }
            return Self.json(200, "{\"ok\":true,\"alreadyMember\":\(already),\"member\":{\"type\":\"agent\",\"name\":\(jsonString(agentName))}}")
        }
        return Self.json(400, "{\"error\":\"Invalid channel member\"}")
    }

    public func agentUpdateServer(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        guard let writer = agentWriterAndRole(authorization: authorization, legacyAgentId: legacyAgentId, scopes: ["server"]),
              let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let role = writer.role
        guard role == "owner" || role == "admin" else {
            return agentCapabilityDenied("Agent requires editServerSettings capability to edit the server profile")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid server update\"}")
        }
        oauth.updateServerName(id: agent.serverId, name: name)
        return Self.json(200, "{\"ok\":true,\"id\":\(jsonString(agent.serverId)),\"name\":\(jsonString(name))}")
    }

    public func agentChannelMembers(
        authorization: String?,
        agentId: String?,
        channelRef: String?,
        legacyAgentId: String? = nil
    ) -> HTTPReply {
        guard let writer = agentWriterAndRole(
            authorization: authorization,
            legacyAgentId: legacyAgentId ?? agentId,
            scopes: []
        ), let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let reference = (channelRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.hasPrefix("#") else {
            return Self.json(400, "{\"error\":\"channel is required\"}")
        }
        let raw = String(reference.dropFirst())
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? raw
        let shortId = parts.count > 1 ? parts[1] : nil
        lock.lock()
        let parent = postableChannels.first { _, channel in
            channel.serverId == agent.serverId && channel.name == name
                && (channel.kind == "channel" || channel.kind == "joint") && channel.deletedAt == nil
        }?.key
        var targetId = parent
        var type = "channel"
        if let shortId, let parent {
            targetId = postableChannels.first { _, channel in
                channel.serverId == agent.serverId && channel.kind == "thread"
                    && channel.parentChannelId == parent
                    && (channel.parentMessageId?.hasPrefix(shortId) ?? false)
            }?.key
            type = targetId == nil ? "channel" : "thread"
        }
        guard let targetId, let parentId = type == "thread" ? postableChannels[targetId]?.parentChannelId : targetId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        var humanIds = oauth.channelHumanIds(channelId: parentId)
        var agentIds = oauth.channelAgentIds(channelId: parentId)
        if let canonical = jointProjections.first(where: { $0.localChannelId == parentId })?.canonicalChannelId {
            for link in jointProjections where link.canonicalChannelId == canonical {
                humanIds = Array(Set(humanIds).union(oauth.channelHumanIds(channelId: link.localChannelId)))
                agentIds = Array(Set(agentIds).union(oauth.channelAgentIds(channelId: link.localChannelId)))
            }
        }
        let humanNames = Dictionary(uniqueKeysWithValues: humanIds.map { id in
            (id, accounts.values.first { $0.id == id }?.name ?? id)
        })
        lock.unlock()
        lock.lock()
        let jointCanonical = jointProjections.first { $0.localChannelId == parentId }?.canonicalChannelId
        let jointLinks = jointCanonical.map { canonical in
            jointProjections.filter { $0.canonicalChannelId == canonical }
        } ?? []
        lock.unlock()
        func serversJSON(for userId: String) -> String? {
            guard !jointLinks.isEmpty else { return nil }
            var badges: [(name: String, slug: String, yours: Bool)] = []
            for link in jointLinks {
                guard oauth.channelHumanIds(channelId: link.localChannelId).contains(userId),
                      let details = oauth.serverDetailsValue(id: link.serverId)
                else { continue }
                badges.append((details.name, details.slug, link.serverId == agent.serverId))
            }
            badges.sort { $0.yours && !$1.yours }
            guard !badges.isEmpty, badges.contains(where: { !$0.yours }) else { return nil }
            let items = badges.map { badge in
                "{\"name\":\(jsonString(badge.name)),\"slug\":\(jsonString(badge.slug))\("\(badge.yours ? ",\"yours\":true" : "")")}"
            }.joined(separator: ",")
            return "[\(items)]"
        }
        let humans = humanIds.map { id -> String in
            let name = humanNames[id] ?? id
            let role = oauth.memberRole(serverId: agent.serverId, userId: id) ?? "member"
            var row = "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"role\":\(jsonString(role))"
            if let servers = serversJSON(for: id) { row += ",\"servers\":\(servers)" }
            return row + "}"
        }.joined(separator: ",")
        let agents = agentIds.map { id -> String in
            let name = oauth.agentRuntimeInfo(id: id)?.name ?? ""
            return "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"status\":\"active\"}"
        }.joined(separator: ",")
        return Self.json(200, "{\"channel\":{\"ref\":\(jsonString(reference)),\"type\":\(jsonString(type))},\"humans\":[\(humans)],\"agents\":[\(agents)]}")
    }

    public func agentServerInfo(authorization: String?, legacyAgentId: String? = nil) -> HTTPReply {
        guard let writer = agentWriterAndRole(authorization: authorization, legacyAgentId: legacyAgentId, scopes: []),
              let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let profile = oauth.serverProfile(id: agent.serverId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        let role = oauth.agentRole(serverId: agent.serverId, agentId: agent.id)
        lock.lock()
        let machineId = agentMachineIds[agent.id]
        let machine = machineId.flatMap { id in machines.first { $0.id == id } }
        let channels = postableChannels
            .filter {
                $0.value.serverId == agent.serverId
                    && $0.value.deletedAt == nil
                    && !$0.value.archived
                    && oauth.channelArchivedAt(id: $0.key) == nil
                    && $0.value.kind != "dm"
                    && $0.value.kind != "thread"
            }
            .compactMap { id, channel -> (String, String, String, Bool, Int?)? in
                let joined = channel.memberIds.contains(agent.id) || oauth.channelAgentIds(channelId: id).contains(agent.id)
                // Private and joint surfaces stay invisible without membership;
                // public channels are listed too, with their join state.
                if !joined && (channel.kind == "private" || channel.kind == "joint") { return nil }
                let type = channel.kind == "private" || channel.kind == "joint" ? channel.kind : "channel"
                let agentMute = oauth.notificationPrefs(channelId: id, userId: agent.id)
                return (id, channel.name, type, joined, (agentMute.activityMuted ? agentMute.muteFromSeq : nil))
            }
            .sorted { $0.0 < $1.0 }
        let agentRows = oauth.activeAgentIds(serverId: agent.serverId).map { otherId -> String in
            let info = oauth.agentRuntimeInfo(id: otherId)
            let activity = agentActivities[otherId] ?? (activity: "offline", detail: "")
            let otherRole = oauth.agentRole(serverId: agent.serverId, agentId: otherId) ?? "null"
            return "{\"id\":\(jsonString(otherId)),\"name\":\(jsonString(info?.name ?? "")),\"role\":\(otherRole == "null" ? "null" : jsonString(otherRole)),\"status\":\"active\",\"activity\":\(jsonString(activity.activity)),\"activityDetail\":\(jsonString(activity.detail))}"
        }
        lock.unlock()
        let channelJSON = channels.map { id, name, type, joined, muteFromSeq in
            let muteJSON = muteFromSeq.map(String.init) ?? "null"
            return "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"type\":\(jsonString(type)),\"joined\":\(joined),\"activityMuted\":\(muteFromSeq != nil),\"muteFromSeq\":\(muteJSON)}"
        }.joined(separator: ",")
        let roleJSON = role.map { jsonString($0) } ?? "null"
        let machineIdJSON = machine.map { jsonString($0.id) } ?? "null"
        let machineNameJSON = machine.map { jsonString($0.name) } ?? "null"
        let machineDescriptionJSON = machine?.description.map(jsonString) ?? "null"
        let runtimeContext = "{\"agentId\":\(jsonString(agent.id)),\"runtime\":\(jsonString(agent.runtime)),\"model\":\"external\",\"reasoningEffort\":null,\"serverId\":\(jsonString(agent.serverId)),\"machineId\":\(machineIdJSON),\"machineName\":\(machineNameJSON),\"machineDescription\":\(machineDescriptionJSON),\"machineHostname\":null,\"machineOs\":null,\"daemonVersion\":null,\"workspacePath\":null}"
        let body = "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"runtimeContext\":\(runtimeContext),\"serverRole\":\(roleJSON),\"serverCapabilities\":{\"addChannelMembers\":true,\"createChannels\":true},\"channels\":[\(channelJSON)],\"agents\":[\(agentRows.joined(separator: ","))]}"
        return Self.json(200, body)
    }

    public func agentResolveChannel(authorization: String?, body: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "send") { return denial }
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String, target.hasPrefix("#")
        else {
            return Self.json(400, "{\"error\":\"Invalid target\"}")
        }
        let name = String(target.dropFirst())
        lock.lock()
        let channelId = postableChannels.first { _, channel in
            channel.serverId == agent.serverId && channel.name == name && channel.deletedAt == nil
        }?.key
        lock.unlock()
        guard let channelId, let channel = oauth.channelInfo(id: channelId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        lock.lock()
        let joined = postableChannels[channelId]?.memberIds.contains(agent.id) == true
            || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
        lock.unlock()
        guard type == "channel" || joined else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        return Self.json(200, "{\"channelId\":\(jsonString(channelId)),\"type\":\(jsonString(type))}")
    }

    public func agentCreateChannel(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        guard let writer = agentWriterAndRole(authorization: authorization, legacyAgentId: legacyAgentId, scopes: ["channels"]),
              let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid channel\"}")
        }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil else {
            return Self.json(400, "{\"error\":\"Invalid channel\"}")
        }
        let visibility = (object["visibility"] as? String) ?? "public"
        guard ["public", "private"].contains(visibility) else {
            return Self.json(400, "{\"error\":\"Invalid channel visibility\"}")
        }
        guard let role = writer.role else {
            return Self.json(403, "{\"error\":\"Agent requires createChannels capability to create channels\",\"code\":\"server_role_required\",\"suggestedNextAction\":\"To create channels you need the member role on this server; you are not a member of this server. Ask a server owner or admin to do it, or to change your role.\",\"requiredCapabilities\":[\"createChannels\"],\"requiredRole\":\"member\",\"currentRole\":null}")
        }
        let description = object["description"] as? String
        let type = visibility == "private" ? "private" : "channel"
        let channelId = oauth.createChannel(serverId: agent.serverId, name: name, creatorUserId: agent.id, type: type, description: description)
        oauth.removeChannelHuman(channelId: channelId, userId: agent.id)
        oauth.addChannelAgent(channelId: channelId, agentId: agent.id)
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: agent.serverId, memberIds: [], kind: type, name: name)
        lock.unlock()
        _ = role
        let descriptionJSON = description.map(jsonString) ?? "null"
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name)),\"type\":\(jsonString(type)),\"description\":\(descriptionJSON),\"joined\":true,\"createdByAgentId\":\(jsonString(agent.id))}")
    }

    // MARK: - Task rows shared with the unmigrated task domains

    /// One task row in the published order. The `requiresResourceReceipt`
    /// member is omitted unless the row carries it.
    func taskJSON(_ task: TaskRecord) -> String {
        let assignee = task.assigneeId.map { jsonString($0) } ?? "null"
        let assigneeType = task.assigneeType.map { jsonString($0) } ?? "null"
        let claimed = task.claimedAt.map { jsonString(ISO8601DateFormatter().string(from: $0)) } ?? "null"
        return "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"messageId\":\(jsonString(task.messageId)),\"title\":\(jsonString(task.title)),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"claimedById\":\(assignee),\"claimedByType\":\(assigneeType),\"claimedAt\":\(claimed),\"revision\":\(task.revision)\(task.requiresResourceReceipt ? ",\"requiresResourceReceipt\":true" : "")}"
    }

    /// The channel write policy `GET`/`POST` task routes share.
    func taskChannelAccess(serverId: String, channelId: String, userId: String) -> TaskChannelAccess {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return .missing
        }
        if oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return .write
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        return type == "channel" ? .readOnly : .missing
    }

    /// Public projection of `taskChannelAccess` for the channel-messaging
    /// service until the channel policy moves into its own store.
    public func channelTaskAccess(serverId: String, channelId: String, userId: String) -> ChannelTaskAccess {
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing:
            .missing
        case .readOnly:
            .readOnly
        case .write:
            .write
        }
    }

    public func addTasks(
        channelId: String, titles: [String], descriptions: [String?]? = nil,
        creatorId: String? = nil, creatorType: String = "user"
    ) -> [String] {
        // The directory lock keeps this append ordered with the readers that
        // still snapshot `taskRecords`; the store method itself is one locked
        // read-modify-write for the row array. `creatorType` is accepted for
        // callers but the row has no column for it, as before.
        lock.lock()
        defer { lock.unlock() }
        return tasksAndRemindersStore.appendTasks(
            channelId: channelId,
            titles: titles,
            descriptions: descriptions,
            creatorId: creatorId
        )
    }

}
