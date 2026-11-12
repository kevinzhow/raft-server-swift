import Foundation

// Response shapes for announcements, avatars, channel unread and notification
// settings, the channel create/patch routes, the agent user lookups and the
// app-installation reminder write. Every body owns its published member order
// as an `OrderedJSON` tree (`JSONBodyConvertible`); the strings the retired
// handlers concatenated by hand are reproduced byte for byte.

// MARK: - Assets (non-JSON bodies)

/// A rendered text body with its own header set. Binary assets use
/// `BinaryBodyResponse` and never enter the JSON/text adapter.
public struct ManagedMCPAssetResponse: JSONBodyConvertible {
    public let headers: ResponseHeaders
    let text: String

    init(headers: ResponseHeaders, text: String) {
        self.headers = headers
        self.text = text
    }

    public var jsonBody: OrderedJSON { .raw(text) }
}

// MARK: - Announcements

/// `GET /api/announcements/active`.
public struct ActiveAnnouncementsResponse: JSONBodyConvertible, Equatable {
    struct Document: Sendable, Equatable {
        let id: String
        let title: String
        let pages: [String]
    }

    let announcements: [Document]

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("announcements", .array(announcements.map { document in
            .object([
                OrderedJSONField("id", document.id),
                OrderedJSONField("title", document.title),
                OrderedJSONField("pages", .array(document.pages.map(OrderedJSON.string))),
            ])
        }))])
    }
}

// MARK: - Unread

/// `POST /api/channels/:id/unread`.
public struct ChannelMarkedUnreadResponse: JSONBodyConvertible, Equatable {
    let channelId: String
    let unreadCount: Int
    let maxReadSeq: Int

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("channelId", channelId),
            OrderedJSONField("unreadCount", unreadCount),
            OrderedJSONField("maxReadSeq", maxReadSeq),
        ])
    }
}

/// `GET /api/channels/unread`: the per-channel counts, or the summary.
public struct ChannelUnreadResponse: JSONBodyConvertible {
    struct SummaryEntry: Sendable {
        let channelId: String
        let unreadCount: Int
        let hasMention: Bool
        let maxReadSeq: Int
        let latestMessageId: String?
        let latestSeq: Int?
        let parentChannelId: String?
        let parentMessageId: String?
    }

    struct ThreadAggregate: Sendable {
        let parentChannelId: String
        let count: Int
        let hasMention: Bool
    }

    enum Kind: Sendable {
        case counts([(channelId: String, count: Int)])
        case summary(entries: [SummaryEntry], threadUnread: [ThreadAggregate])
    }

    let kind: Kind

    static func counts(_ pairs: [(channelId: String, count: Int)]) -> ChannelUnreadResponse {
        ChannelUnreadResponse(kind: .counts(pairs))
    }

    static func summary(entries: [SummaryEntry], threadUnread: [ThreadAggregate]) -> ChannelUnreadResponse {
        ChannelUnreadResponse(kind: .summary(entries: entries, threadUnread: threadUnread))
    }

    public var jsonBody: OrderedJSON {
        switch kind {
        case .counts(let pairs):
            return .object(pairs.map { OrderedJSONField($0.channelId, $0.count) })
        case .summary(let entries, let threadUnread):
            let channels = entries.map { entry -> OrderedJSONField in
                let latest: OrderedJSON
                if let messageId = entry.latestMessageId, let seq = entry.latestSeq {
                    latest = .object([
                        OrderedJSONField("messageId", messageId),
                        OrderedJSONField("seq", String(seq)),
                    ])
                } else {
                    latest = .null
                }
                var object = OrderedJSONObject()
                object.append("unreadCount", entry.unreadCount)
                object.append("hasMention", entry.hasMention)
                object.append("hasAnyMention", entry.hasMention)
                object.append("readState", .object([
                    OrderedJSONField("kind", "present"),
                    OrderedJSONField("readStateVersion", 0),
                    OrderedJSONField("maxReadSeq", String(entry.maxReadSeq)),
                    OrderedJSONField("latestActivity", latest),
                ]))
                object.append("parentChannelId", ifPresent: entry.parentChannelId)
                object.append("parentMessageId", ifPresent: entry.parentMessageId)
                return OrderedJSONField(entry.channelId, object.json)
            }
            let threads = threadUnread.sorted { $0.parentChannelId < $1.parentChannelId }.map {
                OrderedJSONField($0.parentChannelId, .object([
                    OrderedJSONField("count", $0.count),
                    OrderedJSONField("hasMention", $0.hasMention),
                ]))
            }
            return .object([
                OrderedJSONField("channels", .object(channels)),
                OrderedJSONField("threadUnread", .object(threads)),
            ])
        }
    }
}

/// `GET|PATCH /api/channels/:id/notification-settings`.
public struct ChannelNotificationSettingsResponse: JSONBodyConvertible, Equatable {
    let activityMuted: Bool
    let muteFromSeq: Int?
    let prefsVersion: Int
    let activityMuteSupported: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("activityMuted", activityMuted),
            OrderedJSONField("muteFromSeq", optional: muteFromSeq),
            OrderedJSONField("prefsVersion", prefsVersion),
            OrderedJSONField("activityMuteSupported", activityMuteSupported),
        ])
    }
}

// MARK: - Channel create/patch

