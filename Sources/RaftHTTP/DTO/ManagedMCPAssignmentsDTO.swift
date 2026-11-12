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
///
/// The route publishes `{ threadChannelId, ...getThreadInfoForChannel }` after
/// the optional first reply has been posted, so a creation response already
/// carries the reply count and participants. There is no `messageId` member.
public struct ChannelThreadResponse: JSONBodyConvertible, Sendable, Equatable {
    public var threadChannelId: String
    public var replyCount: Int
    public var lastReplyAt: String?
    public var participantIds: [String]

    public init(
        threadChannelId: String,
        replyCount: Int,
        lastReplyAt: String?,
        participantIds: [String]
    ) {
        self.threadChannelId = threadChannelId
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.participantIds = participantIds
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("threadChannelId", threadChannelId),
            OrderedJSONField("replyCount", replyCount),
            OrderedJSONField("lastReplyAt", optional: lastReplyAt),
            OrderedJSONField("participantIds", stringArray(participantIds)),
        ])
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
/// Pinned `channelService.getChannelHumansRawForChannels` selects the account
/// row: `id`, `serverId`, `serverName`, `serverSlug`, `name`, `displayName`,
/// `description`, `avatarUrl`, `role` (server membership role), `serverRole`,
/// `channelRole`, then appends `gravatarHash = sha256(trim(lower(email)))`.
/// `routes/channels.ts` spreads that row and appends the effective channel role
/// triple, so the published order is the account row then `effectiveChannelRole`,
/// `channelAdminBasis` and `canChangeChannelRole`.
///
/// A Guest viewer receives the bounded roster (`id`, `name`, `displayName`,
/// `avatarUrl`, `gravatarHash`, `effectiveChannelRole`, `canChangeChannelRole`);
/// the absent description/server/role members are omitted. `displayName` and
/// `avatarUrl` always publish (JSON null when absent), as the pinned guest
/// branch does. A joint row additionally publishes `servers` between
/// `gravatarHash` and the role triple (`channelService.ts:5955-6034`,
/// `routes/channels.ts:3606-3621`). An enabled virtual `#all` audience row has no
/// stored `channelRole`: its `gravatarHash` precedes `serverRole`, matching
/// `getServerAudienceHumans` + the role projection. The profile fields the
/// account row carries are the Web's message-author identity authority
/// (`ChatPanel.memberById` overlays the server roster with this row).
/// One server a joint-channel human participates through, viewed server first
/// then by name/id (pinned `orderChannelMemberServers`).
public struct ChannelMemberServerDTO: Sendable, Equatable {
    public var id: String
    public var name: String
    public var slug: String

    public init(id: String, name: String, slug: String) {
        self.id = id
        self.name = name
        self.slug = slug
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("slug", slug),
        ])
    }
}

public struct ChannelHumanRowDTO: Sendable, Equatable {
    public var id: String
    public var serverId: String?
    public var serverName: String?
    public var serverSlug: String?
    public var name: String
    public var displayName: String?
    public var description: String?
    public var avatarUrl: String?
    public var role: String?
    public var serverRole: String?
    public var channelRole: String?
    public var gravatarHash: String
    /// Joint-channel projections only; nil for ordinary channels and `#all`.
    public var servers: [ChannelMemberServerDTO]?
    /// The enabled virtual `#all` audience row order has no `channelRole` and
    /// places `gravatarHash` before `serverRole`.
    public var virtualAllAudience: Bool
    public var effectiveChannelRole: String
    public var channelAdminBasis: String?
    public var canChangeChannelRole: Bool

    public init(
        id: String,
        serverId: String? = nil,
        serverName: String? = nil,
        serverSlug: String? = nil,
        name: String,
        displayName: String? = nil,
        description: String? = nil,
        avatarUrl: String? = nil,
        role: String? = nil,
        serverRole: String? = nil,
        channelRole: String? = nil,
        gravatarHash: String,
        servers: [ChannelMemberServerDTO]? = nil,
        virtualAllAudience: Bool = false,
        effectiveChannelRole: String,
        channelAdminBasis: String? = nil,
        canChangeChannelRole: Bool
    ) {
        self.id = id
        self.serverId = serverId
        self.serverName = serverName
        self.serverSlug = serverSlug
        self.name = name
        self.displayName = displayName
        self.description = description
        self.avatarUrl = avatarUrl
        self.role = role
        self.serverRole = serverRole
        self.channelRole = channelRole
        self.gravatarHash = gravatarHash
        self.servers = servers
        self.virtualAllAudience = virtualAllAudience
        self.effectiveChannelRole = effectiveChannelRole
        self.channelAdminBasis = channelAdminBasis
        self.canChangeChannelRole = canChangeChannelRole
    }

    var json: OrderedJSON {
        // The Guest row is bounded: it carries only the identity fields the
        // pinned guest branch publishes. The presence of `serverId` marks the
        // ordinary (unbounded) row; its absent profile/role members are then
        // published as JSON null exactly like the pinned role projection.
        var body = OrderedJSONObject()
        body.append("id", id)
        if let serverId { body.append("serverId", serverId) }
        if let serverName { body.append("serverName", serverName) }
        if let serverSlug { body.append("serverSlug", serverSlug) }
        body.append("name", name)
        body.append("displayName", optional: displayName)
        if serverId != nil {
            body.append("description", optional: description)
        }
        body.append("avatarUrl", optional: avatarUrl)
        if let role { body.append("role", role) }
        if virtualAllAudience {
            // Pinned `getServerAudienceHumans` row: role, gravatarHash, then the
            // projectMemberRole additions; no channelRole member exists.
            body.append("gravatarHash", gravatarHash)
            if let serverRole { body.append("serverRole", serverRole) }
        } else {
            if let serverRole { body.append("serverRole", serverRole) }
            if let channelRole { body.append("channelRole", channelRole) }
            body.append("gravatarHash", gravatarHash)
            if let servers {
                body.append("servers", .array(servers.map(\.json)))
            }
        }
        body.append("effectiveChannelRole", effectiveChannelRole)
        if serverId != nil {
            body.append("channelAdminBasis", optional: channelAdminBasis)
        }
        body.append("canChangeChannelRole", canChangeChannelRole)
        return body.json
    }
}

/// `200` body of `GET /api/channels/:channelId/members`: `agents`, `humans`
/// and, for a non-Guest viewer, `externalMembers`.
///
/// The pinned non-Guest response carries `externalMembers`; the Slack external
/// member projection is not ported (see `docs/DEVIATIONS.md`), so this
/// deployment publishes the empty array. The pinned Guest branch answers only
/// `{agents, humans}` (`routes/channels.ts:3631-3655`), so a Guest response
/// omits the key entirely.
public struct ChannelMembersResponse: JSONBodyConvertible, Sendable, Equatable {
    public var agents: [ChannelAgentRowDTO]
    public var humans: [ChannelHumanRowDTO]
    public var externalMembers: [OrderedJSON]?

    public init(
        agents: [ChannelAgentRowDTO],
        humans: [ChannelHumanRowDTO],
        externalMembers: [OrderedJSON]? = nil
    ) {
        self.agents = agents
        self.humans = humans
        self.externalMembers = externalMembers
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("agents", .array(agents.map(\.json)))
        body.append("humans", .array(humans.map(\.json)))
        if let externalMembers { body.append("externalMembers", .array(externalMembers)) }
        return body.json
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
