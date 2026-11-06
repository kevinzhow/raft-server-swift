import Foundation

/// Domain failure for channel membership, thread creation and the human task
/// routes. The refusals both domains share with the channel archive/join
/// surface (`auth_required`, `Not a member of this server`, `Channel not
/// found`, `Forbidden`, the archived and thread-member refusals) are thrown as
/// `ChannelMembershipError`; this enum holds the rest.
///
/// Two refusals publish `code` before `error` or add a key, so they supply
/// `errorBody`; every other case uses the default `{"error":…[,"code":…]}`.
public enum ManagedMCPAssignmentsError: DomainError, Equatable {
    /// The plain missing-session refusal the roster and task routes use.
    case unauthorized
    case invalidChannelMembers
    case usersNotInServer(invalidUserIds: [String])
    case assistantChannelForbidden
    case parentMessageIdRequired
    case parentMessageNotFound
    case invalidChannelMember
    case invalidAgent
    case invalidMember
    case jointChannelAdminLimited
    case invalidChannelRole
    case memberNotFound
    case protectedServerRole
    case channelAdminSelfDemote
    case taskNotFound
    case joinChannelToChangeTasks
    case onlyCreatorCanDeleteTask
    /// `claim` on a task whose channel was deleted.
    case channelDeletedClaimForbidden
    /// A status write other than done/closed/cancelled on a deleted channel.
    case channelDeletedTerminalOnly
    case onlyAssigneeCanReturnToTodo
    case invalidTaskStatus
    case messageNotFound
    case repeatedQueryParameter
    case detailMustBeFullOrSummary
    case limitOutOfRange
    case cursorRequiresLimit
    case invalidCursor

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .jointChannelAdminLimited, .protectedServerRole, .joinChannelToChangeTasks,
             .onlyCreatorCanDeleteTask, .assistantChannelForbidden:
            403
        case .parentMessageNotFound, .memberNotFound, .taskNotFound, .messageNotFound:
            404
        case .channelAdminSelfDemote, .channelDeletedClaimForbidden, .channelDeletedTerminalOnly,
             .onlyAssigneeCanReturnToTodo:
            409
        case .invalidChannelMembers, .usersNotInServer, .parentMessageIdRequired, .invalidChannelMember,
             .invalidAgent, .invalidMember, .invalidChannelRole, .invalidTaskStatus,
             .repeatedQueryParameter, .detailMustBeFullOrSummary, .limitOutOfRange,
             .cursorRequiresLimit, .invalidCursor:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .invalidChannelMembers: "Invalid channel members"
        case .usersNotInServer: "One or more users are not members of this server"
        case .assistantChannelForbidden: "An assistant can only be in its DM with its owner"
        case .parentMessageIdRequired: "parentMessageId is required"
        case .parentMessageNotFound: "Parent message not found"
        case .invalidChannelMember: "Invalid channel member"
        case .invalidAgent: "Invalid agent"
        case .invalidMember: "Invalid member"
        case .jointChannelAdminLimited: "Only a server admin can remove joint channel members"
        case .invalidChannelRole: "Invalid channel role"
        case .memberNotFound: "Member not found"
        case .protectedServerRole: "Server role is managed separately"
        case .channelAdminSelfDemote: "A channel admin cannot demote themselves"
        case .taskNotFound: "Task not found"
        case .joinChannelToChangeTasks: "Join the channel to change tasks"
        case .onlyCreatorCanDeleteTask: "Only the task creator can delete it"
        case .channelDeletedClaimForbidden: "This channel was deleted; the task can only be closed"
        case .channelDeletedTerminalOnly: "This channel was deleted; only terminal task statuses are allowed"
        case .onlyAssigneeCanReturnToTodo: "Only the current assignee can return this task to todo"
        case .invalidTaskStatus: "Invalid task status"
        case .messageNotFound: "Message not found"
        case .repeatedQueryParameter: "Repeated query parameter"
        case .detailMustBeFullOrSummary: "detail must be full or summary"
        case .limitOutOfRange: "limit must be between 1 and 500"
        case .cursorRequiresLimit: "cursor requires limit"
        case .invalidCursor: "Invalid cursor"
        }
    }

    public var errorCode: String? {
        switch self {
        case .jointChannelAdminLimited: "joint_channel_admin_limited"
        case .protectedServerRole: "protected_server_role"
        case .channelAdminSelfDemote: "channel_admin_self_demote_forbidden"
        case .channelDeletedClaimForbidden, .channelDeletedTerminalOnly: "channel_deleted_terminal_only"
        case .usersNotInServer: "users_not_in_server"
        case .assistantChannelForbidden: "assistant_channel_forbidden"
        case .unauthorized, .invalidChannelMembers, .parentMessageIdRequired, .parentMessageNotFound,
             .invalidChannelMember, .invalidAgent, .invalidMember, .invalidChannelRole,
             .memberNotFound, .taskNotFound, .joinChannelToChangeTasks, .onlyCreatorCanDeleteTask,
             .onlyAssigneeCanReturnToTodo, .invalidTaskStatus, .messageNotFound,
             .repeatedQueryParameter, .detailMustBeFullOrSummary, .limitOutOfRange,
             .cursorRequiresLimit, .invalidCursor:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .usersNotInServer(let invalidUserIds):
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "users_not_in_server"),
                OrderedJSONField("invalidUserIds", .array(invalidUserIds.map(OrderedJSON.string))),
            ])
        case .assistantChannelForbidden:
            // The published body prints `code` before `error`.
            return .object([
                OrderedJSONField("code", "assistant_channel_forbidden"),
                OrderedJSONField("error", errorMessage),
            ])
        default:
            return nil
        }
    }
}
