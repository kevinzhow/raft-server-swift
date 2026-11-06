import Foundation

/// Domain failure for the thread surface.
///
/// Every case names one published refusal. The legacy handlers built those
/// bodies by hand; `Respond.swift` now renders them from `errorBody` /
/// `errorCode`, so the bytes are unchanged. Two unrelated retirements share a
/// status and differ only in the published text (`Unauthorized` vs the public
/// surface's `Missing or invalid Authorization header`), which is why they are
/// separate cases rather than one `unauthorized`.
public enum ThreadsError: DomainError, Equatable {
    /// The thread routes' plain missing-session refusal.
    case unauthorized
    /// `GET /api/channels/:channelId/threads` public-surface refusal: no header.
    case missingAuthorization
    /// Same surface, a header that is not a live bearer token.
    case invalidAccessToken
    case notServerMember
    case forbidden
    case channelNotFound
    case channelNotVisible
    case threadNotFound
    case threadNotFoundForMessage
    case limitOutOfRange
    case cursorRequiresLimit
    case invalidCursor

    public var status: UInt {
        switch self {
        case .unauthorized, .missingAuthorization, .invalidAccessToken:
            401
        case .notServerMember, .forbidden:
            403
        case .channelNotFound, .channelNotVisible, .threadNotFound, .threadNotFoundForMessage:
            404
        case .limitOutOfRange, .cursorRequiresLimit, .invalidCursor:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidAccessToken:
            "Invalid or expired token"
        case .notServerMember:
            "Not a member of this server"
        case .forbidden:
            "Forbidden"
        case .channelNotFound:
            "Channel not found"
        case .channelNotVisible:
            "Channel not found or not visible"
        case .threadNotFound:
            "Thread not found"
        case .threadNotFoundForMessage:
            "No thread found for this message"
        case .limitOutOfRange:
            "limit must be an integer between 1 and 200"
        case .cursorRequiresLimit:
            "cursor requires limit"
        case .invalidCursor:
            "invalid cursor"
        }
    }

    /// The public thread route appends the machine-readable auth code; the
    /// thread-not-found message publishes its code *before* `error`, so it uses
    /// `errorBody` instead.
    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidAccessToken:
            "auth_required"
        case .unauthorized, .notServerMember, .forbidden, .channelNotFound,
             .channelNotVisible, .threadNotFound, .threadNotFoundForMessage,
             .limitOutOfRange, .cursorRequiresLimit, .invalidCursor:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .threadNotFoundForMessage:
            return .object([
                OrderedJSONField("code", "THREAD_NOT_FOUND"),
                OrderedJSONField("error", errorMessage),
            ])
        case .unauthorized, .missingAuthorization, .invalidAccessToken, .notServerMember,
             .forbidden, .channelNotFound, .channelNotVisible, .threadNotFound,
             .limitOutOfRange, .cursorRequiresLimit, .invalidCursor:
            return nil
        }
    }

    /// The public thread route's refusal keeps the standard JSON header set but
    /// also marks the reply `no-store`, as its legacy reply helper did. Every
    /// other thread refusal uses the plain set.
    public var responseHeaders: [String: String] {
        switch self {
        case .missingAuthorization, .invalidAccessToken:
            ["Cache-Control": "no-store"]
        case .unauthorized, .notServerMember, .forbidden, .channelNotFound,
             .channelNotVisible, .threadNotFound, .threadNotFoundForMessage,
             .limitOutOfRange, .cursorRequiresLimit, .invalidCursor:
            [:]
        }
    }
}

// MARK: - Service

/// The thread domain: follower roster, follow/unfollow with its frozen reply
/// window, the followed and unfollowed inbox pages, and the per-message and
/// per-channel thread projections.
///
/// The service owns the thread follow ledger and returns the published
/// `Codable` / `JSONBodyConvertible` DTOs; every refusal is a `ThreadsError`.
/// It builds no HTTP reply, header set or JSON string. Follow and unfollow take
/// one `MessagesAndThreadsStore` critical section, so the follow row, its start
/// time and the unfollow suppression row can never be observed half-updated.
public struct ThreadsService: Sendable {
    private let store: MessagesAndThreadsStore
    private let dependencies: ThreadsDependencies
    private let publishFollowersUpdated: @Sendable (ThreadFollowersUpdatedPayload) -> Void

