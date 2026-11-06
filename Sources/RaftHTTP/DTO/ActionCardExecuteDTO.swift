import Foundation
import RaftShared

// MARK: - Agent task request bodies

/// `POST /internal/agent-api/tasks/claim` and the internal-admin claim route.
///
/// The legacy raw-JSON parser read the body and every field
/// independently: a value of the wrong type was ignored, a non-array
/// `task_numbers`/`message_ids` became an empty list, and only `channel` is
/// required. Decoding keeps that leniency per field so a body the old parser
/// accepted still reaches the same decision.
public struct AgentTaskClaimRequest: Decodable, Sendable, Equatable {
    public var channel: String?
    public var taskNumbers: [Int]
    public var messageIds: [String]
    public var seenUpToSeq: Int?

    public init(
        channel: String? = nil,
        taskNumbers: [Int] = [],
        messageIds: [String] = [],
        seenUpToSeq: Int? = nil
    ) {
        self.channel = channel
        self.taskNumbers = taskNumbers
        self.messageIds = messageIds
        self.seenUpToSeq = seenUpToSeq
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case taskNumbers = "task_numbers"
        case messageIds = "message_ids"
        case seenUpToSeq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = try? container.decodeIfPresent(String.self, forKey: .channel)
        taskNumbers = Self.integers(try? container.decode([JSONValue].self, forKey: .taskNumbers))
        messageIds = Self.strings(try? container.decode([JSONValue].self, forKey: .messageIds))
        seenUpToSeq = Self.integer(try? container.decode(JSONValue.self, forKey: .seenUpToSeq))
    }

    /// The legacy `compactMap { $0 as? Int }`: only integral JSON numbers count.
    static func integers(_ values: [JSONValue]?) -> [Int] {
        (values ?? []).compactMap { value in
            switch value {
            case .integer(let number):
                return Int(exactly: number)
            case .number(let number):
                return number.isFinite && number.rounded() == number
                    ? Int(exactly: number)
                    : nil
            case .object, .array, .string, .bool, .null:
                return nil
            }
        }
    }

    static func strings(_ values: [JSONValue]?) -> [String] {
        (values ?? []).compactMap { value in
            if case .string(let string) = value { return string }
            return nil
        }
    }

    static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .integer(let number):
            return Int(exactly: number)
        case .number(let number):
            return number.isFinite && number.rounded() == number ? Int(exactly: number) : nil
        case .object, .array, .string, .bool, .null, .none:
            return nil
        }
    }
}

/// `POST /internal/agent-api/tasks/update-status` and the internal-admin
/// update-status route.
///
/// Same per-field leniency as the claim body: `channel`, `task_number` and
/// `status` are required, `seenUpToSeq` is optional, and a wrongly typed value
/// is ignored instead of failing the decode.
public struct AgentTaskStatusUpdateRequest: Decodable, Sendable, Equatable {
    public var channel: String?
    public var taskNumber: Int?
    public var status: String?
    public var seenUpToSeq: Int?

    public init(
        channel: String? = nil,
        taskNumber: Int? = nil,
        status: String? = nil,
        seenUpToSeq: Int? = nil
    ) {
        self.channel = channel
        self.taskNumber = taskNumber
        self.status = status
        self.seenUpToSeq = seenUpToSeq
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case taskNumber = "task_number"
        case status
        case seenUpToSeq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = try? container.decodeIfPresent(String.self, forKey: .channel)
        taskNumber = AgentTaskClaimRequest.integer(
            try? container.decode(JSONValue.self, forKey: .taskNumber)
        )
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        seenUpToSeq = AgentTaskClaimRequest.integer(
            try? container.decode(JSONValue.self, forKey: .seenUpToSeq)
        )
    }
}

// MARK: - Agent task responses

/// `GET /internal/agent-api/tasks` success body.
public struct AgentTasksListResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct Task: Sendable, Equatable {
        public var id: String
        public var channelId: String
        public var title: String
        public var status: String
        public var taskNumber: Int

        public init(id: String, channelId: String, title: String, status: String, taskNumber: Int) {
            self.id = id
            self.channelId = channelId
            self.title = title
            self.status = status
            self.taskNumber = taskNumber
        }
    }

    public var tasks: [Task]

    public init(tasks: [Task]) {
        self.tasks = tasks
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("tasks", .array(tasks.map { task in
                .object([
                    OrderedJSONField("id", task.id),
                    OrderedJSONField("channelId", task.channelId),
                    OrderedJSONField("title", task.title),
                    OrderedJSONField("status", task.status),
                    OrderedJSONField("taskNumber", task.taskNumber),
                ])
            })),
        ])
    }
}

