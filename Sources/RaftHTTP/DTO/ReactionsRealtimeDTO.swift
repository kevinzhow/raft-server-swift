import Foundation

// Request and response shapes of the Done/Undone, read-all, Activity page and
// agent wake/event routes. Every response conforms to `JSONBodyConvertible`
// because the published member order is not alphabetical.

// MARK: - Requests

/// One JSON member of a request body, keeping the three states the legacy
/// parser told apart: the key was absent, the value was JSON `null`, or a
/// value was present.
public enum InboxRequestMember: Sendable, Equatable {
    case absent
    case null
    case string(String)
    /// Present and not a string (number, boolean, array, object).
    case other
}

/// `POST /api/channels/inbox/done|undone` and `/threads/done|undone`.
///
/// Leniency matches the retired object parse: a scope id that is not a string
/// is simply missing, and the frontier members keep absent/null/other apart so
/// the service can refuse each exactly as before.
public struct InboxScopeRequest: Decodable, Sendable, Equatable {
    public var channelId: String?
    public var threadChannelId: String?
    public var frontierSpace: InboxRequestMember
    public var throughActivitySeq: InboxRequestMember

    private enum CodingKeys: String, CodingKey {
        case channelId, threadChannelId, frontierSpace, throughActivitySeq
    }

    public init(
        channelId: String? = nil,
        threadChannelId: String? = nil,
        frontierSpace: InboxRequestMember = .absent,
        throughActivitySeq: InboxRequestMember = .absent
    ) {
        self.channelId = channelId
        self.threadChannelId = threadChannelId
        self.frontierSpace = frontierSpace
        self.throughActivitySeq = throughActivitySeq
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try? container.decode(String.self, forKey: .channelId)
        threadChannelId = try? container.decode(String.self, forKey: .threadChannelId)
        frontierSpace = Self.member(container, .frontierSpace)
        throughActivitySeq = Self.member(container, .throughActivitySeq)
    }

    private static func member(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> InboxRequestMember {
        guard container.contains(key) else { return .absent }
        if (try? container.decodeNil(forKey: key)) == true { return .null }
        if let value = try? container.decode(String.self, forKey: key) { return .string(value) }
        return .other
    }
}

// MARK: - Read-all

/// `POST /api/channels/inbox/read-all`.
public struct InboxReadAllResponse: JSONBodyConvertible, Equatable {
    public struct Scope: Sendable, Equatable {
        public var scopeId: String
        public var maxReadSeq: Int
        public var readStateVersion: Int
    }

    public var scopes: [Scope]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("markedCount", scopes.count),
            OrderedJSONField("scopes", .array(scopes.map { scope in
                .object([
                    OrderedJSONField("scopeId", scope.scopeId),
                    OrderedJSONField("maxReadSeq", scope.maxReadSeq),
                    OrderedJSONField("readStateVersion", scope.readStateVersion),
                ])
            })),
        ])
    }
}

// MARK: - Activity page

/// `GET /api/channels/inbox`.
public struct ChannelInboxResponse: JSONBodyConvertible, Equatable {
    public enum Item: Sendable, Equatable {
        case thread(
            threadChannelId: String,
            parentChannelId: String?,
            parentChannelType: String?,
            latestActivityMessageId: String,
            firstUnreadMessageId: String?,
            firstMentionMessageId: String?,
            unreadCount: Int,
            hasMention: Bool,
            isFollowing: Bool
        )
        case conversation(
            kind: String,
            channelId: String,
            channelType: String,
            lastMessageId: String,
            firstUnreadMessageId: String?,
            firstMentionMessageId: String?,
            unreadCount: Int,
            hasMention: Bool
        )

        var jsonBody: OrderedJSON {
            switch self {
            case let .thread(
                threadChannelId, parentChannelId, parentChannelType, latestActivityMessageId,
                firstUnreadMessageId, firstMentionMessageId, unreadCount, hasMention, isFollowing
            ):
                return .object([
                    OrderedJSONField("kind", "thread"),
                    OrderedJSONField("threadChannelId", threadChannelId),
                    OrderedJSONField("parentChannelId", optional: parentChannelId),
                    OrderedJSONField("parentChannelType", optional: parentChannelType),
                    OrderedJSONField("latestActivityMessageId", latestActivityMessageId),
                    OrderedJSONField("firstUnreadMessageId", optional: firstUnreadMessageId),
                    OrderedJSONField("firstMentionMessageId", optional: firstMentionMessageId),
                    OrderedJSONField("unreadCount", unreadCount),
                    OrderedJSONField("hasMention", hasMention),
                    OrderedJSONField("isFollowing", isFollowing),
                ])
            case let .conversation(
                kind, channelId, channelType, lastMessageId,
                firstUnreadMessageId, firstMentionMessageId, unreadCount, hasMention
            ):
                return .object([
                    OrderedJSONField("kind", kind),
                    OrderedJSONField("channelId", channelId),
                    OrderedJSONField("channelType", channelType),
                    OrderedJSONField("lastMessageId", lastMessageId),
                    OrderedJSONField("firstUnreadMessageId", optional: firstUnreadMessageId),
                    OrderedJSONField("firstMentionMessageId", optional: firstMentionMessageId),
                    OrderedJSONField("unreadCount", unreadCount),
                    OrderedJSONField("hasMention", hasMention),
                ])
            }
        }
    }

    public struct Group: Sendable, Equatable {
        public var channelId: String
        public var channelName: String
        public var channelType: String
        public var count: Int
        public var lastActivityAt: String
    }

