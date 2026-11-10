import Foundation

/// Canonical task projection returned by the public task writer. The host
/// message remains an independent chat row linked by messageId.
public struct CanonicalTaskPayload: JSONBodyConvertible, Sendable {
    let projection: TaskReadProjection

    init(_ task: TaskRecord, channelId: String, channelName: String?, channelType: String,
         creatorType: String?, creatorName: String?, creatorMembershipStatus: String? = "active", assigneeName: String? = nil) {
        projection = TaskReadProjection(task, channelId: channelId, channelName: channelName, channelType: channelType,
            creatorType: creatorType, creatorName: creatorName, creatorMembershipStatus: creatorMembershipStatus,
            assigneeName: assigneeName)
    }

    public var id: String { projection.id }
    public var messageId: String { projection.messageId }
    public var jsonBody: OrderedJSON { projection.jsonBody }

    var createdEventBody: OrderedJSON {
        // Node's task-created projector intentionally omits receipt/membership
        // metadata while retaining the full canonical association and text.
        guard case .object(let fields) = jsonBody else { return jsonBody }
        let keys = ["id", "messageId", "channelId", "channelName", "channelType", "taskNumber", "title", "description", "status",
                    "claimedByType", "claimedById", "claimedByName", "claimedAt", "completedAt", "createdByType", "createdById", "createdByName",
                    "createdAt", "updatedAt", "revision", "taskCurrentProjection", "isLegacy"]
        return .object(keys.compactMap { key in fields.first { $0.key == key } })
    }
}

public struct ChannelTasksCreatedResponse: JSONBodyConvertible, Sendable {
    public let tasks: [CanonicalTaskPayload]
    public var jsonBody: OrderedJSON { .object([.init("tasks", .array(tasks.map(\.jsonBody)))]) }
}

public struct CanonicalTaskResponse: JSONBodyConvertible, Sendable {
    public let task: CanonicalTaskPayload
    public var jsonBody: OrderedJSON { .object([.init("task", task.jsonBody)]) }
}

public struct AgentExecutionStopResponse: JSONBodyConvertible, Sendable {
    /// A real stop with a machine target waits for durable dispatch. An owned
    /// unassigned agent has no process to contact and needs only stopped intent.
    public let appliesOnReconnect: Bool

    public init(appliesOnReconnect: Bool = true) { self.appliesOnReconnect = appliesOnReconnect }

    public var jsonBody: OrderedJSON {
        appliesOnReconnect ? .object([.init("ok", true), .init("appliesOnReconnect", true)]) : .object([.init("ok", true)])
    }
}