/// One `results` member of the claim reply.
///
/// The legacy handler built each member with a fixed key order; the cases keep
/// that order and the exact published text.
public enum AgentTaskClaimResult: Sendable, Equatable {
    case taskNotFound(taskNumber: Int)
    case taskUnavailable(taskNumber: Int)
    case alreadyClaimedByYou(taskNumber: Int)
    case alreadyClaimed(taskNumber: Int)
    case claimed(taskNumber: Int, messageId: String)
    case messageNotFound(prefix: String)
    case messageAlreadyClaimedByYou(messageId: String, taskNumber: Int)
    case messageAlreadyClaimed(messageId: String, taskNumber: Int)
    case claimedMessage(messageId: String, taskNumber: Int)

    public var json: OrderedJSON {
        switch self {
        case .taskNotFound(let taskNumber):
            return .object([
                OrderedJSONField("taskNumber", taskNumber),
                OrderedJSONField("success", false),
                OrderedJSONField("reason", "not found"),
            ])
        case .taskUnavailable(let taskNumber):
            return .object([
                OrderedJSONField("taskNumber", taskNumber),
                OrderedJSONField("success", false),
                OrderedJSONField("reason", "task not found"),
            ])
        case .alreadyClaimedByYou(let taskNumber):
            return .object([
                OrderedJSONField("taskNumber", taskNumber),
                OrderedJSONField("success", false),
                OrderedJSONField("reason", "already claimed by you"),
            ])
        case .alreadyClaimed(let taskNumber):
            return .object([
                OrderedJSONField("taskNumber", taskNumber),
                OrderedJSONField("success", false),
                OrderedJSONField("reason", "already claimed"),
            ])
        case .claimed(let taskNumber, let messageId):
            return .object([
                OrderedJSONField("taskNumber", taskNumber),
                OrderedJSONField("messageId", messageId),
                OrderedJSONField("success", true),
            ])
        case .messageNotFound(let prefix):
            return .object([
                OrderedJSONField("messageId", prefix),
                OrderedJSONField("success", false),
                OrderedJSONField("reason", "not found"),
            ])
        case .messageAlreadyClaimedByYou(let messageId, let taskNumber):
            return .object([
                OrderedJSONField("messageId", messageId),
                OrderedJSONField("success", false),
                OrderedJSONField("reason", "already claimed by you"),
                OrderedJSONField("taskNumber", taskNumber),
            ])
        case .messageAlreadyClaimed(let messageId, let taskNumber):
            return .object([
                OrderedJSONField("messageId", messageId),
                OrderedJSONField("success", false),
                OrderedJSONField("reason", "already claimed"),
                OrderedJSONField("taskNumber", taskNumber),
            ])
        case .claimedMessage(let messageId, let taskNumber):
            return .object([
                OrderedJSONField("messageId", messageId),
                OrderedJSONField("success", true),
                OrderedJSONField("taskNumber", taskNumber),
            ])
        }
    }
}

/// `POST .../tasks/claim` success body.
public struct AgentTaskClaimResponse: JSONBodyConvertible, Sendable, Equatable {
    public var results: [AgentTaskClaimResult]

    public init(results: [AgentTaskClaimResult]) {
        self.results = results
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("results", .array(results.map(\.json)))])
    }
}

/// The task object `POST .../tasks/update-status` publishes.
public struct AgentTaskDetail: Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var messageId: String
    public var title: String
    public var status: String
    public var taskNumber: Int
    public var claimedById: String?
    public var claimedByType: String?
    public var claimedAt: String?
    public var revision: Int
    public var requiresResourceReceipt: Bool

    public init(
        id: String,
        channelId: String,
        messageId: String,
        title: String,
        status: String,
        taskNumber: Int,
        claimedById: String?,
        claimedByType: String?,
        claimedAt: String?,
        revision: Int,
        requiresResourceReceipt: Bool
    ) {
        self.id = id
        self.channelId = channelId
        self.messageId = messageId
        self.title = title
        self.status = status
        self.taskNumber = taskNumber
        self.claimedById = claimedById
        self.claimedByType = claimedByType
        self.claimedAt = claimedAt
        self.revision = revision
        self.requiresResourceReceipt = requiresResourceReceipt
    }

    public var json: OrderedJSON {
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
        if requiresResourceReceipt {
            body.append("requiresResourceReceipt", true)
        }
        return body.json
    }
}

