import Foundation

/// Typed refusals of the reminder routes and the saved-message write. The
/// status, message and (where published) `code` are the legacy bodies.
public enum ManagedMCPAgentCatalogError: DomainError, Equatable {
    case unauthorized
    case notAServerMember
    case agentNotFound
    case forbidden
    case remindersMovedToApp
    case externalAgentsCannotRemind
    case titleRequired
    case messageIdRequired
    case fireAtRequired
    case invalidStatusFilter
    case reminderNotFound
    case reminderVersionConflict(currentVersion: Int)
    case invalidReminderUpdate
    /// A version-bound write the ledger refused (fired or canceled rows); the
    /// message is the ledger's own text.
    case reminderMutationRefused(String)
    case agentTokenInvalid
    case messageNotFound

    public var status: UInt {
        switch self {
        case .unauthorized, .agentTokenInvalid: 401
        case .notAServerMember, .forbidden: 403
        case .agentNotFound, .reminderNotFound, .messageNotFound: 404
        case .remindersMovedToApp, .externalAgentsCannotRemind, .reminderVersionConflict,
             .reminderMutationRefused: 409
        case .titleRequired, .messageIdRequired, .fireAtRequired, .invalidStatusFilter,
             .invalidReminderUpdate: 400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .notAServerMember: "Not a member of this server"
        case .agentNotFound: "Agent not found"
        case .forbidden: "Forbidden"
        case .remindersMovedToApp: "Reminders are managed by the Reminder App now"
        case .externalAgentsCannotRemind: "External agents cannot create reminders"
        case .titleRequired: "title is required"
        case .messageIdRequired: "msgId is required for agent-created reminders"
        case .fireAtRequired: "fireAt or delaySeconds is required"
        case .invalidStatusFilter: "Invalid status filter"
        case .reminderNotFound: "Reminder not found"
        case .reminderVersionConflict: "Reminder version conflict"
        case .invalidReminderUpdate: "Invalid reminder update"
        case .reminderMutationRefused(let message): message
        case .agentTokenInvalid: "Invalid or expired token"
        case .messageNotFound: "Message not found"
        }
    }

    public var errorCode: String? {
        switch self {
        case .remindersMovedToApp: "reminders_moved_to_app"
        case .externalAgentsCannotRemind: "reminders_unsupported_for_external_agents"
        case .agentTokenInvalid: "auth_required"
        default: nil
        }
    }

    public var errorBody: OrderedJSON? {
        guard case .reminderVersionConflict(let current) = self else { return nil }
        return .object([
            OrderedJSONField("error", errorMessage),
            OrderedJSONField("currentVersion", current),
        ])
    }
}
