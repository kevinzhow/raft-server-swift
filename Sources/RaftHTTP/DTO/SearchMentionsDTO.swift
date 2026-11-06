import Foundation

// MARK: - GET /api/messages/search
//
// Published order is not alphabetical, so every body below is an ordered
// `JSONBodyConvertible` tree rendered once by
// `Sources/RaftHTTPServer/Features/Respond.swift`. The legacy handler built
// these bodies as string literals; the trees reproduce their member order and
// their literal `null` members byte-for-byte.

/// One human-search hit.
///
/// Published order: `id`, `senderId`, `senderType`, `channelId`,
/// `parentChannelId`, `content`, `snippet`, `channelArchivedAt`. The archive
/// timestamp is always a member and prints `null` when the channel is live.
public struct HumanMessageSearchRowDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var senderId: String
    public var senderType: String
    public var channelId: String
    public var parentChannelId: String
    public var content: String
    public var snippet: String
    public var channelArchivedAt: String?

    public init(
        id: String,
        senderId: String,
        senderType: String,
        channelId: String,
        parentChannelId: String,
        content: String,
        snippet: String,
        channelArchivedAt: String?
    ) {
        self.id = id
        self.senderId = senderId
        self.senderType = senderType
        self.channelId = channelId
        self.parentChannelId = parentChannelId
        self.content = content
        self.snippet = snippet
        self.channelArchivedAt = channelArchivedAt
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("senderId", senderId)
        body.append("senderType", senderType)
        body.append("channelId", channelId)
        body.append("parentChannelId", parentChannelId)
        body.append("content", content)
        body.append("snippet", snippet)
        body.append("channelArchivedAt", optional: channelArchivedAt)
        return body.json
    }
}

/// `200` body of `GET /api/messages/search`.
///
/// Published order: `results`, `hasMore`.
public struct HumanMessageSearchResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var results: [HumanMessageSearchRowDTO]
    public var hasMore: Bool

    public init(results: [HumanMessageSearchRowDTO], hasMore: Bool) {
        self.results = results
        self.hasMore = hasMore
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("results", .array(results.map(\.jsonBody)))
        body.append("hasMore", hasMore)
        return body.json
    }
}

// MARK: - Current task projection shared by both agent searches

/// The current task row projected onto a search hit.
///
/// Published order: `title`, `description`, `revision`, `superseded`,
/// `amendedAt`, `amendedByType`, `amendedByName`, `source`. The legacy body was
/// a `tasks_current_projection` literal; the member order is the contract.
public struct TaskCurrentProjectionDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var title: String
    public var description: String?
    public var revision: Int
    public var superseded: Bool
    public var amendedAt: String?
    public var amendedByType: String?
    public var amendedByName: String?

    public init(
        title: String,
        description: String?,
        revision: Int,
        superseded: Bool,
        amendedAt: String?,
        amendedByType: String?,
        amendedByName: String?
    ) {
        self.title = title
        self.description = description
        self.revision = revision
        self.superseded = superseded
        self.amendedAt = amendedAt
        self.amendedByType = amendedByType
        self.amendedByName = amendedByName
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("title", title)
        body.append("description", optional: description)
        body.append("revision", revision)
        body.append("superseded", superseded)
        body.append("amendedAt", optional: amendedAt)
        body.append("amendedByType", optional: amendedByType)
        body.append("amendedByName", optional: amendedByName)
        body.append("source", "tasks_current_projection")
        return body.json
    }
}

// MARK: - GET /internal/agent/:agentId/search

/// One machine-keyed managed-agent search hit.
///
/// Published order: `id`, `senderId`, `senderName`, `senderType`, `channelId`,
/// `channelType`, `channelName`, `parentChannelId`, `threadId`,
/// `parentMessageId`, `parentMessageContent`, `content`, `snippet`,
/// `channelArchivedAt`; then the task fields only when the host message has a
/// task row.
public struct AgentMessageSearchRowDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var senderId: String
    public var senderName: String
    public var senderType: String
    public var channelId: String
    public var channelType: String
    public var channelName: String
    public var parentChannelId: String
    public var threadId: String?
    public var parentMessageId: String?
    public var parentMessageContent: String?
    public var content: String
    public var snippet: String
    public var channelArchivedAt: String?
    public var taskNumber: Int?
    public var taskCurrentProjection: TaskCurrentProjectionDTO?

    public init(
        id: String,
        senderId: String,
        senderName: String,
        senderType: String,
        channelId: String,
        channelType: String,
        channelName: String,
        parentChannelId: String,
        threadId: String?,
        parentMessageId: String?,
        parentMessageContent: String?,
        content: String,
        snippet: String,
        channelArchivedAt: String?,
        taskNumber: Int?,
        taskCurrentProjection: TaskCurrentProjectionDTO?
    ) {
        self.id = id
        self.senderId = senderId
        self.senderName = senderName
        self.senderType = senderType
        self.channelId = channelId
        self.channelType = channelType
        self.channelName = channelName
        self.parentChannelId = parentChannelId
        self.threadId = threadId
        self.parentMessageId = parentMessageId
        self.parentMessageContent = parentMessageContent
        self.content = content
        self.snippet = snippet
        self.channelArchivedAt = channelArchivedAt
        self.taskNumber = taskNumber
        self.taskCurrentProjection = taskCurrentProjection
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("senderId", senderId)
        body.append("senderName", senderName)
        body.append("senderType", senderType)
        body.append("channelId", channelId)
        body.append("channelType", channelType)
        body.append("channelName", channelName)
        body.append("parentChannelId", parentChannelId)
        body.append("threadId", optional: threadId)
        body.append("parentMessageId", optional: parentMessageId)
        body.append("parentMessageContent", optional: parentMessageContent)
        body.append("content", content)
        body.append("snippet", snippet)
        body.append("channelArchivedAt", optional: channelArchivedAt)
        if let taskNumber {
            body.append("taskNumber", taskNumber)
        }
        if let taskCurrentProjection {
            body.append("taskCurrentProjection", taskCurrentProjection.jsonBody)
        }
        return body.json
    }
}

