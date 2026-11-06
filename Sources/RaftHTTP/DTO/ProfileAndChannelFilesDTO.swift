import Foundation
import RaftShared

// The published shapes for the message-reaction, third-party-event delivery and
// agent-reaction surface. Every response body is a `JSONBodyConvertible` tree
// because the legacy handlers printed a fixed member order; a plain `Codable`
// body would sort its keys and change the bytes.

/// Domain failure for the reaction, reaction-actor, agent-reaction and
/// third-party-delivery operations.
///
/// The published bodies are the bytes the retired handlers printed: most are
/// the canonical `{"error": …}` (plus `code`), while the agent short-id
/// conflict prints `errorCode`, the two stale-actor refusals add
/// `rebaselineRequired`/`currentDiscussionVersion`, and the capability refusal
/// appends `requiredCapability`. Those carry an explicit `errorBody`.
public enum ProfileAndChannelFilesError: DomainError, Equatable {
    /// Human session refusal; the legacy `PublicVisits` reply also publishes
    /// `Cache-Control: no-store`.
    case authRequired(bearerPresent: Bool)
    /// Machine-key or agent-credential refusal on the agent routes.
    case agentAuthRequired(message: String)
    case capabilityNotAuthorized(capability: String)
    case invalidEmoji
    case messageNotFound
    case ambiguousShortId
    case ambiguousShortIdAgentApi
    case invalidMessageId
    case systemMessage
    case notChannelMember
    case channelArchived
    case invalidActorEmoji
    case invalidActorLimit
    case invalidActorCursor
    case actorVisibilityChanged
    case discussionVersionChanged(currentVersion: Int)
    case eventIdsNotEmpty
    case eventIdsInvalid

    public var status: UInt {
        switch self {
        case .authRequired, .agentAuthRequired:
            401
        case .capabilityNotAuthorized, .notChannelMember:
            403
        case .messageNotFound:
            404
        case .channelArchived, .actorVisibilityChanged, .discussionVersionChanged:
            409
        case .invalidEmoji, .ambiguousShortId, .ambiguousShortIdAgentApi,
             .invalidMessageId, .systemMessage, .invalidActorEmoji, .invalidActorLimit,
             .invalidActorCursor, .eventIdsNotEmpty, .eventIdsInvalid:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .authRequired(let bearerPresent):
            bearerPresent
                ? "Invalid or expired token"
                : "Missing or invalid Authorization header"
        case .agentAuthRequired(let message):
            message
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .invalidEmoji:
            "A valid emoji is required"
        case .messageNotFound:
            "Message not found"
        case .ambiguousShortId:
            "Message short id is ambiguous"
        case .ambiguousShortIdAgentApi:
            "Message short id is ambiguous"
        case .invalidMessageId:
            "Message id must be a full UUID or 8-character short id"
        case .systemMessage:
            "System messages cannot receive reactions"
        case .notChannelMember:
            "You must join this channel to react to messages"
        case .channelArchived:
            "This channel is archived"
        case .invalidActorEmoji:
            "A valid emoji is required"
        case .invalidActorLimit:
            "limit must be an integer between 1 and 100"
        case .invalidActorCursor:
            "Invalid reaction actors cursor"
        case .actorVisibilityChanged:
            "Reaction actor visibility changed while reading this page"
        case .discussionVersionChanged:
            "Reaction discussion changed while reading this page"
        case .eventIdsNotEmpty:
            "eventIds must be a non-empty array"
        case .eventIdsInvalid:
            "eventIds must contain third-party event ids"
        }
    }

    public var responseHeaders: [String: String] {
        switch self {
        case .authRequired:
            ["Cache-Control": "no-store"]
        default:
            [:]
        }
    }

    public var errorCode: String? {
        switch self {
        case .authRequired, .agentAuthRequired:
            "auth_required"
        case .capabilityNotAuthorized:
            "capability_not_authorized"
        case .channelArchived:
            "channel_archived"
        case .invalidActorEmoji:
            "invalid_reaction_emoji"
        case .invalidActorLimit:
            "invalid_reaction_actor_limit"
        case .invalidActorCursor:
            "invalid_reaction_actors_cursor"
        case .actorVisibilityChanged:
            "reaction_actor_visibility_changed"
        case .discussionVersionChanged:
            "reaction_discussion_version_changed"
        case .eventIdsNotEmpty, .eventIdsInvalid:
            "event_ids_invalid"
        case .invalidEmoji, .messageNotFound, .ambiguousShortId, .ambiguousShortIdAgentApi,
             .invalidMessageId, .systemMessage, .notChannelMember:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .capabilityNotAuthorized(let capability):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "capability_not_authorized")
            body.append("requiredCapability", capability)
            return body.json
        case .ambiguousShortIdAgentApi:
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("errorCode", "AMBIGUOUS_ID")
            return body.json
        case .actorVisibilityChanged:
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "reaction_actor_visibility_changed")
            body.append("rebaselineRequired", true)
            return body.json
        case .discussionVersionChanged(let currentVersion):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "reaction_discussion_version_changed")
            body.append("currentDiscussionVersion", currentVersion)
            body.append("rebaselineRequired", true)
            return body.json
        default:
            return nil
        }
    }
}


/// `POST`/`DELETE /api/messages/:id/reactions` and the two agent reaction
/// routes. `emoji` is the only key the handlers read; a missing or non-string
/// value keeps the legacy `A valid emoji is required` 400.
public struct ProfileReactionRequestDTO: Codable, Sendable, Equatable {
    public var emoji: String?

