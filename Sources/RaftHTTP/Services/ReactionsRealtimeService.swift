import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The inbox-read and wake boundary: Done/Undone per scope, read-all, the
/// read-mutation acknowledgement and the agent wake-hint projections.
///
/// The state transitions stay on `EmailLoginDirectory` with unchanged
/// signatures, so every existing caller and test compiles untouched. This type
/// exists so a route can hand over a decoded request DTO instead of a JSON
/// string, and so the domain has a `Service` boundary of its own.
public struct ReactionsRealtimeService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// `POST /api/read-mutations`.
    public func acknowledgeReadMutation(
        _ body: ReadMutationAckRequestDTO,
        authorization: String?,
        serverId: String
    ) -> HTTPReply {
        directory.postReadMutation(
            authorization: authorization,
            serverId: serverId,
            body: body.encodedBody()
        )
    }

    /// `POST /api/channels/inbox/done`.
    public func channelInboxDone(
        authorization: String?,
        serverId: String?,
        body: String
    ) -> HTTPReply {
        directory.channelInboxDone(authorization: authorization, serverId: serverId, body: body)
    }

    /// `POST /api/channels/threads/done`.
    public func threadInboxDone(
        authorization: String?,
        serverId: String?,
        body: String
    ) -> HTTPReply {
        directory.threadInboxDone(authorization: authorization, serverId: serverId, body: body)
    }

    /// `POST /api/channels/inbox/undone`.
    public func inboxUndone(
        authorization: String?,
        serverId: String?,
        body: String
    ) -> HTTPReply {
        directory.inboxUndone(authorization: authorization, serverId: serverId, body: body)
    }

    /// `POST /api/channels/threads/undone`.
    public func threadInboxUndone(
        authorization: String?,
        serverId: String?,
        body: String
    ) -> HTTPReply {
        directory.threadInboxUndone(authorization: authorization, serverId: serverId, body: body)
    }

    /// `POST /api/channels/inbox/read-all`.
    public func inboxReadAll(authorization: String?, serverId: String?) -> HTTPReply {
        directory.inboxReadAll(authorization: authorization, serverId: serverId)
    }

    /// `GET /internal/agent-api/wake-hints`.
    public func agentWakeHints(authorization: String?, since: String?, limit: String? = nil) -> HTTPReply {
        directory.agentWakeHints(authorization: authorization, since: since, limit: limit)
    }

    /// `GET /internal/agent-api/third-party-events`.
    public func agentThirdPartyEvents(authorization: String?) -> HTTPReply {
        directory.agentThirdPartyEvents(authorization: authorization)
    }
}

extension EmailLoginDirectory {

