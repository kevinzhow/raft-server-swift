import Foundation

/// Typed JSON codec for realtime event payloads.
///
/// Every helper is `JSONEncoder`/`JSONDecoder` backed: no `JSONSerialization`,
/// no `try!`, and no serialize → string → parse round trip. The route features
/// call these helpers with the `HTTPReply` body they already own, so the frame
/// shape lives in `RealtimeEventDTO` and not in spliced string literals.
public enum ChannelMessagingService {
    // MARK: - Primitive codec

    /// Deterministic key order keeps an emitted frame stable across processes.
    public static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: String) -> T? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// JSON string literal for one value, used only where a payload embeds a
    /// document verbatim (the reply body itself is already canonical JSON).
    public static func jsonString(_ value: String) -> String? {
        encode(value)
    }

    // MARK: - Realtime events

    /// `thread:followers-updated` for one thread channel. The thread id is both
    /// the room suffix and the payload field, so both are returned together.
    public struct ThreadFollowersUpdatedEvent: Sendable, Equatable {
        public let threadChannelId: String
        public let payloadJSON: String
    }

    /// `channel:updated` for one created channel.
    public struct ChannelUpdatedEvent: Sendable, Equatable {
        public let channelId: String
        public let payloadJSON: String
    }

    /// `task:created` for one channel.
    public struct TaskCreatedEvent: Sendable, Equatable {
        public let channelId: String
        public let payloadJSON: String
    }

    /// `task:updated` for one channel.
    public struct TaskUpdatedEvent: Sendable, Equatable {
        public let channelId: String
        public let payloadJSON: String
    }

    public static func threadFollowersUpdatedEvent(fromBody body: String) -> ThreadFollowersUpdatedEvent? {
        guard let payload = decode(ThreadFollowersUpdatedPayload.self, from: body),
              !payload.threadChannelId.isEmpty,
              let payloadJSON = encode(payload)
        else { return nil }
        return ThreadFollowersUpdatedEvent(
            threadChannelId: payload.threadChannelId,
            payloadJSON: payloadJSON
        )
    }

    /// A `POST /api/channels` reply omits the description even though it stores
    /// one, and the frame always reports `joined: true`.
    private struct CreatedChannelProjection: Decodable {
        let id: String
        let name: String
        let description: String?
    }

    public static func channelUpdatedEvent(fromReplyBody body: String) -> ChannelUpdatedEvent? {
        guard let created = decode(CreatedChannelProjection.self, from: body) else { return nil }
        let summary = CreatedChannelSummaryDTO(
            id: created.id,
            name: created.name,
            description: created.description,
            joined: true
        )
        guard let payloadJSON = encode(ChannelUpdatedPayload(channel: summary)) else { return nil }
        return ChannelUpdatedEvent(channelId: created.id, payloadJSON: payloadJSON)
    }

    private struct TasksCreatedReply: Decodable {
        let taskIds: [String]
    }

    private struct TaskCreateRequest: Decodable {
        let tasks: [TaskDraft]
    }

    private struct TaskDraft: Decodable {
        let title: String?
    }

    /// The create reply only carries ids; titles come from the request body.
    /// Rows without a title are skipped, matching the upstream `compactMap`.
    public static func taskCreatedEvent(
        replyBody: String,
        requestBody: String,
        channelId: String
    ) -> TaskCreatedEvent? {
        guard let reply = decode(TasksCreatedReply.self, from: replyBody),
              let request = decode(TaskCreateRequest.self, from: requestBody)
        else { return nil }
        let titles = request.tasks.compactMap(\.title)
        let items = zip(reply.taskIds, titles).map { id, title in
            TaskCreatedItemDTO(id: id, channelId: channelId, title: title, status: "todo")
        }
        guard let payloadJSON = encode(TaskCreatedPayload(channelId: channelId, tasks: items)) else {
            return nil
        }
        return TaskCreatedEvent(channelId: channelId, payloadJSON: payloadJSON)
    }

    private struct TaskChannelProjection: Decodable {
        let channelId: String
    }

    public static func taskUpdatedEvent(fromReplyBody body: String) -> TaskUpdatedEvent? {
        guard let task = decode(TaskChannelProjection.self, from: body),
              let channelIdJSON = jsonString(task.channelId)
        else { return nil }
        // The reply body is already the canonical task projection. Splice it
        // whole so the frame keeps every field the HTTP body carries instead of
        // re-encoding a narrower DTO.
        return TaskUpdatedEvent(
            channelId: task.channelId,
            payloadJSON: "{\"channelId\":\(channelIdJSON),\"task\":\(body)}"
        )
    }

    public static func reminderPayload(reminderId: String, ownerAgentId: String) -> String? {
        encode(ReminderRealtimePayload(reminderId: reminderId, ownerAgentId: ownerAgentId))
    }

    public static func errorPayload(_ error: String, code: String? = nil) -> String? {
        encode(APIErrorDTO(error: error, code: code))
    }
}
