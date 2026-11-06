import Foundation

/// Domain failure for the served-inbox surface.
///
/// Every case names one published refusal. The legacy handlers built those
/// bodies by hand; `Respond.swift` now renders them from `errorCode` /
/// `errorBody`, so the bytes are unchanged. `notJoinable` is the one non-error
/// shape (`{"status":"NOT_JOINABLE"}`), which is why it carries `errorBody`.
public enum InboxAndWakeError: DomainError, Equatable {
    case invalidChannelId
    case invalidSyncCursor
    case missingAuthorization
    case invalidAccessToken
    case emailVerificationRequired
    case forbidden
    case invalidMessagePageCursor
    case channelNotFound
    case channelNotVisible
    case notJoinable
    case unauthorized

    public var status: UInt {
        switch self {
        case .invalidChannelId, .invalidSyncCursor, .invalidMessagePageCursor:
            400
        case .missingAuthorization, .invalidAccessToken, .unauthorized:
            401
        case .emailVerificationRequired, .forbidden:
            403
        case .channelNotFound, .channelNotVisible, .notJoinable:
            404
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidChannelId:
            "Invalid channel id"
        case .invalidSyncCursor:
            "Invalid sync cursor"
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidAccessToken:
            "Invalid or expired token"
        case .emailVerificationRequired:
            "Email verification required"
        case .forbidden:
            "Forbidden"
        case .invalidMessagePageCursor:
            "Invalid message page cursor"
        case .channelNotFound:
            "Channel not found"
        case .channelNotVisible:
            "Channel not found or not visible"
        case .notJoinable:
            "NOT_JOINABLE"
        case .unauthorized:
            "Unauthorized"
        }
    }

    /// The machine-readable `code` the published object appends after `error`.
    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidAccessToken:
            "auth_required"
        case .invalidMessagePageCursor:
            "invalid_message_page_cursor"
        case .invalidChannelId, .invalidSyncCursor, .emailVerificationRequired,
             .forbidden, .channelNotFound, .channelNotVisible, .notJoinable, .unauthorized:
            nil
        }
    }

    /// The agent-diagnostics refusal publishes `status` instead of `error`.
    public var errorBody: OrderedJSON? {
        switch self {
        case .notJoinable:
            .object([OrderedJSONField("status", "NOT_JOINABLE")])
        case .invalidChannelId, .invalidSyncCursor, .missingAuthorization,
             .invalidAccessToken, .emailVerificationRequired, .forbidden,
             .invalidMessagePageCursor, .channelNotFound, .channelNotVisible,
             .unauthorized:
            nil
        }
    }
}

/// The served-inbox boundary: the channel message page and its sync cursor, the
/// mention-delivery diagnostics, and the Done inbox page.
///
/// The service owns the ordering, validation and projection rules; the stores
/// own the rows and the OAuth ledger owns reads/unread state. It returns the
/// published `JSONBodyConvertible` DTOs and throws `InboxAndWakeError`; it never
/// builds an HTTP reply, header set or dictionary payload. Each operation reads one
/// `MessagesAndThreadsStore` snapshot and one `ServersAndChannelsStore` snapshot,
/// so a page, its window and its summaries all see the same rows.
public struct InboxAndWakeService: Sendable {
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let oauth: OAuthLedger
    private let dependencies: InboxAndWakeDependencies

    init(
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        oauth: OAuthLedger,
        dependencies: InboxAndWakeDependencies
    ) {
        self.messages = messages
        self.channels = channels
        self.oauth = oauth
        self.dependencies = dependencies
    }

    // MARK: - GET /api/messages/sync

