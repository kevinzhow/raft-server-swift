import Foundation

/// Domain failures of the message-send surface: the attachment download URL,
/// the thread-follower undo routes and the migration receipt DM.
///
/// The published bodies are the legacy ones. `auth_required` is the extra
/// `code` the shared bearer check appends; `invalid_attachment_id` publishes
/// `code` before `error`, so that case supplies an explicit `errorBody`.
public enum MessageSendError: DomainError, Equatable {
    /// No `Bearer` header on a route that requires one.
    case missingAuthorization
    /// A `Bearer` header whose token is unknown or whose session family is revoked.
    case invalidToken
    /// The follower routes' own unauthenticated answer.
    case unauthorized
    case emailVerificationRequired
    case missingServerId
    case invalidAttachmentId
    case notServerMember
    case attachmentNotFound
    case threadNotFound
    case forbidden

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidToken, .unauthorized:
            401
        case .emailVerificationRequired, .notServerMember, .forbidden:
            403
        case .missingServerId, .invalidAttachmentId:
            400
        case .attachmentNotFound, .threadNotFound:
            404
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidToken:
            "Invalid or expired token"
        case .unauthorized:
            "Unauthorized"
        case .emailVerificationRequired:
            "Email verification required"
        case .missingServerId:
            "Missing X-Server-Id header"
        case .invalidAttachmentId:
            "Invalid attachment id"
        case .notServerMember:
            "Not a member of this server"
        case .attachmentNotFound:
            "Attachment not found"
        case .threadNotFound:
            "Thread not found"
        case .forbidden:
            "Forbidden"
        }
    }

    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidToken:
            "auth_required"
        case .unauthorized, .emailVerificationRequired, .missingServerId, .invalidAttachmentId,
             .notServerMember, .attachmentNotFound, .threadNotFound, .forbidden:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .invalidAttachmentId:
            // Legacy order: `code` first, then `error`.
            .object([
                OrderedJSONField("code", "invalid_attachment_id"),
                OrderedJSONField("error", errorMessage),
            ])
        case .missingAuthorization, .invalidToken, .unauthorized, .emailVerificationRequired,
             .missingServerId, .notServerMember, .attachmentNotFound, .threadNotFound,
             .forbidden:
            nil
        }
    }
}