/// `200` body of `GET /internal/agent/:agentId/search`.
///
/// Published order: `results`, `hasMore`.
public struct AgentMessageSearchResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var results: [AgentMessageSearchRowDTO]
    public var hasMore: Bool

    public init(results: [AgentMessageSearchRowDTO], hasMore: Bool) {
        self.results = results
        self.hasMore = hasMore
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("results", .array(results.map(\.jsonBody)))
        body.append("hasMore", hasMore)
        return body.json
    }
}

// MARK: - GET /internal/agent-api/search

/// One agent-api search hit.
///
/// The base published order is `id`, `content`, `senderName`, `senderType`,
/// `senderId`, `channelId`, `channelName`, `parentChannelId`, `snippet`.
/// `enhanced=true` appends `channelType`, `threadId`, `parentMessageId`,
/// `parentMessageContent`; the task fields follow when the host message has a
/// task row.
public struct AgentApiSearchRowDTO: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var content: String
    public var senderName: String
    public var senderType: String
    public var senderId: String
    public var channelId: String
    public var channelName: String
    public var parentChannelId: String
    public var snippet: String
    public var enhanced: Bool
    public var channelType: String?
    public var threadId: String?
    public var parentMessageId: String?
    public var parentMessageContent: String?
    public var taskNumber: Int?
    public var taskCurrentProjection: TaskCurrentProjectionDTO?

    public init(
        id: String,
        content: String,
        senderName: String,
        senderType: String,
        senderId: String,
        channelId: String,
        channelName: String,
        parentChannelId: String,
        snippet: String,
        enhanced: Bool,
        channelType: String?,
        threadId: String?,
        parentMessageId: String?,
        parentMessageContent: String?,
        taskNumber: Int?,
        taskCurrentProjection: TaskCurrentProjectionDTO?
    ) {
        self.id = id
        self.content = content
        self.senderName = senderName
        self.senderType = senderType
        self.senderId = senderId
        self.channelId = channelId
        self.channelName = channelName
        self.parentChannelId = parentChannelId
        self.snippet = snippet
        self.enhanced = enhanced
        self.channelType = channelType
        self.threadId = threadId
        self.parentMessageId = parentMessageId
        self.parentMessageContent = parentMessageContent
        self.taskNumber = taskNumber
        self.taskCurrentProjection = taskCurrentProjection
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("content", content)
        body.append("senderName", senderName)
        body.append("senderType", senderType)
        body.append("senderId", senderId)
        body.append("channelId", channelId)
        body.append("channelName", channelName)
        body.append("parentChannelId", parentChannelId)
        body.append("snippet", snippet)
        if enhanced {
            body.append("channelType", optional: channelType)
            body.append("threadId", optional: threadId)
            body.append("parentMessageId", optional: parentMessageId)
            body.append("parentMessageContent", optional: parentMessageContent)
        }
        if let taskNumber {
            body.append("taskNumber", taskNumber)
        }
        if let taskCurrentProjection {
            body.append("taskCurrentProjection", taskCurrentProjection.jsonBody)
        }
        return body.json
    }
}

/// `200` body of `GET /internal/agent-api/search`.
///
/// Published order: `results`, `hasMore`.
public struct AgentApiSearchResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var results: [AgentApiSearchRowDTO]
    public var hasMore: Bool

    public init(results: [AgentApiSearchRowDTO], hasMore: Bool) {
        self.results = results
        self.hasMore = hasMore
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("results", .array(results.map(\.jsonBody)))
        body.append("hasMore", hasMore)
        return body.json
    }
}

// MARK: - GET /api/messages/context/:messageId stored fallback

