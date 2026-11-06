import Foundation

// MARK: - Typed request bodies for the messaging and channel JSON routes (Batch C)

/// A published JSON request body that already has a typed model.
///
/// The directory keeps its raw-body parsers: they are the authority for every
/// malformed shape and for the exact error code each route publishes. A route
/// decodes this type first and hands the parser the canonical JSON for the
/// shape that was just decoded, so the typed route and the raw fallback read
/// exactly the same keys. A body that does not decode (no `Content-Type`,
/// malformed JSON, or a value of the wrong type) keeps the original
/// `request.bodyText()` path and therefore its original reply.
///
/// Only fields the directory actually reads belong here: a key the parser
/// ignores is dropped by the round trip, which cannot change a reply.
///
/// Public because the route feature lives in `RaftHTTPServer` and re-encodes
/// the decoded body before it calls the directory's parser.
public protocol MessagingAndChannelsRequestDTO: Codable, Sendable, Equatable {
    /// Canonical JSON for the shape that was just decoded.
    func encodedBody() -> String
}

extension MessagingAndChannelsRequestDTO {
    /// Sorted keys make the round trip deterministic, so the body the raw
    /// parser sees is stable across processes.
    public func encodedBody() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `POST` and `DELETE /api/messages/:messageId/reactions` request body.
///
/// `emoji` is the only key either route reads. The directory trims it, caps it
/// at 16 UTF-16 units and rejects whitespace or an empty value with the same
/// `A valid emoji is required` reply, so an omitted or `null` emoji keeps the
/// raw 400 instead of becoming a decode error here.
public struct ReactionMutationRequestDTO: Codable, Sendable, Equatable, MessagingAndChannelsRequestDTO {
    public var emoji: String?

    public init(emoji: String? = nil) {
        self.emoji = emoji
    }
}

/// `POST /api/read-mutations` request body.
///
/// The route fingerprints the payload as `kind:scopeId:throughSeq` and replays
/// an identical body with `ALREADY_ADMITTED`, so the round trip must preserve
/// the shape of `throughSeq`: upstream reads a JSON number with
/// `as? NSNumber` first and a string second, and the two spellings fingerprint
/// the same but still have to re-encode as the spelling that arrived.
public struct ReadMutationAckRequestDTO: Codable, Sendable, Equatable, MessagingAndChannelsRequestDTO {
    public var mutationId: String
    public var kind: String
    public var scopeId: String?
    public var throughSeq: ThroughSeq?

    public init(
        mutationId: String,
        kind: String,
        scopeId: String? = nil,
        throughSeq: ThroughSeq? = nil
    ) {
        self.mutationId = mutationId
        self.kind = kind
        self.scopeId = scopeId
        self.throughSeq = throughSeq
    }

    /// `throughSeq` accepts a decimal JSON number or its string spelling.
    /// Anything else fails to decode and keeps the raw parser.
    public enum ThroughSeq: Codable, Sendable, Equatable {
        case number(Int)
        case string(String)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "throughSeq must be a decimal number or a string"
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }
}

/// `PATCH /api/tasks/:taskId/status` request body.
///
/// `status` is the only key the route reads and it must be one of the five
/// task statuses; an unknown value still answers the raw
/// `Invalid task status` 400, so the lookup stays in the directory.
public struct TaskStatusUpdateRequestDTO: Codable, Sendable, Equatable, MessagingAndChannelsRequestDTO {
    public var status: String

    public init(status: String) {
        self.status = status
    }
}

/// `POST /api/channels/dm` request body.
///
/// This is the only channel-creation surface `ChannelsFeature` owns. A peer is
/// named either as an agent (`agentId`) or as a human server member (`userId`);
/// both absent or unknown keeps the raw `Invalid DM peer` 400.
public struct ChannelCreateRequestDTO: Codable, Sendable, Equatable, MessagingAndChannelsRequestDTO {
    public var agentId: String?
    public var userId: String?

    public init(agentId: String? = nil, userId: String? = nil) {
        self.agentId = agentId
        self.userId = userId
    }
}

/// `POST /api/channels/threads/follow` and `/unfollow` request body.
///
/// A client names the thread directly (`threadChannelId`) or by the parent
/// message it hangs off (`parentMessageId`); both absent keeps the raw
/// `Thread not found` 404. The follower event published after a successful
/// write is built from the same canonical body, so the round trip has to keep
/// `threadChannelId` exactly as it arrived.
public struct ThreadFollowMutationDTO: Codable, Sendable, Equatable, MessagingAndChannelsRequestDTO {
    public var threadChannelId: String?
    public var parentMessageId: String?

    public init(threadChannelId: String? = nil, parentMessageId: String? = nil) {
        self.threadChannelId = threadChannelId
        self.parentMessageId = parentMessageId
    }
}
