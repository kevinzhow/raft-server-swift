import Foundation

// MARK: - Ordered bodies
//
// The thread replies publish a fixed key order that is not alphabetical, and
// two of them always print a nullable field as JSON `null`. `JSONEncoder` on
// Linux writes keyed containers in hash order, so every body below is a
// `JSONBodyConvertible` tree and `Sources/RaftHTTPServer/Features/Respond.swift`
// renders it once. The tree is the only source of the published bytes.

// MARK: - GET /api/channels/threads/followers

/// One agent row inside a follower-roster thread.
///
/// Published order: `id`, `name`.
public struct ThreadFollowerAgentDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("name", name)
        return body.json
    }
}

/// One thread the caller can see in the follower roster.
///
/// Published order: `threadChannelId`, `canManage`, `agents`. The legacy reply
/// always prints `agents`, using `[]` when the thread has none.
public struct ThreadFollowerRosterRowDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var threadChannelId: String
    public var canManage: Bool
    public var agents: [ThreadFollowerAgentDTO]

    public init(threadChannelId: String, canManage: Bool, agents: [ThreadFollowerAgentDTO]) {
        self.threadChannelId = threadChannelId
        self.canManage = canManage
        self.agents = agents
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("threadChannelId", threadChannelId)
        body.append("canManage", canManage)
        body.append("agents", .array(agents.map(\.jsonBody)))
        return body.json
    }
}

/// `200` body of `GET /api/channels/threads/followers`.
public struct ThreadFollowerRosterResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var threads: [ThreadFollowerRosterRowDTO]

    public init(threads: [ThreadFollowerRosterRowDTO]) {
        self.threads = threads
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("threads", .array(threads.map(\.jsonBody)))
        return body.json
    }
}

// MARK: - POST /api/channels/threads/follow and /unfollow

/// `200` body of `POST /api/channels/threads/follow|unfollow`.
///
/// Published order: `ok`, `following`; `ok` is always `true` on success, so the
/// legacy literal is part of the wire shape.
public struct ThreadFollowResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var ok: Bool
    public var following: Bool

    public init(following: Bool) {
        self.ok = true
        self.following = following
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", ok)
        body.append("following", following)
        return body.json
    }
}

// MARK: - GET /api/channels/threads/followed

/// One followed-thread row.
///
/// Published order: `threadChannelId`, `parentChannelId`,
/// `parentMessageCreatedAt`, `unreadCount`, `firstUnreadMessageId`,
/// `hasMention`, `taskId`, `taskClaimedByType`, `taskClaimedById`,
/// `taskClaimedByName`. The four task fields print JSON `null` when absent.
public struct FollowedThreadRowDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var threadChannelId: String
    public var parentChannelId: String
    public var parentMessageCreatedAt: String
    public var unreadCount: Int
    public var firstUnreadMessageId: String?
    public var hasMention: Bool
    public var taskId: String?
    public var taskClaimedByType: String?
    public var taskClaimedById: String?
    public var taskClaimedByName: String?

    public init(
        threadChannelId: String,
        parentChannelId: String,
        parentMessageCreatedAt: String,
        unreadCount: Int,
        firstUnreadMessageId: String?,
        hasMention: Bool,
        taskId: String?,
        taskClaimedByType: String?,
        taskClaimedById: String?,
        taskClaimedByName: String?
    ) {
        self.threadChannelId = threadChannelId
        self.parentChannelId = parentChannelId
        self.parentMessageCreatedAt = parentMessageCreatedAt
        self.unreadCount = unreadCount
        self.firstUnreadMessageId = firstUnreadMessageId
        self.hasMention = hasMention
        self.taskId = taskId
        self.taskClaimedByType = taskClaimedByType
        self.taskClaimedById = taskClaimedById
        self.taskClaimedByName = taskClaimedByName
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("threadChannelId", threadChannelId)
        body.append("parentChannelId", parentChannelId)
        body.append("parentMessageCreatedAt", parentMessageCreatedAt)
        body.append("unreadCount", unreadCount)
        body.append("firstUnreadMessageId", optional: firstUnreadMessageId)
        body.append("hasMention", hasMention)
        body.append("taskId", optional: taskId)
        body.append("taskClaimedByType", optional: taskClaimedByType)
        body.append("taskClaimedById", optional: taskClaimedById)
        body.append("taskClaimedByName", optional: taskClaimedByName)
        return body.json
    }
}

/// `200` body of `GET /api/channels/threads/followed`.
///
/// A request without `limit` publishes only `threads`; a request with `limit`
/// always publishes `next` too, using JSON `null` on the last page.
public struct FollowedThreadsResponse: Sendable, Equatable, JSONBodyConvertible {
    public var threads: [FollowedThreadRowDTO]
    public var next: String?
    /// `true` when the request supplied `limit`, which is what selects the
    /// two-field shape.
    public var publishesNext: Bool

    public init(threads: [FollowedThreadRowDTO], next: String? = nil, publishesNext: Bool = false) {
        self.threads = threads
        self.next = next
        self.publishesNext = publishesNext
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("threads", .array(threads.map(\.jsonBody)))
        if publishesNext {
            body.append("next", optional: next)
        }
        return body.json
    }
}

// MARK: - GET /api/channels/inbox/unfollowed

