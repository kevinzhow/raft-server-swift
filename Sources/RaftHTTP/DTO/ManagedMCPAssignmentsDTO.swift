import Foundation

// MARK: - Request bodies
//
// The legacy handlers parsed the raw body into a dictionary and read each key
// with a checked cast, so a key of the wrong type read as absent. Every request
// type below decodes the same way: a member that is missing, `null` or of
// another type is `nil`, and only a body that is not a JSON object fails to
// decode (the route answers its published 400/404 for that).

extension KeyedDecodingContainer {
    /// One member decoded leniently: absent, `null` and a wrong type are `nil`.
    func lenient<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        try? decode(type, forKey: key)
    }

    /// An array member whose non-string elements are dropped; a member that is
    /// not an array reads as empty (the legacy `compactMap { $0 as? String }`).
    func lenientStrings(forKey key: Key) -> [String] {
        ((try? decode([LenientString].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

/// One array element that reads as `nil` when it is not a string.
struct LenientString: Decodable {
    let value: String?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

/// `POST /api/channels/:channelId/members/batch`.
public struct ChannelMembersBatchRequest: Decodable, Sendable, Equatable {
    public var userIds: [String]
    public var agentIds: [String]

    public init(userIds: [String] = [], agentIds: [String] = []) {
        self.userIds = userIds
        self.agentIds = agentIds
    }

    private enum CodingKeys: String, CodingKey { case userIds, agentIds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userIds = container.lenientStrings(forKey: .userIds)
        agentIds = container.lenientStrings(forKey: .agentIds)
    }
}

/// `POST /api/channels/:channelId/members`: an agent or a human peer.
public struct ChannelMemberRequest: Decodable, Sendable, Equatable {
    public var agentId: String?
    public var userId: String?

    public init(agentId: String? = nil, userId: String? = nil) {
        self.agentId = agentId
        self.userId = userId
    }

    private enum CodingKeys: String, CodingKey { case agentId, userId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = container.lenient(String.self, forKey: .agentId)
        userId = container.lenient(String.self, forKey: .userId)
    }
}

/// `POST /api/channels/:channelId/threads`.
public struct ChannelThreadRequest: Decodable, Sendable, Equatable {
    public var parentMessageId: String?
    public var content: String?

    public init(parentMessageId: String? = nil, content: String? = nil) {
        self.parentMessageId = parentMessageId
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case parentMessageId, content }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentMessageId = container.lenient(String.self, forKey: .parentMessageId)
        content = container.lenient(String.self, forKey: .content)
    }
}

/// `PATCH /api/channels/:channelId/members/user/:memberId/role`.
public struct ChannelRoleRequest: Decodable, Sendable, Equatable {
    public var role: String?

    public init(role: String? = nil) {
        self.role = role
    }

    private enum CodingKeys: String, CodingKey { case role }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = container.lenient(String.self, forKey: .role)
    }
}

/// `PATCH /api/tasks/:taskId/status`.
public struct TaskStatusRequest: Decodable, Sendable, Equatable {
    public var status: String?

    public init(status: String? = nil) {
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case status }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lenient(String.self, forKey: .status)
    }
}

/// `POST /api/tasks/convert-message`.
public struct TaskConvertRequest: Decodable, Sendable, Equatable {
    public var messageId: String?

    public init(messageId: String? = nil) {
        self.messageId = messageId
    }

    private enum CodingKeys: String, CodingKey { case messageId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = container.lenient(String.self, forKey: .messageId)
    }
}

// MARK: - Response bodies
//
// Every body below publishes a member order that is not alphabetical, so each
// is a `JSONBodyConvertible` tree rendered once by `Respond.swift`.

private func stringArray(_ values: [String]) -> OrderedJSON {
    .array(values.map(OrderedJSON.string))
}

/// `200` body of `POST /api/channels/:channelId/members/batch`.
///
/// Published order: `ok`, `added{userIds,agentIds}`,
/// `alreadyMembers{userIds,agentIds}`.
public struct ChannelMembersBatchResponse: JSONBodyConvertible, Sendable, Equatable {
    public var addedUserIds: [String]
    public var addedAgentIds: [String]
    public var alreadyUserIds: [String]
    public var alreadyAgentIds: [String]

    public init(addedUserIds: [String], addedAgentIds: [String], alreadyUserIds: [String], alreadyAgentIds: [String]) {
        self.addedUserIds = addedUserIds
        self.addedAgentIds = addedAgentIds
        self.alreadyUserIds = alreadyUserIds
        self.alreadyAgentIds = alreadyAgentIds
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("added", .object([
                OrderedJSONField("userIds", stringArray(addedUserIds)),
                OrderedJSONField("agentIds", stringArray(addedAgentIds)),
            ])),
            OrderedJSONField("alreadyMembers", .object([
                OrderedJSONField("userIds", stringArray(alreadyUserIds)),
                OrderedJSONField("agentIds", stringArray(alreadyAgentIds)),
            ])),
        ])
    }
}

/// `200` body of `POST /api/channels/:channelId/threads`.
public enum ChannelThreadResponse: JSONBodyConvertible, Sendable, Equatable {
    /// A live thread already hangs off the parent message: `threadChannelId`,
    /// `replyCount`, `lastReplyAt`, `participantIds`.
    case existing(threadChannelId: String, replyCount: Int, lastReplyAt: String?, participantIds: [String])
    /// A thread was created: `threadChannelId`, `messageId` (`null` without a
    /// first reply), `replyCount` 0, `lastReplyAt` `null`, `participantIds` `[]`.
    case created(threadChannelId: String, messageId: String?)