    public init(emoji: String? = nil) {
        self.emoji = emoji
    }
}

/// `POST /internal/agent-api/third-party-events/delivered`.
///
/// `eventIds` stays a JSON tree so a non-string element reaches the legacy
/// `eventIds must contain third-party event ids` refusal instead of failing
/// the whole decode and being reported as the empty-array refusal.
public struct ThirdPartyEventDeliveryRequestDTO: Decodable, Sendable {
    public var eventIds: [JSONValue]?

    public init(eventIds: [JSONValue]? = nil) {
        self.eventIds = eventIds
    }
}

/// One emoji bucket of a reaction ACK, in first-reaction order.
public struct ProfileReactionBucket: Sendable, Equatable {
    public var emoji: String
    public var reactorIds: [String]
    public var reactorNames: [String]

    public init(emoji: String, reactorIds: [String], reactorNames: [String]) {
        self.emoji = emoji
        self.reactorIds = reactorIds
        self.reactorNames = reactorNames
    }

    public var count: Int { reactorIds.count }

    /// `{emoji,count,reactorIds,reactorNames}` in the published order.
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("emoji", emoji)
        body.append("count", count)
        body.append("reactorIds", .array(reactorIds.map(OrderedJSON.string)))
        body.append("reactorNames", .array(reactorNames.map(OrderedJSON.string)))
        return body.json
    }
}

/// The `POST`/`DELETE /api/messages/:id/reactions` ACK.
///
/// Member order is `reactions`, `commentRef`, `attachments`, then the optional
/// `actionMetadata` and `reactionViewer`. The agent reaction routes publish the
/// same body without `reactionViewer`.
public struct ReactionMutationResponseDTO: JSONBodyConvertible, Sendable, Equatable {
    public var reactions: [ProfileReactionBucket]
    /// Exact `commentRef` object; `nil` publishes JSON `null`.
    public var commentRef: OrderedJSON?
    /// Exact `attachments` array.
    public var attachments: OrderedJSON
    public var actionMetadata: OrderedJSON?
    public var reactionViewer: OrderedJSON?

    public init(
        reactions: [ProfileReactionBucket],
        commentRef: OrderedJSON?,
        attachments: OrderedJSON,
        actionMetadata: OrderedJSON? = nil,
        reactionViewer: OrderedJSON? = nil
    ) {
        self.reactions = reactions
        self.commentRef = commentRef
        self.attachments = attachments
        self.actionMetadata = actionMetadata
        self.reactionViewer = reactionViewer
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("reactions", .array(reactions.map(\.jsonBody)))
        body.append("commentRef", commentRef ?? .null)
        body.append("attachments", attachments)
        body.append("actionMetadata", ifPresent: actionMetadata)
        body.append("reactionViewer", ifPresent: reactionViewer)
        return body.json
    }
}

/// `GET /api/messages/:id/reactions/viewer`.
public struct ReactionViewerResponseDTO: JSONBodyConvertible, Sendable, Equatable {
    public var serverId: String
    public var messageId: String
    public var viewerVersion: Int
    public var reactedEmojis: [String]

    public init(serverId: String, messageId: String, viewerVersion: Int, reactedEmojis: [String]) {
        self.serverId = serverId
        self.messageId = messageId
        self.viewerVersion = viewerVersion
        self.reactedEmojis = reactedEmojis
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("serverId", serverId)
        body.append("messageId", messageId)
        body.append("viewerVersion", viewerVersion)
        body.append("reactedEmojis", .array(reactedEmojis.map(OrderedJSON.string)))
        return body.json
    }
}

/// One `actorRef` of the reaction-actor page.
public struct ProfileReactionActor: Sendable, Equatable {
    public var kind: String
    public var id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("actorRef", .object([
                OrderedJSONField("kind", kind),
                OrderedJSONField("id", id),
            ]))
        ])
    }
}

/// `GET /api/messages/:id/reactions/actors`.
///
/// Member order is `discussion`, `discussionVersion`, `actors`, `nextCursor`;
/// `nextCursor` is present and JSON `null` on the last page.
public struct ReactionActorsResponseDTO: JSONBodyConvertible, Sendable, Equatable {
    public var discussion: OrderedJSON
    public var discussionVersion: Int
    public var actors: [ProfileReactionActor]
    public var nextCursor: String?

    public init(
        discussion: OrderedJSON,
        discussionVersion: Int,
        actors: [ProfileReactionActor],
        nextCursor: String?
    ) {
        self.discussion = discussion
        self.discussionVersion = discussionVersion
        self.actors = actors
        self.nextCursor = nextCursor
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("discussion", discussion)
        body.append("discussionVersion", discussionVersion)
        body.append("actors", .array(actors.map(\.jsonBody)))
        body.append("nextCursor", optional: nextCursor)
        return body.json
    }
}

/// `POST /internal/agent-api/third-party-events/delivered`.
///
/// The legacy object prints `ok` before `delivered`, which is not the sorted
/// order, so the tree carries it.
public struct ThirdPartyEventDeliveryResponseDTO: JSONBodyConvertible, Sendable, Equatable {
    public var delivered: Int

    public init(delivered: Int) {
        self.delivered = delivered
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("delivered", delivered)
        return body.json
    }
}
