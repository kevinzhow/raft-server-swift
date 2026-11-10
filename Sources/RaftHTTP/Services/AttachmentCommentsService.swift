import Foundation
import RaftShared

/// Domain failure for the attachment-comment routes, human and agent.
///
/// Every case is one published refusal; `Respond.swift` renders them from
/// `errorMessage` and `errorCode`, so the default `{"error":…[,"code":…]}`
/// bytes of the retired handlers are unchanged.
public enum AttachmentCommentsError: DomainError, Equatable {
    case unauthorized
    /// The agent credential is missing, unknown, revoked or its agent is deleted.
    case agentAuthRequired
    case capabilityNotAuthorized
    case commentsDisabled
    case idsOutOfRange
    case invalidAttachmentId
    case attachmentNotFound
    case attachmentNotLinked
    case channelArchived
    case notAChannelMember
    case contentRequired
    case invalidMentions
    /// `anchor_invalid`, `anchor_type_invalid` or `anchor_too_large`.
    case invalidAnchor(code: String)
    case agentCommentCreateDisabled

    public var status: UInt {
        switch self {
        case .unauthorized, .agentAuthRequired:
            401
        case .capabilityNotAuthorized, .commentsDisabled, .notAChannelMember,
             .agentCommentCreateDisabled:
            403
        case .attachmentNotFound:
            404
        case .attachmentNotLinked:
            422
        case .channelArchived:
            409
        case .idsOutOfRange, .invalidAttachmentId, .contentRequired, .invalidMentions,
             .invalidAnchor:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .agentAuthRequired:
            "Invalid or expired token"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .commentsDisabled:
            "Attachment comments are not enabled on this server"
        case .idsOutOfRange:
            "ids must contain 1-100 attachment ids"
        case .invalidAttachmentId:
            "A valid attachment id is required"
        case .attachmentNotFound:
            "Attachment not found"
        case .attachmentNotLinked:
            "This attachment is not linked to a message"
        case .channelArchived:
            "This channel is archived"
        case .notAChannelMember:
            "You must join this channel to comment"
        case .contentRequired:
            "content is required"
        case .invalidMentions:
            "Invalid mentions payload"
        case .invalidAnchor:
            "Invalid anchor"
        case .agentCommentCreateDisabled:
            "Agents cannot create attachment comments"
        }
    }

    public var errorCode: String? {
        switch self {
        case .agentAuthRequired:
            "auth_required"
        case .capabilityNotAuthorized:
            "capability_not_authorized"
        case .commentsDisabled:
            "attachment_comments_disabled"
        case .invalidAttachmentId:
            "invalid_attachment_id"
        case .attachmentNotLinked:
            "attachment_not_linked"
        case .channelArchived:
            "channel_archived"
        case .notAChannelMember:
            "not_a_member"
        case .invalidMentions:
            "mentions_invalid"
        case .invalidAnchor(let code):
            code
        case .agentCommentCreateDisabled:
            "agent_comment_create_disabled"
        case .unauthorized, .idsOutOfRange, .attachmentNotFound, .contentRequired:
            nil
        }
    }
}

// MARK: - Injected dependencies

/// The not-yet-migrated decisions the attachment-comment routes need: the human
/// session, the agent credential, the feature-flag gate, the attachment
/// visibility rules shared with other domains, the thread lookup shared with the
/// action-card and managed-MCP domains, and the mention-row writer shared with
/// message create. Everything else is a store or the OAuth ledger.
struct AttachmentCommentsDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var commentsEnabled: @Sendable (_ serverId: String, _ userId: String) -> Bool
    var visibleAttachment: @Sendable (_ userId: String, _ serverId: String?, _ attachment: ChannelAttachment) -> Bool
    var visibleAttachmentUnlocked: @Sendable (_ userId: String, _ serverId: String?, _ attachment: ChannelAttachment) -> Bool
    var agentCredential: @Sendable (String?) -> (agentId: String, scopes: [String])?
    var agentVisibleAttachment: @Sendable (_ agentId: String, _ serverId: String, _ attachmentId: String) -> ChannelAttachment?
    var agentHistoryThread: @Sendable (_ parentId: String, _ anchorMessageId: String) -> String?
    var resolveMentions: @Sendable (_ serverId: String, _ channelId: String, _ senderId: String,
        _ content: String, _ mentions: [MentionInput], _ warnUnresolved: Bool,
        _ surface: MessageMentionSurface) throws -> ResolvedMentions
    var recordMemberMentionRows: @Sendable (_ messageId: String, _ channelId: String, _ resolution: ResolvedMentions) -> Void
}

