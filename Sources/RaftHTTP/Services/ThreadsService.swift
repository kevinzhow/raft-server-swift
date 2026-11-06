import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The thread boundary: the follower roster, follow/unfollow with its frozen
/// reply window, the followed and unfollowed inbox pages, and the per-message
/// and per-channel thread projections.
///
/// The state transitions stay on `EmailLoginDirectory` with unchanged
/// signatures, so every existing caller and test compiles untouched. This type
/// exists so a route can hand over a decoded request DTO instead of a JSON
/// string, and so the domain has a `Service` boundary of its own.
public struct ThreadsService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// `GET /api/channels/threads/followers`.
    public func threadFollowerRoster(
        authorization: String?,
        serverId: String,
        threadChannelIds: String?
    ) -> HTTPReply {
        directory.threadFollowerRoster(
            authorization: authorization,
            serverId: serverId,
            threadChannelIds: threadChannelIds
        )
    }

    /// `POST /api/channels/threads/follow` and `/unfollow`.
    public func setThreadFollow(
        _ body: ThreadFollowMutationDTO,
        authorization: String?,
        serverId: String,
        follow: Bool
    ) -> HTTPReply {
        directory.setThreadFollow(
            authorization: authorization,
            serverId: serverId,
            body: body.encodedBody(),
            follow: follow
        )
    }

    /// `GET /api/channels/threads/followed`.
    public func followedThreads(
        authorization: String?,
        serverId: String,
        limit: String? = nil,
        cursor: String? = nil,
        unreadOnly: String? = nil
    ) -> HTTPReply {
        directory.followedThreads(
            authorization: authorization,
            serverId: serverId,
            limit: limit,
            cursor: cursor,
            unreadOnly: unreadOnly
        )
    }

    /// `GET /api/channels/inbox/unfollowed`.
    public func unfollowedInbox(
        authorization: String?,
        serverId: String,
        limit: String?,
        query: String?
    ) -> HTTPReply {
        directory.unfollowedInbox(
            authorization: authorization,
            serverId: serverId,
            limit: limit,
            query: query
        )
    }

    /// `GET /api/channels/:channelId/threads/:messageId`.
    public func threadInfo(
        authorization: String?,
        serverId: String,
        channelId: String,
        messageId: String
    ) -> HTTPReply {
        directory.threadInfo(
            authorization: authorization,
            serverId: serverId,
            channelId: channelId,
            messageId: messageId
        )
    }

    /// `GET /api/channels/:channelId/threads`.
    public func channelThreadSummaries(
        authorization: String?,
        serverId: String?,
        channelId: String,
        parentMessageIds: String? = nil
    ) -> HTTPReply {
        directory.channelThreadSummaries(
            authorization: authorization,
            serverId: serverId,
            channelId: channelId,
            parentMessageIds: parentMessageIds
        )
    }
}

extension EmailLoginDirectory {