    public var jsonBody: OrderedJSON {
        switch self {
        case .existing(let threadChannelId, let replyCount, let lastReplyAt, let participantIds):
            return .object([
                OrderedJSONField("threadChannelId", threadChannelId),
                OrderedJSONField("replyCount", replyCount),
                OrderedJSONField("lastReplyAt", optional: lastReplyAt),
                OrderedJSONField("participantIds", stringArray(participantIds)),
            ])
        case .created(let threadChannelId, let messageId):
            return .object([
                OrderedJSONField("threadChannelId", threadChannelId),
                OrderedJSONField("messageId", optional: messageId),
                OrderedJSONField("replyCount", 0),
                OrderedJSONField("lastReplyAt", .null),
                OrderedJSONField("participantIds", .array([])),
            ])
        }
    }
}

/// One agent row of a channel roster.
///
/// Published order: `id`, `name`, `activity`, `activityDetail`.
public struct ChannelAgentRowDTO: Sendable, Equatable {
    public var id: String
    public var name: String
    public var activity: String
    public var activityDetail: String

    public init(id: String, name: String, activity: String, activityDetail: String) {
        self.id = id
        self.name = name
        self.activity = activity
        self.activityDetail = activityDetail
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("activity", activity),
            OrderedJSONField("activityDetail", activityDetail),
        ])
    }
}

/// `200` body of `GET /api/channels/:channelId/agents`.
public struct ChannelAgentsResponse: JSONBodyConvertible, Sendable, Equatable {
    public var agents: [ChannelAgentRowDTO]

    public init(agents: [ChannelAgentRowDTO]) {
        self.agents = agents
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("agents", .array(agents.map(\.json)))])
    }
}

/// One human row of a channel roster.
///
/// Published order: `id`, `name`, `serverRole`, `effectiveChannelRole`,
/// `channelAdminBasis` (`null` for a plain member), `canChangeChannelRole`.
public struct ChannelHumanRowDTO: Sendable, Equatable {
    public var id: String
    public var name: String
    public var serverRole: String
    public var effectiveChannelRole: String
    public var channelAdminBasis: String?
    public var canChangeChannelRole: Bool

    public init(
        id: String,
        name: String,
        serverRole: String,
        effectiveChannelRole: String,
        channelAdminBasis: String?,
        canChangeChannelRole: Bool
    ) {
        self.id = id
        self.name = name
        self.serverRole = serverRole
        self.effectiveChannelRole = effectiveChannelRole
        self.channelAdminBasis = channelAdminBasis
        self.canChangeChannelRole = canChangeChannelRole
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("serverRole", serverRole),
            OrderedJSONField("effectiveChannelRole", effectiveChannelRole),
            OrderedJSONField("channelAdminBasis", optional: channelAdminBasis),
            OrderedJSONField("canChangeChannelRole", canChangeChannelRole),
        ])
    }
}

/// `200` body of `GET /api/channels/:channelId/members`: `agents`, `humans`.
public struct ChannelMembersResponse: JSONBodyConvertible, Sendable, Equatable {
    public var agents: [ChannelAgentRowDTO]
    public var humans: [ChannelHumanRowDTO]

    public init(agents: [ChannelAgentRowDTO], humans: [ChannelHumanRowDTO]) {
        self.agents = agents
        self.humans = humans
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agents", .array(agents.map(\.json))),
            OrderedJSONField("humans", .array(humans.map(\.json))),
        ])
    }
}

/// `200` body of the channel-role patch: `ok`, `authorityRevision`.
public struct ChannelRoleUpdateResponse: JSONBodyConvertible, Sendable, Equatable {
    public var authorityRevision: Int

    public init(authorityRevision: Int) {
        self.authorityRevision = authorityRevision
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("authorityRevision", authorityRevision),
        ])
    }
}

/// `200` body of `POST /api/tasks/convert-message`.
public struct TaskConvertResponse: JSONBodyConvertible, Sendable, Equatable {
    public var taskIds: [String]

    public init(taskIds: [String]) {
        self.taskIds = taskIds
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("taskIds", stringArray(taskIds))])
    }
}

/// `200` body of `GET /api/tasks/server`.
///
/// The task rows are projected by the task catalog, which has not migrated, so
/// they enter as already-rendered JSON fragments and keep their member order.
/// The reply also publishes `x-response-bytes` (the body length), which the DTO
/// derives from its own rendering.
public struct ServerTasksResponse: JSONBodyConvertible, Sendable, Equatable {
    public var taskFragments: [String]
    /// `true` for the paginated shape that closes with `next_cursor`.
    public var paginated: Bool
    public var nextCursor: String?

    public init(taskFragments: [String], paginated: Bool, nextCursor: String?) {
        self.taskFragments = taskFragments
        self.paginated = paginated
        self.nextCursor = nextCursor
    }

    public var jsonBody: OrderedJSON {
        var fields = [OrderedJSONField("tasks", .array(taskFragments.map(OrderedJSON.raw)))]
        if paginated {
            fields.append(OrderedJSONField("next_cursor", optional: nextCursor))
        }
        return .object(fields)
    }

    /// The rendered body length the reply publishes as `Content-Length` and
    /// `x-response-bytes`.
    public var responseBytes: Int {
        jsonBody.render().utf8.count
    }

    /// The standard JSON header set plus `x-response-bytes`.
    public var headers: ResponseHeaders {
        .standard(extra: ["x-response-bytes": String(responseBytes)])
    }
}
