import Foundation
import RaftShared

// DTOs for the human-message create surface: the v1/v2 create route, the
// sender-side mention actions it leaves pending, the forward lookup and the
// forward write. Every body below publishes an exact member order, so each one
// is a `JSONBodyConvertible` tree except the single-key forward flag.

// MARK: - Lenient request decoding

private extension KeyedDecodingContainer {
    /// The value under `key` when the key is present — a JSON `null` stays
    /// `.null` — and `nil` when it is absent. The legacy routes read every field
    /// on its own (`as? String`, `is Bool`, `!= nil`), so a field of the wrong
    /// type must neither fail the whole body nor look absent.
    func lenient(_ key: Key) -> JSONValue? {
        guard contains(key) else { return nil }
        return try? decode(JSONValue.self, forKey: key)
    }
}

/// `POST /api/messages` and `POST /api/v2/messages`.
///
/// Each field keeps its raw JSON value because the published refusals depend on
/// the exact shape: a `null` or non-string `randomId` is a 400 while a missing
/// one is not, and an `attachmentIds` that is present but not an array of UUIDs
/// is the generic body refusal. The service validates in the legacy order.
public struct HumanMessageCreateRequest: Decodable, Sendable, Equatable {
    public var channelId: JSONValue?
    public var content: JSONValue?
    public var attachmentIds: JSONValue?
    public var asTask: JSONValue?
    public var mentions: JSONValue?
    public var timezone: JSONValue?
    public var randomId: JSONValue?

    public init(
        channelId: JSONValue? = nil,
        content: JSONValue? = nil,
        attachmentIds: JSONValue? = nil,
        asTask: JSONValue? = nil,
        mentions: JSONValue? = nil,
        timezone: JSONValue? = nil,
        randomId: JSONValue? = nil
    ) {
        self.channelId = channelId
        self.content = content
        self.attachmentIds = attachmentIds
        self.asTask = asTask
        self.mentions = mentions
        self.timezone = timezone
        self.randomId = randomId
    }

    /// The well-formed body: a channel, its text and an optional idempotency id.
    public init(channelId: String, content: String, randomId: String? = nil) {
        self.init(
            channelId: .string(channelId),
            content: .string(content),
            randomId: randomId.map(JSONValue.string)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case channelId, content, attachmentIds, asTask, mentions, timezone, randomId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = container.lenient(.channelId)
        content = container.lenient(.content)
        attachmentIds = container.lenient(.attachmentIds)
        asTask = container.lenient(.asTask)
        mentions = container.lenient(.mentions)
        timezone = container.lenient(.timezone)
        randomId = container.lenient(.randomId)
    }
}

/// `POST /api/messages/mention-actions/execute` and
/// `POST /internal/agent-api/mention-actions/execute`.
///
/// The two routes read the id list differently (the agent route also accepts
/// `ids` and trims), so the raw values are kept and each operation applies its
/// own rule.
public struct MentionActionsRequest: Decodable, Sendable, Equatable {
    public var action: JSONValue?
    public var resolutionIds: JSONValue?
    public var ids: JSONValue?

    public init(action: JSONValue? = nil, resolutionIds: JSONValue? = nil, ids: JSONValue? = nil) {
        self.action = action
        self.resolutionIds = resolutionIds
        self.ids = ids
    }

    public init(action: String, resolutionIds: [String]) {
        self.init(action: .string(action), resolutionIds: .array(resolutionIds.map(JSONValue.string)))
    }

    private enum CodingKeys: String, CodingKey {
        case action, resolutionIds, ids
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = container.lenient(.action)
        resolutionIds = container.lenient(.resolutionIds)
        ids = container.lenient(.ids)
    }
}

/// `POST /api/messages/forward`.
public struct HumanMessageForwardRequest: Decodable, Sendable, Equatable {
    public var destinationChannelId: JSONValue?
    public var channelId: JSONValue?
    public var note: JSONValue?
    public var sourceMessageIds: JSONValue?
    public var destinationChannelIds: JSONValue?
    public var randomId: JSONValue?
    public var requestId: JSONValue?

    public init(
        destinationChannelId: JSONValue? = nil,
        channelId: JSONValue? = nil,
        note: JSONValue? = nil,
        sourceMessageIds: JSONValue? = nil,
        destinationChannelIds: JSONValue? = nil,
        randomId: JSONValue? = nil,
        requestId: JSONValue? = nil
    ) {
        self.destinationChannelId = destinationChannelId
        self.channelId = channelId
        self.note = note
        self.sourceMessageIds = sourceMessageIds
        self.destinationChannelIds = destinationChannelIds
        self.randomId = randomId
        self.requestId = requestId
    }