/// `POST .../tasks/update-status` success body.
public struct AgentTaskStatusUpdateResponse: JSONBodyConvertible, Sendable, Equatable {
    public var task: AgentTaskDetail

    public init(task: AgentTaskDetail) {
        self.task = task
    }

    public var jsonBody: OrderedJSON { task.json }
}

/// One held message in the task-write freshness gate.
public struct AgentTaskHeldMessage: Sendable, Equatable {
    public var id: String
    public var seq: Int
    public var content: String
    public var senderId: String
    public var createdAt: String

    public init(id: String, seq: Int, content: String, senderId: String, createdAt: String) {
        self.id = id
        self.seq = seq
        self.content = content
        self.senderId = senderId
        self.createdAt = createdAt
    }

    public var json: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("seq", seq),
            OrderedJSONField("content", content),
            OrderedJSONField("senderId", senderId),
            OrderedJSONField("createdAt", createdAt),
        ])
    }
}

/// The task-write freshness `held` body.
public struct AgentTaskWriteHoldResponse: JSONBodyConvertible, Sendable, Equatable {
    public var heldMessages: [AgentTaskHeldMessage]
    public var newMessageCount: Int
    public var seenUpToSeq: Int

    public init(heldMessages: [AgentTaskHeldMessage], newMessageCount: Int, seenUpToSeq: Int) {
        self.heldMessages = heldMessages
        self.newMessageCount = newMessageCount
        self.seenUpToSeq = seenUpToSeq
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("state", "held")
        body.append("outcome", "held")
        body.append("subtype", "freshness")
        body.append("reason", "newer_messages_available")
        body.append("decision", "syncing_hold")
        body.append("available_actions", .array([.string("check_messages"), .string("retry_action")]))
        body.append("heldMessages", .array(heldMessages.map(\.json)))
        body.append("newMessageCount", newMessageCount)
        body.append("seenUpToSeq", seenUpToSeq)
        return body.json
    }
}

// MARK: - Operation outcomes

/// A claim either lands on the task ledger or is stopped by the freshness gate.
public enum AgentTaskClaimOutcome: JSONBodyConvertible, Sendable, Equatable {
    case claimed(AgentTaskClaimResponse)
    case held(AgentTaskWriteHoldResponse)

    public var jsonBody: OrderedJSON {
        switch self {
        case .claimed(let response): response.jsonBody
        case .held(let response): response.jsonBody
        }
    }
}

/// A status write either lands on the task ledger or is stopped by the
/// freshness gate.
public enum AgentTaskStatusUpdateOutcome: JSONBodyConvertible, Sendable, Equatable {
    case updated(AgentTaskStatusUpdateResponse)
    case held(AgentTaskWriteHoldResponse)

    public var jsonBody: OrderedJSON {
        switch self {
        case .updated(let response): response.jsonBody
        case .held(let response): response.jsonBody
        }
    }
}

// MARK: - Agent send request body

/// `POST /internal/agent-api/send` and `/internal/agent-api/v2/send`.
///
/// The legacy raw-JSON parser read the body and every field on
/// its own: a missing `target` is the published 400, a missing `content` is an
/// empty string, a non-array `attachmentIds` is the per-entry refusal, and a
/// value of the wrong type for an optional field is ignored. Decoding keeps
/// that leniency per field. `mentions` keeps only objects that carry string
/// `type`, `id` and `name`, exactly like the old `mentionInputs` helper.
public struct AgentSendMessageRequest: Decodable, Sendable {
    public var target: String?
    public var content: String?
    public var sendDraft: Bool
    public var continueAnyway: Bool
    public var continueFlag: Bool
    public var reconcileOnly: Bool
    /// `nil` when the key is absent; `.null` when it is a JSON null. Any other
    /// value is validated by the service so the legacy per-entry 400 survives.
    public var attachmentIds: JSONValue?
    public var idempotencyKey: String
    public var seenUpToSeq: Double?
    public var freshnessContextMode: String?
    public var draftReholdCount: Int?
    public var draftReplacedExisting: Bool
    public var seenExactSeqs: [JSONValue]
    public var seenCards: JSONValue?
    var mentions: [MentionInput]

