/// Whether this create call has a scheduled-delivery transport. This is server
/// context, independent of the reminder body and its authorization decisions.
public enum ReminderDeliveryPreparation: Sendable {
    case omit
    case prepare
}

/// A committed reminder response and its optional scheduled notification.
/// Only `response` is an HTTP body; recipient metadata is never serialized there.
public struct ReminderCreateCompletion: Sendable {
    public let response: ReminderEnvelopeResponse
    public let scheduledDelivery: ReminderScheduledDelivery?
}

/// The domain-selected user destinations and the exact scheduled event body.
public struct ReminderScheduledDelivery: Sendable {
    public static let eventName = "reminder:scheduled"
    public let recipientUserIds: Set<String>
    public let payload: ReminderRealtimePayload
}

extension ReminderRealtimePayload: JSONBodyConvertible {
    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("reminderId", reminderId),
            OrderedJSONField("ownerAgentId", ownerAgentId),
        ])
    }
}