/// One unfollowed-thread inbox row.
///
/// Published order: `kind`, `threadChannelId`, `latestActivityMessageId`,
/// `replyCount`, `unreadCount`, `hasMention`, `isFollowing`, `unfollowedAt`.
public struct UnfollowedInboxItemDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var kind: String
    public var threadChannelId: String
    public var latestActivityMessageId: String
    public var replyCount: Int
    public var unreadCount: Int
    public var hasMention: Bool
    public var isFollowing: Bool
    public var unfollowedAt: String

    public init(
        threadChannelId: String,
        latestActivityMessageId: String,
        replyCount: Int,
        unfollowedAt: String
    ) {
        self.kind = "thread"
        self.threadChannelId = threadChannelId
        self.latestActivityMessageId = latestActivityMessageId
        self.replyCount = replyCount
        self.unreadCount = 0
        self.hasMention = false
        self.isFollowing = false
        self.unfollowedAt = unfollowedAt
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("kind", kind)
        body.append("threadChannelId", threadChannelId)
        body.append("latestActivityMessageId", latestActivityMessageId)
        body.append("replyCount", replyCount)
        body.append("unreadCount", unreadCount)
        body.append("hasMention", hasMention)
        body.append("isFollowing", isFollowing)
        body.append("unfollowedAt", unfollowedAt)
        return body.json
    }
}

/// `200` body of `GET /api/channels/inbox/unfollowed`.
///
/// Published order: `items`, `hasMore`, `totalCount`; `totalCount` is always
/// JSON `null` on this surface.
public struct UnfollowedInboxResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var items: [UnfollowedInboxItemDTO]
    public var hasMore: Bool

    public init(items: [UnfollowedInboxItemDTO], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("items", .array(items.map(\.jsonBody)))
        body.append("hasMore", hasMore)
        body.append("totalCount", .null)
        return body.json
    }
}

// MARK: - GET /api/channels/:channelId/threads/:messageId

/// `200` body of `GET /api/channels/:channelId/threads/:messageId`.
///
/// Published order: `threadChannelId`, `replyCount`, `lastReplyAt`,
/// `participantIds`. `lastReplyAt` prints JSON `null` for a thread without
/// replies.
public struct ThreadInfoResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var threadChannelId: String
    public var replyCount: Int
    public var lastReplyAt: String?
    public var participantIds: [String]

    public init(threadChannelId: String, replyCount: Int, lastReplyAt: String?, participantIds: [String]) {
        self.threadChannelId = threadChannelId
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.participantIds = participantIds
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("threadChannelId", threadChannelId)
        body.append("replyCount", replyCount)
        body.append("lastReplyAt", optional: lastReplyAt)
        body.append("participantIds", .array(participantIds.map(OrderedJSON.string)))
        return body.json
    }
}

// MARK: - GET /api/channels/:channelId/threads

/// One reply preview inside a channel thread summary.
///
/// Published order: `preview`, `senderType`, `senderId`, `senderName`,
/// `senderDisplayName`.
public struct ChannelThreadReplyDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var preview: String
    public var senderType: String
    public var senderId: String
    public var senderName: String
    public var senderDisplayName: String

    public init(preview: String, senderType: String, senderId: String, senderName: String, senderDisplayName: String) {
        self.preview = preview
        self.senderType = senderType
        self.senderId = senderId
        self.senderName = senderName
        self.senderDisplayName = senderDisplayName
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("preview", preview)
        body.append("senderType", senderType)
        body.append("senderId", senderId)
        body.append("senderName", senderName)
        body.append("senderDisplayName", senderDisplayName)
        return body.json
    }
}

/// One parent message's canonical thread summary.
///
/// Published order: `threadChannelId`, `replyCount`, `latestReplies`,
/// `unreadCount`, `firstUnreadMessageId`, `participantIds`, `followed`.
public struct ChannelThreadSummaryDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var threadChannelId: String
    public var replyCount: Int
    public var latestReplies: [ChannelThreadReplyDTO]
    public var unreadCount: Int
    public var firstUnreadMessageId: String?
    public var participantIds: [String]
    public var followed: Bool

    public init(
        threadChannelId: String,
        replyCount: Int,
        latestReplies: [ChannelThreadReplyDTO],
        unreadCount: Int,
        firstUnreadMessageId: String?,
        participantIds: [String],
        followed: Bool
    ) {
        self.threadChannelId = threadChannelId
        self.replyCount = replyCount
        self.latestReplies = latestReplies
        self.unreadCount = unreadCount
        self.firstUnreadMessageId = firstUnreadMessageId
        self.participantIds = participantIds
        self.followed = followed
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("threadChannelId", threadChannelId)
        body.append("replyCount", replyCount)
        body.append("latestReplies", .array(latestReplies.map(\.jsonBody)))
        body.append("unreadCount", unreadCount)
        body.append("firstUnreadMessageId", optional: firstUnreadMessageId)
        body.append("participantIds", .array(participantIds.map(OrderedJSON.string)))
        body.append("followed", followed)
        return body.json
    }
}

/// One `parentMessageId: summary` member of the channel thread map.
public struct ChannelThreadSummaryEntry: Sendable, Equatable {
    public var parentMessageId: String
    public var summary: ChannelThreadSummaryDTO

    public init(parentMessageId: String, summary: ChannelThreadSummaryDTO) {
        self.parentMessageId = parentMessageId
        self.summary = summary
    }
}

/// `200` body of `GET /api/channels/:channelId/threads`.
///
/// The upstream body is a bare object keyed by parent message id, with no
/// wrapper member. Members are published in the order the canonical threads
/// were selected, so two identical requests render identical bytes.
public struct ChannelThreadSummariesResponse: Sendable, Equatable, JSONBodyConvertible {
    public var entries: [ChannelThreadSummaryEntry]

    public init(entries: [ChannelThreadSummaryEntry]) {
        self.entries = entries
    }

    public var jsonBody: OrderedJSON {
        .object(entries.map { OrderedJSONField($0.parentMessageId, $0.summary.jsonBody) })
    }
}