    /// The channel message page and its sync cursor.
    ///
    /// A non-UUID `channel_id` is the published 400 before any credential check;
    /// `since_seq` accepts only an absent value, `"0"` or an integer. Without a
    /// `channel_id` the page aggregates every visible channel of the server, and
    /// a guest only sees channels they were added to.
    public func syncChannelMessages(
        channelId: String?,
        sinceSeq: String?,
        authorization: String?,
        serverId: String?,
        limit rawLimit: String? = nil
    ) throws -> InboxSyncPageDTO {
        if let channelId, !ServerScope.isUUID(channelId) {
            throw InboxAndWakeError.invalidChannelId
        }
        guard sinceSeq == nil || sinceSeq == "0" || Int(sinceSeq ?? "") != nil else {
            throw InboxAndWakeError.invalidSyncCursor
        }
        let userId = try requireUser(authorization)
        guard dependencies.isEmailVerified(userId) else {
            throw InboxAndWakeError.emailVerificationRequired
        }
        let pageLimit = MessagePageCursor.messagePageLimit(rawLimit)
        let commentsVisible = dependencies.attachmentCommentsEnabled(serverId ?? "", userId)
        let messageState = messages.state
        let channelState = channels.state
        if channelId == nil {
            return InboxSyncPageDTO(messages: Self.broadcastRows(
                userId: userId,
                serverId: serverId,
                sinceSeq: sinceSeq,
                pageLimit: pageLimit,
                commentsVisible: commentsVisible,
                messageState: messageState,
                channelState: channelState,
                oauth: oauth
            ))
        }
        guard let channelId else { throw InboxAndWakeError.invalidChannelId }
        if let serverId,
           dependencies.channelProbeAccess(channelId, serverId, userId) == .residue {
            throw InboxAndWakeError.forbidden
        }
        let visible: Bool = {
            guard let channel = channelState.postableChannels[channelId], channel.serverId == serverId else {
                return false
            }
            if channel.kind == "channel" { return true }
            let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
            if channel.kind == "thread" {
                if guest { return false }
                if let parentId = channel.parentChannelId,
                   let parent = channelState.postableChannels[parentId], parent.kind == "channel" {
                    return true
                }
            }
            return channel.memberIds.contains(userId)
        }()
        let storageChannelId = channelState.jointProjections
            .first { $0.localChannelId == channelId }?
            .canonicalChannelId ?? channelId
        let allRows = messageState.humanMessageRows.filter {
            $0.channelId == storageChannelId || $0.channelId == channelId
        }
        let cursor = Int(sinceSeq ?? "") ?? 0
        let indexed = allRows.filter { $0.seq > cursor }
        let limited = Array(indexed.suffix(pageLimit))
        let rows = limited.map { message in
            Self.syncRow(
                message,
                channelId: channelId,
                commentsVisible: commentsVisible,
                attachmentComments: messageState.attachmentCommentRecords,
                metadata: dependencies.forwardMetadata(message.id, userId, serverId)
                    ?? dependencies.actionCardMetadata(message.id)
            )
        }
        guard visible else { throw InboxAndWakeError.channelNotVisible }
        return InboxSyncPageDTO(messages: rows)
    }

    /// The `channel_id`-less sync page: every visible channel of the server in
    /// store order, then the newest `pageLimit` rows.
    private static func broadcastRows(
        userId: String,
        serverId: String?,
        sinceSeq: String?,
        pageLimit: Int,
        commentsVisible: Bool,
        messageState: MessagesAndThreadsStore.State,
        channelState: ServersAndChannelsStore.State,
        oauth: OAuthLedger
    ) -> [InboxSyncMessageDTO] {
        let cursor = Int(sinceSeq ?? "") ?? 0
        let isGuest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
        var guestJoined: Set<String> = []
        if isGuest {
            let candidateIds = Array(channelState.postableChannels.keys)
            guestJoined = Set(candidateIds.filter { oauth.channelHumanIds(channelId: $0).contains(userId) })
        }
        var visibleChannels: [String] = []
        for (id, channel) in channelState.postableChannels {
            guard channel.serverId == serverId, channel.deletedAt == nil, !channel.archived else { continue }
            if isGuest && !guestJoined.contains(id) { continue }
            if channel.kind == "channel" || channel.memberIds.contains(userId) {
                visibleChannels.append(id)
            }
        }
        var rows: [InboxSyncMessageDTO] = []
        for id in visibleChannels {
            let channelRows = messageState.humanMessageRows.filter { $0.channelId == id }
            for message in channelRows where message.seq > cursor {
                rows.append(Self.syncRow(
                    message,
                    channelId: id,
                    commentsVisible: commentsVisible,
                    attachmentComments: messageState.attachmentCommentRecords,
                    metadata: nil
                ))
            }
        }
        return Array(rows.suffix(pageLimit))
    }

    private static func syncRow(
        _ message: StoredHumanMessage,
        channelId: String,
        commentsVisible: Bool,
        attachmentComments: [String: [AttachmentCommentRecord]],
        metadata: OrderedJSON?
    ) -> InboxSyncMessageDTO {
        InboxSyncMessageDTO(
            id: message.id,
            channelId: channelId,
            seq: message.seq,
            content: message.content,
            attachments: attachmentChips(
                message.attachmentIds,
                commentsVisible: commentsVisible,
                records: attachmentComments
            ),
            commentRef: commentsVisible
                ? commentRef(records: attachmentComments, messageId: message.id)
                : nil,
            actionMetadata: metadata
        )
    }