/// The thread target the stored context was rewritten onto.
///
/// Published order: `kind`, `channelId`, `messageId`,
/// `threadParentMessageId`, `threadChannelId`.
public struct MessageContextCanonicalTargetDTO: Sendable, Equatable, JSONBodyConvertible {
    public var kind: String
    public var channelId: String
    public var messageId: String
    public var threadParentMessageId: String
    public var threadChannelId: String

    public init(
        kind: String,
        channelId: String,
        messageId: String,
        threadParentMessageId: String,
        threadChannelId: String
    ) {
        self.kind = kind
        self.channelId = channelId
        self.messageId = messageId
        self.threadParentMessageId = threadParentMessageId
        self.threadChannelId = threadChannelId
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("kind", kind)
        body.append("channelId", channelId)
        body.append("messageId", messageId)
        body.append("threadParentMessageId", threadParentMessageId)
        body.append("threadChannelId", threadChannelId)
        return body.json
    }
}

/// One message inside the stored context window.
///
/// Published order: `id`, `channelId`, `content`, `seq`, optional
/// `attachments`, then `commentRef` and `actionMetadata` when the projection
/// supplied them. The window path always publishes `attachments`; the legacy
/// single-message joint/thread path omitted it entirely, which is why the
/// member is optional. The attachment rows, comment reference and action
/// metadata are rendered by the not-yet-migrated attachment/action-card
/// domains, so they enter as raw JSON fragments whose member order those
/// domains own.
public struct MessageContextMessageDTO: Sendable, Equatable, JSONBodyConvertible {
    public var id: String
    public var channelId: String
    public var content: String
    public var seq: Int
    public var attachmentsJSON: String?
    public var commentRefJSON: String?
    public var actionMetadataJSON: String?

    public init(
        id: String,
        channelId: String,
        content: String,
        seq: Int,
        attachmentsJSON: String?,
        commentRefJSON: String?,
        actionMetadataJSON: String?
    ) {
        self.id = id
        self.channelId = channelId
        self.content = content
        self.seq = seq
        self.attachmentsJSON = attachmentsJSON
        self.commentRefJSON = commentRefJSON
        self.actionMetadataJSON = actionMetadataJSON
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("channelId", channelId)
        body.append("content", content)
        body.append("seq", seq)
        if let attachmentsJSON {
            body.append("attachments", .raw("[\(attachmentsJSON)]"))
        }
        if let commentRefJSON {
            body.append("commentRef", .raw(commentRefJSON))
        }
        if let actionMetadataJSON {
            body.append("actionMetadata", .raw(actionMetadataJSON))
        }
        return body.json
    }
}

/// `200` body of the stored `GET /api/messages/context/:messageId` fallback.
///
/// Published order: `channelId`, `targetMessageId`, `hasOlder`, `hasNewer`,
/// `messages`, optional `canonicalTarget`, `threadSummariesByParentMessageId`,
/// `historyLimited`, `channelArchived`.
public struct StoredMessageContextResponse: Sendable, Equatable, JSONBodyConvertible {
    public var channelId: String
    public var targetMessageId: String
    public var hasOlder: Bool
    public var hasNewer: Bool
    public var messages: [MessageContextMessageDTO]
    public var canonicalTarget: MessageContextCanonicalTargetDTO?
    /// The comma-joined `"parentId":{…}` members the thread-summary domain
    /// renders; the surrounding object braces are added here.
    public var threadSummariesByParentMessageIdJSON: String
    public var channelArchived: Bool

    public init(
        channelId: String,
        targetMessageId: String,
        hasOlder: Bool,
        hasNewer: Bool,
        messages: [MessageContextMessageDTO],
        canonicalTarget: MessageContextCanonicalTargetDTO?,
        threadSummariesByParentMessageIdJSON: String,
        channelArchived: Bool
    ) {
        self.channelId = channelId
        self.targetMessageId = targetMessageId
        self.hasOlder = hasOlder
        self.hasNewer = hasNewer
        self.messages = messages
        self.canonicalTarget = canonicalTarget
        self.threadSummariesByParentMessageIdJSON = threadSummariesByParentMessageIdJSON
        self.channelArchived = channelArchived
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("channelId", channelId)
        body.append("targetMessageId", targetMessageId)
        body.append("hasOlder", hasOlder)
        body.append("hasNewer", hasNewer)
        body.append("messages", .array(messages.map(\.jsonBody)))
        if let canonicalTarget {
            body.append("canonicalTarget", canonicalTarget.jsonBody)
        }
        body.append(
            "threadSummariesByParentMessageId",
            .raw("{\(threadSummariesByParentMessageIdJSON)}")
        )
        body.append("historyLimited", false)
        body.append("channelArchived", channelArchived)
        return body.json
    }
}

// MARK: - DELETE /api/channels/:channelId

/// `200` body of a soft channel delete.
///
/// The body is the single `ok` member; a plain `Codable` DTO is sorted-key
/// deterministic here because there is nothing to order.
public struct DeleteChannelResponse: Codable, Sendable, Equatable {
    public var ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}