    public var items: [Item]
    public var hasMore: Bool
    public var totalCount: Int
    public var totalUnreadCount: Int
    public var activeUnreadCount: Int
    public var groups: [Group]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("items", .array(items.map(\.jsonBody))),
            OrderedJSONField("hasMore", hasMore),
            OrderedJSONField("totalCount", totalCount),
            OrderedJSONField("totalUnreadCount", totalUnreadCount),
            OrderedJSONField("activeUnreadCount", activeUnreadCount),
            OrderedJSONField("groups", .array(groups.map { group in
                .object([
                    OrderedJSONField("channelId", group.channelId),
                    OrderedJSONField("channelName", group.channelName),
                    OrderedJSONField("channelType", group.channelType),
                    OrderedJSONField("count", group.count),
                    OrderedJSONField("lastActivityAt", group.lastActivityAt),
                ])
            })),
        ])
    }
}

// MARK: - Agent API

/// `GET /internal/agent-api/mentions`.
public struct AgentMentionInboxResponse: JSONBodyConvertible, Equatable {
    public var messageIds: [String]
    public var hasMore: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("mentions", .array(messageIds.map { .object([OrderedJSONField("messageId", $0)]) })),
            OrderedJSONField("has_more", hasMore),
        ])
    }
}

/// One content-free wake hint. A third-party app event has no sequence and no
/// target, and publishes both as JSON `null`.
public struct AgentWakeHint: Sendable, Equatable {
    public var seq: Int?
    public var messageId: String
    public var target: String?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("event_id", "wake-hint:\(messageId)"),
            OrderedJSONField("seq", optional: seq),
            OrderedJSONField("message_id", messageId),
            OrderedJSONField("target", optional: target),
            OrderedJSONField("wake_reason", "message_pending"),
        ])
    }
}

/// `GET /internal/agent-api/wake-hints`.
public struct AgentWakeHintsResponse: JSONBodyConvertible, Equatable {
    public var hints: [AgentWakeHint]
    public var lastHintSeq: Int?
    public var hasMore: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("wake_hints", .array(hints.map(\.jsonBody))),
            OrderedJSONField("last_hint_seq", optional: lastHintSeq),
            OrderedJSONField("has_more", hasMore),
        ])
    }
}

/// One entry of `GET /internal/agent-api/events`.
public enum AgentEventEntry: Sendable, Equatable {
    public struct ExternalMessage: Sendable, Equatable {
        public var messageId: String?
        public var provider: String?
        public var actorName: String?
    }

    public struct ThirdPartySource: Sendable, Equatable {
        public var clientId: String
        public var clientName: String
        public var oauthClientId: String
        public var resource: String
    }

    case message(
        seq: Int,
        messageId: String,
        senderId: String,
        senderName: String,
        senderType: String,
        content: String,
        mentioned: Bool,
        channelId: String,
        channelName: String,
        channelType: String,
        timestamp: String,
        attachments: [AgentHistoryMessage.Attachment],
        external: ExternalMessage?
    )
    case action(seq: Int, messageId: String, content: String)
    case thirdParty(
        seq: Int,
        messageId: String,
        content: String,
        kind: String,
        summary: String,
        source: ThirdPartySource
    )

    var jsonBody: OrderedJSON {
        switch self {
        case let .message(
            seq, messageId, senderId, senderName, senderType, content, mentioned,
            channelId, channelName, channelType, timestamp, attachments, external
        ):
            var body = OrderedJSONObject()
            body.append("seq", seq)
            body.append("message_id", messageId)
            body.append("sender_id", senderId)
            body.append("sender_name", senderName)
            body.append("sender_type", senderType)
            body.append("senderType", senderType)
            body.append("content", content)
            body.append("mentioned", mentioned)
            body.append("channel_id", channelId)
            body.append("channel_name", channelName)
            body.append("channel_type", channelType)
            body.append("timestamp", timestamp)
            body.append("attachments", .array(attachments.map(\.jsonBody)))
            if let external {
                body.append("external_message", .object([
                    OrderedJSONField("message_id", optional: external.messageId),
                    OrderedJSONField("provider", optional: external.provider),
                    OrderedJSONField("actor_name", optional: external.actorName),
                ]))
            }
            return body.json
        case let .action(seq, messageId, content):
            return .object([
                OrderedJSONField("seq", seq),
                OrderedJSONField("message_id", messageId),
                OrderedJSONField("sender_type", "agent"),
                OrderedJSONField("senderType", "agent"),
                OrderedJSONField("content", content),
                OrderedJSONField("mentioned", true),
            ])
        case let .thirdParty(seq, messageId, content, kind, summary, source):
            return .object([
                OrderedJSONField("seq", seq),
                OrderedJSONField("message_id", messageId),
                OrderedJSONField("sender_type", "third_party_app"),
                OrderedJSONField("senderType", "third_party_app"),
                OrderedJSONField("content", content),
                OrderedJSONField("mentioned", false),
                OrderedJSONField("third_party_event", .object([
                    OrderedJSONField("id", messageId),
                    OrderedJSONField("kind", kind),
                    OrderedJSONField("summary", summary),
                    OrderedJSONField("source", .object([
                        OrderedJSONField("client_id", source.clientId),
                        OrderedJSONField("client_name", source.clientName),
                        OrderedJSONField("oauth_client_id", source.oauthClientId),
                        OrderedJSONField("resource", source.resource),
                    ])),
                ])),
            ])
        }
    }
}

/// `GET /internal/agent-api/events`.
public struct AgentEventsResponse: JSONBodyConvertible, Equatable {
    public var events: [AgentEventEntry]
    public var hasMore: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("events", .array(events.map(\.jsonBody))),
            OrderedJSONField("has_more", hasMore),
        ])
    }
}