    // MARK: - GET /api/messages/channel/:channelId

    /// One channel page, its frozen window and the thread summaries hanging off
    /// it. A guest visibility refusal runs before cursor validation; a non-UUID
    /// channel is the published 404, and a UUID the caller cannot see uses the
    /// neutral body after the page has been projected.
    public func listChannelMessages(
        channelId: String,
        authorization: String?,
        serverId: String?,
        limit rawLimit: String? = nil,
        before rawBefore: String? = nil,
        after rawAfter: String? = nil
    ) throws -> ChannelMessagesPageDTO {
        let channelState = channels.state
        if let serverId, let userId = sessionUserId(authorization) {
            let threadScope = channelState.postableChannels[channelId]?.kind == "thread"
            let guestVisible = dependencies.guestCanSeeScope(channelId)
            if oauth.memberRole(serverId: serverId, userId: userId) == "guest",
               !oauth.channelHumanIds(channelId: channelId).contains(userId) {
                throw InboxAndWakeError.forbidden
            }
            if threadScope, oauth.memberRole(serverId: serverId, userId: userId) == "guest", !guestVisible {
                throw InboxAndWakeError.forbidden
            }
        }
        let before = MessagePageCursor.parsePageCursor(rawBefore)
        let after = MessagePageCursor.parsePageCursor(rawAfter)
        if before == .invalid || after == .invalid
            || (before.value != nil && after.value != nil && rawBefore != nil && rawAfter != nil) {
            throw InboxAndWakeError.invalidMessagePageCursor
        }
        if !ServerScope.isUUID(channelId) {
            throw InboxAndWakeError.channelNotFound
        }
        let userId: String?
        switch dependencies.authorize(authorization) {
        case .user(let id):
            userId = id
        case .missingAuthorization, .invalidAccessToken:
            userId = nil
        }
        let messageState = messages.state
        if let userId, let serverId,
           dependencies.channelProbeAccess(channelId, serverId, userId) == .residue {
            throw InboxAndWakeError.forbidden
        }
        let visible: Bool = {
            guard let channel = channelState.postableChannels[channelId],
                  channel.serverId == serverId,
                  channel.deletedAt == nil,
                  let userId
            else { return false }
            if channel.kind == "channel" { return true }
            let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
            if channel.kind == "thread" {
                if guest { return false }
                if let parentId = channel.parentChannelId, let parent = channelState.postableChannels[parentId] {
                    if parent.kind == "channel" { return parent.deletedAt == nil }
                    return channel.memberIds.contains(userId)
                }
                return channel.memberIds.contains(userId)
            }
            return channel.memberIds.contains(userId)
        }()
        let storageChannelId = channelState.jointProjections
            .first { $0.localChannelId == channelId }?
            .canonicalChannelId ?? channelId
        let rows = messageState.humanMessageRows.filter {
            $0.channelId == storageChannelId || $0.channelId == channelId
        }
        let cursorRows = rows.filter { row in
            if let before = before.value, row.seq >= before { return false }
            if let after = after.value, row.seq <= after { return false }
            return true
        }
        let pageRows = Array(cursorRows.suffix(MessagePageCursor.messagePageLimit(rawLimit)))
        let statusRequests = pageRows.map { (id: $0.id, senderId: $0.senderId, senderType: $0.senderType) }
        let memberStatusSnapshot = channelState.serverMemberStatuses
        var senderStatuses: [String: String] = [:]
        for request in statusRequests {
            if request.senderType == "agent" {
                senderStatuses[request.id] = oauth.agentRuntimeInfo(id: request.senderId)?.deleted == true
                    ? "removed"
                    : "active"
            } else if let serverId, oauth.memberRole(serverId: serverId, userId: request.senderId) != nil {
                senderStatuses[request.id] = "active"
            } else {
                senderStatuses[request.id] = memberStatusSnapshot[
                    "\(serverId ?? "")\n\(request.senderId)"
                ] ?? "removed"
            }
        }
        let highWater = rows.map(\.seq).max() ?? 0
        let pageSeqs = pageRows.map(\.seq)
        let isTail = rawBefore == nil && rawAfter == nil
        let coveredFrom = pageSeqs.first ?? (isTail ? 1 : 0)
        let coveredThrough = pageSeqs.last ?? 0
        let coveredAfter = max(0, coveredFrom - 1)
        let window = InboxMessageWindowDTO(
            serverId: serverId ?? "",
            receiverId: userId ?? "",
            scopeId: channelId,
            coveredFromSeq: coveredFrom,
            coveredAfterSeq: coveredAfter,
            coveredThroughSeq: coveredThrough,
            remoteHighWaterSeq: highWater,
            hasGap: !isTail,
            hasNewer: rawBefore != nil,
            completeThroughLatest: isTail
        )
        let commentsVisible = dependencies.attachmentCommentsEnabled(serverId ?? "", userId)
        let listed = pageRows.map { message -> InboxChannelMessageRowDTO in
            let membershipStatus = senderStatuses[message.id] ?? "removed"
            var metadata = dependencies.actionCardMetadata(message.id)
            if let userId {
                metadata = dependencies.forwardMetadata(message.id, userId, serverId) ?? metadata
            }
            return InboxChannelMessageRowDTO(
                id: message.id,
                senderId: message.senderId,
                senderType: message.senderType,
                senderMembershipStatus: membershipStatus,
                content: message.content,
                attachments: Self.attachmentChips(
                    message.attachmentIds,
                    commentsVisible: commentsVisible,
                    records: messageState.attachmentCommentRecords
                ),
                reactions: dependencies.reactions(message.id),
                mentions: Self.visibleMentions(messageState.storedMentions, messageId: message.id),
                commentRef: commentsVisible
                    ? Self.commentRef(
                        records: messageState.attachmentCommentRecords,
                        messageId: message.id
                    )
                    : nil,
                actionMetadata: metadata
            )
        }
        let summaries = dependencies.threadSummaries(channelId, pageRows.map(\.id))
        guard visible else { throw InboxAndWakeError.channelNotVisible }
        return ChannelMessagesPageDTO(
            messages: listed,
            messageWindow: window,
            threadSummariesByParentMessageId: summaries
        )
    }

