import Foundation

// Response shapes for the agent history read (`GET /internal/agent-api/history`
// and `GET /internal/agent/:agentId/history`). Every member keeps the order the
// retired handler printed; the three page layouts differ in their members.

/// One message row of a history page.
public struct AgentHistoryMessage: Sendable, Equatable {
    /// The external-projection facts a third-party-app row carries.
    public struct External: Sendable, Equatable {
        public var messageId: String?
        public var provider: String?
        public var actorName: String?
    }

    public var id: String
    public var channelId: String
    public var content: String
    public var seq: Int
    public var senderType: String
    public var senderId: String
    public var senderName: String
    public var senderTimezone: String?
    public var createdAt: Date
    /// Present only in the regular page layout.
    public var mentioned: Bool?
    public var external: External?

    var jsonBody: OrderedJSON {
        var row = OrderedJSONObject()
        row.append("id", id)
        row.append("channelId", channelId)
        row.append("content", content)
        row.append("seq", seq)
        row.append("senderType", senderType)
        row.append("senderId", senderId)
        row.append("senderName", senderName)
        row.append("senderTimezone", optional: senderTimezone)
        row.append("createdAt", AgentHistoryFormat.timestamp(createdAt))
        row.append("attachments", .array([]))
        if let mentioned { row.append("mentioned", mentioned) }
        if let external {
            row.append("external_message", .object([
                OrderedJSONField("message_id", optional: external.messageId),
                OrderedJSONField("provider", optional: external.provider),
                OrderedJSONField("actor_name", optional: external.actorName),
            ]))
        }
        return row.json
    }
}

enum AgentHistoryFormat {
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// The channel card a non-DM page carries.
public struct AgentHistoryChannelCard: Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    public var description: String?
    public var archived: Bool
}

/// Where a DM or reminders read is consumed.
public struct AgentHistoryConsumptionScope: Sendable, Equatable {
    public var agentId: String
    public var channelId: String
    public var channelType: String
    public var target: String
}

/// A read of one third-party event (`agent-event:<id>`).
public struct AgentHistoryThirdPartyEvent: Sendable, Equatable {
    public var id: String
    public var content: String
    public var clientKey: String
    public var clientName: String
    public var createdAt: Date
    public var kind: String
    public var externalEventId: String?
    public var payloadHash: String
    /// The stored payload text (`{}` when empty), already valid JSON.
    public var payloadJSON: String
    public var expiresAt: Date
}

/// The unread read: the page and the cursor facts it advanced.
public struct AgentHistoryUnreadPage: Sendable, Equatable {
    public var messages: [AgentHistoryMessage]
    public var hasNewer: Bool
    public var lastReadSeq: Int
    public var modelSeenUpToSeq: Int
    public var target: String
}

/// The regular (latest / before / after / around) read.
public struct AgentHistoryPage: Sendable, Equatable {
    public var messages: [AgentHistoryMessage]
    public var hasOlder: Bool
    public var hasNewer: Bool
    public var lastReadSeq: Int
    public var modelSeenUpToSeq: Int?
    public var target: String
    public var consumptionScope: AgentHistoryConsumptionScope?
    public var channelCard: AgentHistoryChannelCard?
    /// The peer card text from the action-card prepare service, already JSON.
    public var peerCardJSON: String?
}

/// `GET …/history`.
public enum AgentHistoryResponse: JSONBodyConvertible, Sendable, Equatable {
    case thirdPartyEvent(AgentHistoryThirdPartyEvent)
    case unread(AgentHistoryUnreadPage)
    case page(AgentHistoryPage)

    public var jsonBody: OrderedJSON {
        switch self {
        case .thirdPartyEvent(let event):
            let id = event.id
            let row = OrderedJSON.object([
                OrderedJSONField("id", id),
                OrderedJSONField("content", event.content),
                OrderedJSONField("seq", 1),
                OrderedJSONField("senderType", "third_party_app"),
                OrderedJSONField("senderId", event.clientKey),
                OrderedJSONField("senderName", event.clientName),
                OrderedJSONField("createdAt", AgentHistoryFormat.timestamp(event.createdAt)),
                OrderedJSONField("attachments", .array([])),
                OrderedJSONField("third_party_event", .object([
                    OrderedJSONField("id", id),
                    OrderedJSONField("kind", event.kind),
                    OrderedJSONField("client_id", event.clientKey),
                    OrderedJSONField("client_name", event.clientName),
                    OrderedJSONField("external_event_id", optional: event.externalEventId),
                    OrderedJSONField("payload_hash", event.payloadHash),
                    OrderedJSONField("payload", .raw(event.payloadJSON)),
                    OrderedJSONField("expires_at", AgentHistoryFormat.timestamp(event.expiresAt)),
                ])),
            ])
            return .object([
                OrderedJSONField("messages", .array([row])),
                OrderedJSONField("has_more", false),
                OrderedJSONField("has_older", false),
                OrderedJSONField("has_newer", false),
            ])
        case .unread(let page):
            return .object([
                OrderedJSONField("messages", .array(page.messages.map(\.jsonBody))),
                OrderedJSONField("has_more", page.hasNewer),
                OrderedJSONField("has_older", false),
                OrderedJSONField("has_newer", page.hasNewer),
                OrderedJSONField("last_read_seq", page.lastReadSeq),
                OrderedJSONField("unread_after_seq", page.lastReadSeq),
                OrderedJSONField("model_seen_up_to_seq", page.modelSeenUpToSeq),
                OrderedJSONField("target", page.target),
            ])
        case .page(let page):
            var body = OrderedJSONObject()
            body.append("messages", .array(page.messages.map(\.jsonBody)))
            body.append("has_more", page.hasOlder || page.hasNewer)
            body.append("has_older", page.hasOlder)
            body.append("has_newer", page.hasNewer)
            body.append("last_read_seq", page.lastReadSeq)
            body.append("model_seen_up_to_seq", optional: page.modelSeenUpToSeq)
            body.append("target", page.target)
            if let scope = page.consumptionScope {
                body.append("consumption_scope", .object([
                    OrderedJSONField("agent_id", scope.agentId),
                    OrderedJSONField("channel_id", scope.channelId),
                    OrderedJSONField("channel_type", scope.channelType),
                    OrderedJSONField("target", scope.target),
                ]))
            }
            if let card = page.channelCard {
                body.append("channel_card", .object([
                    OrderedJSONField("id", card.id),
                    OrderedJSONField("name", card.name),
                    OrderedJSONField("type", card.type),
                    OrderedJSONField("description", optional: card.description),
                    OrderedJSONField("archived", card.archived),
                ]))
            }
            if let peer = page.peerCardJSON {
                body.append("peer_card", .raw(peer))
            }
            return body.json
        }
    }
}