/// The message-send boundary: the attachment download URL, the thread-follower
/// removal/restore undo ledger and the migration receipt DM.
///
/// Every read-modify-write runs inside one `MessagesAndThreadsStore` (or
/// `ServersAndChannelsStore`) critical section; the routes only decode a body
/// and project the returned DTO or thrown `DomainError`.
///
/// Four bridges stay injected because their domains are not migrated:
/// `visibleAttachment` is the attachment-visibility policy (joint channels and
/// message-linked rows) in `AgentsLifecycleService`, `emitRealtime` is the
/// directory's socket emitter slot, and `registerPostableChannel` /
/// `appendHumanMessage` are the channel-registration and serialized message
/// append paths the receipt DM writes through. The directory's `messageSend`
/// accessor (`AuthCoreService`) wires them for the HTTP surface; a test passes
/// its own.
public struct MessageSendService: Sendable {
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let visibleAttachment: @Sendable (_ userId: String, _ serverId: String?, _ attachment: ChannelAttachment) -> Bool
    private let emitRealtime: @Sendable (_ room: String, _ event: String, _ payload: String?) -> Void
    private let registerPostableChannel: @Sendable (_ serverId: String, _ channelId: String, _ memberId: String, _ kind: String, _ name: String) -> Void
    private let appendHumanMessage: @Sendable (StoredHumanMessage) -> Int
    private let now: @Sendable () -> Date
    private let makeToken: @Sendable () -> String

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        visibleAttachment: @escaping @Sendable (String, String?, ChannelAttachment) -> Bool,
        emitRealtime: @escaping @Sendable (String, String, String?) -> Void = { _, _, _ in },
        registerPostableChannel: @escaping @Sendable (String, String, String, String, String) -> Void,
        appendHumanMessage: @escaping @Sendable (StoredHumanMessage) -> Int,
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.messages = messages
        self.channels = channels
        self.profiles = profiles
        self.oauth = oauth
        self.visibleAttachment = visibleAttachment
        self.emitRealtime = emitRealtime
        self.registerPostableChannel = registerPostableChannel
        self.appendHumanMessage = appendHumanMessage
        self.now = now
        self.makeToken = makeToken
    }

    // MARK: - GET /api/attachments/:id/url

    /// A presigned download URL, or the unauthenticated `/api/attachments/<id>`
    /// fallback. The published order is `url` then `expiresAt`; the
    /// query-token propagation path publishes `"expiresAt":null`.
    ///
    /// The legacy order is authorization (401), verification (403), retirement
    /// (401), missing server header (400), attachment id shape (400), server
    /// membership (403) and finally the attachment/visibility lookup (404).
    public func attachmentDownloadURL(
        attachmentId: String,
        authorization: String?,
        serverId: String?,
        disposition: String? = nil,
        download: String? = nil,
        propagateQueryToken: String? = nil
    ) throws -> AttachmentDownloadURLResponse {
        let userId = try authenticatedUserId(authorization)
        guard profiles.isEmailVerified(userId: userId) else {
            throw MessageSendError.emailVerificationRequired
        }
        guard profiles.account(userId: userId)?.retiredAt == nil else {
            throw MessageSendError.unauthorized
        }
        guard let serverId, !serverId.isEmpty else {
            throw MessageSendError.missingServerId
        }
        guard ServerScope.isUUID(attachmentId) else {
            throw MessageSendError.invalidAttachmentId
        }
        if !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil {
            throw MessageSendError.notServerMember
        }
        guard let record = messages.attachmentDownloadRecord(attachmentId: attachmentId),
              visibleAttachment(userId, serverId, record.attachment)
        else {
            throw MessageSendError.attachmentNotFound
        }
        let mimeType = record.attachment.mimeType
        let isMedia = mimeType?.hasPrefix("video/") == true || mimeType?.hasPrefix("audio/") == true
        let inline = disposition == "inline" && download != "1"
        let ttl = inline && isMedia ? 3600 : 300
        var url = record.presign?(attachmentId, mimeType, ttl) ?? "/api/attachments/\(attachmentId)"
        if let queryToken = propagateQueryToken {
            let encoded = queryToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? queryToken
            let separator = url.contains("?") ? "&" : "?"
            url += "\(separator)token=\(encoded)&serverId=\(serverId)"
            return AttachmentDownloadURLResponse(url: url, expiresAt: nil)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: now().addingTimeInterval(Double(ttl)))
        return AttachmentDownloadURLResponse(url: url, expiresAt: expiresAt)
    }

    // MARK: - DELETE /api/channels/threads/:threadId/followers/agents/:agentId

    /// Removes an agent from a thread's follower set and returns the undo token.
    ///
    /// The legacy order is the session (401), server membership (403), thread
    /// lookup (404) and the thread-manage policy (403) before the undo row is
    /// written. A second removal for the same thread/agent pair replays the
    /// first token and publishes the leading `"ok":true` member.
    public func removeThreadFollower(
        authorization: String?,
        serverId: String,
        threadId: String,
        agentId: String
    ) throws -> ThreadFollowerRemovalResponse {
        let userId = try followerUserId(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw MessageSendError.notServerMember
        }
        try requireManagedThread(serverId: serverId, threadId: threadId, userId: userId)
        switch messages.beginThreadFollowerRemoval(
            serverId: serverId,
            threadId: threadId,
            agentId: agentId,
            undoToken: makeToken()
        ) {
        case .replay(let undoToken):
            return ThreadFollowerRemovalResponse(removed: true, undoToken: undoToken, ok: true)
        case .created(let undoToken):
            oauth.removeChannelAgent(channelId: threadId, agentId: agentId)
            emitRealtime(
                "channel:\(threadId)",
                "thread:followers-updated",
                OrderedJSON.object([OrderedJSONField("threadChannelId", threadId)]).render()
            )
            return ThreadFollowerRemovalResponse(removed: true, undoToken: undoToken)
        }
    }

    // MARK: - POST /api/channels/threads/:threadId/followers/agents/:agentId/restore

    /// Restores a removed follower. A token that is unknown, already consumed,
    /// or issued for another thread/agent pair answers the published
    /// `{"ok":true,"restored":false}` without a write.
    public func restoreThreadFollower(
        authorization: String?,
        serverId: String,
        threadId: String,
        agentId: String,
        undoToken: String
    ) throws -> ThreadFollowerRestoreResponse {
        let userId = try followerUserId(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw MessageSendError.notServerMember
        }
        try requireManagedThread(serverId: serverId, threadId: threadId, userId: userId)
        guard case .restored = messages.restoreThreadFollower(
            threadId: threadId,
            agentId: agentId,
            undoToken: undoToken
        ) else {
            return ThreadFollowerRestoreResponse(restored: false)
        }
        oauth.addChannelAgent(channelId: threadId, agentId: agentId)
        emitRealtime(
            "channel:\(threadId)",
            "thread:followers-updated",
            OrderedJSON.object([OrderedJSONField("threadChannelId", threadId)]).render()
        )
        return ThreadFollowerRestoreResponse(restored: true)
    }

    // MARK: - Migration receipt DM

    /// A completed Computer migration writes one receipt into an agent-only DM
    /// named `migration-receipt-<supportRef>`; the agent reads it as
    /// `dm:@migration-receipt-<supportRef>` and cannot reply to it.
    ///
    /// The channel lookup is one store read; an existing channel is returned
    /// unchanged, so a repeated completion does not post a second notice.
    @discardableResult
    public func createMigrationReceiptDm(
        agentId: String,
        serverId: String,
        supportRef: String
    ) -> String? {
        let name = "migration-receipt-\(supportRef)"
        if let existing = channels.directChannelId(name: name, memberId: agentId) {
            return existing
        }
        let channelId = oauth.createChannel(
            serverId: serverId,
            name: name,
            creatorUserId: agentId,
            type: "dm"
        )
        registerPostableChannel(serverId, channelId, agentId, "dm", name)
        oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        _ = appendHumanMessage(StoredHumanMessage(
            id: makeToken(),
            channelId: channelId,
            senderId: "system",
            content: "Migration completed. Your Computer workspace moved successfully (migration \(supportRef)). This is a one-way notice: continue in your owner's DM.",
            randomId: nil,
            messageType: "system",
            senderType: "system"
        ))
        return channelId
    }

    // MARK: - Policy

    /// The shared bearer check: a missing or non-`Bearer` header is the
    /// `missingAuthorization` answer, an unknown token the `invalidToken` one.
    private func authenticatedUserId(_ authorization: String?) throws -> String {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw MessageSendError.missingAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let userId = profiles.userId(forAccessToken: token) else {
            throw MessageSendError.invalidToken
        }
        return userId
    }

    /// The follower routes answer their own bare `Unauthorized` for both an
    /// absent and an unknown bearer, so they collapse the two typed refusals.
    private func followerUserId(_ authorization: String?) throws -> String {
        guard let userId = try? authenticatedUserId(authorization) else {
            throw MessageSendError.unauthorized
        }
        return userId
    }

    /// A live thread on this server that `userId` may manage, or the published
    /// 404/403. The manage policy is the legacy one: an owner or admin of the
    /// server, otherwise the sender of the thread's parent message.
    private func requireManagedThread(
        serverId: String,
        threadId: String,
        userId: String
    ) throws {
        guard let thread = channels.postableChannel(id: threadId),
              thread.serverId == serverId,
              thread.kind == "thread"
        else {
            throw MessageSendError.threadNotFound
        }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        if role == "owner" || role == "admin" { return }
        guard let parentMessageId = thread.parentMessageId,
              messages.humanMessageRow(id: parentMessageId)?.senderId == userId
        else {
            throw MessageSendError.forbidden
        }
    }
}

