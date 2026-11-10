import Foundation

/// The task-history read uses the same global middleware chain as every task
/// mutation upstream (`requireAuth`, `requireVerified`, `requireServer`) and
/// then `requireTaskInServer`. These are the published refusals of that chain.
public enum TaskHistoryError: DomainError, Equatable {
    case authRequired(bearerPresent: Bool)
    case emailVerificationRequired
    case missingServerId
    case notServerMember
    case taskNotFound
    case legacyTask

    public var status: UInt {
        switch self {
        case .authRequired: 401
        case .emailVerificationRequired, .notServerMember: 403
        case .missingServerId: 400
        case .taskNotFound: 404
        case .legacyTask: 409
        }
    }

    public var errorMessage: String {
        switch self {
        case .authRequired(let bearerPresent):
            bearerPresent ? "Invalid or expired token" : "Missing or invalid Authorization header"
        case .emailVerificationRequired:
            "Email verification required"
        case .missingServerId:
            "Missing X-Server-Id header"
        case .notServerMember:
            "Not a member of this server"
        case .taskNotFound:
            "Task not found"
        case .legacyTask:
            "legacy task cards do not have canonical history"
        }
    }

    public var errorCode: String? {
        if case .authRequired(_) = self { return "auth_required" }
        return nil
    }
}