    private enum CodingKeys: String, CodingKey {
        case destinationChannelId, channelId, note, sourceMessageIds
        case destinationChannelIds, randomId, requestId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destinationChannelId = container.lenient(.destinationChannelId)
        channelId = container.lenient(.channelId)
        note = container.lenient(.note)
        sourceMessageIds = container.lenient(.sourceMessageIds)
        destinationChannelIds = container.lenient(.destinationChannelIds)
        randomId = container.lenient(.randomId)
        requestId = container.lenient(.requestId)
    }
}

// MARK: - Create responses

/// One outsider mention a send leaves for the sender to resolve.
public struct PendingMentionAction: JSONBodyConvertible, Sendable, Equatable {
    public var resolutionId: String
    public var messageId: String
    public var targetType: String
    public var targetHandle: String
    public var targetAvatarUrl: String?
    public var expiresAt: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("resolutionId", resolutionId),
            OrderedJSONField("messageId", messageId),
            OrderedJSONField("targetType", targetType),
            OrderedJSONField("targetHandle", targetHandle),
            OrderedJSONField("targetAvatarUrl", optional: targetAvatarUrl),
            OrderedJSONField("reason", "not_member"),
            OrderedJSONField("availableActions", .array([.string("notify"), .string("add")])),
            OrderedJSONField("expiresAt", expiresAt),
        ])
    }
}

/// A v2 send's report that a DM went to a stopped agent.
public struct MessageDeliveryWarning: JSONBodyConvertible, Sendable, Equatable {
    public var agentId: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("targetType", "agent"),
            OrderedJSONField("targetId", agentId),
            OrderedJSONField("reason", "agent_stopped"),
        ])
    }
}

/// The reply of a human message create.
///
/// `messageJSON` is the stored row's published body, rendered by the message
/// write that owns the row shape; it enters the tree as a raw fragment. A v1
/// send answers with that row alone unless outsider mentions are pending, a v2
/// send always nests it.
public struct HumanMessageCreatedResponse: JSONBodyConvertible, Sendable, Equatable {
    public var messageJSON: String
    public var nested: Bool
    public var pendingMentionActions: [PendingMentionAction]
    public var deliveryWarnings: [MessageDeliveryWarning]
    public var unresolvedMentionHandles: [String]

    public var jsonBody: OrderedJSON {
        guard nested else { return .raw(messageJSON) }
        var body = OrderedJSONObject()
        body.append("message", .raw(messageJSON))
        if !pendingMentionActions.isEmpty {
            body.append("pendingMentionActions", .array(pendingMentionActions.map(\.jsonBody)))
        }
        if !deliveryWarnings.isEmpty {
            body.append("deliveryWarnings", .array(deliveryWarnings.map(\.jsonBody)))
        }
        if !unresolvedMentionHandles.isEmpty {
            body.append("unresolvedMentionHandles", .array(unresolvedMentionHandles.map(OrderedJSON.string)))
        }
        return body.json
    }
}

// MARK: - Mention actions

/// One id's outcome in a mention-action batch. `reason` and
/// `dedupedResolutionIds` are omitted when absent.
public struct MentionActionResult: JSONBodyConvertible, Sendable, Equatable {
    public var resolutionId: String
    public var action: String
    public var messageId: String?
    public var channelId: String?
    public var targetType: String?
    public var targetId: String?
    public var status: String
    public var reason: String?
    public var deduped: [String]?

    public init(
        resolutionId: String,
        action: String,
        status: String,
        reason: String? = nil,
        deduped: [String]? = nil,
        messageId: String? = nil,
        channelId: String? = nil,
        targetType: String? = nil,
        targetId: String? = nil
    ) {
        self.resolutionId = resolutionId
        self.action = action
        self.messageId = messageId
        self.channelId = channelId
        self.targetType = targetType
        self.targetId = targetId
        self.status = status
        self.reason = reason
        self.deduped = deduped
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("resolutionId", resolutionId)
        body.append("action", action)
        body.append("messageId", ifPresent: messageId)
        body.append("channelId", ifPresent: channelId)
        body.append("targetType", ifPresent: targetType)
        body.append("targetId", ifPresent: targetId)
        body.append("status", status)
        body.append("reason", ifPresent: reason)
        if let deduped {
            body.append("dedupedResolutionIds", .array(deduped.map(OrderedJSON.string)))
        }
        return body.json
    }
}

/// `{"ok":true,"action":…,"results":[…]}`.
public struct MentionActionsResponse: JSONBodyConvertible, Sendable, Equatable {
    public var action: String
    public var results: [MentionActionResult]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("action", action),
            OrderedJSONField("results", .array(results.map(\.jsonBody))),
        ])
    }
}

/// One withheld sender-side mention the bound agent may still act on.
public struct AgentPendingMentionAction: JSONBodyConvertible, Sendable, Equatable {
    public var resolutionId: String
    public var messageId: String
    public var channelId: String
    public var channelName: String
    public var targetType: String
    public var targetId: String
    public var targetHandle: String
    public var messageSeq: Int? = nil
    public var createdAt: String? = nil
    public var expiresAt: String? = nil
    public var reason: String? = nil
    public var availableActions: [String] = ["notify"]

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("resolutionId", resolutionId)
        body.append("messageId", messageId)
        body.append("messageSeq", ifPresent: messageSeq)
        body.append("channelId", channelId)
        body.append("channelName", channelName)
        body.append("targetType", targetType)
        body.append("targetId", targetId)
        body.append("targetHandle", targetHandle)
        body.append("reason", ifPresent: reason)
        body.append("availableActions", .array(availableActions.map(OrderedJSON.string)))
        body.append("createdAt", ifPresent: createdAt)
        body.append("expiresAt", ifPresent: expiresAt)
        return body.json
    }
}

