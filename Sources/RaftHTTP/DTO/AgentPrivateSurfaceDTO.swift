import Foundation

// Response shapes for the agent records and their private surfaces: creation,
// listing, the single-agent read, the profile patch, the external status, the
// assistant-owner reads and the wake-hint stream.
//
// Every response owns its published member order as an `OrderedJSON` tree
// (`JSONBodyConvertible`). The ordered tree also keeps `jsonString` escaping, so
// a `/` in a URL stays unescaped as the retired handlers printed it. The stored
// runtime config and env texts enter as `OrderedJSON.raw`: they were rendered
// once by the config document and are echoed as received.

/// The agent runtime members the create reply and the `agent:created` event
/// share.
public struct AgentRuntimeProjection: Sendable, Equatable {
    public var id: String
    public var name: String
    public var runtime: String
    public var model: String
    public var external: Bool
    /// The stored env text; `null` for an external agent.
    public var envVarsJSON: String
    public var runtimeConfigJSON: String

    public init(
        id: String,
        name: String,
        runtime: String,
        model: String,
        external: Bool,
        envVarsJSON: String,
        runtimeConfigJSON: String
    ) {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.model = model
        self.external = external
        self.envVarsJSON = envVarsJSON
        self.runtimeConfigJSON = runtimeConfigJSON
    }

    func fields(includeEnvVars: Bool) -> [OrderedJSONField] {
        [
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("runtime", runtime),
            OrderedJSONField("model", model),
            OrderedJSONField("external", external),
            OrderedJSONField("machineId", .null),
            OrderedJSONField("reasoningEffort", .null),
            OrderedJSONField("envVars", includeEnvVars
                ? .raw(envVarsJSON.isEmpty ? "{}" : envVarsJSON)
                : .null),
            OrderedJSONField("runtimeConfig", .raw(runtimeConfigJSON.isEmpty ? "{}" : runtimeConfigJSON)),
        ]
    }

    /// The `agent:created` broadcast: the agent without its env.
    public var broadcastJSON: String {
        OrderedJSON.object(fields(includeEnvVars: false)).render()
    }
}

/// `POST /api/agents`.
public struct CreatedAgentResponse: JSONBodyConvertible, Equatable {
    public var agent: AgentRuntimeProjection
    public var creatorId: String
    public var displayName: String
    public var description: String?
    public var avatarUrl: String?
    public var serverRole: String
    public var hostedProvider: String?

    public init(
        agent: AgentRuntimeProjection,
        creatorId: String,
        displayName: String,
        description: String?,
        avatarUrl: String?,
        serverRole: String,
        hostedProvider: String?
    ) {
        self.agent = agent
        self.creatorId = creatorId
        self.displayName = displayName
        self.description = description
        self.avatarUrl = avatarUrl
        self.serverRole = serverRole
        self.hostedProvider = hostedProvider
    }

    public var jsonBody: OrderedJSON {
        var fields = agent.fields(includeEnvVars: true)
        fields.append(OrderedJSONField("creator", AgentHumanRef(id: creatorId).json))
        fields.append(OrderedJSONField("displayName", displayName))
        fields.append(OrderedJSONField("description", optional: description))
        fields.append(OrderedJSONField("avatarUrl", optional: avatarUrl))
        fields.append(OrderedJSONField("serverRole", serverRole))
        if let hostedProvider {
            fields.append(OrderedJSONField("hostedRuntime", .object([
                OrderedJSONField("kind", hostedProvider),
                OrderedJSONField("state", "provisioning"),
            ])))
        }
        return .object(fields)
    }
}

struct AgentHumanRef {
    var id: String

    var json: OrderedJSON {
        .object([OrderedJSONField("type", "human"), OrderedJSONField("id", id)])
    }
}

/// One agent row of the list and single-agent reads.
public struct AgentSummary: Sendable, Equatable {
    public var id: String
    public var name: String
    public var displayName: String
    public var runtime: String
    public var model: String
    public var external: Bool
    public var serverRole: String
    public var creatorId: String?
    public var description: String?
    /// Present for an external agent in the list (`null` when never seen).
    public var includesLastSeen: Bool
    public var lastSeenAt: String?
    /// Present when the caller may see the config (redacted config text and env
    /// text, both raw).
    public var config: Config?

