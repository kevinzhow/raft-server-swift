import Foundation

/// Typed shapes for the served-inbox surface: the channel message page and its
/// sync cursor, mention deliveries, and the Done page.
///
/// Every published object here has a legacy member order that is not
/// alphabetical, so each shape is a `JSONBodyConvertible` tree that
/// `Sources/RaftHTTPServer/Features/Respond.swift` renders once. Strings use
/// the module's legacy `jsonString` escaping; `JSONEncoder` cannot reproduce
/// the order (Linux keyed containers are hash ordered).
///
/// Four per-message fragments stay owned by domains that have not migrated yet
/// (reaction buckets, forward metadata, action-card metadata, thread summaries).
/// They enter the service as `OrderedJSON` from an injected closure and are
/// placed verbatim at the position the legacy row published them; the surrounding
/// members are typed here.

// MARK: - Attachment chips and scoped comment chips

/// One attachment chip of a served message row.
public struct InboxAttachmentChipDTO: Sendable, Equatable, JSONBodyConvertible {
    public let id: String
    public let commentCount: Int
    public let filename: String?
    public let mimeType: String?
    public let sizeBytes: Int?
    public let width: Int?
    public let height: Int?

    public init(id: String, commentCount: Int, filename: String? = nil, mimeType: String? = nil,
                sizeBytes: Int? = nil, width: Int? = nil, height: Int? = nil) {
        self.id = id; self.commentCount = commentCount; self.filename = filename
        self.mimeType = mimeType; self.sizeBytes = sizeBytes; self.width = width; self.height = height
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id); body.append("commentCount", commentCount)
        body.append("filename", ifPresent: filename)
        body.append("mimeType", ifPresent: mimeType)
        if let sizeBytes { body.append("sizeBytes", sizeBytes) }
        if filename != nil {
            body.append("width", optional: width); body.append("height", optional: height)
        }
        return body.json
    }
}

/// `hostSource` of a scoped attachment-comment chip.
public struct InboxCommentSourceDTO: Sendable, Equatable {
    public let channelId: String
    public let rootThreadChannelId: String?

    public init(channelId: String, rootThreadChannelId: String?) {
        self.channelId = channelId
        self.rootThreadChannelId = rootThreadChannelId
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("type", "channel"),
            OrderedJSONField("routeKind", "channel"),
            OrderedJSONField("channelId", channelId),
            OrderedJSONField("rootThreadChannelId", optional: rootThreadChannelId),
        ])
    }
}

/// Scoped attachment-comment chip carried by a served message row.
public struct InboxCommentRefDTO: Sendable, Equatable {
    public let attachmentId: String
    public let filename: String?
    public let hostMessageId: String
    public let hostSource: InboxCommentSourceDTO

    public init(attachmentId: String, hostMessageId: String, hostSource: InboxCommentSourceDTO, filename: String? = nil) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.hostMessageId = hostMessageId
        self.hostSource = hostSource
    }

    var jsonBody: OrderedJSON {
        var fields = [
            OrderedJSONField("attachmentId", attachmentId),
            OrderedJSONField("hostMessageId", hostMessageId),
            OrderedJSONField("hostSource", hostSource.jsonBody),
        ]
        if let filename { fields.append(OrderedJSONField("filename", filename)) }
        return .object(fields)
    }
}

/// One visible mention chip (`type`, `id`, `name`) of a channel message row.
public struct InboxMentionDTO: Sendable, Equatable {
    public let type: String
    public let id: String
    public let name: String

    public init(type: String, id: String, name: String) {
        self.type = type
        self.id = id
        self.name = name
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("type", type),
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
        ])
    }
}

// MARK: - GET /api/messages/sync

/// One row of the sync stream.
///
/// Member order is the legacy string: `id`, `channelId`, `seq`, `content`,
/// `attachments`, then the optional `commentRef` and `actionMetadata`. Only a
/// scoped `channel_id` page carries `actionMetadata`; the broadcast page never
/// does.
public struct InboxSyncMessageDTO: Sendable, Equatable, JSONBodyConvertible {
    public let id: String
    public let facts: MessageReadFactsDTO?
    public let channelId: String
    public let seq: Int
    public let content: String
    public let attachments: [InboxAttachmentChipDTO]
    public let commentRef: InboxCommentRefDTO?
    public let actionMetadata: OrderedJSON?

    public init(
        id: String,
        channelId: String,
        seq: Int,
        content: String,
        attachments: [InboxAttachmentChipDTO],
        commentRef: InboxCommentRefDTO?,
        actionMetadata: OrderedJSON? = nil,
        facts: MessageReadFactsDTO? = nil
    ) {
        self.id = id
        self.facts = facts
        self.channelId = channelId
        self.seq = seq
        self.content = content
        self.attachments = attachments
        self.commentRef = commentRef
        self.actionMetadata = actionMetadata
    }

