import Foundation
import RaftShared

// MARK: - Request bodies
//
// The retired handlers read their bodies with raw object casts plus per-field
// `as?` casts. Each decoder below keeps that tolerance: a member of the wrong
// JSON type reads as the legacy `nil`, so the domain's published 400 is
// unchanged, and where the legacy handler told "absent" from "present but
// wrong" the type keeps the difference.

/// `POST /internal/agent-api/tasks/amend`.
public struct AgentTaskAmendRequest: Decodable, Sendable, Equatable {
    public var channel: String?
    /// The legacy `(value as? NSNumber)?.intValue`: a boolean reads as 0/1 and a
    /// fractional number truncates.
    public var taskNumber: Int?
    public var title: String?
    public var description: String?
    public var seenUpToSeq: Int?

    public init(
        channel: String? = nil,
        taskNumber: Int? = nil,
        title: String? = nil,
        description: String? = nil,
        seenUpToSeq: Int? = nil
    ) {
        self.channel = channel
        self.taskNumber = taskNumber
        self.title = title
        self.description = description
        self.seenUpToSeq = seenUpToSeq
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case taskNumber = "task_number"
        case title
        case description
        case seenUpToSeq
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = try? container.decode(String.self, forKey: .channel)
        taskNumber = Self.numberIntValue(try? container.decode(JSONValue.self, forKey: .taskNumber))
        title = try? container.decode(String.self, forKey: .title)
        description = try? container.decode(String.self, forKey: .description)
        seenUpToSeq = AgentTaskClaimRequest.integer(try? container.decode(JSONValue.self, forKey: .seenUpToSeq))
    }

    static func numberIntValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .integer(let number):
            return Int(exactly: number)
        case .number(let number):
            return number.isFinite && abs(number) < 9.0e18 ? Int(number) : nil
        case .bool(let flag):
            return flag ? 1 : 0
        case .object, .array, .string, .null, .none:
            return nil
        }
    }
}

/// `PATCH /api/tasks/:taskId/assignee`.
public struct TaskAssigneePatchRequest: Decodable, Sendable, Equatable {
    /// `assignee` was absent (a 400), JSON `null` (clear), an object with a
    /// `user`/`agent` type and a non-empty id (set), or anything else (a 400).
    public enum Assignee: Sendable, Equatable {
        case absent
        case cleared
        case set(type: String, id: String)
        case invalid
    }

    /// `expectedRevision` was absent or `null`, an integer, or another type.
    public enum ExpectedRevision: Sendable, Equatable {
        case none
        case value(Int)
        case invalid
    }

    public var assignee: Assignee
    public var expectedRevision: ExpectedRevision

    public init(assignee: Assignee = .absent, expectedRevision: ExpectedRevision = .none) {
        self.assignee = assignee
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case assignee
        case expectedRevision
    }

    private struct AssigneeObject: Decodable {
        var type: String?
        var id: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case id
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decode(String.self, forKey: .type)
            id = try? container.decode(String.self, forKey: .id)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if !container.contains(.assignee) {
            assignee = .absent
        } else if (try? container.decodeNil(forKey: .assignee)) == true {
            assignee = .cleared
        } else if let raw = try? container.decode(AssigneeObject.self, forKey: .assignee),
                  let type = raw.type, type == "user" || type == "agent",
                  let id = raw.id, !id.isEmpty {
            assignee = .set(type: type, id: id)
        } else {
            assignee = .invalid
        }
        if !container.contains(.expectedRevision)
            || (try? container.decodeNil(forKey: .expectedRevision)) == true {
            expectedRevision = .none
        } else if let value = AgentTaskClaimRequest.integer(
            try? container.decode(JSONValue.self, forKey: .expectedRevision)
        ) {
            expectedRevision = .value(value)
        } else {
            expectedRevision = .invalid
        }
    }
}

/// `PATCH /internal/agent-api/channels/:channelId` and the machine-keyed twin.
public struct AgentChannelUpdateRequest: Decodable, Sendable, Equatable {
    public var name: String?
    public var description: String?
    public var archived: Bool?
    /// The legacy handlers tested `object["visibility"] != nil`, so a present
    /// non-string value still counts as a visibility change attempt.
    public var visibilityPresent: Bool
    public var visibility: String?

    public init(
        name: String? = nil,
        description: String? = nil,
        archived: Bool? = nil,
        visibilityPresent: Bool = false,
        visibility: String? = nil
    ) {
        self.name = name
        self.description = description
        self.archived = archived
        self.visibilityPresent = visibilityPresent
        self.visibility = visibility
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case archived
        case visibility
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        description = try? container.decode(String.self, forKey: .description)
        archived = try? container.decode(Bool.self, forKey: .archived)
        visibilityPresent = container.contains(.visibility)
        visibility = try? container.decode(String.self, forKey: .visibility)
    }
}

/// `POST|DELETE …/channels/:channelId/members`.
public struct AgentChannelMemberRequest: Decodable, Sendable, Equatable {
    public var user: String?
    public var agent: String?

