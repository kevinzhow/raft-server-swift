import Foundation
import RaftShared

// MARK: - Request bodies
//
// The retired handlers read these bodies with a raw object cast plus per-field
// `as? String` / `as? Int` / `as? Bool` checks. The decoders below keep that
// tolerance: a value of the wrong JSON type reads as absent, and a body that
// is not a JSON object fails to decode. The feature turns a failed decode into
// the same published 400 the raw parser produced.

/// `POST /internal/agent-api/tasks/delete`
/// (`POST /internal/agent/:agentId/tasks/delete`).
public struct AgentTaskDeleteRequest: Decodable, Sendable, Equatable {
    public var channel: String?
    public var taskNumber: Int?

    public init(channel: String? = nil, taskNumber: Int? = nil) {
        self.channel = channel
        self.taskNumber = taskNumber
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case taskNumber = "task_number"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = (try? container.decode(String.self, forKey: .channel))
        taskNumber = (try? container.decode(Int.self, forKey: .taskNumber))
    }
}

/// `POST /internal/agent-api/tasks/convert`
/// (`POST /internal/agent/:agentId/tasks/convert`).
public struct AgentTaskConvertRequest: Decodable, Sendable, Equatable {
    public var channel: String?
    public var messageId: String?

    public init(channel: String? = nil, messageId: String? = nil) {
        self.channel = channel
        self.messageId = messageId
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case messageId = "message_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = (try? container.decode(String.self, forKey: .channel))
        messageId = (try? container.decode(String.self, forKey: .messageId))
    }
}

/// One `tasks[]` element of `POST /internal/agent-api/tasks`.
///
/// Upstream reads `title` with `as? String ?? ""` and `creates_resource` with
/// `as? Bool == true`, so a wrong-typed value reads as empty/false rather than
/// failing the whole batch. A non-object element fails the array cast, which
/// the request decoder reproduces because it only decodes objects.
public struct AgentTaskCreateItem: Decodable, Sendable, Equatable {
    public var title: String
    public var createsResource: Bool

    public init(title: String = "", createsResource: Bool = false) {
        self.title = title
        self.createsResource = createsResource
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case createsResource = "creates_resource"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        createsResource = ((try? container.decode(Bool.self, forKey: .createsResource)) ?? false) == true
    }
}

/// `POST /internal/agent-api/tasks`.
public struct AgentTaskCreateRequest: Decodable, Sendable, Equatable {
    public var channel: String?
    public var tasks: [AgentTaskCreateItem]
    public var assignee: String?
    public var idempotencyKey: String?
    /// Whether the request carried a `tasks` key at all. The retired parser
    /// required a JSON object for `tasks`; an absent key is the same
    /// 400 as an empty array, but the idempotency check runs before the title
    /// check for an explicit empty array.
    public var hasTasksKey: Bool
    /// Whether the `tasks` value decoded as an array of objects. The retired
    /// parser failed the shape check before the idempotency lookup.
    public var hasValidTasks: Bool

    public init(
        channel: String? = nil,
        tasks: [AgentTaskCreateItem] = [],
        assignee: String? = nil,
        idempotencyKey: String? = nil,
        hasTasksKey: Bool = true,
        hasValidTasks: Bool = true
    ) {
        self.channel = channel
        self.tasks = tasks
        self.assignee = assignee
        self.idempotencyKey = idempotencyKey
        self.hasTasksKey = hasTasksKey
        self.hasValidTasks = hasValidTasks
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case tasks
        case assignee
        case idempotencyKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = (try? container.decode(String.self, forKey: .channel))
        hasTasksKey = container.contains(.tasks)
        let decodedTasks = try? container.decode([AgentTaskCreateItem].self, forKey: .tasks)
        tasks = decodedTasks ?? []
        hasValidTasks = decodedTasks != nil
        assignee = (try? container.decode(String.self, forKey: .assignee))
        idempotencyKey = (try? container.decode(String.self, forKey: .idempotencyKey))
    }
}

/// The `receipt` object of `POST /internal/agent-api/tasks/resource-receipt`.
///
/// Upstream requires a JSON object and reads the seven fields with `as? String`
/// plus a trim and non-empty check. The payload is also stored verbatim as the
/// reminder notes, so the whole object is kept as a `JSONValue` tree.
public struct AgentTaskResourceReceipt: Sendable, Equatable {
    public var object: String
    public var purpose: String
    public var teardownOwner: String
    public var securityPrivacy: String
    public var expiry: String
    public var runbook: String
    public var tracking: String
    /// The complete decoded object, in the request's member order.
    public var payload: JSONValue

    public init(
        object: String,
        purpose: String,
        teardownOwner: String,
        securityPrivacy: String,
        expiry: String,
        runbook: String,
        tracking: String,
        payload: JSONValue = .null
    ) {
        self.object = object
        self.purpose = purpose
        self.teardownOwner = teardownOwner
        self.securityPrivacy = securityPrivacy
        self.expiry = expiry
        self.runbook = runbook
        self.tracking = tracking
        self.payload = payload
    }

