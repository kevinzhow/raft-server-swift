import Foundation

/// Realtime frame sink injected into `ChannelMessagingService`.
///
/// The service decides *what* frame to publish; the feature layer owns the two
/// transports that already exist: the directory's room emitter and the
/// `RealtimeHub` used for user-scoped `channel:updated` notifications. Both are
/// passed as closures so this file never imports Vapor or `RaftRealtime`.
public struct ChannelRealtimeSink: Sendable {
    /// `(room, event, payloadJSON)` for one channel room.
    public var emit: @Sendable (String, String, String) -> Void
    /// One user's live sessions receive `channel:updated`.
    public var emitToUser: @Sendable (String, String, String) -> Void
    /// Grant the room to every live session of one user before emitting.
    public var joinUserSessions: @Sendable (String, String) -> Void

    public init(
        emit: @escaping @Sendable (String, String, String) -> Void = { _, _, _ in },
        emitToUser: @escaping @Sendable (String, String, String) -> Void = { _, _, _ in },
        joinUserSessions: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) {
        self.emit = emit
        self.emitToUser = emitToUser
        self.joinUserSessions = joinUserSessions
    }

    /// No socket attached (unit tests and the database-less startup).
    public static let disabled = ChannelRealtimeSink()
}

/// Domain failure for the channel-messaging task operation. The feature layer
/// owns the wire encoding; this type owns the status, published message and the
/// optional machine-readable code.
public enum ChannelMessagingError: DomainError, Equatable {
    case unauthorized
    case notServerMember
    case channelNotFound
    case channelReadOnly
    case channelArchived
    case invalidTaskList

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .notServerMember, .channelReadOnly:
            403
        case .channelNotFound:
            404
        case .channelArchived:
            409
        case .invalidTaskList:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .notServerMember:
            "Not a member of this server"
        case .channelNotFound:
            "Channel not found"
        case .channelReadOnly:
            "Join the channel to change tasks"
        case .channelArchived:
            "This channel is archived"
        case .invalidTaskList:
            "Invalid task list"
        }
    }

    /// Only the archived reply publishes a `code` beside `error`.
    public var errorCode: String? {
        switch self {
        case .channelArchived:
            "channel_archived"
        case .unauthorized, .notServerMember, .channelNotFound, .channelReadOnly, .invalidTaskList:
            nil
        }
    }
}

/// The channel-task access decision the messaging operation needs. It mirrors
/// the directory's internal `TaskChannelAccess` so the service can receive the
/// answer through a closure without owning the channel policy yet.
public enum ChannelTaskAccess: Sendable, Equatable {
    case missing
    case readOnly
    case write
}

/// Directory-backed operations the task-create route still calls in their
/// not-yet-migrated domain. The feature wires them at the composition root, so
/// this service owns no directory state and no directory call site.
public struct ChannelMessagingDependencies: Sendable {
    public var sessionUserId: @Sendable (String?) -> String?
    public var memberRole: @Sendable (_ serverId: String, _ userId: String) -> String?
    public var taskChannelAccess: @Sendable (
        _ serverId: String,
        _ channelId: String,
        _ userId: String
    ) -> ChannelTaskAccess
    public var isChannelArchived: @Sendable (_ channelId: String) -> Bool
    public var addTasks: @Sendable (
        _ channelId: String,
        _ titles: [String],
        _ descriptions: [String?]?,
        _ creatorId: String?
    ) -> [String]

    public init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        memberRole: @escaping @Sendable (String, String) -> String?,
        taskChannelAccess: @escaping @Sendable (String, String, String) -> ChannelTaskAccess,
        isChannelArchived: @escaping @Sendable (String) -> Bool,
        addTasks: @escaping @Sendable (String, [String], [String?]?, String?) -> [String]
    ) {
        self.sessionUserId = sessionUserId
        self.memberRole = memberRole
        self.taskChannelAccess = taskChannelAccess
        self.isChannelArchived = isChannelArchived
        self.addTasks = addTasks
    }
}

/// Channel-messaging orchestration: the `task:created` operation plus the
/// realtime publication that the channel and task routes emit.
///
/// `createChannelTasks` is the typed replacement for the
/// `EmailLoginDirectory.createChannelTasks` extension handler: it keeps the
/// upstream authorization order (401 before any policy read, then 403/404,
/// the archived gate, and only then body validation), hands the store one
/// append operation, and publishes `task:created` from typed values.
///
/// The three `publish…` entry points own the frame guards that used to live in
/// `ChannelsFeature`/`MessagingFeature`. They accept the already-built HTTP
/// reply status and body, so this file never sees a reply value.
public struct ChannelMessagingService: Sendable {
    private let dependencies: ChannelMessagingDependencies
    private let sink: ChannelRealtimeSink

    public init(
        dependencies: ChannelMessagingDependencies,
        sink: ChannelRealtimeSink = .disabled
    ) {
        self.dependencies = dependencies
        self.sink = sink
    }