/// `GET /internal/agent-api/mention-actions/pending`.
public struct AgentPendingMentionActionsResponse: JSONBodyConvertible, Sendable, Equatable {
    public var pendingMentionActions: [AgentPendingMentionAction]
    public var hasMore: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("pendingMentionActions", .array(pendingMentionActions.map(\.jsonBody))),
            OrderedJSONField("has_more", hasMore),
        ])
    }
}

// MARK: - Forward lookup

/// `GET /api/messages/forward/enabled`. The rollout flag is retired.
public struct MessageForwardEnabledResponse: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}

/// One entry of the forward-target search.
public struct ForwardTarget: JSONBodyConvertible, Sendable, Equatable {
    public var type: String
    public var channelType: String?
    public var id: String
    public var title: String
    public var subtitle: String
    public var avatarUrl: String?
    public var channelId: String?
    public var joined: Bool?
    public var dmExists: Bool?
    public var canForwardNow: Bool
    public var requiredAction: String?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("type", type),
            OrderedJSONField("channelType", optional: channelType),
            OrderedJSONField("id", id),
            OrderedJSONField("title", title),
            OrderedJSONField("subtitle", subtitle),
            OrderedJSONField("avatarUrl", optional: avatarUrl),
            OrderedJSONField("channelId", optional: channelId),
            OrderedJSONField("joined", optional: joined),
            OrderedJSONField("dmExists", optional: dmExists),
            OrderedJSONField("canForwardNow", canForwardNow),
            OrderedJSONField("requiredAction", optional: requiredAction),
        ])
    }
}

/// `GET /api/messages/forward/targets/search`.
public struct ForwardTargetsResponse: JSONBodyConvertible, Sendable, Equatable {
    public var targets: [ForwardTarget]

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("targets", .array(targets.map(\.jsonBody)))])
    }
}

// MARK: - Forward write

/// The forwarded message as the destination publishes it.
///
/// Each forwarded item is rendered by the metadata projection that the message
/// read paths share, so it enters the tree as a raw fragment at the published
/// position.
public struct ForwardedMessage: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var content: String
    public var attachmentIds: [String]
    public var randomId: String?
    public var destinationTargetId: String
    public var renderedItems: [String]

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("messageType", "chat")
        body.append("channelId", channelId)
        body.append("content", content)
        body.append("attachments", .array(attachmentIds.map { .object([OrderedJSONField("id", $0)]) }))
        body.append("randomId", ifPresent: randomId)
        body.append("actionMetadata", .object([
            OrderedJSONField("kind", "forwarded-bundle"),
            OrderedJSONField("destinationTargetId", destinationTargetId),
            OrderedJSONField("forwardedItems", .array(renderedItems.map(OrderedJSON.raw))),
        ]))
        return body.json
    }
}

/// One destination's result of a batch forward.
public enum ForwardBatchResult: JSONBodyConvertible, Sendable, Equatable {
    case success(destinationChannelId: String, message: HumanMessageForwardResponse)
    case failed(destinationChannelId: String, code: String, error: String)

    public var jsonBody: OrderedJSON {
        switch self {
        case .success(let destinationChannelId, let message):
            .object([
                OrderedJSONField("destinationChannelId", destinationChannelId),
                OrderedJSONField("status", "success"),
                OrderedJSONField("message", message.jsonBody),
            ])
        case .failed(let destinationChannelId, let code, let error):
            .object([
                OrderedJSONField("destinationChannelId", destinationChannelId),
                OrderedJSONField("status", "failed"),
                OrderedJSONField("code", code),
                OrderedJSONField("error", error),
            ])
        }
    }
}

/// `POST /api/messages/forward`: one forwarded message, a stored message the
/// forward metadata could not be attached to, or a batch. The outcome travels
/// in the `X-Raft-Forward-Outcome` header (absent for the stored fallback).
public enum HumanMessageForwardResponse: JSONBodyConvertible, Sendable, Equatable {
    case message(ForwardedMessage, outcome: String)
    /// The stored row's own published body, when the row vanished before the
    /// forward metadata was committed.
    case stored(messageJSON: String)
    case batch([ForwardBatchResult], outcome: String)

    public var outcome: String? {
        switch self {
        case .message(_, let outcome), .batch(_, let outcome): outcome
        case .stored: nil
        }
    }

    public var headers: ResponseHeaders {
        guard let outcome else { return .standard() }
        return .standard(extra: ["X-Raft-Forward-Outcome": outcome])
    }

    public var jsonBody: OrderedJSON {
        switch self {
        case .message(let message, _):
            message.jsonBody
        case .stored(let messageJSON):
            .raw(messageJSON)
        case .batch(let results, _):
            .object([OrderedJSONField("results", .array(results.map(\.jsonBody)))])
        }
    }
}
