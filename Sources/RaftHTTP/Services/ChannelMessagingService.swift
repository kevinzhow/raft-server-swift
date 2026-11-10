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
    case tooManyTasks
    case emptyTaskTitle
    case threadTasksUnsupported

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .notServerMember, .channelReadOnly:
            403
        case .channelNotFound:
            404
        case .channelArchived, .threadTasksUnsupported:
            409
        case .invalidTaskList, .tooManyTasks, .emptyTaskTitle:
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
            "You must join this channel to modify tasks"
        case .channelArchived:
            "This channel is archived"
        case .invalidTaskList:
            "tasks array is required"
        case .tooManyTasks:
            "Cannot create more than 50 tasks at once"
        case .emptyTaskTitle:
            "Each task must have a non-empty title"
        case .threadTasksUnsupported:
            "Thread messages cannot become tasks"
        }
    }

    /// Only the archived reply publishes a `code` beside `error`.
    public var errorCode: String? {
        switch self {
        case .channelArchived:
            "channel_archived"
        case .unauthorized, .notServerMember, .channelNotFound, .channelReadOnly, .invalidTaskList, .tooManyTasks, .emptyTaskTitle, .threadTasksUnsupported:
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

/// Domain operations used by task creation, bound to their concrete owners.
/// The adapter keeps authorization and archive decisions out of composition.
public struct ChannelMessagingDependencies: Sendable {
    public var sessionUserId: @Sendable (String?) -> String?
    public var memberRole: @Sendable (_ serverId: String, _ userId: String) -> String?
    public var taskChannelAccess: @Sendable (
        _ serverId: String,
        _ channelId: String,
        _ userId: String
    ) -> ChannelTaskAccess
    public var isChannelArchived: @Sendable (_ channelId: String) -> Bool
    var isThread: @Sendable (String) -> Bool
    var createCanonicalTasks: @Sendable (String, String, String, [TaskDraft]) throws -> TaskExecutionCreatedBatch

    /// Retain the concrete catalog's operations and its original owners.
    public init(auth: AuthCoreService, oauth: OAuthLedger, catalog: TaskCatalogService) {
        sessionUserId = { try? auth.authenticate($0) }
        memberRole = { oauth.activeRegularServerMember(serverId: $0, userId: $1) ? oauth.memberRole(serverId: $0, userId: $1) : nil }
        taskChannelAccess = { catalog.channelTaskAccess(serverId: $0, channelId: $1, userId: $2) }
        isChannelArchived = { oauth.channelArchivedAt(id: $0) != nil }
        isThread = { catalog.isThread(channelId: $0) }
        createCanonicalTasks = { try catalog.createCanonicalTasks(serverId: $0, channelId: $1, creatorId: $2, drafts: $3) }
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

    /// Derive the user transport for one Fallback value while preserving the
    /// domain operations and the general relay. The base and other copies keep
    /// their original user bindings; no transport is installed into shared state.
    public func bindingUserDelivery(
        emitToUser: @escaping @Sendable (String, String, String) -> Void,
        joinUserSessions: @escaping @Sendable (String, String) -> Void
    ) -> Self {
        Self(
            dependencies: dependencies,
            sink: ChannelRealtimeSink(
                emit: sink.emit, emitToUser: emitToUser, joinUserSessions: joinUserSessions
            )
        )
    }

    // MARK: - POST /api/tasks/channel/:channelId

    /// Create canonical tasks, their host messages and the persisted summary.
    /// The public response is the Node `{tasks}` projection.
    public func createChannelTasks(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: String
    ) throws -> ChannelTasksCreatedResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ChannelMessagingError.unauthorized
        }
        guard !serverId.isEmpty else { throw MessageSendError.missingServerId }
        guard dependencies.memberRole(serverId, userId) != nil else {
            throw ChannelMessagingError.notServerMember
        }
        if dependencies.isThread(channelId) { throw ChannelMessagingError.threadTasksUnsupported }
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
        guard request.tasks.count <= 50 else { throw ChannelMessagingError.tooManyTasks }
        guard request.tasks.allSatisfy({ !($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ChannelMessagingError.emptyTaskTitle
        }
        let drafts = request.tasks.map { TaskDraft(title: $0.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   description: $0.description?.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let batch = try dependencies.createCanonicalTasks(serverId, channelId, userId, drafts)
        for surface in batch.surfaces {
            for stored in batch.messages where stored.messageType != "system" {
                var projected = stored
                projected.channelId = surface.channelId
                try AgentExecutionPublication.publish(room: "channel:\(surface.channelId)", event: "message:new", identity: stored.id,
                    payloadJSON: AgentExecutionPublication.messagePayload(projected, senderName: batch.creatorName), emit: sink.emit)
            }
            let taskPayload = OrderedJSON.object([.init("channelId", surface.channelId),
                                                  .init("tasks", .array(batch.project(to: surface).map(\.createdEventBody)))])
            try AgentExecutionPublication.publish(room: "channel:\(surface.channelId)", event: "task:created",
                identity: batch.tasks.map(\.id).joined(separator: ","), payloadJSON: taskPayload.render(), emit: sink.emit)
            for stored in batch.messages where stored.messageType == "system" {
                var projected = stored
                projected.channelId = surface.channelId
                try AgentExecutionPublication.publish(room: "channel:\(surface.channelId)", event: "message:new", identity: stored.id,
                    payloadJSON: AgentExecutionPublication.systemMessagePayload(projected, channelType: surface.type), emit: sink.emit)
            }
        }
        let local = batch.surfaces.first { $0.channelId == channelId }
            ?? TaskExecutionSurface(channelId: channelId, serverId: serverId, name: nil, type: "channel")
        return ChannelTasksCreatedResponse(tasks: batch.project(to: local))
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

    /// A committed assignment has already passed its mutation guards. Keep the
    /// successful reply convention in the publisher instead of the HTTP Feature.
    public func publishCommittedTaskUpdated(_ json: String) {
        publishTaskUpdated(status: 200, replyBody: json)
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