// MARK: - Remaining untyped helpers

// The members below are still the legacy directory extension and are the
// remaining work for this domain: the v2 send envelope, the mention-resolution
// and pending-mention assembly, the forward-bundle projection and the
// attachment-row writers. They are kept byte-identical in this file so every
// current caller keeps resolving; they are NOT part of the typed service above
// and still build JSON strings by hand.
extension EmailLoginDirectory {
    func forwardContextLocked(source: PendingForwardSource, selectedThreads: Set<String>) -> ForwardSourceContext {
        if source.channelKind == "thread" {
            let parent = source.parentChannelId.flatMap { postableChannels[$0] }
            let publicParent = parent?.kind == "channel"
            return ForwardSourceContext(
                bundleSourceId: source.channelId,
                sourceTargetId: publicParent ? source.channelId : nil,
                sourceThreadId: publicParent ? source.channelId : nil,
                parentChannelId: publicParent ? source.parentChannelId : nil,
                sourceIsThreadParent: false,
                snapshotId: publicParent ? source.parentChannelId : nil,
                snapshotType: "thread",
                snapshotLabel: publicParent ? "#\(parent?.name ?? "")" : "",
                snapshotLabelVisibility: publicParent ? "public" : "restricted"
            )
        }
        if source.channelKind == "channel",
           let threadId = postableChannels.first(where: { $0.value.kind == "thread" && $0.value.parentMessageId == source.messageId })?.key,
           selectedThreads.contains(threadId) {
            return ForwardSourceContext(
                bundleSourceId: threadId,
                sourceTargetId: threadId,
                sourceThreadId: threadId,
                parentChannelId: source.channelId,
                sourceIsThreadParent: true,
                snapshotId: source.channelId,
                snapshotType: "thread",
                snapshotLabel: "#\(source.channelName)",
                snapshotLabelVisibility: "public"
            )
        }
        let publicSource = source.channelKind == "channel"
        return ForwardSourceContext(
            bundleSourceId: source.channelId,
            sourceTargetId: publicSource ? source.channelId : nil,
            sourceThreadId: nil,
            parentChannelId: nil,
            sourceIsThreadParent: false,
            snapshotId: publicSource ? source.channelId : nil,
            snapshotType: publicSource ? "channel" : source.channelKind,
            snapshotLabel: publicSource ? "#\(source.channelName)" : "",
            snapshotLabelVisibility: publicSource ? "public" : "restricted"
        )
    }