    // MARK: - POST /api/tasks/channel/:channelId

    /// Creates the posted task batch and publishes `task:created`.
    ///
    /// The reply is `{"taskIds":[…]}`; every refusal is a typed
    /// `ChannelMessagingError` that `respond` renders with the bytes the old
    /// `Self.json` helper produced.
    public func createChannelTasks(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: String
    ) throws -> TaskIDsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ChannelMessagingError.unauthorized
        }
        guard dependencies.memberRole(serverId, userId) != nil else {
            throw ChannelMessagingError.notServerMember
        }
        switch dependencies.taskChannelAccess(serverId, channelId, userId) {
        case .missing:
            throw ChannelMessagingError.channelNotFound
        case .readOnly:
            throw ChannelMessagingError.channelReadOnly
        case .write:
            break
        }
        guard !dependencies.isChannelArchived(channelId) else {
            throw ChannelMessagingError.channelArchived
        }
        guard let request = Self.decode(CreateChannelTasksRequest.self, from: body), !request.tasks.isEmpty else {
            throw ChannelMessagingError.invalidTaskList
        }
        let titles = request.tasks.compactMap(\.title).filter { !$0.isEmpty }
        let descriptions = request.tasks.map(\.description)
        let taskIds = dependencies.addTasks(channelId, titles, descriptions, userId)
        publishTaskCreated(taskIds: taskIds, requestBody: body, channelId: channelId)
        return TaskIDsResponse(taskIds: taskIds)
    }

    // MARK: - Realtime publication for routes that keep their HTTP reply

    /// `POST /api/channels`: grant the creator's sessions the new channel room
    /// and publish `channel:updated` to each of them.
    public func publishCreatedChannel(status: Int, replyBody: String, authorization: String?) {
        guard status == 200,
              let userId = dependencies.sessionUserId(authorization),
              let event = Self.channelUpdatedEvent(fromReplyBody: replyBody)
        else { return }
        sink.joinUserSessions(userId, "channel:\(event.channelId)")
        sink.emitToUser(userId, "channel:updated", event.payloadJSON)
    }

    /// `PATCH /api/tasks/:taskId/claim`: publish `task:updated` for the task's
    /// channel.
    public func publishTaskUpdated(status: Int, replyBody: String) {
        guard status == 200, let event = Self.taskUpdatedEvent(fromReplyBody: replyBody) else { return }
        sink.emit("channel:\(event.channelId)", "task:updated", event.payloadJSON)
    }

    /// `POST /api/channels/threads/follow|unfollow`: publish
    /// `thread:followers-updated` for the thread channel.
    ///
    /// The thread service owns the resolved mutation and publishes only after a
    /// successful write, so this entry point takes the typed payload the frame
    /// already carries instead of re-decoding a reply body.
    public func publishThreadFollowers(_ payload: ThreadFollowersUpdatedPayload) {
        guard !payload.threadChannelId.isEmpty,
              let payloadJSON = Self.encode(payload) else { return }
        sink.emit("channel:\(payload.threadChannelId)", "thread:followers-updated", payloadJSON)
    }

    private func publishTaskCreated(taskIds: [String], requestBody: String, channelId: String) {
        // The event projection reads titles from the request with the strict
        // decoder the old helper used: a body the encoder could not decode
        // emits no frame even though the write already succeeded.
        guard let request = Self.decode(TaskCreatedEventRequest.self, from: requestBody) else { return }
        let titles = request.tasks.compactMap(\.title)
        let items = zip(taskIds, titles).map { id, title in
            TaskCreatedItemDTO(id: id, channelId: channelId, title: title, status: "todo")
        }
        guard let payloadJSON = Self.encode(TaskCreatedPayload(channelId: channelId, tasks: items)) else {
            return
        }
        sink.emit("channel:\(channelId)", "task:created", payloadJSON)
    }

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

    /// `channel:updated` for one created channel.
    private struct ChannelUpdatedEvent: Sendable, Equatable {
        let channelId: String
        let payloadJSON: String
    }

    /// `task:updated` for one channel.
    private struct TaskUpdatedEvent: Sendable, Equatable {
        let channelId: String
        let payloadJSON: String
    }

    /// A `POST /api/channels` reply omits the description even though it stores
    /// one, and the frame always reports `joined: true`.
    private struct CreatedChannelProjection: Decodable {
        let id: String
        let name: String
        let description: String?
    }

    private static func channelUpdatedEvent(fromReplyBody body: String) -> ChannelUpdatedEvent? {
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

    /// The create reply only carries ids; titles come from the request body.
    /// Rows without a title are skipped, matching the upstream `compactMap`.
    private struct TaskCreatedEventRequest: Decodable {
        struct Draft: Decodable {
            let title: String?
        }

        let tasks: [Draft]
    }

    private struct TaskChannelProjection: Decodable {
        let channelId: String
    }

    private static func taskUpdatedEvent(fromReplyBody body: String) -> TaskUpdatedEvent? {
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