    public func inboxUndone(authorization: String?, serverId: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelId = object["channelId"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid inbox undone request\"}")
        }
        lock.lock()
        guard postableChannels[channelId]?.kind != "thread" else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        inboxDoneScopes.remove("\(userId)\n\(channelId)")
        inboxDoneAt.removeValue(forKey: "\(userId)\n\(channelId)")
        inboxDoneFrontiers.removeValue(forKey: "\(userId)\n\(channelId)")
        lock.unlock()
        _ = serverId
        return Self.json(200, "{\"ok\":true}")
    }

    /// A thread is readable only through its parent's current visibility.
    ///
    /// Moved here with the reactions/inbox surface, which still resolves thread
    /// scopes on the directory; `ThreadsService` owns the migrated copy of the
    /// same policy for the thread routes.
    func threadParentVisibleLocked(threadId: String, userId: String) -> Bool {
        guard let thread = postableChannels[threadId], thread.kind == "thread" else { return false }
        guard let parentId = thread.parentChannelId else { return true }
        guard let parent = postableChannels[parentId] else { return false }
        return parent.kind == "channel" || parent.memberIds.contains(userId)
    }

    public func threadInboxUndone(authorization: String?, serverId: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let threadId = object["threadChannelId"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid inbox undone request\"}")
        }
        lock.lock()
        guard postableChannels[threadId]?.kind == "thread",
              threadParentVisibleLocked(threadId: threadId, userId: userId)
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        inboxDoneScopes.remove("\(userId)\n\(threadId)")
        inboxDoneAt.removeValue(forKey: "\(userId)\n\(threadId)")
        inboxDoneFrontiers.removeValue(forKey: "\(userId)\n\(threadId)")
        lock.unlock()
        _ = serverId
        return Self.json(200, "{\"ok\":true}")
    }

    /// Canonical `throughActivitySeq`: a decimal string in (0, Int64.max] with no
    /// leading zero. Anything else is DONE_FRONTIER_REQUIRED.

    /// Resolves the Done frontier for a scope. An explicit frontier must be
    /// canonical and inside the int4 authority; an omitted frontier snapshots
    /// the latest activity. The persisted frontier is the admission snapshot.
    func resolveDoneFrontier(object: [String: Any], scopeId: String) -> (reply: HTTPReply?, frontier: Int?) {
        if let space = object["frontierSpace"], !(space is NSNull) {
            guard let value = space as? String, value == "storage" else {
                return (Self.json(400, "{\"code\":\"DONE_FRONTIER_UNMAPPABLE\",\"error\":\"frontierSpace must be storage\"}"), nil)
            }
        }
        // An explicit frontier is validated whenever the key is present; JSON
        // null is an invalid frontier, not an omitted one.
        let explicit = object.keys.contains("throughActivitySeq")
        var frontier = 0
        if explicit {
            guard let parsed = Self.parseDoneFrontier(object["throughActivitySeq"]) else {
                return (Self.json(400, "{\"code\":\"DONE_FRONTIER_REQUIRED\",\"error\":\"throughActivitySeq must be a canonical positive decimal string\"}"), nil)
            }
            frontier = parsed
        }
        let latest = oauth.channelUnreadInfo(channelId: scopeId, userId: "").latestSeq ?? 0
        if !explicit { frontier = latest }
        guard frontier <= Self.doneFrontierInt4Limit else {
            return (Self.json(409, "{\"code\":\"DONE_FRONTIER_ABOVE_INT4_AUTHORITY\",\"error\":\"Done frontier exceeds the int4 authority\"}"), nil)
        }
        // Keep the existing permissive contract for scopes with no real activity;
        // elsewhere an explicit frontier beyond the latest is rejected before any
        // write, so a rejected Done never admits a mutation.
        if explicit, latest > 0, frontier > latest {
            return (Self.json(409, "{\"code\":\"DONE_FRONTIER_BEYOND_LATEST\",\"error\":\"Done frontier is beyond the latest activity\"}"), nil)
        }
        return (nil, frontier)
    }

    public func channelInboxDone(authorization: String?, serverId: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelId = object["channelId"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid inbox done request\"}")
        }
        let resolution = resolveDoneFrontier(object: object, scopeId: channelId)
        if let reply = resolution.reply { return reply }
        guard let frontier = resolution.frontier else {
            return Self.json(400, "{\"code\":\"DONE_FRONTIER_REQUIRED\",\"error\":\"throughActivitySeq must be a canonical positive decimal string\"}")
        }
        lock.lock()
        let isThread = postableChannels[channelId]?.kind == "thread"
        if isThread {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        let key = "\(userId)\n\(channelId)"
        inboxDoneScopes.insert(key)
        inboxDoneAt[key] = Date()
        inboxDoneFrontiers[key] = frontier
        lock.unlock()
        _ = serverId
        return Self.json(200, "{\"ok\":true}")
    }

    public func threadInboxDone(authorization: String?, serverId: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let threadId = object["threadChannelId"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid inbox done request\"}")
        }
        let resolution = resolveDoneFrontier(object: object, scopeId: threadId)
        if let reply = resolution.reply { return reply }
        guard let frontier = resolution.frontier else {
            return Self.json(400, "{\"code\":\"DONE_FRONTIER_REQUIRED\",\"error\":\"throughActivitySeq must be a canonical positive decimal string\"}")
        }
        lock.lock()
        guard let thread = postableChannels[threadId],
              serverId == nil || thread.serverId == serverId
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        if thread.kind != "thread" {
            let visible = thread.kind == "channel" || thread.memberIds.contains(userId)
            lock.unlock()
            if visible {
                return Self.json(400, "{\"code\":\"NOT_A_THREAD\",\"error\":\"Inbox scope is not a thread\"}")
            }
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        if thread.deletedAt != nil {
            let ownedFacts = inboxFactStore.all().filter {
                $0.receiverType == "user" && $0.receiverId == userId && $0.channelId == threadId
            }
            let followed = threadFollows["\(serverId ?? "")\n\(userId)\n\(threadId)"] != nil
            let hasReadCursor = oauth.channelUnreadInfo(channelId: threadId, userId: userId).maxReadSeq > 0
            guard !ownedFacts.isEmpty || followed || hasReadCursor else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
            }
            if let latestOwned = ownedFacts.last,
               let owned = humanMessageRows.first(where: { $0.id == latestOwned.messageId }) {
                oauth.setChannelReadCursor(channelId: threadId, userId: userId, seq: owned.seq)
            }
            lock.unlock()
            _ = serverId
            return Self.json(200, "{\"ok\":true}")
        }
        guard threadParentVisibleLocked(threadId: threadId, userId: userId) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        let key = "\(userId)\n\(threadId)"
        inboxDoneScopes.insert(key)
        inboxDoneAt[key] = Date()
        inboxDoneFrontiers[key] = frontier
        lock.unlock()
        _ = serverId
        return Self.json(200, "{\"ok\":true}")
    }

    public func inboxReadAll(authorization: String?, serverId: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let serverId, oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        var scopeIds = Set(inboxFactStore.all().filter { $0.receiverId == userId && $0.serverId == serverId }.compactMap(\.channelId))
        scopeIds.formUnion(threadFollows.values.filter { $0.serverId == serverId && $0.userId == userId }.map(\.threadChannelId))
        var scopeRows: [String] = []
        for scopeId in scopeIds.sorted() {
            inboxDoneScopes.insert("\(userId)\n\(scopeId)")
            inboxDoneAt["\(userId)\n\(scopeId)"] = Date()
            let latest = oauth.channelUnreadInfo(channelId: scopeId, userId: userId).latestSeq ?? 0
            inboxDoneFrontiers["\(userId)\n\(scopeId)"] = latest
            oauth.setChannelReadCursor(channelId: scopeId, userId: userId, seq: latest)
            let key = "\(scopeId)\n\(userId)"
            channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
            scopeRows.append("{\"scopeId\":\(jsonString(scopeId)),\"maxReadSeq\":\(latest),\"readStateVersion\":\(channelReadVersions[key] ?? 1)}")
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"markedCount\":\(scopeIds.count),\"scopes\":[\(scopeRows.joined(separator: ","))]}")
    }

    func isSelfCausedFreshnessExemptLocked(_ message: StoredHumanMessage, agentId: String) -> Bool {
        message.messageType == "system"
            && message.causalActorType == "agent"
            && message.causalActorId == agentId
            && message.systemSubtype.map { Self.selfCausedFreshnessExemptSubtypes.contains($0) } == true
    }

    public func channelInbox(
        authorization: String?,
        serverId: String?,
        filter: String?,
        query: String? = nil
    ) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        let params = Self.inboxQueryParameters(query)
        let effectiveFilter = params["filter"] ?? filter ?? "all"
        let limit = min(max(Int(params["limit"] ?? "") ?? 30, 1), 100)
        let offset = max(Int(params["offset"] ?? "") ?? 0, 0)
        let ascending = params["sort"] == "asc"
        let channelFilter = params["channelId"].flatMap { $0.isEmpty ? nil : $0 }
        let scope = params["scope"]
        let search = params["q"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        lock.lock()
        let facts = inboxFactStore.all()
        let doneScopes = inboxDoneScopes
        let mentions = storedMentions
        let follows = threadFollows
        let unfollows = threadUnfollows
        let humanRows = humanMessageRows
        let postable = postableChannels
        lock.unlock()

        var lastFacts: [String: StoredInboxFact] = [:]
        for fact in facts where fact.receiverType == "user" && fact.receiverId == userId {
            guard let scopeId = fact.channelId else { continue }
            if serverId != nil && fact.serverId != serverId { continue }
            if doneScopes.contains("\(userId)\n\(scopeId)") { continue }
            lastFacts[scopeId] = fact
        }

        var visibleScopes: Set<String> = []
        if let serverId {
            visibleScopes = Set(oauth.channelsForServer(serverId: serverId, userId: userId).map(\.id))
        }

        var rows: [InboxRow] = []
        for (scopeId, fact) in lastFacts {
            let scopeServer = fact.serverId ?? postable[scopeId]?.serverId
            if let serverId, let scopeServer, scopeServer != serverId { continue }
            let channel = postable[scopeId]
            let type = channel?.kind ?? oauth.channelType(id: scopeId) ?? "channel"
            if serverId != nil && channel == nil && oauth.channelInfo(id: scopeId) == nil { continue }
            if type == "private" || type == "dm" {
                if !visibleScopes.contains(scopeId) { continue }
            }
            let isThread = type == "thread"
            if let scopeServer, oauth.memberRole(serverId: scopeServer, userId: userId) == "guest",
               !guestCanSeeScopeLocked(scopeId) {
                continue
            }
            let parentChannelId = isThread ? channel?.parentChannelId : nil
            if isThread, let parentChannelId,
               postable[parentChannelId]?.kind == "dm",
               doneScopes.contains("\(userId)\n\(parentChannelId)") { continue }
            let detailMap = inboxMessageDetails(
                scopeId: scopeId,
                history: oauth.historyMessages(channelId: scopeId),
                humans: humanRows
            )
            let scopeMentions = mentions.filter {
                $0.channelId == scopeId
                    && $0.targetType == "user"
                    && $0.targetId == userId
                    && ($0.notifiableAtSend || $0.notifiedAt != nil)
            }
            let unreadInfo = oauth.channelUnreadInfo(channelId: scopeId, userId: userId)
            // An unfollowed thread is an explicit attention opt-out: it stays in
            // Activity All but never contributes unread, mention, or followed
            // state until a direct mention reactivates the follow.
            let suppressed = unfollows["\(serverId ?? "")\n\(userId)\n\(scopeId)"] != nil
            let unread = suppressed ? 0 : unreadInfo.unreadCount
            let firstUnread = suppressed ? nil : oauth.firstUnreadMessageId(channelId: scopeId, userId: userId)
            let firstMention = suppressed ? nil : scopeMentions
                .map { (messageId: $0.messageId, seq: detailMap[$0.messageId]?.seq ?? 0) }
                .filter { $0.seq > unreadInfo.maxReadSeq }
                .min { $0.seq < $1.seq }?.messageId
            let lastMessageId = fact.messageId
            let detail = detailMap[lastMessageId]
            let isFollowing = !suppressed && follows["\(serverId ?? "")\n\(userId)\n\(scopeId)"] != nil
            let parentType = parentChannelId.flatMap { postable[$0]?.kind ?? oauth.channelType(id: $0) }
            rows.append(InboxRow(
                scopeId: scopeId,
                kind: type == "dm" ? "dm" : (isThread ? "thread" : "channel"),
                channelType: type,
                parentChannelId: parentChannelId,
                parentChannelType: isThread ? parentType : nil,
                lastMessageId: lastMessageId,
                lastActivityAt: detail?.createdAt ?? Date(timeIntervalSince1970: 0),
                searchText: [
                    detail?.content ?? "",
                    detail.map { senderName(senderId: $0.senderId) } ?? "",
                ].joined(separator: " ").lowercased(),
                unreadCount: unread,
                firstUnreadMessageId: firstUnread,
                firstMentionMessageId: firstMention,
                hasMention: !suppressed && !scopeMentions.isEmpty,
                isFollowing: isFollowing,
                isDM: type == "dm" || (isThread && postable[parentChannelId ?? ""]?.kind == "dm")
            ))
        }

        for record in unfollows.values
        where record.serverId == serverId && record.userId == userId
            && !doneScopes.contains("\(userId)\n\(record.threadChannelId)")
            && !rows.contains(where: { $0.scopeId == record.threadChannelId }) {
            if oauth.memberRole(serverId: record.serverId, userId: userId) == "guest",
               !guestCanSeeScopeLocked(record.threadChannelId) {
                continue
            }
            let parentId = postable[record.threadChannelId]?.parentChannelId
            if let channelFilter, parentId != channelFilter { continue }
            let lastContent = record.frozenMessages.last?.content ?? ""
            if let search, !search.isEmpty, !lastContent.lowercased().contains(search) { continue }
            let lastAt = humanRows.first { $0.id == record.latestMessageId }?.createdAt ?? record.unfollowedAt
            let parentType = parentId.flatMap { postable[$0]?.kind ?? oauth.channelType(id: $0) }
            rows.append(InboxRow(
                scopeId: record.threadChannelId,
                kind: "thread",
                channelType: "thread",
                parentChannelId: parentId,
                parentChannelType: parentType,
                lastMessageId: record.latestMessageId,
                lastActivityAt: lastAt,
                searchText: lastContent.lowercased(),
                unreadCount: 0,
                firstUnreadMessageId: nil,
                firstMentionMessageId: nil,
                hasMention: false,
                isFollowing: false,
                isDM: parentId.map { postable[$0]?.kind == "dm" } ?? false
            ))
        }

        // A mention-only row exists only because of a notifiable @mention in a
        // scope the receiver has no inbox fact for. It anchors firstMention even
        // after the mention was read.
        var mentionOnly: [String: StoredMention] = [:]
        for mention in mentions
        where mention.targetType == "user" && mention.targetId == userId
            && (mention.notifiableAtSend || mention.notifiedAt != nil)
            && !rows.contains(where: { $0.scopeId == mention.channelId })
            && !doneScopes.contains("\(userId)\n\(mention.channelId)")
            && unfollows["\(serverId ?? "")\n\(userId)\n\(mention.channelId)"] == nil {
            let scopeId = mention.channelId
            guard let channel = postable[scopeId] else { continue }
            if let serverId, channel.serverId != serverId { continue }
            let type = channel.kind
            if type == "private" || type == "dm", !visibleScopes.contains(scopeId) { continue }
            if let serverId, oauth.memberRole(serverId: serverId, userId: userId) == "guest",
               !guestCanSeeScopeLocked(scopeId) { continue }
            if let existing = mentionOnly[scopeId],
               let existingRow = humanRows.first(where: { $0.id == existing.messageId }),
               let candidateRow = humanRows.first(where: { $0.id == mention.messageId }),
               existingRow.createdAt <= candidateRow.createdAt {
                continue
            }
            mentionOnly[scopeId] = mention
        }
        for (scopeId, mention) in mentionOnly {
            guard let channel = postable[scopeId] else { continue }
            let lastAt = humanRows.first { $0.id == mention.messageId }?.createdAt ?? Date(timeIntervalSince1970: 0)
            let parentType = channel.kind == "thread" ? channel.parentChannelId.flatMap { postable[$0]?.kind ?? oauth.channelType(id: $0) } : nil
            rows.append(InboxRow(
                scopeId: scopeId,
                kind: channel.kind == "dm" ? "dm" : (channel.kind == "thread" ? "thread" : "channel"),
                channelType: channel.kind,
                parentChannelId: channel.kind == "thread" ? channel.parentChannelId : nil,
                parentChannelType: parentType,
                lastMessageId: mention.messageId,
                lastActivityAt: lastAt,
                searchText: "",
                unreadCount: 0,
                firstUnreadMessageId: nil,
                firstMentionMessageId: mention.messageId,
                hasMention: true,
                isFollowing: false,
                isDM: channel.kind == "dm"
            ))
        }

        let scopedRows = scope == "dms" ? rows.filter(\.isDM) : rows
        let activeUnreadCount = scopedRows.reduce(0) { $0 + $1.unreadCount }
        let filtered = scopedRows.filter { row in
            switch effectiveFilter {
            case "unread": row.unreadCount > 0
            case "mentions": row.hasMention
            case "unread_mentions": row.unreadCount > 0 && row.hasMention
            default: true
            }
        }.filter { row in
            if let channelFilter {
                let parent = row.kind == "thread" ? (row.parentChannelId ?? row.scopeId) : row.scopeId
                if parent != channelFilter { return false }
            }
            if let search, !search.isEmpty, !row.searchText.contains(search) {
                return false
            }
            return true
        }

        let totalCount = filtered.count
        let totalUnreadCount = filtered.reduce(0) { $0 + $1.unreadCount }
        let sorted = filtered.sorted { left, right in
            if left.lastActivityAt != right.lastActivityAt {
                return ascending ? left.lastActivityAt < right.lastActivityAt : left.lastActivityAt > right.lastActivityAt
            }
            return ascending ? left.scopeId < right.scopeId : left.scopeId > right.scopeId
        }
        let page = Array(sorted.dropFirst(offset).prefix(limit))
        let hasMore = offset + page.count < totalCount

        let items = page.map { row -> String in
            let firstUnread = row.firstUnreadMessageId.map(jsonString) ?? "null"
            let firstMention = row.firstMentionMessageId.map(jsonString) ?? "null"
            if row.kind == "thread" {
                let parent = row.parentChannelId.map(jsonString) ?? "null"
                let parentType = row.parentChannelType.map(jsonString) ?? "null"
                return "{\"kind\":\"thread\",\"threadChannelId\":\(jsonString(row.scopeId)),\"parentChannelId\":\(parent),\"parentChannelType\":\(parentType),\"latestActivityMessageId\":\(jsonString(row.lastMessageId)),\"firstUnreadMessageId\":\(firstUnread),\"firstMentionMessageId\":\(firstMention),\"unreadCount\":\(row.unreadCount),\"hasMention\":\(row.hasMention),\"isFollowing\":\(row.isFollowing)}"
            }
            let kind = row.kind == "dm" ? "dm" : "channel"
            return "{\"kind\":\"\(kind)\",\"channelId\":\(jsonString(row.scopeId)),\"channelType\":\(jsonString(row.channelType)),\"lastMessageId\":\(jsonString(row.lastMessageId)),\"firstUnreadMessageId\":\(firstUnread),\"firstMentionMessageId\":\(firstMention),\"unreadCount\":\(row.unreadCount),\"hasMention\":\(row.hasMention)}"
        }.joined(separator: ",")

        // Facets keep the query filter but ignore channelId, pagination, and the sort direction.
        var groups: [String: InboxGroup] = [:]
        for row in filtered {
            let groupId = row.kind == "thread" ? (row.parentChannelId ?? row.scopeId) : row.scopeId
            let existing = groups[groupId]
            groups[groupId] = InboxGroup(
                channelId: groupId,
                channelName: oauth.channelInfo(id: groupId)?.name ?? postable[groupId]?.name ?? "",
                channelType: oauth.channelType(id: groupId) ?? postable[groupId]?.kind ?? "channel",
                count: (existing?.count ?? 0) + 1,
                lastActivityAt: max(existing?.lastActivityAt ?? Date(timeIntervalSince1970: 0), row.lastActivityAt)
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let groupItems = groups.values.sorted { left, right in
            let leftDM = left.channelType == "dm"
            let rightDM = right.channelType == "dm"
            if leftDM != rightDM { return leftDM }
            if left.lastActivityAt != right.lastActivityAt { return left.lastActivityAt > right.lastActivityAt }
            if left.channelName != right.channelName { return left.channelName < right.channelName }
            return left.channelId < right.channelId
        }.map { group in
            "{\"channelId\":\(jsonString(group.channelId)),\"channelName\":\(jsonString(group.channelName)),\"channelType\":\(jsonString(group.channelType)),\"count\":\(group.count),\"lastActivityAt\":\(jsonString(formatter.string(from: group.lastActivityAt)))}"
        }.joined(separator: ",")

        return Self.json(
            200,
            "{\"items\":[\(items)],\"hasMore\":\(hasMore),\"totalCount\":\(totalCount),\"totalUnreadCount\":\(totalUnreadCount),\"activeUnreadCount\":\(activeUnreadCount),\"groups\":[\(groupItems)]}"
        )
    }

    func inboxMessageDetails(
        scopeId: String,
        history: [OAuthLedger.HistoryMessage],
        humans: [StoredHumanMessage]
    ) -> [String: InboxMessageDetail] {
        var details: [String: InboxMessageDetail] = [:]
        for message in history {
            details[message.id] = InboxMessageDetail(
                content: message.content,
                senderId: message.senderId,
                seq: message.seq,
                createdAt: message.createdAt
            )
        }
        for message in humans where message.channelId == scopeId {
            details[message.id] = InboxMessageDetail(
                content: message.content,
                senderId: message.senderId,
                seq: details[message.id]?.seq ?? 0,
                createdAt: message.createdAt
            )
        }
        return details
    }

    func senderName(senderId: String) -> String {
        if let agent = oauth.agentRuntimeInfo(id: senderId) { return agent.name }
        lock.lock()
        let name = accounts.values.first { $0.id == senderId }?.name
        lock.unlock()
        return name ?? senderId
    }

    /// `GET /internal/agent-api/mentions`. Outsider rows stay hidden until they were notifiable at send or later notified.
    public func agentMentionInbox(authorization: String?, limit rawLimit: String? = nil) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let allowed = credential?.scopes.contains("mentions") == true
        let rows = storedMentions.filter { row in
            row.targetType == "agent"
                && row.targetId == credential?.agentId
                && (row.notifiableAtSend || row.notifiedAt != nil)
        }
        lock.unlock()
        guard allowed else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let pageLimit = Self.messagePageLimit(rawLimit)
        let ordered = rows.reversed()
        let page = Array(ordered.prefix(pageLimit))
        let mentions = page.map { "{\"messageId\":\(jsonString($0.messageId))}" }.joined(separator: ",")
        return Self.json(200, "{\"mentions\":[\(mentions)],\"has_more\":\(rows.count > page.count)}")
    }

    /// `GET /internal/agent-api/wake-hints`. A read credential sees the
    /// undrained third-party events as wake hints.
    /// `GET /internal/agent-api/wake-hints`. A content-free peek at pending
    /// messages: it repeats until `/events` drains them, never advances a
    /// cursor, and never returns message bodies. `since` is a numeric seq or
    /// `latest`; `limit` bounds the batch.
    /// Pending, content-free wake hints for one agent, ordered by server seq.
    /// Callers hold the directory lock. The peek route and the SSE stream share
    /// this projection so both surfaces agree on the hint set and ordering.
    func pendingWakeHintRowsLocked(
        agentId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        sinceSeq: Int?,
        limit: Int
    ) -> (rows: [(seq: Int, json: String)], hasMore: Bool) {
        var conversations: [(id: String, storage: String, name: String, kind: String, parentName: String?, parentShort: String?)] = []
        for (id, channel) in postableChannels.sorted(by: { $0.key < $1.key }) {
            guard channel.serverId == agent.serverId, channel.deletedAt == nil else { continue }
            let visible: Bool
            if channel.kind == "dm" || channel.kind == "thread" || channel.kind == "private" {
                visible = channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
            } else {
                visible = true
            }
            guard visible else { continue }
            let storage = jointProjections.first { $0.localChannelId == id }?.canonicalChannelId ?? id
            var parentName: String?
            var parentShort: String?
            if channel.kind == "thread", let parentId = channel.parentChannelId {
                parentName = postableChannels[parentId]?.name
                parentShort = channel.parentMessageId.map { String($0.prefix(8)) }
            }
            conversations.append((id, storage, channel.name, channel.kind, parentName, parentShort))
        }
        func hintTarget(_ conversation: (id: String, storage: String, name: String, kind: String, parentName: String?, parentShort: String?)) -> String {
            switch conversation.kind {
            case "dm":
                let peer = postableChannels[conversation.id]?.memberIds.first { $0 != agentId }
                    .flatMap { peerId in accounts.values.first { $0.id == peerId }?.name }
                return "dm:@\(peer ?? conversation.name)"
            case "thread":
                if let parentName = conversation.parentName {
                    return "#\(parentName):\(conversation.parentShort ?? "")"
                }
                return "#\(conversation.name)"
            default:
                return "#\(conversation.name)"
            }
        }
        var pending: [(seq: Int, message: StoredHumanMessage, target: String)] = []
        for conversation in conversations {
            let key = "\(conversation.id)\n\(agentId)"
            let cursor = agentChannelReadCursors[key]?.seq ?? 0
            let target = hintTarget(conversation)
            for message in humanMessageRows
            where message.channelId == conversation.storage
                && message.seq > cursor
                && message.senderId != agentId
                && (sinceSeq.map { message.seq > $0 } ?? true)
                && !agentMessageSuppressedLocked(message, agentId: agentId) {
                pending.append((message.seq, message, target))
            }
        }
        pending.sort { $0.seq < $1.seq }
        let hasMore = pending.count > limit
        let rows = pending.prefix(limit).map { entry -> (seq: Int, json: String) in
            (entry.seq, "{\"event_id\":\(jsonString("wake-hint:\(entry.message.id)")),\"seq\":\(entry.seq),\"message_id\":\(jsonString(entry.message.id)),\"target\":\(jsonString(entry.target)),\"wake_reason\":\"message_pending\"}")
        }
        return (rows, hasMore)
    }

    public func agentWakeHints(authorization: String?, since: String?, limit: String? = nil) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            let rawSince = (since ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var sinceSeq: Int?
            if !rawSince.isEmpty, rawSince != "latest" {
                guard let value = Int(rawSince), value >= 0 else {
                    return Self.json(400, "{\"error\":\"since must be a non-negative integer or 'latest'\",\"code\":\"since_invalid\"}")
                }
                sinceSeq = value
            }
            let hintLimit = min(max(Int(limit ?? "") ?? 100, 1), 500)
            lock.lock()
            let pending = pendingWakeHintRowsLocked(agentId: agentId, agent: agent, sinceSeq: sinceSeq, limit: hintLimit)
            let thirdParty = oauth.pendingThirdPartyEventMessages(agentId: agentId)
            lock.unlock()
            var hints = pending.rows.map(\.json)
            for event in thirdParty {
                hints.append("{\"event_id\":\(jsonString("wake-hint:\(event.id)")),\"seq\":null,\"message_id\":\(jsonString(event.id)),\"target\":null,\"wake_reason\":\"message_pending\"}")
            }
            let lastHintSeq = pending.rows.last.map { "\($0.seq)" } ?? "null"
            return Self.json(200, "{\"wake_hints\":[\(hints.joined(separator: ","))],\"last_hint_seq\":\(lastHintSeq),\"has_more\":\(pending.hasMore)}")
        }
    }

    public func agentThirdPartyEvents(authorization: String?) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            lock.lock()
            let actionEvents = pendingActionMessageEvents.filter { $0.agentId == agentId }
            pendingActionMessageEvents.removeAll { $0.agentId == agentId }

            // Every visible conversation, keyed by the channel the agent reads.
            var conversations: [(id: String, storage: String, name: String, type: String)] = []
            for (id, channel) in postableChannels.sorted(by: { $0.key < $1.key }) {
                guard channel.serverId == agent.serverId, channel.deletedAt == nil else { continue }
                let visible: Bool
                if channel.kind == "dm" || channel.kind == "thread" || channel.kind == "private" {
                    visible = channel.memberIds.contains(agentId)
                        || oauth.channelAgentIds(channelId: id).contains(agentId)
                } else {
                    visible = true
                }
                guard visible else { continue }
                let storage = jointProjections.first { $0.localChannelId == id }?.canonicalChannelId ?? id
                conversations.append((id, storage, channel.name, channel.kind == "dm" ? "dm" : "channel"))
            }

            var selected: [(seq: Int, message: StoredHumanMessage, conversation: (id: String, storage: String, name: String, type: String), senderName: String)] = []
            var seenMessages = Set<String>()
            var hasMore = false
            for conversation in conversations {
                let key = "\(conversation.id)\n\(agentId)"
                let cursor = agentChannelReadCursors[key]?.seq ?? 0
                let pending = humanMessageRows.filter { message in
                    message.channelId == conversation.storage
                        && message.seq > cursor
                        && message.senderId != agentId
                        && !agentMessageSuppressedLocked(message, agentId: agentId)
                }
                if pending.count > Self.agentInboxPullCap { hasMore = true }
                for message in pending.prefix(Self.agentInboxPullCap) {
                    guard seenMessages.insert(message.id).inserted else { continue }
                    let senderName = message.externalSenderName
                        ?? accounts.values.first { $0.id == message.senderId }?.name
                        ?? (message.senderId == "system" ? "system" : message.senderId)
                    selected.append((message.seq, message, conversation, senderName))
                }
                if let last = pending.prefix(Self.agentInboxPullCap).last {
                    let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
                    let newSeq = max(previous.seq, last.seq)
                    agentChannelReadCursors[key] = (newSeq, previous.version + (newSeq > previous.seq ? 1 : 0))
                }
            }
            let mentionedIds = Set(storedMentions.filter {
                $0.targetType == "agent" && $0.targetId == agentId
            }.map(\.messageId))
            lock.unlock()

            var events: [String] = []
            var nextSeq = 0
            for row in selected.sorted(by: { $0.seq < $1.seq }) {
                nextSeq = max(nextSeq, row.seq)
                let message = row.message
                let senderType: String
                if message.senderType == "external_projection" {
                    senderType = "third_party_app"
                } else if message.messageType == "system" || message.senderId == "system" {
                    senderType = "system"
                } else if message.senderType == "agent" {
                    senderType = "agent"
                } else {
                    senderType = "human"
                }
                var rowJSON = "{\"seq\":\(row.seq),\"message_id\":\(jsonString(message.id)),\"sender_id\":\(jsonString(message.senderId)),\"sender_name\":\(jsonString(row.senderName)),\"sender_type\":\(jsonString(senderType)),\"senderType\":\(jsonString(senderType)),\"content\":\(jsonString(message.content)),\"mentioned\":\(mentionedIds.contains(message.id)),\"channel_id\":\(jsonString(row.conversation.id)),\"channel_name\":\(jsonString(row.conversation.name)),\"channel_type\":\(jsonString(row.conversation.type)),\"timestamp\":\(jsonString(Self.isoString(message.createdAt)))"
                if senderType == "third_party_app" {
                    let externalId = message.externalMessageId.map(jsonString) ?? "null"
                    let provider = message.externalProvider.map(jsonString) ?? "null"
                    let actor = message.externalSenderName.map(jsonString) ?? "null"
                    rowJSON += ",\"external_message\":{\"message_id\":\(externalId),\"provider\":\(provider),\"actor_name\":\(actor)}"
                }
                rowJSON += "}"
                events.append(rowJSON)
            }
            for event in actionEvents {
                nextSeq += 1
                events.append("{\"seq\":\(nextSeq),\"message_id\":\(jsonString(event.messageId)),\"sender_type\":\"agent\",\"senderType\":\"agent\",\"content\":\(jsonString(event.content)),\"mentioned\":true}")
            }
            for message in oauth.takeThirdPartyEventMessages(agentId: agentId) {
                nextSeq += 1
                let resource = "urn:raft:server:\(message.serverId):agent-inbound"
                let content = Self.inertThirdPartyMentions(message.summary)
                events.append("{\"seq\":\(nextSeq),\"message_id\":\(jsonString(message.id)),\"sender_type\":\"third_party_app\",\"senderType\":\"third_party_app\",\"content\":\(jsonString(content)),\"mentioned\":false,\"third_party_event\":{\"id\":\(jsonString(message.id)),\"kind\":\(jsonString(message.kind)),\"summary\":\(jsonString(message.summary)),\"source\":{\"client_id\":\(jsonString(message.clientKey)),\"client_name\":\(jsonString(message.clientName)),\"oauth_client_id\":\(jsonString(message.clientRecordId)),\"resource\":\(jsonString(resource))}}}")
            }
            return Self.json(200, "{\"events\":[\(events.joined(separator: ","))],\"has_more\":\(hasMore)}")
        }
    }

}