    public struct Config: Sendable, Equatable {
        public var runtimeConfigJSON: String
        public var envVarsJSON: String

        public init(runtimeConfigJSON: String, envVarsJSON: String) {
            self.runtimeConfigJSON = runtimeConfigJSON
            self.envVarsJSON = envVarsJSON
        }
    }

    public init(
        id: String,
        name: String,
        displayName: String,
        runtime: String,
        model: String,
        external: Bool,
        serverRole: String,
        creatorId: String?,
        description: String?,
        includesLastSeen: Bool,
        lastSeenAt: String?,
        config: Config?
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.runtime = runtime
        self.model = model
        self.external = external
        self.serverRole = serverRole
        self.creatorId = creatorId
        self.description = description
        self.includesLastSeen = includesLastSeen
        self.lastSeenAt = lastSeenAt
        self.config = config
    }

    var json: OrderedJSON {
        var fields = [
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("displayName", displayName),
            OrderedJSONField("runtime", runtime),
            OrderedJSONField("model", model),
            OrderedJSONField("external", external),
            OrderedJSONField("serverRole", serverRole),
            OrderedJSONField("creator", creatorId.map { AgentHumanRef(id: $0).json } ?? .null),
            OrderedJSONField("description", optional: description),
        ]
        if includesLastSeen {
            fields.append(OrderedJSONField("lastSeenAt", optional: lastSeenAt))
        }
        if let config {
            fields.append(OrderedJSONField("runtimeConfig", .raw(config.runtimeConfigJSON)))
            fields.append(OrderedJSONField("envVars", .raw(config.envVarsJSON)))
        }
        return .object(fields)
    }
}

/// `GET /api/agents`.
public struct AgentListResponse: JSONBodyConvertible, Equatable {
    public var agents: [AgentSummary]

    public init(agents: [AgentSummary]) {
        self.agents = agents
    }

    public var jsonBody: OrderedJSON { .array(agents.map(\.json)) }
}

/// `GET /api/agents/:id`: the full agent, or the channel summary a guest sees.
public enum AgentDetailResponse: JSONBodyConvertible, Equatable {
    case full(AgentSummary)
    case guest(id: String, name: String, displayName: String, description: String?)

    public var jsonBody: OrderedJSON {
        switch self {
        case .full(let summary):
            summary.json
        case .guest(let id, let name, let displayName, let description):
            .object([
                OrderedJSONField("id", id),
                OrderedJSONField("name", name),
                OrderedJSONField("displayName", displayName),
                OrderedJSONField("avatarUrl", .null),
                OrderedJSONField("description", optional: description),
                OrderedJSONField("profileProjection", "channel_summary"),
            ])
        }
    }
}

/// `GET /api/agents/archived`.
public struct ArchivedAgentsResponse: JSONBodyConvertible, Equatable {
    public struct Row: Sendable, Equatable {
        public var agentId: String
        public var machineName: String?
        public var workspaceState: String

        public init(agentId: String, machineName: String?, workspaceState: String) {
            self.agentId = agentId
            self.machineName = machineName
            self.workspaceState = workspaceState
        }

        var json: OrderedJSON {
            .object([
                OrderedJSONField("agentId", agentId),
                OrderedJSONField("machineName", optional: machineName),
                OrderedJSONField("workspaceState", workspaceState),
            ])
        }
    }

    public var rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("agents", .array(rows.map(\.json)))])
    }
}

/// `GET /api/agents/:id/runtime-options`.
public struct AgentRuntimeOptionsResponse: JSONBodyConvertible, Equatable {
    public var agentId: String

    public init(agentId: String) {
        self.agentId = agentId
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("runtimes", .array([])),
            OrderedJSONField("models", .array([])),
        ])
    }
}

/// `POST /api/agent/login` has no success path (the bootstrap is disabled), so
/// the service only ever throws; this type satisfies the response contract.
public struct AgentLoginResponse: JSONBodyConvertible, Equatable {
    public init() {}