    init(
        target: String? = nil,
        content: String? = nil,
        sendDraft: Bool = false,
        continueAnyway: Bool = false,
        continueFlag: Bool = false,
        reconcileOnly: Bool = false,
        attachmentIds: JSONValue? = nil,
        idempotencyKey: String = "",
        seenUpToSeq: Double? = nil,
        freshnessContextMode: String? = nil,
        draftReholdCount: Int? = nil,
        draftReplacedExisting: Bool = false,
        seenExactSeqs: [JSONValue] = [],
        seenCards: JSONValue? = nil,
        mentions: [MentionInput] = []
    ) {
        self.target = target
        self.content = content
        self.sendDraft = sendDraft
        self.continueAnyway = continueAnyway
        self.continueFlag = continueFlag
        self.reconcileOnly = reconcileOnly
        self.attachmentIds = attachmentIds
        self.idempotencyKey = idempotencyKey
        self.seenUpToSeq = seenUpToSeq
        self.freshnessContextMode = freshnessContextMode
        self.draftReholdCount = draftReholdCount
        self.draftReplacedExisting = draftReplacedExisting
        self.seenExactSeqs = seenExactSeqs
        self.seenCards = seenCards
        self.mentions = mentions
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case content
        case sendDraft
        case continueAnyway
        case `continue`
        case reconcileOnly
        case attachmentIds
        case idempotencyKey
        case seenUpToSeq
        case freshnessContextMode
        case draftReholdCount
        case draftReplacedExisting
        case seenExactSeqs
        case seenCards
        case mentions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try? container.decodeIfPresent(String.self, forKey: .target)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
        sendDraft = (try? container.decodeIfPresent(Bool.self, forKey: .sendDraft)) == true
        continueAnyway = (try? container.decodeIfPresent(Bool.self, forKey: .continueAnyway)) == true
        continueFlag = (try? container.decodeIfPresent(Bool.self, forKey: .continue)) == true
        reconcileOnly = (try? container.decodeIfPresent(Bool.self, forKey: .reconcileOnly)) == true
        attachmentIds = try? container.decodeIfPresent(JSONValue.self, forKey: .attachmentIds)
        idempotencyKey = (try? container.decodeIfPresent(String.self, forKey: .idempotencyKey)) ?? ""
        seenUpToSeq = Self.number(try? container.decodeIfPresent(JSONValue.self, forKey: .seenUpToSeq))
        freshnessContextMode = try? container.decodeIfPresent(String.self, forKey: .freshnessContextMode)
        draftReholdCount = Self.number(
            try? container.decodeIfPresent(JSONValue.self, forKey: .draftReholdCount)
        ).map { Int($0) }
        draftReplacedExisting = (try? container.decodeIfPresent(Bool.self, forKey: .draftReplacedExisting)) == true
        seenExactSeqs = (try? container.decode([JSONValue].self, forKey: .seenExactSeqs)) ?? []
        seenCards = try? container.decodeIfPresent(JSONValue.self, forKey: .seenCards)
        mentions = Self.mentions(try? container.decode([JSONValue].self, forKey: .mentions))
    }

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let number): Double(number)
        case .number(let number): number.isFinite ? number : nil
        case .object, .array, .string, .bool, .null, .none: nil
        }
    }

    static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .integer(let number): Int(exactly: number)
        case .number(let number): number.isFinite && number.rounded() == number ? Int(exactly: number) : nil
        case .object, .array, .string, .bool, .null, .none: nil
        }
    }

    /// The legacy `mentionInputs`: only a JSON object with three string fields
    /// becomes a typed mention; everything else is skipped.
    static func mentions(_ values: [JSONValue]?) -> [MentionInput] {
        (values ?? []).compactMap { value in
            guard case .object(let fields) = value,
                  case .string(let type)? = fields["type"],
                  case .string(let id)? = fields["id"],
                  case .string(let name)? = fields["name"]
            else { return nil }
            return MentionInput(type: type, id: id, name: name)
        }
    }
}

/// The typed metadata the attested-send event rows store. The directory
/// helper renders each shape with the legacy sorted-key JSON encoding.
public enum AttestedSendEventMetadata: Sendable, Equatable {
    case gateTriggered(
        lastSeenMessageId: String?,
        latestMessageId: String?,
        draftReplacedExisting: Bool,
        newMessageCount: Int,
        boundarySource: String,
        boundarySeq: Int,
        latestSeq: Int
    )
    case mentionExemption(
        mentionMessageId: String,
        mentionedHandle: String,
        newMessageCountSinceLastSeen: Int
    )
}