    init(
        store: MessagesAndThreadsStore,
        dependencies: ThreadsDependencies,
        publishFollowersUpdated: @escaping @Sendable (ThreadFollowersUpdatedPayload) -> Void = { _ in }
    ) {
        self.store = store
        self.dependencies = dependencies
        self.publishFollowersUpdated = publishFollowersUpdated
    }

    // MARK: - GET /api/channels/threads/followers

    /// The follower roster for the requested thread channels, in request order.
    /// A thread that is not on this server or is not a thread is skipped, and a
    /// viewer may manage only a thread they own or administer.
    public func threadFollowerRoster(
        authorization: String?,
        serverId: String,
        threadChannelIds: String?
    ) throws -> ThreadFollowerRosterResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ThreadsError.unauthorized
        }
        guard let role = dependencies.memberRole(serverId, userId) else {
            throw ThreadsError.notServerMember
        }
        let ids = (threadChannelIds ?? "")
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }
        let channels = dependencies.channels().channels
        let messages = store.humanMessageRows
        var rows: [ThreadFollowerRosterRowDTO] = []
        for threadId in ids {
            guard let thread = channels[threadId], thread.serverId == serverId, thread.kind == "thread" else {
                continue
            }
            let authorId = thread.parentMessageId.flatMap { parentId in
                messages.first { $0.id == parentId }?.senderId
            }
            let canManage = role == "owner" || role == "admin" || authorId == userId
            let agents = dependencies.channelAgentIds(threadId).compactMap { agentId -> ThreadFollowerAgentDTO? in
                guard let agent = dependencies.agentInfo(agentId) else { return nil }
                return ThreadFollowerAgentDTO(id: agent.id, name: agent.name)
            }
            rows.append(ThreadFollowerRosterRowDTO(
                threadChannelId: threadId,
                canManage: canManage,
                agents: agents
            ))
        }
        return ThreadFollowerRosterResponse(threads: rows)
    }

    // MARK: - POST /api/channels/threads/follow and /unfollow

    /// The follow/unfollow mutation. The body is optional because a body that
    /// is not a JSON object keeps the published `Thread not found` refusal; the
    /// follower event is published only when the request named the thread
    /// directly and the write succeeded, matching the legacy frame guard.
    public func setThreadFollow(
        _ body: ThreadFollowMutationDTO?,
        authorization: String?,
        serverId: String,
        follow: Bool
    ) throws -> ThreadFollowResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ThreadsError.unauthorized
        }
        guard dependencies.memberRole(serverId, userId) != nil else {
            throw ThreadsError.notServerMember
        }
        guard let body else { throw ThreadsError.threadNotFound }
        let snapshot = dependencies.channels()
        let threadId: String
        if let named = body.threadChannelId {
            threadId = named
        } else if let parentMessageId = body.parentMessageId,
                  let resolved = store.threadId(serverId: serverId, parentMessageId: parentMessageId)
                    ?? snapshot.channels.first(where: {
                        $0.value.serverId == serverId && $0.value.parentMessageId == parentMessageId
                    })?.key {
            threadId = resolved
        } else {
            throw ThreadsError.threadNotFound
        }
        guard dependencies.channelServerId(threadId) == serverId else {
            throw ThreadsError.threadNotFound
        }
        guard Self.threadParentVisible(
            threadId: threadId,
            userId: userId,
            channels: snapshot.channels
        ) else {
            throw ThreadsError.threadNotFound
        }
        let parentMessageId = snapshot.channels[threadId]?.parentMessageId ?? body.parentMessageId ?? ""
        store.applyThreadFollow(
            serverId: serverId,
            userId: userId,
            threadChannelId: threadId,
            parentMessageId: parentMessageId,
            follow: follow,
            now: dependencies.now()
        )
        if let requested = body.threadChannelId, !requested.isEmpty {
            publishFollowersUpdated(ThreadFollowersUpdatedPayload(threadChannelId: requested))
        }
        return ThreadFollowResponse(following: follow)
    }

    /// A thread is readable only through its parent's current visibility.
    private static func threadParentVisible(
        threadId: String,
        userId: String,
        channels: [String: PostableChannel]
    ) -> Bool {
        guard let thread = channels[threadId], thread.kind == "thread" else { return false }
        guard let parentId = thread.parentChannelId else { return true }
        guard let parent = channels[parentId] else { return false }
        return parent.kind == "channel" || parent.memberIds.contains(userId)
    }

    // MARK: - GET /api/channels/inbox/unfollowed

    /// The unfollowed inbox page: newest suppression rows first, optionally
    /// filtered by a case-insensitive content match over the frozen replies.
    public func unfollowedInbox(
        authorization: String?,
        serverId: String,
        limit rawLimit: String?,
        query: String?
    ) throws -> UnfollowedInboxResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ThreadsError.unauthorized
        }
        guard dependencies.memberRole(serverId, userId) != nil else {
            throw ThreadsError.notServerMember
        }
        let limit = MessagePageCursor.messagePageLimit(rawLimit)
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var records = store.threadUnfollowRecords(serverId: serverId, userId: userId)
        if !needle.isEmpty {
            records = records.filter { record in
                record.frozenMessages.contains { $0.content.localizedCaseInsensitiveContains(needle) }
            }
        }
        records.sort { $0.unfollowedAt > $1.unfollowedAt }
        let page = Array(records.prefix(limit))
        let formatter = ISO8601DateFormatter()
        let items = page.map { record in
            UnfollowedInboxItemDTO(
                threadChannelId: record.threadChannelId,
                latestActivityMessageId: record.latestMessageId,
                replyCount: record.replyCount,
                unfollowedAt: formatter.string(from: record.unfollowedAt)
            )
        }
        return UnfollowedInboxResponse(items: items, hasMore: records.count > page.count)
    }

    // MARK: - GET /api/channels/threads/followed

    /// The followed-thread page. `limit` selects the `v1:` cursor shape and the
    /// published `next` member; without it the whole list is published and
    /// `next` is absent.
    public func followedThreads(
        authorization: String?,
        serverId: String,
        limit rawLimit: String? = nil,
        cursor rawCursor: String? = nil,
        unreadOnly rawUnreadOnly: String? = nil
    ) throws -> FollowedThreadsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ThreadsError.unauthorized
        }
        guard dependencies.memberRole(serverId, userId) != nil else {
            throw ThreadsError.notServerMember
        }
        let pageLimit: Int?
        if let rawLimit {
            guard let parsed = Int(rawLimit), parsed >= 1, parsed <= 200, String(parsed) == rawLimit else {
                throw ThreadsError.limitOutOfRange
            }
            pageLimit = parsed
        } else {
            pageLimit = nil
        }
        var cursorOffset = 0
        if let rawCursor {
            guard pageLimit != nil else { throw ThreadsError.cursorRequiresLimit }
            guard rawCursor.hasPrefix("v1:"),
                  let parsed = Int(rawCursor.dropFirst(3)),
                  parsed >= 0
            else {
                throw ThreadsError.invalidCursor
            }
            cursorOffset = parsed
        }
        let unreadOnly = rawUnreadOnly == "1" || rawUnreadOnly == "true"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let channels = dependencies.channels().channels
        let messages = store.humanMessageRows
        let unreadMentionIds = store.unreadMentionMessageIds(userId: userId)
        var entries: [FollowedThreadEntry] = []
        for follow in store.activeThreadFollows(serverId: serverId, userId: userId) {
            guard let thread = channels[follow.threadChannelId], thread.deletedAt == nil else { continue }
            if let parentId = thread.parentChannelId,
               let parent = channels[parentId],
               parent.deletedAt != nil {
                continue
            }
            if dependencies.memberRole(serverId, userId) == "guest",
               !dependencies.guestCanSeeScope(follow.threadChannelId) {
                continue
            }
            let info = dependencies.channelUnread(follow.threadChannelId, userId)
            let threadReplies = messages.filter { $0.channelId == follow.threadChannelId }
            var unreadCount = info.unreadCount
            var firstUnread: String?
            if !threadReplies.isEmpty {
                unreadCount = 0
                for reply in threadReplies where reply.seq > info.maxReadSeq && reply.senderId != userId {
                    unreadCount += 1
                    if firstUnread == nil { firstUnread = reply.id }
                }
            }
            if unreadOnly, unreadCount == 0 { continue }
            let unreadIDs = Set(threadReplies
                .filter { $0.seq > info.maxReadSeq && $0.senderId != userId }
                .map(\.id))
            let hasMention = !unreadMentionIds.isDisjoint(with: unreadIDs)
            let parentCreatedAt = messages.first(where: { $0.id == follow.parentMessageId })?.createdAt
                ?? Date.distantPast
            entries.append(FollowedThreadEntry(
                threadId: follow.threadChannelId,
                parentChannelId: thread.parentChannelId ?? "",
                parentCreatedAt: parentCreatedAt,
                unreadCount: unreadCount,
                firstUnread: firstUnread,
                hasMention: hasMention,
                parentMessageId: follow.parentMessageId
            ))
        }
        entries.sort { lhs, rhs in
            if lhs.parentCreatedAt != rhs.parentCreatedAt { return lhs.parentCreatedAt > rhs.parentCreatedAt }
            return lhs.threadId > rhs.threadId
        }
        let page: ArraySlice<FollowedThreadEntry>
        let next: String?
        if let pageLimit {
            let start = min(cursorOffset, entries.count)
            let end = min(start + pageLimit, entries.count)
            page = entries[start..<end]
            next = end < entries.count ? "v1:\(end)" : nil
        } else {
            page = entries[...]
            next = nil
        }
        var rows: [FollowedThreadRowDTO] = []
        for entry in page {
            let task = dependencies.taskForMessage(entry.parentMessageId)
            var claimedName: String?
            if let assigneeId = task?.assigneeId, let assigneeType = task?.assigneeType {
                if assigneeType == "user" {
                    claimedName = dependencies.userName(assigneeId)
                } else {
                    claimedName = dependencies.agentInfo(assigneeId)?.name
                }
            }
            rows.append(FollowedThreadRowDTO(
                threadChannelId: entry.threadId,
                parentChannelId: entry.parentChannelId,
                parentMessageCreatedAt: formatter.string(from: entry.parentCreatedAt),
                unreadCount: entry.unreadCount,
                firstUnreadMessageId: entry.firstUnread,
                hasMention: entry.hasMention,
                taskId: task?.id,
                taskClaimedByType: task?.assigneeType,
                taskClaimedById: task?.assigneeId,
                taskClaimedByName: claimedName
            ))
        }
        return FollowedThreadsResponse(threads: rows, next: next, publishesNext: pageLimit != nil)
    }

    /// One followed row before the published field encoding.
    private struct FollowedThreadEntry {
        var threadId: String
        var parentChannelId: String
        var parentCreatedAt: Date
        var unreadCount: Int
        var firstUnread: String?
        var hasMention: Bool
        var parentMessageId: String
    }

    // MARK: - GET /api/channels/:channelId/threads/:messageId

    /// The canonical thread hanging off one parent message, scoped to the
    /// channel the caller named.
    public func threadInfo(
        authorization: String?,
        serverId: String,
        channelId: String,
        messageId: String
    ) throws -> ThreadInfoResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ThreadsError.unauthorized
        }
        guard dependencies.memberRole(serverId, userId) != nil else {
            throw ThreadsError.notServerMember
        }
        let snapshot = dependencies.channels()
        if dependencies.channelProbeAccess(channelId, serverId, userId) == .residue {
            throw ThreadsError.forbidden
        }
        guard let channel = snapshot.channels[channelId],
              channel.serverId == serverId,
              dependencies.channelActorCanSee(channelId, userId)
        else {
            throw ThreadsError.channelNotVisible
        }
        let messages = store.humanMessageRows
        let inChannel = messages.contains { $0.id == messageId && $0.channelId == channelId }
            || dependencies.messageChannelId(messageId) == channelId
        guard inChannel else { throw ThreadsError.threadNotFoundForMessage }
        guard let thread = Self.canonicalThread(
            parentChannelId: channelId,
            parentMessageId: messageId,
            channels: snapshot.channels,
            order: snapshot.order,
            messages: messages
        ), thread.channel.serverId == serverId else {
            throw ThreadsError.threadNotFoundForMessage
        }
        let replies = messages.filter { $0.channelId == thread.id }
        var participants = Set(replies.map(\.senderId))
        if let parent = messages.first(where: { $0.id == messageId }) {
            participants.insert(parent.senderId)
        }
        let lastReply = replies.last.map { ISO8601DateFormatter().string(from: $0.createdAt) }
        return ThreadInfoResponse(
            threadChannelId: thread.id,
            replyCount: replies.count,
            lastReplyAt: lastReply,
            participantIds: participants.sorted()
        )
    }

    /// One canonical thread per parent message: newest reply, then reply count,
    /// then creation order and id. Historical duplicates must not split reads.
    private static func canonicalThread(
        parentChannelId: String,
        parentMessageId: String,
        channels: [String: PostableChannel],
        order: [String],
        messages: [StoredHumanMessage]
    ) -> (id: String, channel: PostableChannel)? {
        let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let candidates = channels.filter { _, candidate in
            candidate.kind == "thread"
                && candidate.parentChannelId == parentChannelId
                && candidate.parentMessageId == parentMessageId
                && candidate.deletedAt == nil
        }
        guard !candidates.isEmpty else { return nil }
        func lastReplyAt(_ threadId: String) -> Date {
            messages.filter { $0.channelId == threadId }.map(\.createdAt).max() ?? .distantPast
        }
        func replyCount(_ threadId: String) -> Int {
            messages.filter { $0.channelId == threadId }.count
        }
        let sorted = candidates.sorted { lhs, rhs in
            let lhsLast = lastReplyAt(lhs.key)
            let rhsLast = lastReplyAt(rhs.key)
            if lhsLast != rhsLast { return lhsLast > rhsLast }
            let lhsCount = replyCount(lhs.key)
            let rhsCount = replyCount(rhs.key)
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            let lhsOrder = orderIndex[lhs.key] ?? Int.max
            let rhsOrder = orderIndex[rhs.key] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.key < rhs.key
        }
        return sorted.first.map { ($0.key, $0.value) }
    }

    // MARK: - GET /api/channels/:channelId/threads

    /// The channel thread map: one canonical summary per parent message, keyed
    /// by parent message id. Without an explicit parent filter only the newest
    /// 100 threads survive; the surviving threads are visited in creation order,
    /// which is the order the canonical parent members are published in.
    public func channelThreadSummaries(
        authorization: String?,
        serverId: String?,
        channelId: String,
        parentMessageIds rawParentIds: String? = nil
    ) throws -> ChannelThreadSummariesResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            if authorization?.hasPrefix("Bearer ") == true {
                throw ThreadsError.invalidAccessToken
            }
            throw ThreadsError.missingAuthorization
        }
        let snapshot = dependencies.channels()
        guard let channel = snapshot.channels[channelId], channel.serverId == serverId else {
            throw ThreadsError.channelNotFound
        }
        let visible = channel.kind == "channel" || channel.memberIds.contains(userId)
        if !visible,
           dependencies.channelProbeAccess(channelId, serverId ?? "", userId) == .residue {
            throw ThreadsError.forbidden
        }
        guard visible else { throw ThreadsError.channelNotFound }
        var threads = snapshot.channels.filter { _, candidate in
            candidate.serverId == serverId
                && candidate.kind == "thread"
                && candidate.parentChannelId == channelId
                && candidate.deletedAt == nil
        }
        let requestedParents: Set<String>? = {
            guard let rawParentIds,
                  !rawParentIds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return Set(rawParentIds
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }()
        if let requestedParents {
            threads = threads.filter { _, thread in
                guard let parentMessageId = thread.parentMessageId else { return false }
                return requestedParents.contains(parentMessageId)
            }
        }
        let orderIndex = Dictionary(uniqueKeysWithValues: snapshot.order.enumerated().map { ($1, $0) })
        var orderedThreads = threads.map { (id: $0.key, channel: $0.value) }
        orderedThreads.sort { lhs, rhs in
            let left = orderIndex[lhs.id] ?? Int.max
            let right = orderIndex[rhs.id] ?? Int.max
            if left != right { return left < right }
            // Creation order is absent for a thread the ledger did not record
            // (imported rows); the id keeps the published member order stable.
            return lhs.id < rhs.id
        }
        if requestedParents == nil, orderedThreads.count > 100 {
            orderedThreads = Array(orderedThreads.suffix(100))
        }
        let messages = store.humanMessageRows
        var canonicalByParent: [String: (id: String, channel: PostableChannel)] = [:]
        var parentOrder: [String] = []
        for (threadId, thread) in orderedThreads {
            guard let parentMessageId = thread.parentMessageId else { continue }
            if let existing = canonicalByParent[parentMessageId] {
                let existingLast = messages.filter { $0.channelId == existing.id }.map(\.createdAt).max() ?? .distantPast
                let candidateLast = messages.filter { $0.channelId == threadId }.map(\.createdAt).max() ?? .distantPast
                let existingCount = messages.filter { $0.channelId == existing.id }.count
                let candidateCount = messages.filter { $0.channelId == threadId }.count
                if candidateLast > existingLast
                    || (candidateLast == existingLast && candidateCount > existingCount)
                    || (candidateLast == existingLast && candidateCount == existingCount && threadId < existing.id) {
                    canonicalByParent[parentMessageId] = (threadId, thread)
                }
            } else {
                canonicalByParent[parentMessageId] = (threadId, thread)
                parentOrder.append(parentMessageId)
            }
        }
        var entries: [ChannelThreadSummaryEntry] = []
        for parentMessageId in parentOrder {
            guard let canonical = canonicalByParent[parentMessageId] else { continue }
            let threadId = canonical.id
            let replies = messages.filter { $0.channelId == threadId }
            var participantSet = Set(replies.map(\.senderId))
            if let parent = messages.first(where: { $0.id == parentMessageId }) {
                participantSet.insert(parent.senderId)
            }
            let participants = Array(participantSet).sorted()
            let following = store.isThreadFollowed(
                serverId: serverId ?? "",
                userId: userId,
                threadChannelId: threadId
            )
            let unreadInfo = dependencies.channelUnread(threadId, userId)
            var unreadCount = 0
            var firstUnread: String?
            if following {
                if replies.isEmpty {
                    unreadCount = unreadInfo.unreadCount
                    firstUnread = dependencies.firstUnreadMessageId(threadId, userId)
                } else {
                    var first: String?
                    for reply in replies where reply.seq > unreadInfo.maxReadSeq && reply.senderId != userId {
                        unreadCount += 1
                        if first == nil { first = reply.id }
                    }
                    firstUnread = first
                }
            }
            let latestReplyDTOs = replies
                .filter { $0.messageType != "system" }
                .suffix(3)
                .map { reply -> ChannelThreadReplyDTO in
                    let senderName: String
                    let senderDisplay: String
                    if reply.senderType == "agent" {
                        let info = dependencies.agentInfo(reply.senderId)
                        senderName = info?.name ?? reply.senderId
                        senderDisplay = info?.displayName ?? senderName
                    } else {
                        let name = dependencies.userName(reply.senderId) ?? reply.senderId
                        senderName = name
                        senderDisplay = name
                    }
                    return ChannelThreadReplyDTO(
                        preview: reply.content,
                        senderType: reply.senderType,
                        senderId: reply.senderId,
                        senderName: senderName,
                        senderDisplayName: senderDisplay
                    )
                }
            entries.append(ChannelThreadSummaryEntry(
                parentMessageId: parentMessageId,
                summary: ChannelThreadSummaryDTO(
                    threadChannelId: threadId,
                    replyCount: replies.count,
                    latestReplies: latestReplyDTOs,
                    unreadCount: unreadCount,
                    firstUnreadMessageId: firstUnread,
                    participantIds: participants,
                    followed: following
                )
            ))
        }
        return ChannelThreadSummariesResponse(entries: entries)
    }
}