    public func threadFollowerRoster(authorization: String?, serverId: String, threadChannelIds: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let ids = (threadChannelIds ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        var threads: [String] = []
        lock.lock()
        for threadId in ids {
            guard let thread = postableChannels[threadId], thread.serverId == serverId, thread.kind == "thread" else { continue }
            let authorId = thread.parentMessageId.flatMap { parentId in
                humanMessageRows.first { $0.id == parentId }?.senderId
            }
            let canManage = role == "owner" || role == "admin" || authorId == userId
            let agents = oauth.channelAgentIds(channelId: threadId).compactMap { agentId -> String? in
                guard let agent = oauth.agentRuntimeInfo(id: agentId) else { return nil }
                return "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name))}"
            }.joined(separator: ",")
            threads.append("{\"threadChannelId\":\(jsonString(threadId)),\"canManage\":\(canManage),\"agents\":[\(agents)]}")
        }
        lock.unlock()
        return Self.json(200, "{\"threads\":[\("\(threads.joined(separator: ","))")]}")
    }

    /// A thread is readable only through its parent's current visibility.
    func threadParentVisibleLocked(threadId: String, userId: String) -> Bool {
        guard let thread = postableChannels[threadId], thread.kind == "thread" else { return false }
        guard let parentId = thread.parentChannelId else { return true }
        guard let parent = postableChannels[parentId] else { return false }
        return parent.kind == "channel" || parent.memberIds.contains(userId)
    }

    public func setThreadFollow(authorization: String?, serverId: String, body: String, follow: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        lock.lock()
        var threadId = object["threadChannelId"] as? String
        if threadId == nil, let parentMessageId = object["parentMessageId"] as? String {
            threadId = threadFollows.values.first {
                $0.serverId == serverId && $0.parentMessageId == parentMessageId
            }?.threadChannelId
            if threadId == nil {
                threadId = postableChannels.first { _, channel in
                    channel.serverId == serverId && channel.parentMessageId == parentMessageId
                }?.key
            }
        }
        lock.unlock()
        guard let threadId, let thread = oauth.channelInfo(id: threadId), thread.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        lock.lock()
        guard threadParentVisibleLocked(threadId: threadId, userId: userId) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        let key = "\(serverId)\n\(userId)\n\(threadId)"
        let parentMessageId = postableChannels[threadId]?.parentMessageId ?? (object["parentMessageId"] as? String) ?? ""
        if follow {
            threadFollows[key] = (serverId, userId, threadId, parentMessageId)
            threadFollowStarts[key] = threadFollowStarts[key] ?? Date()
            threadUnfollows.removeValue(forKey: key)
        } else {
            threadFollows.removeValue(forKey: key)
            let startedAt = threadFollowStarts.removeValue(forKey: key) ?? .distantPast
            let frozen = humanMessageRows
                .filter { $0.channelId == threadId && $0.createdAt >= startedAt }
                .map { (id: $0.id, content: $0.content) }
            threadUnfollows[key] = ThreadUnfollowRecord(
                serverId: serverId,
                userId: userId,
                threadChannelId: threadId,
                parentMessageId: parentMessageId,
                unfollowedAt: Date(),
                latestMessageId: frozen.last?.id ?? parentMessageId,
                replyCount: frozen.count,
                frozenMessages: frozen
            )
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"following\":\(follow)}")
    }

    public func unfollowedInbox(authorization: String?, serverId: String, limit rawLimit: String?, query: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let limit = Self.messagePageLimit(rawLimit)
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        var records = threadUnfollows.values.filter { $0.serverId == serverId && $0.userId == userId }
        if !needle.isEmpty {
            records = records.filter { record in
                record.frozenMessages.contains { $0.content.localizedCaseInsensitiveContains(needle) }
            }
        }
        records.sort { $0.unfollowedAt > $1.unfollowedAt }
        let page = Array(records.prefix(limit))
        let formatter = ISO8601DateFormatter()
        let items = page.map { record -> String in
            "{\"kind\":\"thread\",\"threadChannelId\":\(jsonString(record.threadChannelId)),\"latestActivityMessageId\":\(jsonString(record.latestMessageId)),\"replyCount\":\(record.replyCount),\"unreadCount\":0,\"hasMention\":false,\"isFollowing\":false,\"unfollowedAt\":\(jsonString(formatter.string(from: record.unfollowedAt)))}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"items\":[\("\(items)")],\"hasMore\":\(records.count > page.count),\"totalCount\":null}")
    }

    @discardableResult
    public func addHumanMessageForTesting(channelId: String, senderId: String, content: String, messageType: String = "chat", senderType: String = "user", senderTimezone: String? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil,
            messageType: messageType,
            senderType: senderType,
            senderTimezone: senderTimezone
        ))
        lock.unlock()
        return id
    }

    public func addThreadFollowForTesting(serverId: String, userId: String, threadChannelId: String, parentMessageId: String) {
        lock.lock()
        threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] = (
            serverId: serverId, userId: userId,
            threadChannelId: threadChannelId, parentMessageId: parentMessageId
        )
        lock.unlock()
    }

    /// Fixture seam: the unfollow suppression row an HTTP unfollow would write,
    /// without depending on a prior follow or on frozen messages.
    public func unfollowThreadForTesting(
        serverId: String,
        userId: String,
        threadChannelId: String,
        parentMessageId: String,
        latestMessageId: String? = nil
    ) {
        lock.lock()
        let key = "\(serverId)\n\(userId)\n\(threadChannelId)"
        threadFollows.removeValue(forKey: key)
        threadFollowStarts.removeValue(forKey: key)
        threadUnfollows[key] = ThreadUnfollowRecord(
            serverId: serverId,
            userId: userId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId,
            unfollowedAt: Date(),
            latestMessageId: latestMessageId ?? parentMessageId,
            replyCount: 0,
            frozenMessages: []
        )
        lock.unlock()
    }

    public func threadUnfollowSuppressedForTesting(serverId: String, userId: String, threadChannelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return threadUnfollows["\(serverId)\n\(userId)\n\(threadChannelId)"] != nil
    }

    public func inboxDoneFrontierForTesting(userId: String, scopeId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return inboxDoneFrontiers["\(userId)\n\(scopeId)"]
    }

    public func mentionNotificationStateForTesting(messageId: String, targetId: String) -> (notifiableAtSend: Bool, notified: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = storedMentions.first(where: { $0.messageId == messageId && $0.targetId == targetId }) else { return nil }
        return (row.notifiableAtSend, row.notifiedAt != nil)
    }

    @discardableResult
    public func addHumanMessageWithSeqForTesting(channelId: String, senderId: String, content: String, seq: Int) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        _ = appendHumanMessageLocked(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil
        ), seq: seq)
        lock.unlock()
        return id
    }

    public func setServerOnboardingAgentForTesting(serverId: String, agentId: String?) {
        lock.lock()
        let greeting = serverOnboardingSettings[serverId]?.greeting ?? true
        serverOnboardingSettings[serverId] = (agentId: agentId, greeting: greeting)
        lock.unlock()
    }

    public func setMachineMigrationStateForTesting(migrationRef: String, state: String) {
        lock.lock()
        if var record = machineMigrations[migrationRef] {
            record.state = state
            record.updatedAt = Date()
            machineMigrations[migrationRef] = record
        }
        lock.unlock()
    }

    public func userChannelReadCursorForTesting(userId: String, channelId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return userChannelReadCursors["\(userId)\n\(channelId)"]
    }

    public func threadFollowerIdsForTesting(threadChannelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return threadFollows.values
            .filter { $0.threadChannelId == threadChannelId }
            .map(\.userId)
            .sorted()
    }

    public func followedThreads(
        authorization: String?,
        serverId: String,
        limit rawLimit: String? = nil,
        cursor rawCursor: String? = nil,
        unreadOnly rawUnreadOnly: String? = nil
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let pageLimit: Int?
        if let rawLimit {
            guard let parsed = Int(rawLimit), parsed >= 1, parsed <= 200, String(parsed) == rawLimit else {
                return Self.json(400, "{\"error\":\"limit must be an integer between 1 and 200\"}")
            }
            pageLimit = parsed
        } else {
            pageLimit = nil
        }
        var cursorOffset = 0
        if let rawCursor {
            guard pageLimit != nil else {
                return Self.json(400, "{\"error\":\"cursor requires limit\"}")
            }
            guard rawCursor.hasPrefix("v1:"), let parsed = Int(rawCursor.dropFirst(3)), parsed >= 0 else {
                return Self.json(400, "{\"error\":\"invalid cursor\"}")
            }
            cursorOffset = parsed
        }
        let unreadOnly = rawUnreadOnly == "1" || rawUnreadOnly == "true"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let follows = threadFollows.values.filter {
            $0.serverId == serverId
                && $0.userId == userId
                && !inboxDoneScopes.contains("\(userId)\n\($0.threadChannelId)")
        }
        var entries: [(threadId: String, parentChannelId: String, parentCreatedAt: Date, unreadCount: Int, firstUnread: String?, hasMention: Bool, follow: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String))] = []
        for follow in follows {
            guard let thread = postableChannels[follow.threadChannelId], thread.deletedAt == nil else { continue }
            if let parentId = thread.parentChannelId, let parent = postableChannels[parentId], parent.deletedAt != nil {
                continue
            }
            if oauth.memberRole(serverId: serverId, userId: userId) == "guest", !guestCanSeeScopeLocked(follow.threadChannelId) {
                continue
            }
            let info = oauth.channelUnreadInfo(channelId: follow.threadChannelId, userId: userId)
            let threadReplies = humanMessageRows.filter { $0.channelId == follow.threadChannelId }
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
            let unreadIDs = Set(threadReplies.filter { $0.seq > info.maxReadSeq && $0.senderId != userId }.map(\.id))
            let hasMention = storedMentions.contains { row in
                row.targetType == "user"
                    && row.targetId == userId
                    && row.notifiableAtSend
                    && unreadIDs.contains(row.messageId)
            }
            let parentCreatedAt = humanMessageRows.first(where: { $0.id == follow.parentMessageId })?.createdAt
                ?? Date.distantPast
            entries.append((
                threadId: follow.threadChannelId,
                parentChannelId: thread.parentChannelId ?? "",
                parentCreatedAt: parentCreatedAt,
                unreadCount: unreadCount,
                firstUnread: firstUnread,
                hasMention: hasMention,
                follow: follow
            ))
        }
        entries.sort { lhs, rhs in
            if lhs.parentCreatedAt != rhs.parentCreatedAt { return lhs.parentCreatedAt > rhs.parentCreatedAt }
            return lhs.threadId > rhs.threadId
        }
        let page: ArraySlice<(threadId: String, parentChannelId: String, parentCreatedAt: Date, unreadCount: Int, firstUnread: String?, hasMention: Bool, follow: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String))>
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
        var rows: [String] = []
        for entry in page {
            let task = taskRecords.first { $0.messageId == entry.follow.parentMessageId }
            let taskJSON = task.map { jsonString($0.id) } ?? "null"
            let claimedType = task?.assigneeType.map { jsonString($0) } ?? "null"
            let claimedId = task?.assigneeId.map { jsonString($0) } ?? "null"
            var claimedName = "null"
            if let assigneeId = task?.assigneeId, let assigneeType = task?.assigneeType {
                if assigneeType == "user" {
                    if let name = accounts.values.first(where: { $0.id == assigneeId })?.name {
                        claimedName = jsonString(name)
                    }
                } else if let name = oauth.agentRuntimeInfo(id: assigneeId)?.name {
                    claimedName = jsonString(name)
                }
            }
            let firstUnreadJSON = entry.firstUnread.map(jsonString) ?? "null"
            rows.append("{\"threadChannelId\":\(jsonString(entry.threadId)),\"parentChannelId\":\(jsonString(entry.parentChannelId)),\"parentMessageCreatedAt\":\(jsonString(formatter.string(from: entry.parentCreatedAt))),\"unreadCount\":\(entry.unreadCount),\"firstUnreadMessageId\":\(firstUnreadJSON),\"hasMention\":\(entry.hasMention ? "true" : "false"),\"taskId\":\(taskJSON),\"taskClaimedByType\":\(claimedType),\"taskClaimedById\":\(claimedId),\"taskClaimedByName\":\(claimedName)}")
        }
        lock.unlock()
        if pageLimit != nil {
            let nextJSON = next.map(jsonString) ?? "null"
            return Self.json(200, "{\"threads\":[\(rows.joined(separator: ","))],\"next\":\(nextJSON)}")
        }
        return Self.json(200, "{\"threads\":[\(rows.joined(separator: ","))]}")
    }

    /// One canonical thread per parent message: newest reply, then reply count,
    /// then creation order and id. Historical duplicates must not split reads.
    func canonicalThreadLocked(parentChannelId: String, parentMessageId: String) -> (id: String, channel: PostableChannel)? {
        let orderIndex = Dictionary(uniqueKeysWithValues: threadOrder.enumerated().map { ($1, $0) })
        let candidates = postableChannels.filter { _, candidate in
            candidate.kind == "thread"
                && candidate.parentChannelId == parentChannelId
                && candidate.parentMessageId == parentMessageId
                && candidate.deletedAt == nil
        }
        guard !candidates.isEmpty else { return nil }
        func lastReplyAt(_ threadId: String) -> Date {
            humanMessageRows.filter { $0.channelId == threadId }.map(\.createdAt).max() ?? .distantPast
        }
        func replyCount(_ threadId: String) -> Int {
            humanMessageRows.filter { $0.channelId == threadId }.count
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

    public func threadInfo(authorization: String?, serverId: String, channelId: String, messageId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let probeAccess = channelProbeAccessLocked(channelId: channelId, serverId: serverId, userId: userId)
        lock.unlock()
        if probeAccess == .residue {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let channel = postableChannels[channelId],
              channel.serverId == serverId,
              channelActorCanSee(channelId: channelId, userId: userId)
        else {
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        }
        lock.lock()
        let inChannel = humanMessageRows.contains { $0.id == messageId && $0.channelId == channelId }
            || oauth.messageChannelId(messageId) == channelId
        guard inChannel else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"THREAD_NOT_FOUND\",\"error\":\"No thread found for this message\"}")
        }
        guard let thread = canonicalThreadLocked(parentChannelId: channelId, parentMessageId: messageId),
              thread.channel.serverId == serverId
        else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"THREAD_NOT_FOUND\",\"error\":\"No thread found for this message\"}")
        }
        let replies = humanMessageRows.filter { $0.channelId == thread.id }
        var participants = Set(replies.map(\.senderId))
        if let parent = humanMessageRows.first(where: { $0.id == messageId }) {
            participants.insert(parent.senderId)
        }
        let participantJSON = participants.sorted().map { jsonString($0) }.joined(separator: ",")
        let lastReply = replies.last.map { jsonString(ISO8601DateFormatter().string(from: $0.createdAt)) } ?? "null"
        lock.unlock()
        return Self.json(200, "{\"threadChannelId\":\(jsonString(thread.id)),\"replyCount\":\(replies.count),\"lastReplyAt\":\(lastReply),\"participantIds\":[\("\(participantJSON)")]}")
    }

    public func channelThreadSummaries(authorization: String?, serverId: String?, channelId: String, parentMessageIds rawParentIds: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        lock.lock()
        guard let channel = postableChannels[channelId], channel.serverId == serverId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let visible = channel.kind == "channel" || channel.memberIds.contains(userId)
        if !visible, channelProbeAccessLocked(channelId: channelId, serverId: serverId ?? "", userId: userId) == .residue {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard visible else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        var threads = postableChannels.filter { _, candidate in
            candidate.serverId == serverId
                && candidate.kind == "thread"
                && candidate.parentChannelId == channelId
                && candidate.deletedAt == nil
        }
        let requestedParents: Set<String>? = {
            guard let rawParentIds, !rawParentIds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Set(rawParentIds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }()
        if let requestedParents {
            threads = threads.filter { _, thread in
                guard let parentMessageId = thread.parentMessageId else { return false }
                return requestedParents.contains(parentMessageId)
            }
        }
        let orderIndex = Dictionary(uniqueKeysWithValues: threadOrder.enumerated().map { ($1, $0) })
        var orderedThreads = threads.map { (id: $0.key, channel: $0.value) }
        orderedThreads.sort { (orderIndex[$0.id] ?? Int.max) < (orderIndex[$1.id] ?? Int.max) }
        if requestedParents == nil, orderedThreads.count > 100 {
            orderedThreads = Array(orderedThreads.suffix(100))
        }
        threads = Dictionary(uniqueKeysWithValues: orderedThreads.map { ($0.id, $0.channel) })
        var canonicalByParent: [String: (id: String, channel: PostableChannel)] = [:]
        for (threadId, thread) in threads {
            guard let parentMessageId = thread.parentMessageId else { continue }
            if let existing = canonicalByParent[parentMessageId] {
                let existingLast = humanMessageRows.filter { $0.channelId == existing.id }.map(\.createdAt).max() ?? .distantPast
                let candidateLast = humanMessageRows.filter { $0.channelId == threadId }.map(\.createdAt).max() ?? .distantPast
                let existingCount = humanMessageRows.filter { $0.channelId == existing.id }.count
                let candidateCount = humanMessageRows.filter { $0.channelId == threadId }.count
                if candidateLast > existingLast
                    || (candidateLast == existingLast && candidateCount > existingCount)
                    || (candidateLast == existingLast && candidateCount == existingCount && threadId < existing.id) {
                    canonicalByParent[parentMessageId] = (threadId, thread)
                }
            } else {
                canonicalByParent[parentMessageId] = (threadId, thread)
            }
        }
        var summaries: [String] = []
        for (parentMessageId, canonical) in canonicalByParent {
            let threadId = canonical.id
            let thread = canonical.channel
            let replies = humanMessageRows.filter { $0.channelId == threadId }
            var participantSet = Set(replies.map(\.senderId))
            if let parent = humanMessageRows.first(where: { $0.id == parentMessageId }) {
                participantSet.insert(parent.senderId)
            }
            let participants = Array(participantSet).sorted()
            let participantJSON = participants.map { jsonString($0) }.joined(separator: ",")
            let following = threadFollows["\(serverId ?? "")\n\(userId)\n\(threadId)"] != nil
            let unreadInfo = oauth.channelUnreadInfo(channelId: threadId, userId: userId)
            var unreadCount = 0
            var firstUnread: String?
            if following {
                if replies.isEmpty {
                    unreadCount = unreadInfo.unreadCount
                    firstUnread = oauth.firstUnreadMessageId(channelId: threadId, userId: userId)
                } else {
                    var first: String?
                    for reply in replies where reply.seq > unreadInfo.maxReadSeq && reply.senderId != userId {
                        unreadCount += 1
                        if first == nil { first = reply.id }
                    }
                    firstUnread = first
                }
            }
            let firstUnreadJSON = firstUnread.map { jsonString($0) } ?? "null"
            let latestReplies = replies.filter { $0.messageType != "system" }.suffix(3).map { reply -> String in
                let senderName: String
                let senderDisplay: String
                if reply.senderType == "agent" {
                    let info = oauth.agentRuntimeInfo(id: reply.senderId)
                    senderName = info?.name ?? reply.senderId
                    senderDisplay = info?.displayName ?? senderName
                } else {
                    let name = accounts.values.first { $0.id == reply.senderId }?.name ?? reply.senderId
                    senderName = name
                    senderDisplay = name
                }
                return "{\"preview\":\(jsonString(reply.content)),\"senderType\":\(jsonString(reply.senderType)),\"senderId\":\(jsonString(reply.senderId)),\"senderName\":\(jsonString(senderName)),\"senderDisplayName\":\(jsonString(senderDisplay))}"
            }.joined(separator: ",")
            summaries.append("\(jsonString(parentMessageId)):{\"threadChannelId\":\(jsonString(threadId)),\"replyCount\":\(replies.count),\"latestReplies\":[\(latestReplies)],\"unreadCount\":\(unreadCount),\"firstUnreadMessageId\":\(firstUnreadJSON),\"participantIds\":[\(participantJSON)],\"followed\":\(following ? "true" : "false")}")
        }
        lock.unlock()
        return Self.json(200, "{\(summaries.joined(separator: ","))}")
    }

}
