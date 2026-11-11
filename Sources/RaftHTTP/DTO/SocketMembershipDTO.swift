import Foundation

/// Typed shapes for the socket room membership surface.
///
/// `SocketMembershipService` returns these instead of `[String]` / hand-built
/// JSON. The `sync:resume` payload is embedded verbatim in the socket frame
/// (`42["sync:resume:response",<body>]`), so `SocketSyncResumeDTO.jsonBody()`
/// reproduces the upstream member order and `jsonString` escaping exactly.
/// `JSONEncoder` cannot: on Linux its keyed containers are hash ordered and it
/// escapes `/` as `\/`. This is the one place where the published bytes, not
/// only the decoded shape, are the contract.

/// Channel ids a socket joins at connect time.
public struct SocketVisibleChannelsDTO: Codable, Sendable, Equatable {
    public let channelIds: [String]

    public init(channelIds: [String]) {
        self.channelIds = channelIds
    }
}

/// `channel:<id>` rooms for one parent channel, including child thread rooms.
public struct SocketChannelRoomsDTO: Codable, Sendable, Equatable {
    public let rooms: [String]

    public init(rooms: [String]) {
        self.rooms = rooms
    }
}

/// One attachment chip in a replayed message.
public struct SocketSyncAttachmentDTO: Codable, Sendable, Equatable {
    public let id: String
    public let commentCount: Int

    public init(id: String, commentCount: Int) {
        self.id = id
        self.commentCount = commentCount
    }
}

/// `hostSource` of a scoped attachment-comment chip.
public struct SocketSyncCommentSourceDTO: Codable, Sendable, Equatable {
    public let type: String
    public let routeKind: String
    public let channelId: String
    public let rootThreadChannelId: String?

    public init(type: String, routeKind: String, channelId: String, rootThreadChannelId: String?) {
        self.type = type
        self.routeKind = routeKind
        self.channelId = channelId
        self.rootThreadChannelId = rootThreadChannelId
    }
}

/// Scoped comment chip carried by a replayed message.
public struct SocketSyncCommentRefDTO: Codable, Sendable, Equatable {
    public let attachmentId: String
    public let hostMessageId: String
    public let hostSource: SocketSyncCommentSourceDTO

    public init(attachmentId: String, hostMessageId: String, hostSource: SocketSyncCommentSourceDTO) {
        self.attachmentId = attachmentId
        self.hostMessageId = hostMessageId
        self.hostSource = hostSource
    }
}

/// One replayed message row.
public struct SocketSyncMessageDTO: Codable, Sendable, Equatable {
    public let id: String
    public let channelId: String
    public let seq: Int
    public let content: String
    /// Upstream `syncMessages` selects the six stored task columns for every
    /// row, so the replay frame publishes them even when they are null.
    public let taskStatus: String?
    public let taskNumber: Int?
    public let taskAssigneeType: String?
    public let taskAssigneeId: String?
    public let taskClaimedAt: String?
    public let taskCompletedAt: String?
    /// Upstream strips the task projection from a forwarded-bundle destination
    /// row. `false` omits the six members entirely; an ordinary row keeps them
    /// present as null.
    public let includesTaskFacts: Bool
    public let attachments: [SocketSyncAttachmentDTO]
    public let commentRef: SocketSyncCommentRefDTO?

    public init(
        id: String,
        channelId: String,
        seq: Int,
        content: String,
        taskStatus: String? = nil,
        taskNumber: Int? = nil,
        taskAssigneeType: String? = nil,
        taskAssigneeId: String? = nil,
        taskClaimedAt: String? = nil,
        taskCompletedAt: String? = nil,
        includesTaskFacts: Bool = true,
        attachments: [SocketSyncAttachmentDTO],
        commentRef: SocketSyncCommentRefDTO?
    ) {
        self.id = id
        self.channelId = channelId
        self.seq = seq
        self.content = content
        self.taskStatus = taskStatus
        self.taskNumber = taskNumber
        self.taskAssigneeType = taskAssigneeType
        self.taskAssigneeId = taskAssigneeId
        self.taskClaimedAt = taskClaimedAt
        self.taskCompletedAt = taskCompletedAt
        self.includesTaskFacts = includesTaskFacts
        self.attachments = attachments
        self.commentRef = commentRef
    }

    /// Exact upstream row bytes, including the six task columns and the
    /// optional trailing `commentRef`.
    func jsonBody() -> String {
        let status = taskStatus.map(jsonString) ?? "null"
        let number = taskNumber.map { String($0) } ?? "null"
        let assigneeType = taskAssigneeType.map(jsonString) ?? "null"
        let assigneeId = taskAssigneeId.map(jsonString) ?? "null"
        let claimedAt = taskClaimedAt.map(jsonString) ?? "null"
        let completedAt = taskCompletedAt.map(jsonString) ?? "null"
        let taskFields = includesTaskFacts
            ? "\"taskStatus\":\(status),\"taskNumber\":\(number),\"taskAssigneeType\":\(assigneeType),\"taskAssigneeId\":\(assigneeId),\"taskClaimedAt\":\(claimedAt),\"taskCompletedAt\":\(completedAt),"
            : ""
        var body = "{\"id\":\(jsonString(id)),\"channelId\":\(jsonString(channelId)),\"seq\":\(seq),\"content\":\(jsonString(content)),\(taskFields)\"attachments\":[\(attachments.map { $0.jsonBody() }.joined(separator: ","))]"
        if let commentRef {
            body += ",\"commentRef\":\(commentRef.jsonBody())"
        }
        return body + "}"
    }
}

extension SocketSyncAttachmentDTO {
    func jsonBody() -> String {
        "{\"id\":\(jsonString(id)),\"commentCount\":\(commentCount)}"
    }
}

extension SocketSyncCommentRefDTO {
    func jsonBody() -> String {
        "{\"attachmentId\":\(jsonString(attachmentId)),\"hostMessageId\":\(jsonString(hostMessageId)),\"hostSource\":\(hostSource.jsonBody())}"
    }
}

extension SocketSyncCommentSourceDTO {
    func jsonBody() -> String {
        let thread = rootThreadChannelId.map(jsonString) ?? "null"
        return "{\"type\":\"channel\",\"routeKind\":\"channel\",\"channelId\":\(jsonString(channelId)),\"rootThreadChannelId\":\(thread)}"
    }
}

/// `sync:resume` catch-up body. `nil` from the service means the viewer has no
/// server role (or the cursor is invalid); upstream sends no frame at all.
public struct SocketSyncResumeDTO: Codable, Sendable, Equatable {
    public let messages: [SocketSyncMessageDTO]
    public let currentSeq: Int
    public let hasMore: Bool

    public init(messages: [SocketSyncMessageDTO], currentSeq: Int, hasMore: Bool) {
        self.messages = messages
        self.currentSeq = currentSeq
        self.hasMore = hasMore
    }

    /// Upstream member order and escaping for the socket frame body.
    public func jsonBody() -> String {
        let body = messages.map { $0.jsonBody() }.joined(separator: ",")
        return "{\"messages\":[\(body)],\"currentSeq\":\(currentSeq),\"hasMore\":\(hasMore)}"
    }
}

/// Minimal channel projection the membership rules need from the OAuth ledger.
public struct SocketChannelVisibility: Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: String

    public init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }
}
