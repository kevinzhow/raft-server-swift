import Foundation

/// One scope row of the Activity page before projection.
private struct InboxRow {
    var scopeId: String
    var kind: String
    var channelType: String
    var parentChannelId: String?
    var parentChannelType: String?
    var lastMessageId: String
    var lastActivityAt: Date
    var searchText: String
    var unreadCount: Int
    var firstUnreadMessageId: String?
    var firstMentionMessageId: String?
    var hasMention: Bool
    var isFollowing: Bool
    var isDM: Bool
}

private struct InboxGroup {
    var channelId: String
    var channelName: String
    var channelType: String
    var count: Int
    var lastActivityAt: Date
}

private struct InboxMessageDetail {
    var content: String
    var senderId: String
    var seq: Int
    var createdAt: Date
}

/// `GET /api/channels/inbox`: the Activity page.
extension ReactionsRealtimeService {
    public func channelInbox(
        authorization: String?,
        serverId: String?,
        filter: String?,
        query: String? = nil
    ) throws -> ChannelInboxResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ReactionsRealtimeError.inboxAuthRequired(bearer: authorization?.hasPrefix("Bearer ") == true)
        }
        let params = MessagePageCursor.inboxQueryParameters(query)
        let effectiveFilter = params["filter"] ?? filter ?? "all"
        let limit = min(max(Int(params["limit"] ?? "") ?? 30, 1), 100)
        let offset = max(Int(params["offset"] ?? "") ?? 0, 0)
        let ascending = params["sort"] == "asc"
        let channelFilter = params["channelId"].flatMap { $0.isEmpty ? nil : $0 }
        let scope = params["scope"]
        let search = params["q"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let facts = inboxFacts.all()
        let snapshot = messages.inboxReadSnapshot()
        let doneScopes = snapshot.doneScopes
        let mentions = snapshot.mentions
        let unfollows = snapshot.unfollows
        let humanRows = snapshot.humanRows
        let postable = channels.postableChannels

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
               !dependencies.guestCanSeeScope(scopeId) {
                continue
            }
            let parentChannelId = isThread ? channel?.parentChannelId : nil
            if isThread, let parentChannelId,
               postable[parentChannelId]?.kind == "dm",
               doneScopes.contains("\(userId)\n\(parentChannelId)") { continue }
            let detailMap = Self.inboxMessageDetails(
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
            let followKey = "\(serverId ?? "")\n\(userId)\n\(scopeId)"
            let suppressed = unfollows[followKey] != nil
            let unread = suppressed ? 0 : unreadInfo.unreadCount
            let firstUnread = suppressed ? nil : oauth.firstUnreadMessageId(channelId: scopeId, userId: userId)
            let firstMention = suppressed ? nil : scopeMentions
                .map { (messageId: $0.messageId, seq: detailMap[$0.messageId]?.seq ?? 0) }
                .filter { $0.seq > unreadInfo.maxReadSeq }
                .min { $0.seq < $1.seq }?.messageId
            let lastMessageId = fact.messageId
            let detail = detailMap[lastMessageId]
            let isFollowing = !suppressed && snapshot.followKeys.contains(followKey)
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
               !dependencies.guestCanSeeScope(record.threadChannelId) {
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
               !dependencies.guestCanSeeScope(scopeId) { continue }
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

        let items = page.map { row -> ChannelInboxResponse.Item in
            if row.kind == "thread" {
                return .thread(
                    threadChannelId: row.scopeId,
                    parentChannelId: row.parentChannelId,
                    parentChannelType: row.parentChannelType,
                    latestActivityMessageId: row.lastMessageId,
                    firstUnreadMessageId: row.firstUnreadMessageId,
                    firstMentionMessageId: row.firstMentionMessageId,
                    unreadCount: row.unreadCount,
                    hasMention: row.hasMention,
                    isFollowing: row.isFollowing
                )
            }
            return .conversation(
                kind: row.kind == "dm" ? "dm" : "channel",
                channelId: row.scopeId,
                channelType: row.channelType,
                lastMessageId: row.lastMessageId,
                firstUnreadMessageId: row.firstUnreadMessageId,
                firstMentionMessageId: row.firstMentionMessageId,
                unreadCount: row.unreadCount,
                hasMention: row.hasMention
            )
        }

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
        let groupItems = groups.values.sorted { left, right in
            let leftDM = left.channelType == "dm"
            let rightDM = right.channelType == "dm"
            if leftDM != rightDM { return leftDM }
            if left.lastActivityAt != right.lastActivityAt { return left.lastActivityAt > right.lastActivityAt }
            if left.channelName != right.channelName { return left.channelName < right.channelName }
            return left.channelId < right.channelId
        }.map { group in
            ChannelInboxResponse.Group(
                channelId: group.channelId,
                channelName: group.channelName,
                channelType: group.channelType,
                count: group.count,
                lastActivityAt: DateText.isoString(group.lastActivityAt)
            )
        }

        return ChannelInboxResponse(
            items: items,
            hasMore: hasMore,
            totalCount: totalCount,
            totalUnreadCount: totalUnreadCount,
            activeUnreadCount: activeUnreadCount,
            groups: groupItems
        )
    }

    private static func inboxMessageDetails(
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

    private func senderName(senderId: String) -> String {
        if let agent = oauth.agentRuntimeInfo(id: senderId) { return agent.name }
        return dependencies.userName(senderId) ?? senderId
    }
}
