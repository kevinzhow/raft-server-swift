import Foundation
import RaftShared

// Request and response shapes for the app-reminder routes (the owner list, the
// internal machine routes and the agent-api routes) and the saved-message
// write. Every response owns its published member order as an `OrderedJSON`
// tree, reproducing the strings the retired handlers concatenated by hand.

// MARK: - Requests

/// `POST /internal/agent/:id/reminders` and `POST /internal/agent-api/reminders`.
public struct ReminderCreateRequest: Decodable, Sendable, Equatable {
    /// Trimmed title; nil when absent, wrong-typed or blank.
    public var title: String?
    public var msgId: String?
    public var fireAt: String?
    public var delaySeconds: Int?
    public var notes: String?
    public var recurrence: String?
    public var channelId: String?
    public var threadId: String?

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        let trimmed = members["title"]?.castString?.trimmingCharacters(in: .whitespacesAndNewlines)
        title = (trimmed?.isEmpty == false) ? trimmed : nil
        msgId = members["msgId"]?.castString
        fireAt = members["fireAt"]?.castString
        delaySeconds = members["delaySeconds"]?.castInt
        notes = members["notes"]?.castString
        recurrence = members["recurrence"]?.castString
        channelId = members["channelId"]?.castString
        threadId = members["threadId"]?.castString
    }
}

/// The reminder snooze body: an ISO `fireAt`, or a non-negative `delaySeconds`.
public struct ReminderSnoozeRequest: Decodable, Sendable, Equatable {
    public var fireAt: String?
    public var delaySeconds: Int?

    public init() {}

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        fireAt = members["fireAt"]?.castString
        delaySeconds = members["delaySeconds"]?.castInt
    }
}

/// The reminder update body. A body that is not a JSON object does not decode,
/// which the service answers with the published 400.
public struct ReminderUpdateRequest: Decodable, Sendable, Equatable {
    public var title: String?
    public var fireAt: String?
    public var notes: String?

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        title = members["title"]?.castString
        fireAt = members["fireAt"]?.castString
        notes = members["notes"]?.castString
    }
}

/// The reminder cancel body: the optional `expectedVersion` (0 when absent).
public struct ReminderCancelRequest: Decodable, Sendable, Equatable {
    public var expectedVersion: Int

    public init() {
        expectedVersion = 0
    }

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        expectedVersion = members["expectedVersion"]?.castInt ?? 0
    }
}

/// `POST /api/channels/saved`.
public struct SaveChannelMessageRequest: Decodable, Sendable, Equatable {
    public var messageId: String?

    public init(from decoder: any Decoder) throws {
        let members = try LegacyJSONObjectBody(from: decoder).members
        messageId = members["messageId"]?.castString
    }
}

// MARK: - Responses

/// One reminder as the machine and agent-api routes print it.
public struct ReminderSummary: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var status: String
    public var version: Int
    public var title: String
    public var ownerAgentId: String?
    public var fireAt: Date?

    public init(
        id: String, status: String, version: Int, title: String,
        ownerAgentId: String? = nil, fireAt: Date? = nil
    ) {
        self.id = id
        self.status = status
        self.version = version
        self.title = title
        self.ownerAgentId = ownerAgentId
        self.fireAt = fireAt
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("reminderId", id)
        body.append("ownerAgentId", optional: ownerAgentId)
        body.append("status", status)
        body.append("version", version)
        body.append("title", title)
        body.append("fireAt", optional: fireAt.map { ISO8601DateFormatter().string(from: $0) })
        return body.json
    }
}

/// `{"reminder": …}`. `ownerAgentId` is the agent the reminder belongs to; it is
/// not printed, the route reads it to publish the realtime event.
public struct ReminderEnvelopeResponse: JSONBodyConvertible, Sendable, Equatable {
    public var reminder: ReminderSummary
    public var ownerAgentId: String

    public init(reminder: ReminderSummary, ownerAgentId: String) {
        self.reminder = reminder
        self.ownerAgentId = ownerAgentId
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("reminder", reminder)])
    }
}

/// `{"reminders": […]}` of summaries.
public struct ReminderSummaryListResponse: JSONBodyConvertible, Sendable, Equatable {
    public var reminders: [ReminderSummary]

    public init(reminders: [ReminderSummary]) {
        self.reminders = reminders
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("reminders", .array(reminders.map(\.jsonBody)))])
    }
}

/// `GET /api/reminders`.
public struct ReminderOwnerListResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var id: String
        public var title: String
        public var ownerAgentId: String
        public var fireAt: Date

        public init(id: String, title: String, ownerAgentId: String, fireAt: Date) {
            self.id = id
            self.title = title
            self.ownerAgentId = ownerAgentId
            self.fireAt = fireAt
        }
    }

    public var reminders: [Item]

    public init(reminders: [Item]) {
        self.reminders = reminders
    }

    public var jsonBody: OrderedJSON {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .object([OrderedJSONField("reminders", .array(reminders.map { item in
            .object([
                OrderedJSONField("id", item.id),
                OrderedJSONField("title", item.title),
                OrderedJSONField("ownerAgentId", item.ownerAgentId),
                OrderedJSONField("fireAt", formatter.string(from: item.fireAt)),
            ])
        }))])
    }
}

/// `GET …/reminders/:id/log`.
public struct ReminderLogResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct Event: Sendable, Equatable {
        public var eventType: String
        public var version: Int

        public init(eventType: String, version: Int) {
            self.eventType = eventType
            self.version = version
        }
    }

    public var events: [Event]

    public init(events: [Event]) {
        self.events = events
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("events", .array(events.map { event in
            .object([
                OrderedJSONField("eventType", event.eventType),
                OrderedJSONField("version", event.version),
            ])
        }))])
    }
}