// MARK: - Agent send responses

/// The `attention` hint a first channel post publishes.
public struct AgentSendAttention: JSONBodyConvertible, Sendable, Equatable {
    public var muteCommand: String
    public var stillArrives: [String]

    public init(muteCommand: String, stillArrives: [String]) {
        self.muteCommand = muteCommand
        self.stillArrives = stillArrives
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("driveByJoinedToPost", .object([
                OrderedJSONField("reason", "first_agent_message_with_recent_channel_join"),
                OrderedJSONField("muteCommand", muteCommand),
                OrderedJSONField("stillArrives", .array(stillArrives.map(OrderedJSON.string))),
            ])),
        ])
    }
}

/// The channel/peer card fragment the send reply may append.
///
/// The card bytes are rendered by the action-card prepare service, so they
/// enter as raw JSON at the published member position.
public struct AgentSendCardFields: Sendable, Equatable {
    public var channelCard: String?
    public var channelCardChanged: Bool?
    public var peerCard: String?

    public init(channelCard: String? = nil, channelCardChanged: Bool? = nil, peerCard: String? = nil) {
        self.channelCard = channelCard
        self.channelCardChanged = channelCardChanged
        self.peerCard = peerCard
    }

    func append(to body: inout OrderedJSONObject) {
        if let channelCard {
            body.append("channelCard", .raw(channelCard))
            if channelCardChanged == true {
                body.append("channelCardChanged", true)
            }
        }
        if let peerCard {
            body.append("peerCard", .raw(peerCard))
        }
    }
}

/// The idempotency-replay `sent` body.
public struct AgentSendReceiptResponse: JSONBodyConvertible, Sendable, Equatable {
    public var messageId: String
    public var messageSeq: Int
    public var channelId: String
    public var content: String

    public init(messageId: String, messageSeq: Int, channelId: String, content: String) {
        self.messageId = messageId
        self.messageSeq = messageSeq
        self.channelId = channelId
        self.content = content
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("state", "sent")
        body.append("messageId", messageId)
        body.append("messageSeq", messageSeq)
        body.append("id", messageId)
        body.append("channelId", channelId)
        body.append("content", content)
        body.append("seq", messageSeq)
        return body.json
    }
}

/// `reconcileOnly` with no stored receipt.
public struct AgentSendReconcileNotFoundResponse: JSONBodyConvertible, Sendable, Equatable {
    public init() {}

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("state", "not_found"),
            OrderedJSONField("reconciliation", true),
        ])
    }
}

/// `reconcileOnly` with a stored receipt.
public struct AgentSendReconcileCommittedResponse: JSONBodyConvertible, Sendable, Equatable {
    public var messageId: String
    public var messageSeq: Int

    public init(messageId: String, messageSeq: Int) {
        self.messageId = messageId
        self.messageSeq = messageSeq
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("state", "committed"),
            OrderedJSONField("messageId", messageId),
            OrderedJSONField("messageSeq", messageSeq),
            OrderedJSONField("reconciliation", true),
            OrderedJSONField("receiptComplete", false),
        ])
    }
}

/// The `freshnessContextMode: "withheld"` hold.
public struct AgentSendWithheldResponse: JSONBodyConvertible, Sendable, Equatable {
    public var withheldMessageCount: Int

    public init(withheldMessageCount: Int) {
        self.withheldMessageCount = withheldMessageCount
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("state", "held"),
            OrderedJSONField("freshnessContextMode", "withheld"),
            OrderedJSONField("withheldMessageCount", withheldMessageCount),
        ])
    }
}

/// The freshness `held` body.
public struct AgentSendHeldResponse: JSONBodyConvertible, Sendable, Equatable {
    public var producerFactId: String
    /// Envelopes already rendered by the action-card prepare service.
    public var heldMessages: [String]
    public var newMessageCount: Int
    public var shownMessageCount: Int
    public var omittedMessageCount: Int
    public var seenUpToSeq: Int
    public var seenUpToMessageId: String?
    public var firstShownSeq: Int?
    public var formalMentionCount: Int
    public var continueAnywaySuggested: Bool
    public var holdReasons: [String]?
    public var cards: AgentSendCardFields