    public init(user: String? = nil, agent: String? = nil) {
        self.user = user
        self.agent = agent
    }

    private enum CodingKeys: String, CodingKey {
        case user
        case agent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try? container.decode(String.self, forKey: .user)
        agent = try? container.decode(String.self, forKey: .agent)
    }
}

/// `PATCH /internal/agent-api/server`.
public struct AgentServerUpdateRequest: Decodable, Sendable, Equatable {
    public var name: String?

    public init(name: String? = nil) {
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
    }
}

/// `POST /internal/agent-api/resolve-channel`.
public struct AgentResolveChannelRequest: Decodable, Sendable, Equatable {
    public var target: String?

    public init(target: String? = nil) {
        self.target = target
    }

    private enum CodingKeys: String, CodingKey {
        case target
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try? container.decode(String.self, forKey: .target)
    }
}

/// `POST /internal/agent-api/channels`.
public struct AgentCreateChannelRequest: Decodable, Sendable, Equatable {
    public var name: String?
    public var visibility: String?
    public var description: String?

    public init(name: String? = nil, visibility: String? = nil, description: String? = nil) {
        self.name = name
        self.visibility = visibility
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case visibility
        case description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        visibility = try? container.decode(String.self, forKey: .visibility)
        description = try? container.decode(String.self, forKey: .description)
    }
}

// MARK: - Task responses

/// `GET /api/tasks/channel/:channelId`: `{"tasks":[…]}`.
public struct ChannelTaskListResponse: JSONBodyConvertible, Sendable, Equatable {
    public var tasks: [TaskReadProjection]

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("tasks", .array(tasks.map(\.jsonBody)))])
    }
}

/// `GET /api/tasks/channel/:channelId/number/:taskNumber`: `{"task":{…}}`.
public struct ChannelTaskResponse: JSONBodyConvertible, Sendable, Equatable {
    public var task: TaskReadProjection

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("task", task.jsonBody)])
    }
}

/// `POST /internal/agent-api/tasks/amend`: the amended row, or the freshness
/// hold the write gate publishes with a 200.
public enum AgentTaskAmendResponse: JSONBodyConvertible, Sendable, Equatable {
    case amended(ActionCardTaskPayload)
    case held(AgentTaskWriteHoldResponse)

    public var jsonBody: OrderedJSON {
        switch self {
        case .amended(let task): task.jsonBody
        case .held(let hold): hold.jsonBody
        }
    }
}

// MARK: - Channel responses

/// `POST /api/channels/:channelId/(un)archive`: `{"archivedAt":…}`.
public struct ChannelArchivedResponse: JSONBodyConvertible, Sendable, Equatable {
    public var archivedAt: String?

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("archivedAt", optional: archivedAt)])
    }
}

/// `PATCH …/channels/:channelId` success bodies.
public enum AgentChannelUpdateResponse: JSONBodyConvertible, Sendable, Equatable {
    case jointArchived(id: String, archived: Bool)
    case jointRenamed(id: String, name: String)
    case updated(id: String, name: String, description: String?, type: String)

    public var jsonBody: OrderedJSON {
        switch self {
        case .jointArchived(let id, let archived):
            .object([OrderedJSONField("id", id), OrderedJSONField("archived", archived)])
        case .jointRenamed(let id, let name):
            .object([
                OrderedJSONField("id", id),
                OrderedJSONField("name", name),
                OrderedJSONField("type", "joint"),
            ])
        case .updated(let id, let name, let description, let type):
            .object([
                OrderedJSONField("id", id),
                OrderedJSONField("name", name),
                OrderedJSONField("description", optional: description),
                OrderedJSONField("type", type),
            ])
        }
    }
}

/// `POST|DELETE …/channels/:channelId/members`.
public struct AgentChannelMemberWriteResponse: JSONBodyConvertible, Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case added(alreadyMember: Bool)
        case removed(wasMember: Bool)
    }

    public var change: Change
    /// `human` or `agent`.
    public var memberType: String
    public var memberName: String

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        let member = OrderedJSON.object([
            OrderedJSONField("type", memberType),
            OrderedJSONField("name", memberName),
        ])
        switch change {
        case .added(let alreadyMember):
            body.append("alreadyMember", alreadyMember)
            body.append("member", member)
        case .removed(let wasMember):
            body.append("wasMember", wasMember)
            body.append("member", member)
            body.append("attention", Self.attention)
        }
        return body.json
    }

    /// Removing a member does not unfollow its thread follows; the response says so.
    static let attention: OrderedJSON = .object([
        OrderedJSONField("stillArrives", .array([
            .string("Followed threads still notify this member unless they unfollow them."),
        ])),
        OrderedJSONField(
            "threadBoundary",
            "Removing this member does not unfollow existing thread follows. Private channel/thread content still requires current parent access."
        ),
        OrderedJSONField("manageCommand", "Use raft thread unfollow to manage thread follows."),
    ])
}

/// `PATCH /internal/agent-api/server`.
public struct AgentServerUpdateResponse: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var name: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
        ])
    }
}

