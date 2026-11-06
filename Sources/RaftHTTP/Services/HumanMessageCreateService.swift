import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The human-message create boundary: the v1 create route, the sender-side
/// mention actions it leaves pending, and the forward lookup plus forward write.
///
/// The state transitions stay on `EmailLoginDirectory` with unchanged
/// signatures, so every existing caller and test compiles untouched. This type
/// is the `Service` boundary the routes call; the raw body stays the input
/// because a create body publishes a per-key `issues` list.
public struct HumanMessageCreateService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// `POST /api/messages`.
    public func createHumanMessage(
        body: String,
        authorization: String?,
        serverId: String?,
        contract: String = "v1"
    ) -> HTTPReply {
        directory.createHumanMessage(
            body: body,
            authorization: authorization,
            serverId: serverId,
            contract: contract
        )
    }

    /// `POST /api/messages/mention-actions/execute`.
    public func executeMentionActions(
        body: String,
        authorization: String?,
        serverId: String?
    ) -> HTTPReply {
        directory.executeMentionActions(
            body: body,
            authorization: authorization,
            serverId: serverId
        )
    }

    /// `GET /internal/agent-api/mention-actions/pending`.
    public func agentMentionActionsPending(authorization: String?) -> HTTPReply {
        directory.agentMentionActionsPending(authorization: authorization)
    }

    /// `GET /api/messages/forward/targets/search`.
    public func searchForwardTargets(
        query: String?,
        limit: String?,
        authorization: String?,
        serverId: String?
    ) -> HTTPReply {
        directory.searchForwardTargets(
            query: query,
            limit: limit,
            authorization: authorization,
            serverId: serverId
        )
    }

    /// `GET /api/messages/forward/enabled`.
    public func messageForwardEnabled(authorization: String?, serverId: String?) -> HTTPReply {
        directory.messageForwardEnabled(authorization: authorization, serverId: serverId)
    }

    /// `POST /api/messages/forward`.
    public func forwardHumanMessage(
        body: String,
        authorization: String?,
        serverId: String?
    ) -> HTTPReply {
        directory.forwardHumanMessage(
            body: body,
            authorization: authorization,
            serverId: serverId
        )
    }

    /// Turns on Computer and App references for one server.
    public func allowComposerResourceReferences(serverId: String) {
        directory.allowComposerResourceReferences(serverId: serverId)
    }
}

extension EmailLoginDirectory {
    /// Turns on Computer and App references for one server. Installed apps stay empty until recorded separately.
    public func allowComposerResourceReferences(serverId: String) {
        lock.lock()
        composerResourceServers.insert(serverId)
        lock.unlock()
    }

    /// Whether a stored mention is still a pending sender-side action.
    func pendingAgentMentionLocked(_ mention: StoredMention, agentId: String) -> Bool {
        guard mention.senderId == agentId,
              mention.notifiedAt == nil,
              !mention.notifiableAtSend,
              Date().timeIntervalSince(mention.createdAt) < 7 * 24 * 60 * 60,
              let channel = postableChannels[mention.channelId],
              channel.serverId == pendingAgentMentionServer(agentId: agentId),
              humanMessageRows.contains(where: { $0.id == mention.messageId })
        else { return false }
        return true
    }

    func pendingAgentMentionServer(agentId: String) -> String? {
        oauth.agentRuntimeInfo(id: agentId)?.serverId
    }

