import Foundation

// MARK: - Typed request bodies for the internal agent API JSON routes (Batch F)

/// A published JSON request body on the internal agent-principal surface.
///
/// The directory keeps its raw-body parsers: they are the authority for every
/// malformed shape and for the exact error code the route publishes. A route
/// decodes this type first and hands the parser the canonical JSON for the
/// shape that was just decoded, so the typed route and the raw fallback read
/// exactly the same keys. A body that does not decode (a non-JSON content
/// type, malformed JSON, or a value of the wrong type) keeps the original
/// `request.bodyText()` path and therefore its original reply.
///
/// Only fields the directory actually reads belong here: a key the parser
/// ignores is dropped by the round trip, which cannot change a reply.
///
/// Public because the route feature lives in `RaftHTTPServer` and re-encodes
/// the decoded body before it calls the directory's parser.
public protocol InternalAgentApiRequestDTO: Codable, Sendable, Equatable {
    /// Canonical JSON for the shape that was just decoded.
    func encodedBody() -> String
}

extension InternalAgentApiRequestDTO {
    /// Sorted keys make the round trip deterministic, so the body the raw
    /// parser sees is stable across processes.
    public func encodedBody() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `POST internal/agent-api/tasks/claim` request body.
///
/// The directory requires `channel` and reads `task_numbers`, `message_ids`
/// and `seenUpToSeq`. Every field stays optional so a body that decodes but
/// omits a required key reaches the directory's parser, which publishes the
/// canonical `Invalid task claim request` reply instead of a decode error.
public struct AgentTaskClaimDTO: Codable, Sendable, Equatable, InternalAgentApiRequestDTO {
    public var channel: String?
    public var task_numbers: [Int]?
    public var message_ids: [String]?
    public var seenUpToSeq: Int?

    public init(
        channel: String? = nil,
        task_numbers: [Int]? = nil,
        message_ids: [String]? = nil,
        seenUpToSeq: Int? = nil
    ) {
        self.channel = channel
        self.task_numbers = task_numbers
        self.message_ids = message_ids
        self.seenUpToSeq = seenUpToSeq
    }
}

/// The `unclaim` verb of the agent task family accepts the same body shape as
/// `claim`. It is spelled as its own published type so a route can name the
/// verb it serves; the surface registers only `claim` today, and the raw
/// parser remains the authority for both verbs.
public struct AgentTaskUnclaimDTO: Codable, Sendable, Equatable, InternalAgentApiRequestDTO {
    public var channel: String?
    public var task_numbers: [Int]?
    public var message_ids: [String]?
    public var seenUpToSeq: Int?

    public init(
        channel: String? = nil,
        task_numbers: [Int]? = nil,
        message_ids: [String]? = nil,
        seenUpToSeq: Int? = nil
    ) {
        self.channel = channel
        self.task_numbers = task_numbers
        self.message_ids = message_ids
        self.seenUpToSeq = seenUpToSeq
    }
}

/// `POST internal/agent-api/tasks/update-status` request body.
///
/// The directory requires `channel`, `task_number` and a `status` contained in
/// `validTaskStatuses`; a decoded body that omits one of them keeps the
/// published `Invalid task status request` 400 because the parser sees the
/// re-encoded shape.
public struct AgentStatusUpdateDTO: Codable, Sendable, Equatable, InternalAgentApiRequestDTO {
    public var channel: String?
    public var task_number: Int?
    public var status: String?
    public var seenUpToSeq: Int?

    public init(
        channel: String? = nil,
        task_number: Int? = nil,
        status: String? = nil,
        seenUpToSeq: Int? = nil
    ) {
        self.channel = channel
        self.task_number = task_number
        self.status = status
        self.seenUpToSeq = seenUpToSeq
    }
}

/// `POST` and `DELETE internal/agent-api/messages/:messageId/reactions`
/// request body.
///
/// `emoji` is the only key either verb reads. The directory trims it, caps it
/// at 16 UTF-16 units and rejects whitespace or an empty value with the same
/// `A valid emoji is required` reply, so an omitted or `null` emoji keeps the
/// raw 400 instead of becoming a decode error here.
public struct AgentMessageReactionDTO: Codable, Sendable, Equatable, InternalAgentApiRequestDTO {
    public var emoji: String?

    public init(emoji: String? = nil) {
        self.emoji = emoji
    }
}

/// `POST internal/agent-api/channels/:channelId/join` request body.
///
/// The route's only input is the `:channelId` path parameter, and the current
/// upstream client sends an empty body. The published type exists so the
/// shared agent-channel body shape has a name and so a future body field is
/// added in one place; decoding it cannot change a reply today.
public struct AgentChannelJoinDTO: Codable, Sendable, Equatable, InternalAgentApiRequestDTO {
    public init() {}
}