/// `GET …/channel-members`.
public struct AgentChannelMembersResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct ServerBadge: Sendable, Equatable {
        public var name: String
        public var slug: String
        public var yours: Bool
    }

    public struct Human: Sendable, Equatable {
        public var id: String
        public var name: String
        public var role: String
        /// Present only for a joint channel with a member of another server.
        public var servers: [ServerBadge]?
    }

    public struct Agent: Sendable, Equatable {
        public var id: String
        public var name: String
    }

    public var ref: String
    public var type: String
    public var humans: [Human]
    public var agents: [Agent]

    public var jsonBody: OrderedJSON {
        let humanRows = humans.map { human -> OrderedJSON in
            var row = OrderedJSONObject()
            row.append("id", human.id)
            row.append("name", human.name)
            row.append("role", human.role)
            if let servers = human.servers {
                row.append("servers", .array(servers.map { badge in
                    var item = OrderedJSONObject()
                    item.append("name", badge.name)
                    item.append("slug", badge.slug)
                    if badge.yours { item.append("yours", true) }
                    return item.json
                }))
            }
            return row.json
        }
        let agentRows = agents.map { agent in
            OrderedJSON.object([
                OrderedJSONField("id", agent.id),
                OrderedJSONField("name", agent.name),
                OrderedJSONField("status", "active"),
            ])
        }
        return .object([
            OrderedJSONField("channel", .object([
                OrderedJSONField("ref", ref),
                OrderedJSONField("type", type),
            ])),
            OrderedJSONField("humans", .array(humanRows)),
            OrderedJSONField("agents", .array(agentRows)),
        ])
    }
}

/// `GET …/server`.
public struct AgentServerInfoResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct RuntimeContext: Sendable, Equatable {
        public var agentId: String
        public var runtime: String
        public var serverId: String
        public var machineId: String?
        public var machineName: String?
        public var machineDescription: String?
    }

    public struct Channel: Sendable, Equatable {
        public var id: String
        public var name: String
        public var type: String
        public var joined: Bool
        public var muteFromSeq: Int?
    }

    public struct Agent: Sendable, Equatable {
        public var id: String
        public var name: String
        public var role: String?
        public var activity: String
        public var activityDetail: String
    }

    public var id: String
    public var name: String
    public var slug: String
    public var runtimeContext: RuntimeContext
    public var serverRole: String?
    public var channels: [Channel]
    public var agents: [Agent]

    public var jsonBody: OrderedJSON {
        let context = OrderedJSON.object([
            OrderedJSONField("agentId", runtimeContext.agentId),
            OrderedJSONField("runtime", runtimeContext.runtime),
            OrderedJSONField("model", "external"),
            OrderedJSONField("reasoningEffort", .null),
            OrderedJSONField("serverId", runtimeContext.serverId),
            OrderedJSONField("machineId", optional: runtimeContext.machineId),
            OrderedJSONField("machineName", optional: runtimeContext.machineName),
            OrderedJSONField("machineDescription", optional: runtimeContext.machineDescription),
            OrderedJSONField("machineHostname", .null),
            OrderedJSONField("machineOs", .null),
            OrderedJSONField("daemonVersion", .null),
            OrderedJSONField("workspacePath", .null),
        ])
        let channelRows = channels.map { channel in
            OrderedJSON.object([
                OrderedJSONField("id", channel.id),
                OrderedJSONField("name", channel.name),
                OrderedJSONField("type", channel.type),
                OrderedJSONField("joined", channel.joined),
                OrderedJSONField("activityMuted", channel.muteFromSeq != nil),
                OrderedJSONField("muteFromSeq", optional: channel.muteFromSeq),
            ])
        }
        let agentRows = agents.map { agent in
            OrderedJSON.object([
                OrderedJSONField("id", agent.id),
                OrderedJSONField("name", agent.name),
                OrderedJSONField("role", optional: agent.role),
                OrderedJSONField("status", "active"),
                OrderedJSONField("activity", agent.activity),
                OrderedJSONField("activityDetail", agent.activityDetail),
            ])
        }
        return .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("slug", slug),
            OrderedJSONField("runtimeContext", context),
            OrderedJSONField("serverRole", optional: serverRole),
            OrderedJSONField("serverCapabilities", .object([
                OrderedJSONField("addChannelMembers", true),
                OrderedJSONField("createChannels", true),
            ])),
            OrderedJSONField("channels", .array(channelRows)),
            OrderedJSONField("agents", .array(agentRows)),
        ])
    }
}

/// `POST /internal/agent-api/resolve-channel`.
public struct AgentResolveChannelResponse: JSONBodyConvertible, Sendable, Equatable {
    public var channelId: String
    public var type: String

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("channelId", channelId), OrderedJSONField("type", type)])
    }
}

/// `POST /internal/agent-api/channels`.
public struct AgentCreateChannelResponse: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    public var description: String?
    public var createdByAgentId: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("type", type),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("joined", true),
            OrderedJSONField("createdByAgentId", createdByAgentId),
        ])
    }
}
