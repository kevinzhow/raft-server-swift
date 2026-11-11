import Foundation

/// Domain failures of the agent task history/unclaim routes (both the
/// credential `/internal/agent-api/*` surface and the legacy machine
/// `/internal/agent/:id/tasks` surface).
public enum AgentTaskApiError: DomainError, Equatable {
    /// The channel reference does not resolve for this agent, or the agent is
    /// gone. Upstream `resolveAgentApiTaskChannel` collapses both into one 404.
    case agentOrChannelNotFound
    case taskNotFound
    /// A legacy task card (no canonical host message) has no event timeline.
    case legacyTaskHistory
    case channelArchived
    /// `canAgentPostToChannel` refused the task write.
    case agentCannotModifyTasks
    /// The route cannot address a thread target; the associated value is the
    /// route-specific published refusal (`claim` and `create` differ upstream).
    case threadTaskWrite(String)
    /// A joint task older than this participant workspace is read-only.
    case historicalJointReadOnly
    case taskDone
    case taskNotAssigned
    case taskChangedConcurrently
    /// Legacy body guard: `channel and task_number are required`.
    case invalidLegacyUnclaimRequest
    /// The legacy tasks list publishes its own short filter refusal.
    case invalidStatusFilter
    /// The legacy tasks list requires the `channel` query parameter.
    case channelQueryRequired

    public var status: UInt {
        switch self {
        case .agentOrChannelNotFound, .taskNotFound:
            404
        case .channelArchived, .legacyTaskHistory, .taskDone, .taskNotAssigned, .taskChangedConcurrently,
             .threadTaskWrite:
            409
        case .agentCannotModifyTasks, .historicalJointReadOnly:
            403
        case .invalidLegacyUnclaimRequest, .invalidStatusFilter, .channelQueryRequired:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .agentOrChannelNotFound:
            "Agent or channel not found"
        case .taskNotFound:
            "Task not found"
        case .legacyTaskHistory:
            "legacy task cards do not have canonical history"
        case .channelArchived:
            "This channel is archived"
        case .agentCannotModifyTasks:
            "Agent must join this channel to modify tasks"
        case .threadTaskWrite(let message):
            message
        case .historicalJointReadOnly:
            "Historical tasks are read-only from a participant workspace"
        case .taskDone:
            "task is done"
        case .taskNotAssigned:
            "task is not assigned"
        case .taskChangedConcurrently:
            "task state changed concurrently"
        case .invalidLegacyUnclaimRequest:
            "channel and task_number are required"
        case .invalidStatusFilter:
            "Invalid status value"
        case .channelQueryRequired:
            "channel query param is required (e.g. #general)"
        }
    }

    public var errorCode: String? {
        switch self {
        case .channelArchived:
            "channel_archived"
        case .historicalJointReadOnly:
            "joint_task_read_only"
        case .agentOrChannelNotFound, .taskNotFound, .legacyTaskHistory, .agentCannotModifyTasks,
             .taskDone, .taskNotAssigned, .taskChangedConcurrently, .threadTaskWrite,
             .invalidLegacyUnclaimRequest, .invalidStatusFilter, .channelQueryRequired:
            nil
        }
    }
}