    /// A viewer who cannot read the source still sees the forward, with the pointers removed.

    func forwardMetadataJSONLocked(messageId: String, userId: String, serverId: String?) -> String? {
        guard let record = forwardRecords[messageId] else { return nil }
        let rendered = record.items.map { item in
            forwardItemReadableLocked(item, userId: userId, serverId: serverId)
                ? Self.forwardItemJSON(item)
                : Self.scrubbedForwardItemJSON(item)
        }.joined(separator: ",")
        return "{\"kind\":\"forwarded-bundle\",\"forwardedItems\":[\(rendered)]}"
    }

    func forwardItemReadableLocked(_ item: ForwardItemRecord, userId: String, serverId: String?) -> Bool {
        guard let targetId = item.sourceTargetId, let serverId else { return false }
        guard let channel = postableChannels[targetId], channel.serverId == serverId, channel.deletedAt == nil else { return false }
        if channel.kind == "channel" { return true }
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId,
                  let parent = postableChannels[parentId],
                  parent.serverId == serverId,
                  parent.deletedAt == nil
            else { return channel.memberIds.contains(userId) }
            if parent.kind == "channel" { return true }
            return parent.memberIds.contains(userId) || channel.memberIds.contains(userId)
        }
        return channel.memberIds.contains(userId)
    }

    /// A batch keeps one result per distinct destination. A denial or conflict stays inside that result.
    func forwardToMany(object: [String: Any], sourceIds: [String], note: String, authorization: String?, serverId: String) -> HTTPReply {
        guard let destinations = Self.forwardDestinationIds(object["destinationChannelIds"]) else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        guard let rawRequestId = object["requestId"] as? String else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let requestId = rawRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ServerScope.isUUID(requestId) else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let sourcesJSON = sourceIds.map { jsonString($0) }.joined(separator: ",")
        var results: [String] = []
        var successes = 0
        var replays = 0
        for destination in destinations {
            let randomId = "forward:\(requestId):\(destination)"
            let body = "{\"destinationChannelId\":\(jsonString(destination)),\"sourceMessageIds\":[\(sourcesJSON)],\"note\":\(jsonString(note)),\"randomId\":\(jsonString(randomId))}"
            let reply = forwardHumanMessage(body: body, authorization: authorization, serverId: serverId)
            if reply.status == 200 {
                successes += 1
                if reply.value(for: "X-Raft-Forward-Outcome") == "idempotent_replay" {
                    replays += 1
                }
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"success\",\"message\":\(reply.body)}")
            } else if reply.status == 409 {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"request_conflict\",\"error\":\"Forward request conflicts with an earlier request\"}")
            } else if reply.status == 403 || reply.status == 404 {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"destination_unavailable\",\"error\":\"Could not forward to this target\"}")
            } else {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"forward_failed\",\"error\":\"Could not forward to this target\"}")
            }
        }
        let failed = destinations.count - successes
        let outcome: String
        if failed > 0 {
            outcome = successes > 0 ? "partial_failure" : "all_failed"
        } else if replays == destinations.count {
            outcome = "idempotent_replay"
        } else {
            outcome = "success"
        }
        var reply = Self.json(200, "{\"results\":[\(results.joined(separator: ","))]}")
        reply.headers["X-Raft-Forward-Outcome"] = outcome
        return reply
    }

    /// `POST /api/v2/messages`. The message is always nested. A stopped agent DM adds `agent_stopped`.
    func v2HumanSend(_ reply: HTTPReply, channelId: String, mentions: [MentionInput], unresolvedMentionHandles: [String] = []) -> HTTPReply {
        guard reply.status == 200,
              let data = reply.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = object["id"] as? String
        else { return reply }
        let pending = pendingMentionActionsJSON(channelId: channelId, messageId: messageId, mentions: mentions)
        let warnings = stoppedAgentDeliveryWarningJSON(channelId: channelId, messageId: messageId)
        var body = "{\"message\":\(reply.body)"
        if !pending.isEmpty {
            body += ",\"pendingMentionActions\":[\(pending)]"
        }
        if !warnings.isEmpty {
            body += ",\"deliveryWarnings\":[\(warnings)]"
        }
        if !unresolvedMentionHandles.isEmpty {
            let handles = unresolvedMentionHandles.map { jsonString($0) }.joined(separator: ",")
            body += ",\"unresolvedMentionHandles\":[\(handles)]"
        }
        body += "}"
        return Self.json(200, body)
    }

    /// A DM delivery to a stopped agent is dropped as `wake_suppressed` and reported to the v2 sender as `agent_stopped`.
    func stoppedAgentDeliveryWarningJSON(channelId: String, messageId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId],
              channel.kind == "dm",
              let agentId = channel.agentId,
              serverAgents[agentId]?.status == "stopped"
        else { return "" }
        storedAgentDeliveries.append((agentId: agentId, messageId: messageId, channelType: channel.kind))
        return "{\"targetType\":\"agent\",\"targetId\":\(jsonString(agentId)),\"reason\":\"agent_stopped\"}"
    }

    /// A completed Computer migration writes one receipt into an agent-only DM
    /// named `migration-receipt-<supportRef>`; the agent reads it as
    /// `dm:@migration-receipt-<supportRef>` and cannot reply to it.
    @discardableResult

    /// Outsider mentions on a new human send are returned beside the message, not inside it.
    func withPendingMentionActions(_ reply: HTTPReply, channelId: String, mentions: [MentionInput]) -> HTTPReply {
        guard reply.status == 200,
              let data = reply.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = object["id"] as? String
        else { return reply }
        let actions = pendingMentionActionsJSON(channelId: channelId, messageId: messageId, mentions: mentions)
        guard !actions.isEmpty else { return reply }
        return Self.json(200, "{\"message\":\(reply.body),\"pendingMentionActions\":[\(actions)]}")
    }

    func pendingMentionActionsJSON(channelId: String, messageId: String, mentions: [MentionInput]) -> String {
        lock.lock()
        defer { lock.unlock() }
        let channel = postableChannels[channelId]
        let members = channel?.memberIds ?? []
        let serverId = channel?.serverId
        let directMessage = channel?.kind == "dm"
        let expiresAt = Self.pendingMentionExpiry()
        var parts: [String] = []
        for mention in mentions {
            guard mention.type == "user" || mention.type == "agent",
                  ServerScope.isUUID(mention.id),
                  !mention.name.isEmpty
            else { continue }
            let avatar: String?
            if mention.type == "user" {
                guard accounts.values.contains(where: { $0.id == mention.id }), !members.contains(mention.id) else { continue }
                avatar = accounts.values.first { $0.id == mention.id }?.avatarUrl
            } else {
                if oauth.channelAgentIds(channelId: channelId).contains(mention.id) { continue }
                if let agent = serverAgents[mention.id], agent.serverId == serverId {
                    avatar = agent.avatarUrl
                } else if let agent = oauth.agentRuntimeInfo(id: mention.id), agent.serverId == serverId, !agent.deleted {
                    avatar = agent.avatarUrl
                } else {
                    continue
                }
            }
            let avatarJSON = avatar.map { jsonString($0) } ?? "null"
            let existing = storedMentions.first { $0.messageId == messageId && $0.targetType == mention.type && $0.targetId == mention.id }
            let resolutionId = existing?.id ?? UUID().uuidString.lowercased()
            if existing == nil {
                let senderId = humanMessageRows.first { $0.id == messageId }?.senderId ?? ""
                storedMentions.append(StoredMention(
                    id: resolutionId,
                    messageId: messageId,
                    channelId: channelId,
                    senderId: senderId,
                    targetType: mention.type,
                    targetId: mention.id,
                    handle: mention.name,
                    notifiableAtSend: false,
                    notifiedAt: nil,
                    notifiedByType: nil,
                    notifiedById: nil,
                    notifiedAction: nil
                ))
            }
            if directMessage { continue }
            parts.append("{\"resolutionId\":\(jsonString(resolutionId)),\"messageId\":\(jsonString(messageId)),\"targetType\":\(jsonString(mention.type)),\"targetHandle\":\(jsonString(mention.name)),\"targetAvatarUrl\":\(avatarJSON),\"reason\":\"not_member\",\"availableActions\":[\"notify\",\"add\"],\"expiresAt\":\(jsonString(expiresAt))}")
        }
        return parts.joined(separator: ",")
    }

    /// Caller holds the directory lock.
    func mentionHumanVisibleLocked(serverId: String, senderId: String, targetId: String) -> Bool {
        if targetId == senderId { return true }
        guard hideHumansFromMembers[serverId] == true else { return true }
        guard let targetRole = oauth.memberRole(serverId: serverId, userId: targetId) else { return false }
        let senderRole = oauth.memberRole(serverId: serverId, userId: senderId)
        let senderIsAgent = oauth.agentRuntimeInfo(id: senderId)?.serverId == serverId
        guard senderRole == "member" || senderIsAgent else { return true }
        if targetRole == "owner" || targetRole == "admin" { return true }
        for (id, channel) in postableChannels
        where channel.serverId == serverId && channel.deletedAt == nil && channel.memberIds.contains(senderId) {
            if channel.name != "all" && channel.memberIds.contains(targetId) { return true }
            if jointRosterLocked(channelId: id)?.contains(targetId) == true { return true }
        }
        return false
    }

    func resolvedMessageMentions(
        serverId: String,
        senderId: String,
        content: String,
        typed: [MentionInput],
        warnUnresolved: Bool
    ) -> (mentions: [MentionInput], unresolved: [String]) {
        lock.lock()
        defer { lock.unlock() }
        var resolved: [MentionInput] = []
        var seen = Set<String>()
        func append(type: String, id: String, name: String) {
            let key = "\(type):\(id)"
            guard seen.insert(key).inserted else { return }
            resolved.append(MentionInput(type: type, id: id, name: name))
        }
        var typedNames = Set<String>()
        let senderIsAgent = oauth.agentRuntimeInfo(id: senderId)?.serverId == serverId
        let hiddenDirectoryForSender = hideHumansFromMembers[serverId] == true
        for mention in typed where mention.type == "user" || mention.type == "agent" {
            guard ServerScope.isUUID(mention.id), !mention.name.isEmpty else { continue }
            typedNames.insert(mention.name.lowercased())
            if mention.type == "user" {
                if hiddenDirectoryForSender {
                    guard mentionHumanVisibleLocked(serverId: serverId, senderId: senderId, targetId: mention.id) else { continue }
                } else {
                    guard accounts.values.contains(where: { $0.id == mention.id }) else { continue }
                }
                append(type: "user", id: mention.id, name: mention.name)
            } else {
                let runtime = oauth.agentRuntimeInfo(id: mention.id)
                let directory = serverAgents[mention.id]
                guard runtime?.serverId == serverId || directory?.serverId == serverId else { continue }
                append(type: "agent", id: mention.id, name: mention.name)
            }
        }
        var agentNames: [(id: String, name: String)] = oauth.serverAgents(serverId: serverId).map { ($0.id, $0.name) }
        for (id, agent) in serverAgents where agent.serverId == serverId {
            if !agentNames.contains(where: { $0.id == id }) { agentNames.append((id, agent.name)) }
        }
        var unresolved: [String] = []
        let hiddenDirectory = hiddenDirectoryForSender
        var seenHandles = Set<String>()
        for handle in Self.mentionHandlesOutsideCode(content)
            where !typedNames.contains(handle.lowercased()) && seenHandles.insert(handle).inserted {
            let humanMatches = accounts.values.filter { account in
                account.id != senderId
                    && (account.name.caseInsensitiveCompare(handle) == .orderedSame
                        || (account.displayName ?? "").caseInsensitiveCompare(handle) == .orderedSame)
                    && oauth.memberRole(serverId: serverId, userId: account.id) != nil
                    && (!hiddenDirectory || mentionHumanVisibleLocked(serverId: serverId, senderId: senderId, targetId: account.id))
            }.map(\.id)
            let agentMatches = agentNames.filter { $0.name.caseInsensitiveCompare(handle) == .orderedSame }.map(\.id)
            let total = humanMatches.count + agentMatches.count
            if warnUnresolved {
                guard total == 1 else {
                    unresolved.append("@" + handle)
                    continue
                }
            }
            for id in humanMatches { append(type: "user", id: id, name: handle) }
            for id in agentMatches { append(type: "agent", id: id, name: handle) }
        }
        return (resolved, unresolved)
    }

    func recordMemberMentionRows(messageId: String, channelId: String, mentions: [MentionInput]) {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId] else { return }
        for mention in mentions where mention.type == "user" || mention.type == "agent" {
            guard ServerScope.isUUID(mention.id) else { continue }
            let isMember = mention.type == "user"
                ? oauth.memberRole(serverId: channel.serverId, userId: mention.id) != nil
                : oauth.agentRuntimeInfo(id: mention.id)?.serverId == channel.serverId
            guard isMember else { continue }
            guard !storedMentions.contains(where: {
                $0.messageId == messageId && $0.targetType == mention.type && $0.targetId == mention.id
            }) else { continue }
            storedMentions.append(StoredMention(
                id: UUID().uuidString.lowercased(),
                messageId: messageId,
                channelId: channelId,
                senderId: "system",
                targetType: mention.type,
                targetId: mention.id,
                handle: mention.name,
                notifiableAtSend: true,
                notifiedAt: nil,
                notifiedByType: nil,
                notifiedById: nil,
                notifiedAction: nil
            ))
        }
    }

    /// An agent that belongs to a server but is not a member of a channel until someone adds it.
    public func addServerAgent(serverId: String, id: String, name: String, avatarUrl: String?, status: String = "inactive") {
        lock.lock()
        serverAgents[id] = ServerAgent(id: id, serverId: serverId, name: name, avatarUrl: avatarUrl, status: status)
        lock.unlock()
    }

    /// Stored forwarded-bundle metadata. The reaction route projects it for the HTTP body and the channel broadcast.
    public func setForwardedBundle(messageId: String, items: [ForwardedSource]) {
        lock.lock()
        forwardedBundles[messageId] = items
        lock.unlock()
    }

    /// An uploaded file on a channel. The send route keeps the caller's `attachmentIds` order, not upload time.
    public func addChannelAttachment(
        channelId: String,
        uploaderId: String,
        filename: String,
        mimeType: String? = nil,
        sizeBytes: Int? = nil,
        messageId: String? = nil
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: messageId,
            messagePosition: nil,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
        lock.unlock()
        return id
    }

    public func linkedAttachmentPositions(ids: [String]) -> [(id: String, messagePosition: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return ids.compactMap { id in
            guard let position = channelAttachments[id]?.messagePosition else { return nil }
            return (id, position)
        }.sorted { $0.messagePosition < $1.messagePosition }
    }

    /// Stored attachment rows for these ids, in `messagePosition` order. Unlinked rows keep a nil position and sort first.
    public func linkedAttachmentRecords(ids: [String]) -> [(id: String, messageId: String?, messagePosition: Int?)] {
        lock.lock()
        defer { lock.unlock() }
        return ids.compactMap { id in
            guard let row = channelAttachments[id] else { return nil }
            return (row.id, row.messageId, row.messagePosition)
        }.sorted { ($0.messagePosition ?? -1) < ($1.messagePosition ?? -1) }
    }
}
