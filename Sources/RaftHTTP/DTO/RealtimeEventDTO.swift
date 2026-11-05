import Foundation

/// Typed contracts for the realtime frames the route layer publishes.
///
/// Before this file the route features parsed an `HTTPReply` body with
/// `JSONSerialization` and then hand-built the frame with spliced strings.
/// These DTOs name each payload so the encoder in `ChannelMessagingService`
/// owns the wire shape and the compiler checks every field.
///
/// Every member is `public` so `RaftHTTPServer` can construct a payload and
/// inspect the typed value without a second decode.

/// `GET /internal/agent-api` credential projection. `resolveAgentApiIdentity`
/// returns it directly from the in-memory credential store.
public struct AgentApiIdentityDTO: Codable, Sendable, Equatable {
    public let agentId: String
    public let serverId: String
    public let scopes: [String]

    public init(agentId: String, serverId: String, scopes: [String]) {
        self.agentId = agentId
        self.serverId = serverId
        self.scopes = scopes
    }
}

/// `thread:followers-updated` body.
public struct ThreadFollowersUpdatedPayload: Codable, Sendable, Equatable {
    public let threadChannelId: String

    public init(threadChannelId: String) {
        self.threadChannelId = threadChannelId
    }
}

/// Channel projection carried by `channel:updated`.
public struct CreatedChannelSummaryDTO: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let joined: Bool

    public init(id: String, name: String, description: String?, joined: Bool) {
        self.id = id
        self.name = name
        self.description = description
        self.joined = joined
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case joined
    }

    /// The upstream event always carries the description key, using `null` when
    /// the channel has none. Synthesized encoding would drop it instead, so the
    /// optional is written explicitly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(joined, forKey: .joined)
    }
}

/// `channel:updated` body.
public struct ChannelUpdatedPayload: Codable, Sendable, Equatable {
    public let channel: CreatedChannelSummaryDTO

    public init(channel: CreatedChannelSummaryDTO) {
        self.channel = channel
    }
}

/// One row of the `task:created` batch.
public struct TaskCreatedItemDTO: Codable, Sendable, Equatable {
    public let id: String
    public let channelId: String
    public let title: String
    public let status: String

    public init(id: String, channelId: String, title: String, status: String) {
        self.id = id
        self.channelId = channelId
        self.title = title
        self.status = status
    }
}

/// `task:created` body.
public struct TaskCreatedPayload: Codable, Sendable, Equatable {
    public let channelId: String
    public let tasks: [TaskCreatedItemDTO]

    public init(channelId: String, tasks: [TaskCreatedItemDTO]) {
        self.channelId = channelId
        self.tasks = tasks
    }
}

/// Reminder frame body shared by `reminder:scheduled` and its siblings.
public struct ReminderRealtimePayload: Codable, Sendable, Equatable {
    public let reminderId: String
    public let ownerAgentId: String

    public init(reminderId: String, ownerAgentId: String) {
        self.reminderId = reminderId
        self.ownerAgentId = ownerAgentId
    }
}

/// Single JSON error body. Route handlers can encode it instead of splicing
/// a message and a code into a string.
public struct APIErrorDTO: Codable, Sendable, Equatable {
    public let error: String
    public let code: String?

    public init(error: String, code: String? = nil) {
        self.error = error
        self.code = code
    }
}