    /// Mentions a reader can see: notifiable at send, or later notified.
    private static func visibleMentions(_ rows: [StoredMention], messageId: String) -> [InboxMentionDTO] {
        rows.filter { row in
            row.messageId == messageId && (row.notifiableAtSend || row.notifiedAt != nil)
        }.map { row in
            InboxMentionDTO(type: row.targetType, id: row.targetId, name: row.handle)
        }
    }

    // MARK: - GET /api/messages/:messageId/mention-deliveries

    /// The author's coarse delivery outcomes. Only the author who can still read
    /// the channel sees them; every other caller gets the neutral
    /// `{"status":"NOT_JOINABLE"}` 404.
    public func mentionDeliveries(
        messageId: String,
        authorization: String?,
        serverId: String?
    ) throws -> MentionDeliveriesResponseDTO {
        let userId = try requireUser(authorization)
        guard dependencies.isEmailVerified(userId) else {
            throw InboxAndWakeError.emailVerificationRequired
        }
        guard ServerScope.isUUID(messageId) else {
            throw InboxAndWakeError.notJoinable
        }
        let messageState = messages.state
        let channelState = channels.state
        guard let message = messageState.humanMessageRows.first(where: {
            $0.id.caseInsensitiveCompare(messageId) == .orderedSame
        }),
            message.senderType == "user",
            message.senderId == userId,
            dependencies.messageSearchVisible(message.channelId, serverId, userId),
            channelState.postableChannels[message.channelId]?.serverId == serverId
        else {
            throw InboxAndWakeError.notJoinable
        }
        let deliveries = messageState.storedMentions.filter {
            $0.messageId == message.id && $0.targetType == "agent" && $0.notifiableAtSend
        }.map { mention in
            MentionDeliveryRowDTO(
                targetId: mention.targetId,
                handle: mention.handle,
                terminalCode: mention.terminalCode
            )
        }
        return MentionDeliveriesResponseDTO(messageId: message.id, deliveries: deliveries)
    }

    // MARK: - GET /api/channels/inbox/done