    /// `GET /internal/agent-api/mention-actions/pending`. Sender-side outsider
    /// mentions authored by the bound agent whose delivery was withheld.
    public func agentMentionActionsPending(authorization: String?) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            lock.lock()
            var rows = storedMentions.filter { pendingAgentMentionLocked($0, agentId: agentId) }
            rows.sort { $0.createdAt > $1.createdAt }
            let limit = 50
            let hasMore = rows.count > limit
            let page = rows.prefix(limit).map { mention -> String in
                let channelName = postableChannels[mention.channelId]?.name ?? ""
                return "{\"resolutionId\":\(jsonString(mention.id)),\"messageId\":\(jsonString(mention.messageId)),\"channelId\":\(jsonString(mention.channelId)),\"channelName\":\(jsonString(channelName)),\"targetType\":\(jsonString(mention.targetType)),\"targetId\":\(jsonString(mention.targetId)),\"targetHandle\":\(jsonString(mention.handle)),\"availableActions\":[\"notify\"]}"
            }
            lock.unlock()
            return Self.json(200, "{\"pendingMentionActions\":[\(page.joined(separator: ","))],\"has_more\":\(hasMore)}")
        }
    }

    /// `POST /internal/agent-api/mention-actions/execute`. Every id is
    /// revalidated at action time and returns a typed per-id status.
    public func agentMentionActionsExecute(authorization: String?, body: String) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
            guard let action = object["action"] as? String, action == "notify" || action == "add" else {
                return Self.json(400, "{\"error\":\"action must be notify or add\"}")
            }
            var seen = Set<String>()
            var ids: [String] = []
            let rawIds = (object["resolutionIds"] as? [Any]) ?? (object["ids"] as? [Any]) ?? []
            for raw in rawIds {
                guard let text = raw as? String else { continue }
                let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                ids.append(id)
                if ids.count == 100 { break }
            }
            guard !ids.isEmpty else {
                return Self.json(400, "{\"error\":\"resolutionIds must include at least one id\"}")
            }
            lock.lock()
            defer { lock.unlock() }
            var results: [String] = []
            for id in ids {
                guard let index = storedMentions.firstIndex(where: { $0.id == id }),
                      storedMentions[index].senderId == agentId,
                      postableChannels[storedMentions[index].channelId]?.serverId == agent.serverId,
                      humanMessageRows.contains(where: { $0.id == storedMentions[index].messageId })
                else {
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\(jsonString(action)),\"status\":\"not_found\"}")
                    continue
                }
                if action == "notify" {
                    guard mentionTargetCanReadLocked(
                        channelId: storedMentions[index].channelId,
                        targetType: storedMentions[index].targetType,
                        targetId: storedMentions[index].targetId
                    ) else {
                        results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"no_permission\",\"reason\":\"target_lacks_read_access\"}")
                        continue
                    }
                    let messageId = storedMentions[index].messageId
                    let targetType = storedMentions[index].targetType
                    let targetId = storedMentions[index].targetId
                    var deduped = [id]
                    for other in storedMentions.indices where storedMentions[other].messageId == messageId
                        && storedMentions[other].targetType == targetType
                        && storedMentions[other].targetId == targetId
                        && storedMentions[other].notifiedAt == nil {
                        storedMentions[other].notifiedAt = Date()
                        storedMentions[other].notifiedByType = "agent"
                        storedMentions[other].notifiedById = agentId
                        storedMentions[other].notifiedAction = "notify_only"
                        if storedMentions[other].id != id { deduped.append(storedMentions[other].id) }
                    }
                    let dedupedJSON = deduped.map(jsonString).joined(separator: ",")
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"queued\",\"dedupedResolutionIds\":[\(dedupedJSON)]}")
                } else {
                    let senderStillVisible = mentionSenderStillInChannelLocked(
                        channelId: storedMentions[index].channelId,
                        agentId: agentId
                    )
                    guard senderStillVisible else {
                        results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"no_permission\",\"reason\":\"sender_lacks_channel_access\"}")
                        continue
                    }
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"no_permission\",\"reason\":\"add_requires_human_member_authority\"}")
                }
            }
            return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action)),\"results\":[\(results.joined(separator: ","))]}")
        }
    }

    /// `add` authority is participant-scoped: an agent that only has read
    /// access to a public channel is not a channel member for this action.
    func mentionSenderStillInChannelLocked(channelId: String, agentId: String) -> Bool {
        guard let channel = postableChannels[channelId] else { return false }
        return channel.memberIds.contains(agentId) || oauth.channelAgentIds(channelId: channelId).contains(agentId)
    }

    /// `POST /api/messages/mention-actions/execute`. A resolution id belongs to the sender who wrote the mention.
    public func executeMentionActions(body: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String,
              action == "notify" || action == "add"
        else {
            return Self.json(400, "{\"error\":\"action must be notify or add\"}")
        }
        var seen = Set<String>()
        var resolutionIds: [String] = []
        for id in (object["resolutionIds"] as? [Any])?.compactMap({ $0 as? String }) ?? [] where !seen.contains(id) {
            seen.insert(id)
            resolutionIds.append(id)
            if resolutionIds.count == 100 { break }
        }
        if resolutionIds.isEmpty {
            return Self.json(400, "{\"error\":\"resolutionIds must include at least one id\"}")
        }
        var results: [String] = []
        for id in resolutionIds {
            guard let index = storedMentions.firstIndex(where: { $0.id == id }),
                  postableChannels[storedMentions[index].channelId]?.serverId == serverId,
                  storedMentions[index].senderId == userId
            else {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\(jsonString(action)),\"status\":\"not_found\"}")
                continue
            }
            if action == "notify" {
                if !mentionTargetCanReadLocked(
                    channelId: storedMentions[index].channelId,
                    targetType: storedMentions[index].targetType,
                    targetId: storedMentions[index].targetId
                ) {
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"no_permission\",\"reason\":\"target_lacks_read_access\"}")
                    continue
                }
                if storedMentions[index].notifiedAt == nil {
                    storedMentions[index].notifiedAt = Date()
                    storedMentions[index].notifiedByType = "user"
                    storedMentions[index].notifiedById = userId
                    storedMentions[index].notifiedAction = "notify_only"
                    if storedMentions[index].targetType == "agent" {
                        storedAgentDeliveries.append((
                            agentId: storedMentions[index].targetId,
                            messageId: storedMentions[index].messageId,
                            channelType: "channel"
                        ))
                    }
                }
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"queued\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            } else if storedMentions[index].notifiedAction == "add" {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"delivered\",\"reason\":\"already_delivered\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            } else if !senderStillInChannelLocked(channelId: storedMentions[index].channelId, userId: userId) {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"no_permission\",\"reason\":\"sender_lacks_channel_access\"}")
            } else {
                storedMentions[index].notifiedAt = Date()
                storedMentions[index].notifiedByType = "user"
                storedMentions[index].notifiedById = userId
                storedMentions[index].notifiedAction = "add"
                let targetId = storedMentions[index].targetId
                let mentionChannelId = storedMentions[index].channelId
                if storedMentions[index].targetType == "agent" {
                    var agents = channelAgentMembers[mentionChannelId] ?? []
                    agents.insert(targetId)
                    channelAgentMembers[mentionChannelId] = agents
                    storedAgentDeliveries.append((
                        agentId: targetId,
                        messageId: storedMentions[index].messageId,
                        channelType: "channel"
                    ))
                } else {
                    postableChannels[mentionChannelId]?.memberIds.insert(targetId)
                }
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"delivered\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            }
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action)),\"results\":[\(results.joined(separator: ","))]}")
    }

    /// A removed channel member can no longer add someone through a mention they sent earlier.
    func senderStillInChannelLocked(channelId: String, userId: String) -> Bool {
        guard let stored = postableChannels[channelId] else { return false }
        if stored.kind == "thread", let parentId = stored.parentChannelId, let parent = postableChannels[parentId] {
            return parent.memberIds.contains(userId)
        }
        return stored.memberIds.contains(userId)
    }

    /// Public channels are readable by any signed-in user. Private surfaces and their threads require membership.
    func mentionTargetCanReadLocked(channelId: String, targetType: String, targetId: String) -> Bool {
        guard let stored = postableChannels[channelId] else { return false }
        let surface: PostableChannel
        let surfaceId: String
        if stored.kind == "thread", let parentId = stored.parentChannelId, let parent = postableChannels[parentId] {
            surface = parent
            surfaceId = parentId
        } else {
            surface = stored
            surfaceId = channelId
        }
        if targetType == "agent" {
            if surface.kind == "channel" { return true }
            return channelAgentMembers[surfaceId]?.contains(targetId) == true
                || channelAgentMembers[channelId]?.contains(targetId) == true
        }
        if surface.kind == "channel" { return true }
        return surface.memberIds.contains(targetId) || stored.memberIds.contains(targetId)
    }

    /// `POST /api/messages`. A bad human create body is refused before any message row exists.
    /// An App reference is refused before persistence when that app is not installed on the channel's server.
    public func createHumanMessage(body: String, authorization: String?, serverId: String?, contract: String = "v1") -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        if let serverId, !serverId.isEmpty,
           !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard Self.humanMessageBodyIsValid(body) else {
            return Self.json(400, "{\"error\":\"Invalid message request body\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelId = object["channelId"] as? String,
              let content = object["content"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid message request body\"}")
        }
        if let asTask = object["asTask"], !(asTask is Bool) {
            return Self.json(400, "{\"error\":\"asTask must be a boolean\"}")
        }
        lock.lock()
        let channel = postableChannels[channelId]
        let referencesEnabled = composerResourceServers.contains(channel?.serverId ?? "")
        let installed = installedServerApps[channel?.serverId ?? ""] ?? []
        lock.unlock()
        guard let channel, channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let parentMember = channel.kind == "thread"
            && (channel.parentChannelId.flatMap { postableChannels[$0] }?.memberIds.contains(userId) ?? false)
        guard channel.memberIds.contains(userId) || parentMember else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        // A thread inherits its parent's freeze: no writes under an archived parent.
        let parentArchived = channel.kind == "thread"
            && channel.parentChannelId.flatMap { oauth.channelArchivedAt(id: $0) } != nil
        if channel.archived || parentArchived {
            if oauth.memberRole(serverId: channel.serverId, userId: userId) == "guest" {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
        }
        let appIds = Self.appReferenceIds(content)
        if !appIds.isEmpty {
            if !referencesEnabled {
                return Self.json(400, "{\"error\":\"Computer and App references are not enabled in this server\"}")
            }
            if appIds.contains(where: { !installed.contains($0) }) {
                return Self.json(400, "{\"error\":\"App reference is not installed in this server\"}")
            }
        }
        let attachmentIds = (object["attachmentIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let typedMentions = Self.mentionInputs(object["mentions"])
        if Self.mentionBindingConflict(typedMentions) {
            return Self.json(400, "{\"error\":\"A mention handle is bound to more than one target\",\"code\":\"mention_binding_conflict\"}")
        }
        let mentionResolution = resolvedMessageMentions(
            serverId: serverId ?? "",
            senderId: userId,
            content: content,
            typed: typedMentions,
            warnUnresolved: contract == "v2"
        )
        let mentions = mentionResolution.mentions
        let unresolvedMentionHandles = mentionResolution.unresolved
        let senderTimezone = Self.parseOptionalIanaTimezone(object["timezone"])
        let reply: HTTPReply
        var createdMessage = false
        if object["randomId"] != nil {
            guard let randomId = object["randomId"] as? String, !randomId.isEmpty, randomId.count <= 128 else {
                return Self.json(400, "{\"error\":\"randomId must be a non-empty string with at most 128 characters\"}")
            }
            let stored = storeHumanMessage(channelId: channelId, senderId: userId, content: content, randomId: randomId, attachmentIds: attachmentIds, senderTimezone: senderTimezone, mentions: mentions)
            reply = stored.reply
            createdMessage = stored.created
        } else {
            let stored = storeHumanMessage(channelId: channelId, senderId: userId, content: content, randomId: nil, attachmentIds: attachmentIds, senderTimezone: senderTimezone, mentions: mentions)
            reply = stored.reply
            createdMessage = stored.created
        }
        if createdMessage, reply.status == 200,
           let data = reply.body.data(using: .utf8),
           let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messageId = stored["id"] as? String {
            recordMemberMentionRows(messageId: messageId, channelId: channelId, mentions: mentions)
        }
        if reply.status == 200, channel.kind == "thread", let parentMessageId = channel.parentMessageId {
            lock.lock()
            threadFollows["\(serverId ?? "")\n\(userId)\n\(channelId)"] = (
                serverId: serverId ?? "",
                userId: userId,
                threadChannelId: channelId,
                parentMessageId: parentMessageId
            )
            for mention in mentions where mention.type == "user" || mention.type == "agent" {
                guard ServerScope.isUUID(mention.id), mention.id != userId else { continue }
                let parent = channel.parentChannelId.flatMap { postableChannels[$0] }
                let parentAllowsHuman = parent?.kind == "channel" || parent?.memberIds.contains(mention.id) == true
                let parentAllowsAgent = parent?.kind == "channel"
                    || parent?.agentId == mention.id
                    || channel.parentChannelId.flatMap { channelAgentMembers[$0]?.contains(mention.id) } == true
                let valid: Bool
                if mention.type == "user" {
                    valid = parentAllowsHuman
                        && accounts.values.contains { $0.id == mention.id }
                        && oauth.memberRole(serverId: serverId ?? "", userId: mention.id) != nil
                } else {
                    valid = parentAllowsAgent
                        && oauth.agentRuntimeInfo(id: mention.id)?.serverId == serverId
                }
                if valid {
                    let suppressionKey = "\(serverId ?? "")\n\(mention.id)\n\(channelId)"
                    if threadUnfollows[suppressionKey] != nil {
                        // A direct mention reactivates a suppressed thread only for
                        // a member of the parent channel. An outsider mention stays
                        // hidden; it must not resurrect the follow.
                        guard channel.parentChannelId.flatMap({ postableChannels[$0] })?.memberIds.contains(mention.id) == true else {
                            continue
                        }
                        threadUnfollows.removeValue(forKey: suppressionKey)
                    }
                    threadFollows["\(serverId ?? "")\n\(mention.id)\n\(channelId)"] = (
                        serverId: serverId ?? "",
                        userId: mention.id,
                        threadChannelId: channelId,
                        parentMessageId: parentMessageId
                    )
                }
            }
            lock.unlock()
        }
        if contract == "v2" {
            return v2HumanSend(reply, channelId: channelId, mentions: mentions, unresolvedMentionHandles: unresolvedMentionHandles)
        }
        return withPendingMentionActions(reply, channelId: channelId, mentions: mentions)
    }

    /// `GET /api/messages/forward/enabled`. The rollout flag is retired, so this stays true.
    public func messageForwardEnabled(authorization: String?, serverId: String?) -> HTTPReply {
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let userId):
            guard isEmailVerified(userId: userId) else {
                return Self.json(403, "{\"error\":\"Email verification required\"}")
            }
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        return Self.json(200, "{\"enabled\":true}")
    }

    /// `GET /api/messages/forward/targets/search`. An empty query returns no targets.
    public func searchForwardTargets(query: String?, limit rawLimit: String?, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        lock.lock()
        let retired = accounts.values.first { $0.id == userId }?.retiredAt != nil
        lock.unlock()
        guard !retired else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return Self.json(200, "{\"targets\":[]}")
        }
        let pageLimit: Int
        if let rawLimit, let parsed = Int(rawLimit), parsed > 0 {
            pageLimit = min(parsed, 20)
        } else {
            pageLimit = 20
        }
        lock.lock()
        defer { lock.unlock() }
        let role = serverMemberRoles["\(serverId)\n\(userId)"]
        let isGuest = role == "guest"
        let hideHumans = hideHumansFromMembers[serverId] == true || isGuest
        var results: [(score: Int, title: String, json: String)] = []
        for (id, channel) in postableChannels where channel.serverId == serverId && channel.deletedAt == nil && !channel.archived {
            guard channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint" else { continue }
            let score = Self.forwardTargetScore(q, channel.name.lowercased())
            if score <= 0 { continue }
            let joined = channel.memberIds.contains(userId)
            if isGuest && !joined { continue }
            if channel.kind != "channel" && !joined { continue }
            let canForwardNow = channel.kind != "channel" || joined
            let required = channel.kind == "channel" && !joined ? "join_channel" : nil
            let title = "#\(channel.name)"
            results.append((
                score + (joined ? 50 : 0),
                title,
                Self.forwardTargetJSON(
                    type: "channel",
                    channelType: channel.kind,
                    id: id,
                    title: title,
                    subtitle: "",
                    avatarUrl: nil,
                    channelId: id,
                    joined: joined,
                    dmExists: nil,
                    canForwardNow: canForwardNow,
                    requiredAction: required
                )
            ))
        }
        var dmPeerIds = Set<String>()
        for (id, channel) in postableChannels where channel.serverId == serverId && channel.kind == "dm" && channel.deletedAt == nil && channel.memberIds.contains(userId) {
            let peerId = channel.agentId ?? channel.memberIds.first { $0 != userId }
            guard let peerId else { continue }
            dmPeerIds.insert(peerId)
            let agent = serverAgents[peerId]
            let account = accounts.values.first { $0.id == peerId }
            let label = agent?.name ?? account?.name ?? peerId
            let score = Self.forwardTargetScore(q, label.lowercased())
            if score <= 0 { continue }
            let title = "@\(label)"
            results.append((
                score + 50,
                title,
                Self.forwardTargetJSON(
                    type: "dm",
                    channelType: "dm",
                    id: peerId,
                    title: title,
                    subtitle: agent == nil ? "" : "agent",
                    avatarUrl: agent?.avatarUrl ?? account?.avatarUrl,
                    channelId: id,
                    joined: nil,
                    dmExists: true,
                    canForwardNow: true,
                    requiredAction: nil
                )
            ))
        }
        if !isGuest {
            for agent in serverAgents.values where agent.serverId == serverId && !dmPeerIds.contains(agent.id) {
                let score = Self.forwardTargetScore(q, agent.name.lowercased())
                if score <= 0 { continue }
                let title = "@\(agent.name)"
                results.append((
                    score,
                    title,
                    Self.forwardTargetJSON(
                        type: "agent",
                        channelType: nil,
                        id: agent.id,
                        title: title,
                        subtitle: "agent",
                        avatarUrl: agent.avatarUrl,
                        channelId: nil,
                        joined: nil,
                        dmExists: false,
                        canForwardNow: false,
                        requiredAction: "create_dm"
                    )
                ))
            }
        }
        if !hideHumans {
            for (key, memberRole) in serverMemberRoles {
                let parts = key.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, parts[0] == serverId, memberRole != "guest" else { continue }
                let memberId = parts[1]
                if memberId == userId || dmPeerIds.contains(memberId) { continue }
                guard let account = accounts.values.first(where: { $0.id == memberId }) else { continue }
                let score = Self.forwardTargetScore(q, account.name.lowercased())
                if score <= 0 { continue }
                let title = "@\(account.name)"
                results.append((
                    score,
                    title,
                    Self.forwardTargetJSON(
                        type: "human",
                        channelType: nil,
                        id: memberId,
                        title: title,
                        subtitle: "",
                        avatarUrl: account.avatarUrl,
                        channelId: nil,
                        joined: nil,
                        dmExists: false,
                        canForwardNow: false,
                        requiredAction: "create_dm"
                    )
                ))
            }
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title < rhs.title
        }
        let targets = results.prefix(pageLimit).map(\.json).joined(separator: ",")
        return Self.json(200, "{\"targets\":[\(targets)]}")
    }



    /// `POST /api/messages/forward`. An empty note becomes `Forwarded N message(s)` in the destination.
    public func forwardHumanMessage(body: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let destinationChannelId: String
        if let raw = object["destinationChannelId"] as? String {
            destinationChannelId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let raw = object["channelId"] as? String {
            destinationChannelId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            destinationChannelId = ""
        }
        let note: String?
        if object["note"] == nil || object["note"] is NSNull {
            note = ""
        } else if let raw = object["note"] as? String {
            note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            note = nil
        }
        let sourceIds = Self.forwardSourceIds(object["sourceMessageIds"])
        if object["destinationChannelIds"] != nil {
            guard let sourceIds, let note else {
                return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
            }
            if note.count > 32_000 {
                return Self.json(400, "{\"error\":\"Message content exceeds maximum length of 32000 characters\"}")
            }
            return forwardToMany(
                object: object,
                sourceIds: sourceIds,
                note: note,
                authorization: authorization,
                serverId: serverId
            )
        }
        guard !destinationChannelId.isEmpty, let sourceIds, let note else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        if note.count > 32_000 {
            return Self.json(400, "{\"error\":\"Message content exceeds maximum length of 32000 characters\"}")
        }
        let randomId: String
        if object["randomId"] == nil || object["randomId"] is NSNull {
            randomId = "forward-\(UUID().uuidString.lowercased())"
        } else if let raw = object["randomId"] as? String, !raw.isEmpty, raw.count <= 128 {
            randomId = raw
        } else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let content = note.isEmpty
            ? "Forwarded \(sourceIds.count) message\(sourceIds.count == 1 ? "" : "s")"
            : note
        lock.lock()
        if let existing = humanMessageRows.first(where: { $0.senderId == userId && $0.randomId == randomId }) {
            if existing.channelId == destinationChannelId,
               existing.content == content,
               let record = forwardRecords[existing.id],
               record.sourceIds == sourceIds {
                let snapshot = existing
                lock.unlock()
                return Self.forwardMessageReply(message: snapshot, record: record, outcome: "idempotent_replay")
            }
            lock.unlock()
            return Self.json(409, "{\"error\":\"This forward request id was already used for different content\",\"code\":\"idempotency_conflict\"}")
        }
        guard let destination = postableChannels[destinationChannelId],
              destination.serverId == serverId,
              destination.deletedAt == nil
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard destination.memberIds.contains(userId) else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"You must join this channel to send messages\"}")
        }
        var pending: [PendingForwardSource] = []
        for id in sourceIds {
            guard let message = humanMessageRows.first(where: { $0.id == id }) else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Source message not found\"}")
            }
            let jointLocalId = jointLocalChannelIdLocked(canonicalChannelId: message.channelId, serverId: serverId, userId: userId)
            let channel = jointLocalId.flatMap { postableChannels[$0] }
                ?? (searchMentions.messageVisible(messageChannelId: message.channelId, serverId: serverId, viewer: .user(userId))
                    ? postableChannels[message.channelId] : nil)
            guard let channel else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Source message not found\"}")
            }
            if message.actionKind == "forwarded-bundle" || forwardedBundles[message.id] != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Forwarded messages can't be forwarded. Select the original message instead.\",\"code\":\"forwarded_source_not_supported\"}")
            }
            if message.messageType != "chat" || message.actionKind != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Only ordinary chat messages can be forwarded\",\"code\":\"unsupported_source_message\"}")
            }
            let attachments = channelAttachments.values
                .filter { $0.messageId == message.id }
                .sorted { ($0.messagePosition ?? 0) < ($1.messagePosition ?? 0) }
            pending.append(PendingForwardSource(
                messageId: message.id,
                content: message.content,
                createdAt: message.createdAt,
                channelId: jointLocalId ?? message.channelId,
                channelKind: channel.kind,
                channelName: channel.name,
                parentChannelId: channel.parentChannelId,
                senderId: message.senderId,
                attachments: attachments
            ))
        }
        let selectedThreads = Set(pending.filter { $0.channelKind == "thread" }.map(\.channelId))
        let prepared = pending.map { source in
            (source, forwardContextLocked(source: source, selectedThreads: selectedThreads))
        }
        if Set(prepared.map { $0.1.bundleSourceId }).count != 1 {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Forwarded bundles must come from a single source\",\"code\":\"cross_source_bundle\"}")
        }
        let ordered = prepared.sorted { lhs, rhs in
            if lhs.1.sourceIsThreadParent != rhs.1.sourceIsThreadParent {
                return lhs.1.sourceIsThreadParent
            }
            if lhs.0.createdAt != rhs.0.createdAt { return lhs.0.createdAt < rhs.0.createdAt }
            return lhs.0.messageId < rhs.0.messageId
        }
        var legacy: [ForwardedSource] = []
        var itemRecords: [ForwardItemRecord] = []
        var projections: [(attachment: ChannelAttachment, id: String, position: Int)] = []
        var position = 0
        for (source, context) in ordered {
            let exposed = context.sourceTargetId != nil
            legacy.append(ForwardedSource(
                sourceServerId: exposed ? serverId : "",
                sourceTargetId: context.sourceTargetId ?? "",
                sourceMessageId: exposed ? source.messageId : "",
                snapshotId: context.snapshotId ?? "",
                snapshotType: context.snapshotType,
                snapshotLabel: context.snapshotLabel,
                snapshotLabelVisibility: context.snapshotLabelVisibility,
                provenanceState: "available"
            ))
            var snapshots: [ForwardAttachmentSnapshot] = []
            for attachment in source.attachments {
                let projectedId = UUID().uuidString.lowercased()
                snapshots.append(ForwardAttachmentSnapshot(
                    id: projectedId,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType ?? "",
                    sizeBytes: attachment.sizeBytes ?? 0,
                    width: attachment.width,
                    height: attachment.height
                ))
                projections.append((attachment, projectedId, position))
                position += 1
            }
            let exposesPointers = context.snapshotLabelVisibility == "public" && context.sourceTargetId != nil
            let uniqueName = accounts.values.first { $0.id == source.senderId }?.name ?? "unknown"
            itemRecords.append(ForwardItemRecord(
                sourceMessageId: source.messageId,
                exposesPointers: exposesPointers,
                sourceAuthorUniqueName: uniqueName,
                sourceIsThreadParent: context.sourceIsThreadParent,
                contentSnapshot: source.content,
                sourceTargetId: context.sourceTargetId,
                sourceThreadId: context.sourceThreadId,
                parentChannelId: context.parentChannelId,
                snapshotId: context.snapshotId,
                snapshotType: context.snapshotType,
                snapshotLabel: context.snapshotLabel,
                snapshotLabelVisibility: context.snapshotLabelVisibility,
                provenanceState: "available",
                attachments: snapshots,
                attachmentPolicy: snapshots.isEmpty ? "excluded" : "projected"
            ))
        }
        let storageChannelId = jointProjections.first { $0.localChannelId == destinationChannelId }?.canonicalChannelId ?? destinationChannelId
        let record = StoredForwardRecord(sourceIds: sourceIds, items: itemRecords, destinationTargetId: destinationChannelId)
        lock.unlock()
        let storedReply = storeHumanMessage(
            channelId: storageChannelId,
            senderId: userId,
            content: content,
            randomId: randomId,
            attachmentIds: []
        ).reply
        guard storedReply.status == 200,
              let data = storedReply.body.data(using: .utf8),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = stored["id"] as? String
        else { return storedReply }
        lock.lock()
        forwardedBundles[messageId] = legacy
        forwardRecords[messageId] = record
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].attachmentIds = projections.map(\.id)
        }
        for projection in projections {
            var copy = projection.attachment
            copy.id = projection.id
            copy.channelId = destinationChannelId
            copy.messageId = messageId
            copy.messagePosition = projection.position
            channelAttachments[copy.id] = copy
        }
        guard var message = humanMessageRows.first(where: { $0.id == messageId }) else {
            lock.unlock()
            return storedReply
        }
        lock.unlock()
        message.channelId = destinationChannelId
        return Self.forwardMessageReply(message: message, record: record, outcome: "success")
    }

}