    init?(payload: JSONValue) {
        guard case .object(let members) = payload else { return nil }
        func trimmed(_ key: String) -> String? {
            guard case .string(let raw)? = members[key] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let object = trimmed("object"),
              let purpose = trimmed("purpose"),
              let teardownOwner = trimmed("teardown_owner"),
              let securityPrivacy = trimmed("security_privacy"),
              let expiry = members["expiry"], case .string(let expiryRaw) = expiry,
              let runbook = trimmed("runbook"),
              let tracking = trimmed("tracking")
        else { return nil }
        self.object = object
        self.purpose = purpose
        self.teardownOwner = teardownOwner
        self.securityPrivacy = securityPrivacy
        self.expiry = expiryRaw
        self.runbook = runbook
        self.tracking = tracking
        self.payload = payload
    }
}

extension AgentTaskResourceReceipt: Decodable {
    public init(from decoder: any Decoder) throws {
        let payload = try JSONValue(from: decoder)
        guard let receipt = AgentTaskResourceReceipt(payload: payload) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "receipt must be an object with the required string fields"
            ))
        }
        self = receipt
    }
}

/// `POST /internal/agent-api/tasks/resource-receipt`.
public struct AgentTaskResourceReceiptRequest: Decodable, Sendable, Equatable {
    public var channel: String?
    public var taskNumber: Int?
    public var receipt: AgentTaskResourceReceipt?

    public init(
        channel: String? = nil,
        taskNumber: Int? = nil,
        receipt: AgentTaskResourceReceipt? = nil
    ) {
        self.channel = channel
        self.taskNumber = taskNumber
        self.receipt = receipt
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case taskNumber = "task_number"
        case receipt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = (try? container.decode(String.self, forKey: .channel))
        taskNumber = (try? container.decode(Int.self, forKey: .taskNumber))
        // Upstream requires the receipt to be a JSON object; otherwise absent.
        receipt = (try? container.decode(AgentTaskResourceReceipt.self, forKey: .receipt))
    }
}

/// `POST /internal/agent-api/tasks/assign`.
public struct AgentTaskAssignRequest: Decodable, Sendable, Equatable {
    public var channel: String?
    public var taskNumber: Int?
    public var assignee: String?

    public init(channel: String? = nil, taskNumber: Int? = nil, assignee: String? = nil) {
        self.channel = channel
        self.taskNumber = taskNumber
        self.assignee = assignee
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case taskNumber = "task_number"
        case assignee
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = (try? container.decode(String.self, forKey: .channel))
        taskNumber = (try? container.decode(Int.self, forKey: .taskNumber))
        assignee = (try? container.decode(String.self, forKey: .assignee))
    }
}

// MARK: - Response bodies

/// One task row, printed in the retired `taskJSON` member order.
public struct ActionCardTaskPayload: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var messageId: String
    public var title: String
    public var status: String
    public var taskNumber: Int
    public var claimedById: String?
    public var claimedByType: String?
    /// Legacy `taskJSON` prints `ISO8601DateFormatter()` (no fractional part).
    public var claimedAt: String?
    public var revision: Int
    public var requiresResourceReceipt: Bool

    init(_ task: TaskRecord) {
        id = task.id
        channelId = task.channelId
        messageId = task.messageId
        title = task.title
        status = task.status
        taskNumber = task.taskNumber
        claimedById = task.assigneeId
        claimedByType = task.assigneeType
        claimedAt = task.claimedAt.map { ISO8601DateFormatter().string(from: $0) }
        revision = task.revision
        requiresResourceReceipt = task.requiresResourceReceipt
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("channelId", channelId)
        body.append("messageId", messageId)
        body.append("title", title)
        body.append("status", status)
        body.append("taskNumber", taskNumber)
        body.append("claimedById", optional: claimedById)
        body.append("claimedByType", optional: claimedByType)
        body.append("claimedAt", optional: claimedAt)
        body.append("revision", revision)
        body.append("requiresResourceReceipt", ifPresent: requiresResourceReceipt ? true : nil)
        return body.json
    }
}

/// `{"ok":true}` for the task delete route.
public struct ActionCardTaskDeleteResponse: JSONBodyConvertible, Sendable, Equatable {
    public init() {}

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("ok", true)])
    }
}

/// `{"task":{…}}` for the task convert route.
public struct ActionCardTaskConvertResponse: JSONBodyConvertible, Sendable, Equatable {
    public var task: ActionCardTaskPayload

    init(task: TaskRecord) {
        self.task = ActionCardTaskPayload(task)
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("task", task)
        return body.json
    }
}

/// The `assignmentReceipt` member of the task create response.
public struct ActionCardTaskAssignmentReceipt: JSONBodyConvertible, Sendable, Equatable {
    public var messageId: String
    public var content: String
    public var assignee: String
    public var state: String