// MARK: - Service

/// Scoped attachment comments: the batch chip counts, the per-attachment list
/// with the viewer's write state, the human create, and the two agent routes.
///
/// A comment is a normal message in the host message's thread, so a create
/// touches the thread channel, the comment rows and the message rows. The comment
/// row and its message row are written in one `MessagesAndThreadsStore`
/// critical section (`appendAttachmentComment`). The thread lookup-and-create
/// that precedes it is not one section — the retired handler released the
/// directory lock around it as well — and runs before the mention and anchor
/// validation, exactly as the published order did.
public struct AttachmentCommentsService: Sendable {
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let dependencies: AttachmentCommentsDependencies

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        dependencies: AttachmentCommentsDependencies
    ) {
        self.messages = messages
        self.channels = channels
        self.profiles = profiles
        self.oauth = oauth
        self.dependencies = dependencies
    }

    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw AttachmentCommentsError.unauthorized
        }
        return userId
    }

    private func requireAgent(
        _ authorization: String?,
        requireRead: Bool
    ) throws -> (agent: OAuthLedger.AgentRuntimeInfo, scopes: [String]) {
        guard let credential = dependencies.agentCredential(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            throw AttachmentCommentsError.agentAuthRequired
        }
        if requireRead, !credential.scopes.contains("read") {
            throw AttachmentCommentsError.capabilityNotAuthorized
        }
        return (agent, credential.scopes)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: Counts

    /// `GET /api/attachments/comments/counts`. Batch chip counts; only
    /// attachments the caller can read are counted.
    public func attachmentCommentCounts(
        authorization: String?,
        serverId: String,
        ids: String?
    ) throws -> AttachmentCommentCountsResponse {
        let userId = try requireUser(authorization)
        guard dependencies.commentsEnabled(serverId, userId) else {
            throw AttachmentCommentsError.commentsDisabled
        }
        let requested = (ids ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !requested.isEmpty, requested.count <= 100 else {
            throw AttachmentCommentsError.idsOutOfRange
        }
        let state = messages.state
        var counts: [(id: String, count: Int)] = []
        for id in requested {
            guard ServerScope.isUUID(id), let attachment = state.channelAttachments[id] else { continue }
            guard dependencies.visibleAttachmentUnlocked(userId, serverId, attachment) else { continue }
            counts.append((id, state.attachmentCommentRecords[id]?.count ?? 0))
        }
        return AttachmentCommentCountsResponse(counts: counts)
    }

    // MARK: List

    /// `GET /api/attachments/:id/comments`: the scoped comment list plus the
    /// viewer write-state so the panel can gate affordances honestly.
    public func attachmentCommentsList(
        authorization: String?,
        serverId: String,
        attachmentId: String
    ) throws -> AttachmentCommentListResponse {
        let userId = try requireUser(authorization)
        guard dependencies.commentsEnabled(serverId, userId) else {
            throw AttachmentCommentsError.commentsDisabled
        }
        guard ServerScope.isUUID(attachmentId) else { throw AttachmentCommentsError.invalidAttachmentId }
        let candidate = messages.state.channelAttachments[attachmentId]
        guard let attachment = candidate,
              dependencies.visibleAttachment(userId, serverId, attachment)
        else {
            throw AttachmentCommentsError.attachmentNotFound
        }
        let records = messages.state.attachmentCommentRecords[attachmentId] ?? []
        let channel = channels.postableChannel(id: attachment.channelId)
        let archived = oauth.channelArchivedAt(id: attachment.channelId) != nil
        let canPost = channel.map { channel in
            channel.kind == "channel"
                ? oauth.memberRole(serverId: serverId, userId: userId) != nil
                : channel.memberIds.contains(userId)
                    || oauth.channelHumanIds(channelId: attachment.channelId).contains(userId)
        } ?? false
        let comments = records.sorted { $0.createdAt < $1.createdAt }.map { record in
            AttachmentCommentListResponse.Comment(
                id: record.id,
                attachmentId: record.attachmentId,
                content: record.content,
                anchorJSON: record.anchorJSON,
                senderType: record.senderType,
                senderId: record.senderId,
                senderName: profiles.account(userId: record.senderId)?.name ?? record.senderId,
                createdAt: Self.timestamp(record.createdAt)
            )
        }
        if archived {
            return AttachmentCommentListResponse(comments: comments, canComment: false, reason: "archived")
        } else if attachment.messageId == nil {
            return AttachmentCommentListResponse(comments: comments, canComment: false, reason: "unlinked")
        } else if canPost {
            return AttachmentCommentListResponse(comments: comments, canComment: true, reason: "ok")
        }
        return AttachmentCommentListResponse(comments: comments, canComment: false, reason: "not_member")
    }

    // MARK: Create

    /// `POST /api/attachments/:id/comments`.
    public func createAttachmentComment(
        authorization: String?,
        attachmentId: String,
        body: IntegrationRequestBody?,
        serverId: String?
    ) throws -> AttachmentCommentCreatedResponse {
        let userId = try requireUser(authorization)
        // The feature gate answers before ANY body validation: a disabled
        // server must see one uniform 403 for every payload.
        if let serverId, !dependencies.commentsEnabled(serverId, userId) {
            throw AttachmentCommentsError.commentsDisabled
        }
        guard ServerScope.isUUID(attachmentId) else { throw AttachmentCommentsError.invalidAttachmentId }
        guard let attachment = messages.state.channelAttachments[attachmentId] else {
            throw AttachmentCommentsError.attachmentNotFound
        }
        // An attachment the caller cannot see is the same neutral 404 as one
        // that does not exist, and that cloak runs before body validation.
        if let serverId, !dependencies.visibleAttachmentUnlocked(userId, serverId, attachment) {
            throw AttachmentCommentsError.attachmentNotFound
        }
        if attachment.messageId == nil { throw AttachmentCommentsError.attachmentNotLinked }
        if oauth.channelArchivedAt(id: attachment.channelId) != nil {
            throw AttachmentCommentsError.channelArchived
        }
        let canPost = channels.postableChannel(id: attachment.channelId).map { channel in
            channel.kind == "channel"
                ? oauth.memberRole(serverId: channel.serverId, userId: userId) != nil
                : channel.memberIds.contains(userId)
                    || oauth.channelHumanIds(channelId: attachment.channelId).contains(userId)
        } ?? false
        if !canPost { throw AttachmentCommentsError.notAChannelMember }
        guard let body, let content = body.string("content"),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AttachmentCommentsError.contentRequired
        }
        // A comment is a normal message in the attachment host message's thread;
        // siblings under the same host share that thread.
        let mentionSurface = try MessageMentionMarkdown.parse(content)
        let hostChannelId = attachment.channelId
        let hostMessageId = attachment.messageId ?? ""
        let hostChannel = channels.postableChannel(id: hostChannelId)
        let hostServerId = hostChannel?.serverId ?? ""
        let hostMembers = Array(hostChannel?.memberIds ?? [])
        let threadChannelId = ensureThread(
            hostChannelId: hostChannelId,
            hostMessageId: hostMessageId,
            hostServerId: hostServerId,
            hostMembers: hostMembers,
            userId: userId
        )
        guard let mentions = Self.strictMentions(body.value("mentions")) else {
            throw AttachmentCommentsError.invalidMentions
        }
        let anchor = Self.canonicalAnchor(body.value("anchor"))
        if let code = anchor.code { throw AttachmentCommentsError.invalidAnchor(code: code) }

        let resolution = try dependencies.resolveMentions(hostServerId, threadChannelId, userId,
            content, mentions, false, mentionSurface)
        let now = Date()
        let id = UUID().uuidString.lowercased()
        messages.appendAttachmentComment(
            AttachmentCommentRecord(
                id: id,
                attachmentId: attachmentId,
                content: content,
                anchorJSON: anchor.json,
                senderId: userId,
                senderType: "user",
                createdAt: now,
                threadChannelId: threadChannelId,
                hostMessageId: hostMessageId,
                hostChannelId: hostChannelId
            ),
            message: StoredHumanMessage(
                id: id,
                channelId: threadChannelId,
                senderId: userId,
                content: content,
                randomId: nil,
                messageType: "comment",
                senderType: "user",
                createdAt: now,
                mentions: resolution.mentions.map { StoredMessageMention(type: $0.type, id: $0.id, name: $0.name) }
            ),
            ledger: MessageLedgerPort(oauth: oauth)
        )
        dependencies.recordMemberMentionRows(id, threadChannelId, resolution)
        return AttachmentCommentCreatedResponse(
            id: id,
            attachmentId: attachmentId,
            content: content,
            createdAt: Self.timestamp(now),
            anchorJSON: anchor.json,
            hostMessageId: hostMessageId,
            hostChannelId: hostChannelId,
            threadChannelId: threadChannelId
        )
    }

    /// The host message's thread: the existing one, or a new thread whose
    /// members are the host channel's members and the commenter.
    private func ensureThread(
        hostChannelId: String,
        hostMessageId: String,
        hostServerId: String,
        hostMembers: [String],
        userId: String
    ) -> String {
        guard !hostMessageId.isEmpty else { return hostChannelId }
        if let existing = dependencies.agentHistoryThread(hostChannelId, hostMessageId) { return existing }
        let created = oauth.createThreadChannel(parentChannelId: hostChannelId, parentMessageId: hostMessageId)
        for member in hostMembers + [userId] {
            channels.addPostableChannel(
                serverId: hostServerId,
                channelId: created,
                memberId: member,
                kind: "thread",
                parentChannelId: hostChannelId,
                parentMessageId: hostMessageId,
                name: "thread"
            )
        }
        oauth.addChannelHuman(channelId: created, userId: userId)
        return created
    }

    // MARK: Agent routes

    /// `GET /internal/agent-api/attachments/:attachmentId/comments`.
    public func agentAttachmentCommentsList(
        authorization: String?,
        attachmentId: String
    ) throws -> AgentAttachmentCommentsResponse {
        let (agent, _) = try requireAgent(authorization, requireRead: true)
        guard ServerScope.isUUID(attachmentId),
              let attachment = dependencies.agentVisibleAttachment(agent.id, agent.serverId, attachmentId)
        else {
            throw AttachmentCommentsError.attachmentNotFound
        }
        let state = messages.state
        let parentAuthor = attachment.messageId.flatMap { messageId in
            state.humanMessageRows.first { $0.id == messageId }?.senderId
        }
        let canResolve = parentAuthor == agent.id
        let comments = (state.attachmentCommentRecords[attachmentId] ?? []).map { comment in
            let reaction = state.messageReactions.first {
                $0.messageId == comment.id && $0.emoji == "✅" && $0.reactorId == parentAuthor
            }
            return AgentAttachmentCommentsResponse.Comment(
                id: comment.id,
                content: comment.content,
                senderType: comment.senderType,
                anchorJSON: comment.anchorJSON,
                resolved: reaction != nil,
                resolvedByReactorId: reaction?.reactorId,
                resolvedByReactorType: reaction?.reactorType,
                resolvedAt: reaction == nil ? nil : Self.timestamp(comment.createdAt)
            )
        }
        return AgentAttachmentCommentsResponse(comments: comments, canResolve: canResolve)
    }

    /// `POST /internal/agent-api/attachments/:attachmentId/comments`: agents are
    /// descoped from writing comments, so a valid call always refuses.
    public func agentAttachmentCommentCreate(
        authorization: String?,
        attachmentId: String
    ) throws -> OkResponse {
        guard dependencies.agentCredential(authorization) != nil else {
            throw AttachmentCommentsError.agentAuthRequired
        }
        guard ServerScope.isUUID(attachmentId) else {
            throw AttachmentCommentsError.attachmentNotFound
        }
        throw AttachmentCommentsError.agentCommentCreateDisabled
    }

    // MARK: Body projections

    /// Strict structured-mention payload: the comment transport reuses the same
    /// wire shape as messages and rejects a malformed batch before any write.
    /// Absent or `null` is an empty batch; anything malformed is nil.
    static func strictMentions(_ raw: JSONValue?) -> [MentionInput]? {
        guard let raw, raw != .null else { return [] }
        guard case .array(let rows) = raw else { return nil }
        var result: [MentionInput] = []
        for row in rows {
            guard case .object(let object) = row,
                  case .string(let type)? = object["type"], type == "user" || type == "agent",
                  case .string(let id)? = object["id"], ServerScope.isUUID(id),
                  case .string(let name)? = object["name"], !name.isEmpty
            else { return nil }
            result.append(MentionInput(type: type, id: id, name: name))
        }
        return result
    }

    /// Canonical anchor projection: a closed type vocabulary, a payload cap
    /// measured before per-type validation, and a rebuild from known fields only
    /// (extras never reach storage). `json` is the stored fragment.
    static func canonicalAnchor(_ raw: JSONValue?) -> (json: String?, code: String?) {
        guard let raw, raw != .null else { return (nil, nil) }
        guard case .object(let object) = raw, case .object(let data)? = object["data"] else {
            return (nil, "anchor_invalid")
        }
        guard case .string(let type)? = object["type"] else { return (nil, "anchor_type_invalid") }
        // The cap measures the whole client payload: a 5 KB quote is rejected
        // as too large instead of being reported as a shape error.
        if let encoded = try? JSONEncoder().encode(raw), encoded.count > 4_096 {
            return (nil, "anchor_too_large")
        }
        func number(_ key: String) -> Double? {
            switch data[key] {
            case .integer(let value)?: Double(value)
            case .number(let value)?: value
            case .bool(let value)?: value ? 1 : 0
            default: nil
            }
        }
        func integer(_ key: String) -> Int? {
            guard let double = number(key), double.isFinite, double.rounded() == double else { return nil }
            return Int(exactly: double)
        }
        func roundedNumber(_ key: String) -> Int? {
            guard let double = number(key), double.isFinite else { return nil }
            return Int(exactly: double.rounded())
        }
        func quote() -> OrderedJSONField? {
            guard case .string(let value)? = data["quote"] else { return nil }
            return OrderedJSONField("quote", value)
        }
        func render(type: String, _ fields: [OrderedJSONField]) -> String {
            OrderedJSON.object([
                OrderedJSONField("type", type),
                OrderedJSONField("data", .object(fields + (quote().map { [$0] } ?? []))),
            ]).render()
        }
        switch type {
        case "lines", "csv-rows":
            guard let start = integer("start"), let end = integer("end"), start >= 1, end >= start else {
                return (nil, "anchor_invalid")
            }
            return (render(type: type, [
                OrderedJSONField("start", start),
                OrderedJSONField("end", end),
            ]), nil)
        case "md-section":
            guard case .string(let headingId)? = data["headingId"], !headingId.isEmpty,
                  case .string(let headingTitle)? = data["headingTitle"]
            else { return (nil, "anchor_invalid") }
            return (render(type: "md-section", [
                OrderedJSONField("headingId", headingId),
                OrderedJSONField("headingTitle", headingTitle),
            ]), nil)
        case "html-region":
            guard let x = roundedNumber("x"), let y = roundedNumber("y"),
                  let w = roundedNumber("w"), let h = roundedNumber("h"),
                  let viewportWidth = roundedNumber("viewportWidth"),
                  let documentWidth = roundedNumber("documentWidth"),
                  let documentHeight = roundedNumber("documentHeight"),
                  x >= 0, y >= 0, w >= 0, h >= 0,
                  viewportWidth > 0, documentWidth > 0, documentHeight > 0
            else { return (nil, "anchor_invalid") }
            return (render(type: "html-region", [
                OrderedJSONField("x", x),
                OrderedJSONField("y", y),
                OrderedJSONField("w", w),
                OrderedJSONField("h", h),
                OrderedJSONField("viewportWidth", viewportWidth),
                OrderedJSONField("documentWidth", documentWidth),
                OrderedJSONField("documentHeight", documentHeight),
            ]), nil)
        default:
            return (nil, "anchor_type_invalid")
        }
    }
}
