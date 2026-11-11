import Foundation

/// One `GET /api/tasks/:taskId/history` event.
///
/// Upstream `taskService.listTaskHistory` maps each `task_events` row in the
/// published member order `id`, `seq`, `eventType`, `actorType`, `actorName`,
/// `payload`, `createdAt`. `actorName` is resolved from the live account/agent
/// row at read time and is `null` for a system event or an unresolvable actor.
public struct TaskHistoryEventDTO: Sendable, Equatable, JSONBodyConvertible {
    public let id: String
    public let seq: Int
    public let eventType: String
    public let actorType: String
    public let actorName: String?
    /// The event-specific payload as retained JSON text. It is inserted raw so
    /// the nested object keeps the recorded member order.
    public let payloadJSON: String
    public let createdAt: String

    public init(id: String, seq: Int, eventType: String, actorType: String,
                actorName: String?, payloadJSON: String, createdAt: String) {
        self.id = id
        self.seq = seq
        self.eventType = eventType
        self.actorType = actorType
        self.actorName = actorName
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("seq", seq),
            OrderedJSONField("eventType", eventType),
            OrderedJSONField("actorType", actorType),
            OrderedJSONField("actorName", optional: actorName),
            OrderedJSONField("payload", .raw(payloadJSON)),
            OrderedJSONField("createdAt", createdAt),
        ])
    }
}

/// The `{events}` body of the task history read.
public struct TaskHistoryResponse: Sendable, Equatable, JSONBodyConvertible {
    public let events: [TaskHistoryEventDTO]

    public init(events: [TaskHistoryEventDTO]) {
        self.events = events
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("events", .array(events.map(\.jsonBody)))])
    }
}