    public var jsonBody: OrderedJSON { .object([]) }
}

/// `POST /api/agents/:id/bootstrap-tokens` (201).
public struct AgentBootstrapTokenResponse: JSONBodyConvertible, Equatable {
    public init() {}

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("token", "bootstrap-disabled"),
            OrderedJSONField("createdAt", "1970-01-01T00:00:00.000Z"),
            OrderedJSONField("scopes", .array(
                ["channels", "knowledge", "mentions", "reactions", "read", "send", "tasks"]
                    .map(OrderedJSON.string)
            )),
        ])
    }
}

/// `PATCH /api/agents/:id/creator`.
public struct AgentCreatorResponse: JSONBodyConvertible, Equatable {
    public var creatorId: String

    public init(creatorId: String) {
        self.creatorId = creatorId
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("creator", AgentHumanRef(id: creatorId).json)])
    }
}

/// `POST /api/agents/:id/avatar`.
public struct AgentAvatarResponse: JSONBodyConvertible, Equatable {
    public var avatarUrl: String

    public init(avatarUrl: String) {
        self.avatarUrl = avatarUrl
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("avatarUrl", avatarUrl)])
    }
}

/// `GET /api/agents/:id/external-status`.
public struct ExternalAgentStatusResponse: JSONBodyConvertible, Equatable {
    public var setupState: String
    public var credentialLastUsedAt: String?

    public init(setupState: String, credentialLastUsedAt: String?) {
        self.setupState = setupState
        self.credentialLastUsedAt = credentialLastUsedAt
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("setupState", setupState),
            OrderedJSONField("credentialLastUsedAt", optional: credentialLastUsedAt),
            OrderedJSONField("lastActivityAt", .null),
        ])
    }
}

/// `GET /api/agents/manageable`.
public struct ManageableAgentsResponse: JSONBodyConvertible, Equatable {
    public struct Row: Sendable, Equatable {
        public var id: String
        public var name: String
        public var serverId: String
        public var serverName: String?

        public init(id: String, name: String, serverId: String, serverName: String?) {
            self.id = id
            self.name = name
            self.serverId = serverId
            self.serverName = serverName
        }
    }

    public var agents: [Row]
    public var reason: String
    public var manageableServerCount: Int

    public init(agents: [Row], reason: String, manageableServerCount: Int) {
        self.agents = agents
        self.reason = reason
        self.manageableServerCount = manageableServerCount
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("data", .object([
                OrderedJSONField("agents", .array(agents.map { row in
                    .object([
                        OrderedJSONField("id", row.id),
                        OrderedJSONField("name", row.name),
                        OrderedJSONField("serverId", row.serverId),
                        OrderedJSONField("serverName", optional: row.serverName),
                    ])
                })),
                OrderedJSONField("reason", reason),
                OrderedJSONField("manageable_server_count", manageableServerCount),
            ])),
        ])
    }
}

/// `PATCH /api/agents/:id`.
public struct AgentPatchResponse: JSONBodyConvertible, Equatable {
    public var id: String
    public var name: String
    public var displayName: String?
    public var model: String
    public var runtime: String
    public var reasoningEffort: String?
    public var description: String?
    public var avatarUrl: String?
    public var serverRole: String
    public var runtimeConfigJSON: String?
    public var envVarsJSON: String?

    public init(
        id: String,
        name: String,
        displayName: String?,
        model: String,
        runtime: String,
        reasoningEffort: String?,
        description: String?,
        avatarUrl: String?,
        serverRole: String,
        runtimeConfigJSON: String?,
        envVarsJSON: String?
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.model = model
        self.runtime = runtime
        self.reasoningEffort = reasoningEffort
        self.description = description
        self.avatarUrl = avatarUrl
        self.serverRole = serverRole
        self.runtimeConfigJSON = runtimeConfigJSON
        self.envVarsJSON = envVarsJSON
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("displayName", optional: displayName),
            OrderedJSONField("model", model),
            OrderedJSONField("runtime", runtime),
            OrderedJSONField("reasoningEffort", optional: reasoningEffort),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("avatarUrl", optional: avatarUrl),
            OrderedJSONField("serverRole", serverRole),
            OrderedJSONField("runtimeConfig", runtimeConfigJSON.map(OrderedJSON.raw) ?? .null),
            OrderedJSONField("envVars", envVarsJSON.map(OrderedJSON.raw) ?? .null),
        ])
    }
}