/// The published answers of `PATCH /api/channels/:id` and `POST /api/channels`.
public enum ManagedMCPChannelRouteResponse: JSONBodyConvertible, Equatable {
    case guestFlags(id: String, guestVisible: Bool, guestJoinable: Bool)
    case visibility(id: String, visibility: String)
    case updated(id: String, name: String, description: String?, systemMessageSeq: Int?)
    case created(id: String, name: String)
    case jointCreated(id: String, name: String, targetServerSlug: String, inviteId: String)

    public var jsonBody: OrderedJSON {
        switch self {
        case .guestFlags(let id, let visible, let joinable):
            return .object([
                OrderedJSONField("ok", true),
                OrderedJSONField("id", id),
                OrderedJSONField("guestVisible", visible),
                OrderedJSONField("guestJoinable", joinable),
            ])
        case .visibility(let id, let visibility):
            return .object([
                OrderedJSONField("ok", true),
                OrderedJSONField("id", id),
                OrderedJSONField("visibility", visibility),
                OrderedJSONField("type", visibility == "private" ? "private" : "channel"),
            ])
        case .updated(let id, let name, let description, let seq):
            return .object([
                OrderedJSONField("id", id),
                OrderedJSONField("name", name),
                OrderedJSONField("description", optional: description),
                OrderedJSONField("systemMessageSeq", optional: seq),
            ])
        case .created(let id, let name):
            return .object([
                OrderedJSONField("id", id),
                OrderedJSONField("name", name),
                OrderedJSONField("joined", true),
                OrderedJSONField("activityMuteSupported", true),
                OrderedJSONField("activityMuted", false),
                OrderedJSONField("muteFromSeq", .null),
                OrderedJSONField("prefsVersion", 0),
                OrderedJSONField("maxReadSeq", 0),
                OrderedJSONField("readStateVersion", 0),
            ])
        case .jointCreated(let id, let name, let slug, let inviteId):
            return .object([
                OrderedJSONField("id", id),
                OrderedJSONField("name", name),
                OrderedJSONField("type", "joint"),
                OrderedJSONField("targetServerSlug", slug),
                OrderedJSONField("jointInvite", .object([
                    OrderedJSONField("id", inviteId),
                    OrderedJSONField("status", "pending"),
                ])),
                OrderedJSONField("joined", true),
            ])
        }
    }
}

/// `POST /api/channels` request.
///
/// `invitedPeople` keeps the retired `as? [String]` rule: one non-string
/// element drops the whole list. Every other member reads like `as? String`.
public struct ManagedMCPChannelCreateRequest: Decodable, Sendable, Equatable {
    public var name: String?
    public var visibility: String?
    public var targetServerSlug: String?
    public var invitedPeople: [String]?
    public var description: String?

    public init(
        name: String? = nil,
        visibility: String? = nil,
        targetServerSlug: String? = nil,
        invitedPeople: [String]? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.visibility = visibility
        self.targetServerSlug = targetServerSlug
        self.invitedPeople = invitedPeople
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case name, visibility, targetServerSlug, invitedPeople, description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        visibility = try? container.decode(String.self, forKey: .visibility)
        targetServerSlug = try? container.decode(String.self, forKey: .targetServerSlug)
        invitedPeople = try? container.decode([String].self, forKey: .invitedPeople)
        description = try? container.decode(String.self, forKey: .description)
    }
}

// MARK: - Agent user lookups

/// `GET /internal/agent-api/users/:name/channels` (JSON) and the text form of
/// `GET .../users/:name`.
public struct AgentUserChannelsResponse: JSONBodyConvertible, Equatable {
    struct Membership: Sendable, Equatable {
        let id: String
        let name: String
        let type: String
        let joined: Bool
        let channelRole: String?
    }

    let name: String
    let uncheckedCount: Int
    let page: [Membership]
    let total: Int
    let offset: Int
    let limit: Int

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("kind", "human"),
            OrderedJSONField("name", name),
            OrderedJSONField("uncheckedCount", uncheckedCount),
            OrderedJSONField("memberships", .array(page.map { row in
                .object([
                    OrderedJSONField("id", row.id),
                    OrderedJSONField("name", row.name),
                    OrderedJSONField("type", row.type),
                    OrderedJSONField("joined", row.joined),
                    OrderedJSONField("channelRole", optional: row.channelRole),
                ])
            })),
            OrderedJSONField("page", .object([
                OrderedJSONField("total", total),
                OrderedJSONField("offset", offset),
                OrderedJSONField("limit", limit),
            ])),
        ])
    }

    /// The plain-text projection `GET .../users/:name` publishes.
    var text: String {
        var text = page.map { "#\($0.name)" }.joined(separator: "\n")
        if uncheckedCount > 0 {
            text += (text.isEmpty ? "" : "\n")
                + "Skipped \(uncheckedCount) visible channel roster checks because the server rejected them."
        }
        return text
    }
}

// MARK: - App reminders

/// `POST /api/app-installation/agent-reminders`.
public struct AppAgentReminderResponse: JSONBodyConvertible, Equatable {
    let created: Bool
    let messageId: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("created", created),
            OrderedJSONField("messageId", messageId),
            OrderedJSONField("surface", .object([
                OrderedJSONField("channelType", "dm"),
                OrderedJSONField("channelName", "reminders"),
                OrderedJSONField("target", "dm:@reminders"),
            ])),
        ])
    }
}