    public init(
        producerFactId: String,
        heldMessages: [String],
        newMessageCount: Int,
        shownMessageCount: Int,
        omittedMessageCount: Int,
        seenUpToSeq: Int,
        seenUpToMessageId: String?,
        firstShownSeq: Int?,
        formalMentionCount: Int,
        continueAnywaySuggested: Bool,
        holdReasons: [String]?,
        cards: AgentSendCardFields
    ) {
        self.producerFactId = producerFactId
        self.heldMessages = heldMessages
        self.newMessageCount = newMessageCount
        self.shownMessageCount = shownMessageCount
        self.omittedMessageCount = omittedMessageCount
        self.seenUpToSeq = seenUpToSeq
        self.seenUpToMessageId = seenUpToMessageId
        self.firstShownSeq = firstShownSeq
        self.formalMentionCount = formalMentionCount
        self.continueAnywaySuggested = continueAnywaySuggested
        self.holdReasons = holdReasons
        self.cards = cards
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("state", "held")
        body.append("outcome", "held")
        body.append("subtype", "freshness")
        body.append("reason", "newer_messages_available")
        body.append("decision", "syncing_hold")
        body.append("producerFactId", producerFactId)
        body.append("available_actions", .array([
            .string("check_messages"),
            .string("send_draft"),
            .string("send_anyway"),
        ]))
        body.append("heldMessages", .array(heldMessages.map(OrderedJSON.raw)))
        body.append("newMessageCount", newMessageCount)
        body.append("shownMessageCount", shownMessageCount)
        body.append("omittedMessageCount", omittedMessageCount)
        body.append("seenUpToSeq", seenUpToSeq)
        body.append("seenUpToMessageId", ifPresent: seenUpToMessageId)
        body.append("firstShownSeq", ifPresent: firstShownSeq)
        body.append("mentionAnnotation", .object([
            OrderedJSONField("formalMentionCount", formalMentionCount),
        ]))
        if continueAnywaySuggested {
            body.append("continueAnywaySuggested", true)
        }
        if let holdReasons, !holdReasons.isEmpty {
            body.append("holdReasons", .array(holdReasons.map(OrderedJSON.string)))
        }
        cards.append(to: &body)
        return body.json
    }
}

/// The card-only hold (a new channel/peer card is waiting to be reviewed).
public struct AgentSendHeldForCardsResponse: JSONBodyConvertible, Sendable, Equatable {
    public var holdReasons: [String]
    public var cards: AgentSendCardFields

    public init(holdReasons: [String], cards: AgentSendCardFields) {
        self.holdReasons = holdReasons
        self.cards = cards
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("state", "held")
        body.append("holdReasons", .array(holdReasons.map(OrderedJSON.string)))
        body.append("heldMessages", .array([OrderedJSON]()))
        body.append("newMessageCount", 0)
        body.append("shownMessageCount", 0)
        body.append("omittedMessageCount", 0)
        cards.append(to: &body)
        return body.json
    }
}

/// The committed `sent` body.
public struct AgentSendSentResponse: JSONBodyConvertible, Sendable, Equatable {
    public var messageId: String
    public var messageSeq: Int
    public var channelId: String
    public var content: String
    /// Already-rendered `pendingMentionActions` envelopes.
    public var pendingMentionActions: [String]
    public var unresolvedMentionHandles: [String]?
    public var cards: AgentSendCardFields
    public var attention: AgentSendAttention?

    public init(
        messageId: String,
        messageSeq: Int,
        channelId: String,
        content: String,
        pendingMentionActions: [String],
        unresolvedMentionHandles: [String]?,
        cards: AgentSendCardFields,
        attention: AgentSendAttention?
    ) {
        self.messageId = messageId
        self.messageSeq = messageSeq
        self.channelId = channelId
        self.content = content
        self.pendingMentionActions = pendingMentionActions
        self.unresolvedMentionHandles = unresolvedMentionHandles
        self.cards = cards
        self.attention = attention
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("ok", true)
        body.append("state", "sent")
        body.append("messageId", messageId)
        body.append("messageSeq", messageSeq)
        body.append("id", messageId)
        body.append("channelId", channelId)
        body.append("content", content)
        body.append("seq", messageSeq)
        if !pendingMentionActions.isEmpty {
            body.append("pendingMentionActions", .array(pendingMentionActions.map(OrderedJSON.raw)))
        }
        if let unresolvedMentionHandles, !unresolvedMentionHandles.isEmpty {
            body.append("unresolvedMentionHandles", .array(unresolvedMentionHandles.map(OrderedJSON.string)))
        }
        cards.append(to: &body)
        if let attention {
            body.append("attention", attention)
        }
        return body.json
    }
}
