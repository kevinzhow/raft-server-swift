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