    /// The Done inbox page. A DM outsider mention is not an inbox item; a guest
    /// only sees scopes they can still read. `totalCount` is the published
    /// literal `null`.
    public func doneInbox(
        authorization: String?,
        serverId: String?,
        query: String? = nil
    ) throws -> InboxDonePageDTO {
        guard let userId = sessionUserId(authorization) else {
            throw InboxAndWakeError.unauthorized
        }
        let params = MessagePageCursor.inboxQueryParameters(query)
        let limit = min(max(Int(params["limit"] ?? "") ?? 30, 1), 100)
        let q = (params["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let channelFilter = params["channelId"]
        let ascending = params["sort"] == "asc"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let messageState = messages.state
        let channelState = channels.state
        let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
        var rows: [(id: String, kind: String, channelId: String?, threadChannelId: String?, parentChannelId: String?, doneAt: Date)] = []
        for key in messageState.inboxDoneScopes where key.hasPrefix("\(userId)\n") {
            let scopeId = String(key.dropFirst("\(userId)\n".count))
            if guest, !dependencies.guestCanSeeScope(scopeId) { continue }
            let type = channelState.postableChannels[scopeId]?.kind
                ?? oauth.channelType(id: scopeId)
                ?? "channel"
            let isThread = type == "thread"
            let parentId = channelState.postableChannels[scopeId]?.parentChannelId
            if let channelFilter, !(isThread ? parentId == channelFilter : scopeId == channelFilter) {
                continue
            }
            if !q.isEmpty {
                let matches = messageState.humanMessageRows.contains { row in
                    row.channelId == scopeId && row.content.localizedCaseInsensitiveContains(q)
                }
                if !matches { continue }
            }
            rows.append((
                id: scopeId,
                kind: isThread ? "thread" : "channel",
                channelId: isThread ? nil : scopeId,
                threadChannelId: isThread ? scopeId : nil,
                parentChannelId: parentId,
                doneAt: messageState.inboxDoneAt[key] ?? Date.distantPast
            ))
        }
        rows.sort { lhs, rhs in
            if lhs.doneAt != rhs.doneAt {
                return ascending ? lhs.doneAt < rhs.doneAt : lhs.doneAt > rhs.doneAt
            }
            return ascending ? lhs.id < rhs.id : lhs.id > rhs.id
        }
        let page = Array(rows.prefix(limit))
        let items = page.map { row -> InboxDoneItemDTO in
            let done = formatter.string(from: row.doneAt)
            if row.kind == "thread" {
                let following = messageState.threadFollows[
                    "\(serverId ?? "")\n\(userId)\n\(row.id)"
                ] != nil
                let unread = oauth.channelUnreadInfo(channelId: row.id, userId: userId).unreadCount
                return .thread(
                    threadChannelId: row.id,
                    parentChannelId: row.parentChannelId,
                    isFollowing: following,
                    unreadCount: unread,
                    doneAt: done
                )
            }
            let unread = oauth.channelUnreadInfo(channelId: row.id, userId: userId).unreadCount
            return .channel(channelId: row.id, unreadCount: unread, doneAt: done)
        }
        return InboxDonePageDTO(items: items, hasMore: rows.count > page.count)
    }

    // MARK: - Helpers

    private func sessionUserId(_ authorization: String?) -> String? {
        if case .user(let id) = dependencies.authorize(authorization) { return id }
        return nil
    }

    private func requireUser(_ authorization: String?) throws -> String {
        switch dependencies.authorize(authorization) {
        case .user(let id):
            return id
        case .missingAuthorization:
            throw InboxAndWakeError.missingAuthorization
        case .invalidAccessToken:
            throw InboxAndWakeError.invalidAccessToken
        }
    }

    /// The attachment chips of one message: a viewer who cannot use attachment
    /// comments observes count zero, never a hint.
    private static func attachmentChips(
        _ ids: [String],
        commentsVisible: Bool,
        records: [String: [AttachmentCommentRecord]]
    ) -> [InboxAttachmentChipDTO] {
        ids.map { id in
            InboxAttachmentChipDTO(
                id: id,
                commentCount: commentsVisible ? (records[id]?.count ?? 0) : 0
            )
        }
    }

    /// The scoped comment chip of one message, in attachment-record order.
    private static func commentRef(
        records: [String: [AttachmentCommentRecord]],
        messageId: String
    ) -> InboxCommentRefDTO? {
        for (attachmentId, rows) in records {
            guard let record = rows.first(where: { $0.id == messageId }),
                  let hostMessageId = record.hostMessageId,
                  let hostChannelId = record.hostChannelId
            else { continue }
            return InboxCommentRefDTO(
                attachmentId: attachmentId,
                hostMessageId: hostMessageId,
                hostSource: InboxCommentSourceDTO(
                    channelId: hostChannelId,
                    rootThreadChannelId: record.threadChannelId
                )
            )
        }
        return nil
    }
}