/// `PUT`/`DELETE /api/agents/:id/assistant-owner`.
public struct AgentAssistantOwnerResponse: JSONBodyConvertible, Equatable {
    public var ownerUserId: String?

    public init(ownerUserId: String?) {
        self.ownerUserId = ownerUserId
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("assistantOf", ownerUserId.map { owner in
                .object([OrderedJSONField("userId", owner)])
            } ?? .null),
        ])
    }
}

/// `GET /internal/agent-api/assistant/owner-inbox`.
public struct AssistantOwnerInboxResponse: JSONBodyConvertible, Equatable {
    public struct Item: Sendable, Equatable {
        public var kind: String
        public var channelId: String
        public var unreadCount: Int
        public var parentChannelId: String?

        public init(kind: String, channelId: String, unreadCount: Int, parentChannelId: String?) {
            self.kind = kind
            self.channelId = channelId
            self.unreadCount = unreadCount
            self.parentChannelId = parentChannelId
        }
    }

    public var ownerUserId: String
    public var items: [Item]

    public init(ownerUserId: String, items: [Item]) {
        self.ownerUserId = ownerUserId
        self.items = items
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("owner", .object([OrderedJSONField("userId", ownerUserId)])),
            OrderedJSONField("items", .array(items.map { item in
                var fields = [
                    OrderedJSONField("kind", item.kind),
                    OrderedJSONField("channelId", item.channelId),
                    OrderedJSONField("unreadCount", item.unreadCount),
                ]
                if let parent = item.parentChannelId {
                    fields.append(OrderedJSONField("parentChannelId", parent))
                }
                return .object(fields)
            })),
        ])
    }
}

/// `GET /internal/agent-api/assistant/owner-messages`.
public struct AssistantOwnerMessagesResponse: JSONBodyConvertible, Equatable {
    public struct Message: Sendable, Equatable {
        public var id: String
        public var content: String
        public var senderId: String
        public var senderType: String

        public init(id: String, content: String, senderId: String, senderType: String) {
            self.id = id
            self.content = content
            self.senderId = senderId
            self.senderType = senderType
        }
    }

    public var ownerUserId: String
    public var channelId: String
    public var messages: [Message]

    public init(ownerUserId: String, channelId: String, messages: [Message]) {
        self.ownerUserId = ownerUserId
        self.channelId = channelId
        self.messages = messages
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("owner", .object([OrderedJSONField("userId", ownerUserId)])),
            OrderedJSONField("channelId", channelId),
            OrderedJSONField("messages", .array(messages.map { message in
                .object([
                    OrderedJSONField("id", message.id),
                    OrderedJSONField("content", message.content),
                    OrderedJSONField("senderId", message.senderId),
                    OrderedJSONField("senderType", message.senderType),
                ])
            })),
        ])
    }
}

/// The first answer of `GET /internal/agent-api/wake-hints/stream`: the
/// credential the poll ticks re-read, the last replayed hint seq and the frames
/// to write first.
public struct AgentWakeStreamStart: Sendable, Equatable {
    public var token: String
    public var cursorSeq: Int?
    public var firstFrame: String

    public init(token: String, cursorSeq: Int?, firstFrame: String) {
        self.token = token
        self.cursorSeq = cursorSeq
        self.firstFrame = firstFrame
    }
}

/// One poll tick of the wake-hint stream.
public struct AgentWakeStreamBatch: Sendable, Equatable {
    public var frames: String
    public var cursorSeq: Int?

    public init(frames: String, cursorSeq: Int?) {
        self.frames = frames
        self.cursorSeq = cursorSeq
    }
}

/// A content-free wake hint row: the server seq and its published JSON text.
public struct AgentWakeHintRow: Sendable, Equatable {
    public var seq: Int
    public var json: String

    public init(seq: Int, json: String) {
        self.seq = seq
        self.json = json
    }
}