    init(messageId: String, content: String, assignee: String) {
        self.messageId = messageId
        self.content = content
        self.assignee = assignee
        state = "assigned"
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("messageId", messageId)
        body.append("content", content)
        body.append("assignee", assignee)
        body.append("state", state)
        return body.json
    }
}

/// `POST /internal/agent-api/tasks` success body.
///
/// Member order is the retired literal (`taskIds`, `tasks`,
/// `assignmentReceipt`), so this is an ordered body. `headers` is carried for
/// the idempotent-replay reply, whose legacy header set drops `X-Robots-Tag`;
/// a first write uses `.standard()`.
public struct ActionCardTaskCreateResponse: JSONBodyConvertible, Sendable, Equatable {
    public var taskIds: [String]
    public var tasks: [ActionCardTaskPayload]
    public var assignmentReceipt: ActionCardTaskAssignmentReceipt?
    public var headers: ResponseHeaders

    init(
        taskIds: [String],
        tasks: [TaskRecord],
        assignmentReceipt: ActionCardTaskAssignmentReceipt?,
        headers: ResponseHeaders = .standard()
    ) {
        self.taskIds = taskIds
        self.tasks = tasks.map(ActionCardTaskPayload.init)
        self.assignmentReceipt = assignmentReceipt
        self.headers = headers
    }

    /// The idempotent-replay projection: the stored body is published
    /// unchanged with the legacy `Content-Type` / `Cache-Control` set.
    public init(replayedBody: String) {
        taskIds = []
        tasks = []
        assignmentReceipt = nil
        headers = .exact([
            "Content-Type": AppFallback.jsonContentType,
            "Cache-Control": "no-store",
        ])
        self.replayedBody = replayedBody
    }

    private var replayedBody: String?

    public var jsonBody: OrderedJSON {
        if let replayedBody { return .raw(replayedBody) }
        var body = OrderedJSONObject()
        body.append("taskIds", .array(taskIds.map(OrderedJSON.string)))
        body.append("tasks", .array(tasks.map(\.jsonBody)))
        body.append("assignmentReceipt", .bodyOrNull(assignmentReceipt))
        return body.json
    }
}

/// The `expiryFollowup` object of the resource-receipt response.
public struct ActionCardTaskExpiryFollowup: JSONBodyConvertible, Sendable, Equatable {
    public var ownerAgentId: String
    public var owner: String
    public var msgId: String
    public var targetChannelId: String
    public var reminderId: String
    public var fireAt: String

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ownerAgentId", ownerAgentId)
        body.append("owner", owner)
        body.append("msgId", msgId)
        body.append("targetChannelId", targetChannelId)
        body.append("reminderId", reminderId)
        body.append("fireAt", fireAt)
        return body.json
    }
}

/// `POST /internal/agent-api/tasks/resource-receipt` success body.
public struct ActionCardTaskResourceReceiptResponse: JSONBodyConvertible, Sendable, Equatable {
    public var taskNumber: Int
    public var expiryFollowup: ActionCardTaskExpiryFollowup

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("taskNumber", taskNumber)
        body.append("expiryFollowup", expiryFollowup)
        return body.json
    }
}

/// One `items[]` row of `GET /internal/agent-api/inbox/conversations`.
public struct ActionCardInboxItem: JSONBodyConvertible, Sendable, Equatable {
    public var target: String
    public var kind: String
    public var unread: Int
    public var mentions: Int
    public var lastReadSeq: Int
    public var activitySeq: Int
    public var latestSenderName: String
    /// `isoMillis`-formatted timestamp, or JSON null.
    public var latestAt: String?

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("target", target)
        body.append("kind", kind)
        body.append("unread", unread)
        body.append("mentions", mentions)
        body.append("lastReadSeq", lastReadSeq)
        body.append("activitySeq", activitySeq)
        body.append("latestSenderName", latestSenderName)
        body.append("latestAt", optional: latestAt)
        return body.json
    }
}

/// `GET /internal/agent-api/inbox/conversations` success body.
public struct ActionCardInboxResponse: JSONBodyConvertible, Sendable, Equatable {
    public var view: String
    public var items: [ActionCardInboxItem]
    public var conversations: Int
    public var dms: Int
    public var mentionConversations: Int
    public var hasMore: Bool
    public var nextBeforeSeq: Int?

    public var jsonBody: OrderedJSON {
        var totals = OrderedJSONObject()
        totals.append("conversations", conversations)
        totals.append("dms", dms)
        totals.append("mentions", mentionConversations)
        var body = OrderedJSONObject()
        body.append("view", view)
        body.append("items", .array(items.map(\.jsonBody)))
        body.append("totals", totals.json)
        body.append("hasMore", hasMore)
        body.append("nextBeforeSeq", optional: nextBeforeSeq)
        return body.json
    }
}
