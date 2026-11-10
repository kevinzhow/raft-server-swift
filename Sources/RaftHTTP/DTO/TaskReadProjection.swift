import Foundation

/// Canonical facts copied onto an independently projected message read row.
/// Optional values clear stale shadow fields; names use the caller's actor map.
struct TaskMessageReadOverlay: Sendable, Equatable {
    let taskStatus: String
    let taskNumber: Int
    let taskAssigneeType: String?
    let taskAssigneeId: String?
    let taskClaimedAt: String?
    let taskCompletedAt: String?
    let taskCurrentProjection: TaskCurrentProjectionDTO
}

/// One truthful human task projection shared by reads, HTTP mutations and task
/// board frames. Action-card/internal execution receipts keep their own DTO.
public struct TaskReadProjection: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var messageId: String
    public var channelName: String?
    public var channelType: String?
    public var title: String
    public var description: String?
    public var status: String
    public var taskNumber: Int
    public var claimedById: String?
    public var claimedByType: String?
    public var claimedByName: String?
    public var claimedAt: String?
    public var completedAt: String?
    public var createdAt: String
    public var updatedAt: String?
    public var createdById: String?
    public var createdByType: String?
    public var createdByName: String?
    public var createdByMembershipStatus: String?
    public var revision: Int
    public var requiresResourceReceipt: Bool
    public var taskCurrentProjection: TaskCurrentProjectionDTO
    public var isLegacy: Bool
    private var resourceReceiptJSON: String?

    init(_ task: TaskRecord, channelId: String? = nil, channelName: String? = nil, channelType: String? = nil,
         creatorType: String? = nil, creatorName: String? = nil, creatorMembershipStatus: String? = nil,
         assigneeName: String? = nil) {
        id = task.id
        self.channelId = channelId ?? task.channelId
        messageId = task.hasHostMessage ? task.messageId : task.id
        self.channelName = channelName
        self.channelType = channelType
        title = task.title
        description = task.description
        status = task.status
        taskNumber = task.taskNumber
        claimedById = task.assigneeId
        claimedByType = task.assigneeType
        claimedByName = assigneeName
        claimedAt = task.claimedAt.map(DateText.isoString)
        completedAt = task.completedAt.map(DateText.isoString)
        createdAt = DateText.isoString(task.createdAt)
        // Missing historical updatedAt is unknown, not a copy of createdAt.
        updatedAt = task.updatedAt.map(DateText.isoString)
        createdById = task.creatorId
        createdByType = creatorType
        createdByName = creatorName
        createdByMembershipStatus = creatorMembershipStatus
        revision = task.revision
        requiresResourceReceipt = task.requiresResourceReceipt
        resourceReceiptJSON = task.resourceReceiptJSON
        taskCurrentProjection = Self.currentProjection(task)
        isLegacy = !task.hasHostMessage
    }

    /// Message readers reuse the task owner's current factual text/revision.
    /// No actor identity or event history is inferred by this pure projection.
    /// Current facts for a matching canonical host on READ. The caller verifies
    /// the real messageId/storage-channel binding and resolves any actor names
    /// from these assignee identifiers. This does not mutate the stored host.
    static func messageReadOverlay(_ task: TaskRecord) -> TaskMessageReadOverlay {
        TaskMessageReadOverlay(taskStatus: task.status, taskNumber: task.taskNumber,
            taskAssigneeType: task.assigneeType, taskAssigneeId: task.assigneeId,
            taskClaimedAt: task.claimedAt.map(DateText.isoString),
            taskCompletedAt: task.completedAt.map(DateText.isoString),
            taskCurrentProjection: currentProjection(task))
    }

    static func currentProjection(_ task: TaskRecord) -> TaskCurrentProjectionDTO {
        TaskCurrentProjectionDTO(title: task.title, description: task.description, revision: task.revision,
            superseded: task.superseded, amendedAt: task.amendedAt.map(DateText.isoString),
            amendedByType: task.amendedByType, amendedByName: task.amendedByName)
    }

    public var jsonBody: OrderedJSON {
        .object([
            .init("id", id), .init("messageId", messageId), .init("channelId", channelId),
            .init("channelName", optional: channelName), .init("channelType", optional: channelType),
            .init("taskNumber", taskNumber), .init("title", title), .init("description", optional: description),
            .init("status", status), .init("createdByType", optional: createdByType),
            .init("createdById", optional: createdById), .init("createdByName", optional: createdByName),
            .init("createdByMembershipStatus", optional: createdByMembershipStatus),
            .init("claimedByType", optional: claimedByType), .init("claimedById", optional: claimedById),
            .init("claimedByName", optional: claimedByName), .init("claimedAt", optional: claimedAt),
            .init("completedAt", optional: completedAt), .init("requiresResourceReceipt", requiresResourceReceipt),
            .init("resourceReceipt", resourceReceiptJSON.map(OrderedJSON.raw) ?? .null),
            // These metadata columns do not exist in the retained native task row.
            .init("resourceReceiptRecordedAt", .null), .init("resourceTeardownOwnerAgentId", .null),
            .init("resourceExpiryFollowupId", .null), .init("createdAt", createdAt),
            .init("updatedAt", optional: updatedAt), .init("revision", revision),
            .init("taskCurrentProjection", taskCurrentProjection.jsonBody), .init("isLegacy", isLegacy),
        ])
    }
}