    public var jsonBody: OrderedJSON {
        var fields: [OrderedJSONField] = [
            OrderedJSONField("id", id),
            OrderedJSONField("channelId", channelId),
            OrderedJSONField("seq", seq),
            OrderedJSONField("content", content),
            OrderedJSONField("attachments", .array(attachments.map(\.jsonBody))),
        ]
        if let commentRef {
            fields.append(OrderedJSONField("commentRef", commentRef.jsonBody))
        }
        if let actionMetadata {
            fields.append(OrderedJSONField("actionMetadata", actionMetadata))
        }
        let body = OrderedJSON.object(fields)
        return facts?.merging(into: body) ?? body
    }
}

/// The bare JSON array the sync route answers with.
public struct InboxSyncPageDTO: Sendable, Equatable, JSONBodyConvertible {
    public let messages: [InboxSyncMessageDTO]

    public init(messages: [InboxSyncMessageDTO]) {
        self.messages = messages
    }

    public var jsonBody: OrderedJSON {
        .array(messages.map(\.jsonBody))
    }
}

// MARK: - GET /api/messages/channel/:channelId

/// One channel history row, including its persisted sequence, message kind and
/// creation time. Reactions and action metadata remain domain-owned fragments.
public struct InboxChannelMessageRowDTO: Sendable, Equatable, JSONBodyConvertible {
    public let id: String
    public let facts: MessageReadFactsDTO?
    public let seq: Int
    public let messageType: String
    public let createdAt: String
    public let senderId: String
    public let senderType: String
    public let senderMembershipStatus: String?
    public let content: String
    public let attachments: [InboxAttachmentChipDTO]
    public let reactions: OrderedJSON
    public let mentions: [InboxMentionDTO]
    public let commentRef: InboxCommentRefDTO?
    public let actionMetadata: OrderedJSON?

    public init(
        id: String,
        seq: Int,
        messageType: String,
        createdAt: String,
        senderId: String,
        senderType: String,
        senderMembershipStatus: String?,
        content: String,
        attachments: [InboxAttachmentChipDTO],
        reactions: OrderedJSON,
        mentions: [InboxMentionDTO],
        commentRef: InboxCommentRefDTO?,
        actionMetadata: OrderedJSON?,
        facts: MessageReadFactsDTO? = nil
    ) {
        self.id = id
        self.facts = facts
        self.seq = seq
        self.messageType = messageType
        self.createdAt = createdAt
        self.senderId = senderId
        self.senderType = senderType
        self.senderMembershipStatus = senderMembershipStatus
        self.content = content
        self.attachments = attachments
        self.reactions = reactions
        self.mentions = mentions
        self.commentRef = commentRef
        self.actionMetadata = actionMetadata
    }

    public var jsonBody: OrderedJSON {
        var fields: [OrderedJSONField] = [
            OrderedJSONField("id", id),
            OrderedJSONField("seq", seq),
            OrderedJSONField("senderId", senderId),
            OrderedJSONField("senderType", senderType),
            OrderedJSONField("senderMembershipStatus", optional: senderMembershipStatus),
            OrderedJSONField("messageType", messageType),
            OrderedJSONField("content", content),
            OrderedJSONField("createdAt", createdAt),
            OrderedJSONField("attachments", .array(attachments.map(\.jsonBody))),
            OrderedJSONField("reactions", reactions),
            OrderedJSONField("mentions", .array(mentions.map(\.jsonBody))),
        ]
        if let commentRef {
            fields.append(OrderedJSONField("commentRef", commentRef.jsonBody))
        }
        if let actionMetadata {
            fields.append(OrderedJSONField("actionMetadata", actionMetadata))
        }
        let body = OrderedJSON.object(fields)
        return facts?.merging(into: body) ?? body
    }
}

/// The frozen receiver-visible window published next to a channel page.
///
/// Member order is the legacy string; `schemaVersion` and `domain` are
/// constants, and the receiver is always the human user who asked.
public struct InboxMessageWindowDTO: Sendable, Equatable {
    public let serverId: String
    public let receiverId: String
    public let scopeId: String
    public let coveredFromSeq: Int
    public let coveredAfterSeq: Int
    public let coveredThroughSeq: Int
    public let remoteHighWaterSeq: Int
    public let hasGap: Bool
    public let hasNewer: Bool
    public let completeThroughLatest: Bool

    public init(
        serverId: String,
        receiverId: String,
        scopeId: String,
        coveredFromSeq: Int,
        coveredAfterSeq: Int,
        coveredThroughSeq: Int,
        remoteHighWaterSeq: Int,
        hasGap: Bool,
        hasNewer: Bool,
        completeThroughLatest: Bool
    ) {
        self.serverId = serverId
        self.receiverId = receiverId
        self.scopeId = scopeId
        self.coveredFromSeq = coveredFromSeq
        self.coveredAfterSeq = coveredAfterSeq
        self.coveredThroughSeq = coveredThroughSeq
        self.remoteHighWaterSeq = remoteHighWaterSeq
        self.hasGap = hasGap
        self.hasNewer = hasNewer
        self.completeThroughLatest = completeThroughLatest
    }

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("schemaVersion", 1),
            OrderedJSONField("domain", "receiver_visible_messages_v1"),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("receiverKind", "user"),
            OrderedJSONField("receiverId", receiverId),
            OrderedJSONField("scopeId", scopeId),
            OrderedJSONField("coveredFromSeq", coveredFromSeq),
            OrderedJSONField("coveredAfterSeq", coveredAfterSeq),
            OrderedJSONField("coveredThroughSeq", coveredThroughSeq),
            OrderedJSONField("remoteHighWaterSeq", remoteHighWaterSeq),
            OrderedJSONField("hasGap", hasGap),
            OrderedJSONField("hasNewer", hasNewer),
            OrderedJSONField("completeThroughLatest", completeThroughLatest),
        ])
    }
}

