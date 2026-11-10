import Foundation

/// A committed publication may be delivered more than once. Clients reconcile
/// messages/tasks by their canonical IDs; eventId identifies the outbox intent.
public struct RealtimePublication: Codable, Sendable, Equatable {
    public let codec: String
    public let eventId: UUID
    public let room: String
    public let event: String
    public let payloadJSON: String

    public init(eventId: UUID, room: String, event: String, payloadJSON: String) {
        codec = "raft-realtime-publication-v1"
        self.eventId = eventId
        self.room = room
        self.event = event
        self.payloadJSON = payloadJSON
    }
}