/// The channel message page body.
public struct ChannelMessagesPageDTO: Sendable, Equatable, JSONBodyConvertible {
    public let messages: [InboxChannelMessageRowDTO]
    public let messageWindow: InboxMessageWindowDTO
    /// Parent message id → `{"replyCount":…,"latestReplies":[…]}`; an empty
    /// object when no thread hangs off this page.
    public let threadSummariesByParentMessageId: OrderedJSON

    public init(
        messages: [InboxChannelMessageRowDTO],
        messageWindow: InboxMessageWindowDTO,
        threadSummariesByParentMessageId: OrderedJSON
    ) {
        self.messages = messages
        self.messageWindow = messageWindow
        self.threadSummariesByParentMessageId = threadSummariesByParentMessageId
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("messages", .array(messages.map(\.jsonBody))),
            OrderedJSONField("historyLimited", false),
            OrderedJSONField("messageWindow", messageWindow.jsonBody),
            OrderedJSONField(
                "threadSummariesByParentMessageId",
                threadSummariesByParentMessageId
            ),
        ])
    }
}

// MARK: - GET /api/messages/:messageId/mention-deliveries

/// One coarse delivery outcome.
///
/// A missing terminal code (or `INSTRUMENT_FAILED`) publishes `unknown`; a
/// terminal code publishes `lost` with its reason category. Member order is the
/// legacy string.
public struct MentionDeliveryRowDTO: Sendable, Equatable {
    public let targetId: String
    public let handle: String
    public let terminalCode: String?

    public init(targetId: String, handle: String, terminalCode: String?) {
        self.targetId = targetId
        self.handle = handle
        self.terminalCode = terminalCode
    }

    var jsonBody: OrderedJSON {
        var fields: [OrderedJSONField] = [
            OrderedJSONField("targetId", targetId),
            OrderedJSONField("targetHandle", handle),
        ]
        guard let terminalCode, terminalCode != "INSTRUMENT_FAILED" else {
            fields.append(OrderedJSONField("outcome", "unknown"))
            return .object(fields)
        }
        let category: String
        switch terminalCode {
        case "QUOTA_LIMITED":
            category = "quota"
        case "DELIVERY_REJECTED":
            category = "runtime_error"
        default:
            category = "unclassified"
        }
        fields.append(OrderedJSONField("outcome", "lost"))
        fields.append(OrderedJSONField("reasonCategory", category))
        return .object(fields)
    }
}

/// The mention-delivery body: `messageId`, then `deliveries`.
public struct MentionDeliveriesResponseDTO: Sendable, Equatable, JSONBodyConvertible {
    public let messageId: String
    public let deliveries: [MentionDeliveryRowDTO]

    public init(messageId: String, deliveries: [MentionDeliveryRowDTO]) {
        self.messageId = messageId
        self.deliveries = deliveries
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("messageId", messageId),
            OrderedJSONField("deliveries", .array(deliveries.map(\.jsonBody))),
        ])
    }
}

// MARK: - GET /api/channels/inbox/done

/// One Done-inbox row: a whole channel or a thread scope.
public enum InboxDoneItemDTO: Sendable, Equatable {
    case thread(
        threadChannelId: String,
        parentChannelId: String?,
        isFollowing: Bool,
        unreadCount: Int,
        doneAt: String
    )
    case channel(channelId: String, unreadCount: Int, doneAt: String)

    var jsonBody: OrderedJSON {
        switch self {
        case .thread(let threadChannelId, let parentChannelId, let isFollowing, let unreadCount, let doneAt):
            return .object([
                OrderedJSONField("kind", "thread"),
                OrderedJSONField("threadChannelId", threadChannelId),
                OrderedJSONField("parentChannelId", optional: parentChannelId),
                OrderedJSONField("isFollowing", isFollowing),
                OrderedJSONField("unreadCount", unreadCount),
                OrderedJSONField("doneAt", doneAt),
            ])
        case .channel(let channelId, let unreadCount, let doneAt):
            return .object([
                OrderedJSONField("kind", "channel"),
                OrderedJSONField("channelId", channelId),
                OrderedJSONField("unreadCount", unreadCount),
                OrderedJSONField("doneAt", doneAt),
            ])
        }
    }
}

/// The Done-inbox page: `items`, `hasMore`, and the literal `totalCount: null`.
public struct InboxDonePageDTO: Sendable, Equatable, JSONBodyConvertible {
    public let items: [InboxDoneItemDTO]
    public let hasMore: Bool

    public init(items: [InboxDoneItemDTO], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("items", .array(items.map(\.jsonBody))),
            OrderedJSONField("hasMore", hasMore),
            OrderedJSONField("totalCount", .null),
        ])
    }
}
