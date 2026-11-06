import Foundation

/// Every refusal of the agent lifecycle surface. The case is the machine
/// readable reason; the status and the exact published body (member order
/// included) are fixed here so the feature layer projects them without a second
/// copy of the legacy literals.
public enum AgentsLifecycleError: DomainError, Equatable {
    case unauthorized
    case invalidOrExpiredToken
    case uploadsDisabled
    case capabilityNotAuthorized
    case channelNotFound
    case emptyFile
    case fileTooLarge(maxBytes: Int)
    case agentMissing
    case forbidden
    case notAMember
    case tooManyFiles
    case uploadForbidden
    case uploadSessionNotFound
    case invalidCursor
    case invalidAttachmentId
    case serverIdRequired
    case attachmentNotFound
    case invalidEventBatch
    case invalidAppVersion
    case computerUnauthorized
    case invalidPrincipal
    case surfaceUnregistered
    case unknownRuntimeProvider

    public var status: UInt {
        switch self {
        case .unauthorized, .invalidOrExpiredToken, .computerUnauthorized, .invalidPrincipal,
             .surfaceUnregistered:
            return 401
        case .capabilityNotAuthorized, .forbidden, .notAMember, .uploadForbidden:
            return 403
        case .channelNotFound, .agentMissing, .uploadSessionNotFound, .attachmentNotFound,
             .unknownRuntimeProvider:
            return 404
        case .emptyFile, .tooManyFiles, .invalidCursor, .invalidAttachmentId, .serverIdRequired,
             .invalidEventBatch, .invalidAppVersion:
            return 400
        case .fileTooLarge:
            return 413
        case .uploadsDisabled:
            return 503
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized, .computerUnauthorized: return "Unauthorized"
        case .invalidOrExpiredToken: return "Invalid or expired token"
        case .uploadsDisabled: return "File uploads are disabled on this server"
        case .capabilityNotAuthorized: return "Agent credential is not authorized for this capability"
        case .channelNotFound: return "Channel not found"
        case .emptyFile: return "Empty files are not allowed"
        case .fileTooLarge: return "Max 50MB per file"
        case .agentMissing: return "Agent not found"
        case .forbidden: return "Forbidden"
        case .notAMember: return "Not a member of this server"
        case .tooManyFiles: return "Max 10 files per message"
        case .uploadForbidden: return "The member cannot upload to this channel."
        case .uploadSessionNotFound: return "Upload session not found."
        case .invalidCursor: return "Invalid cursor"
        case .invalidAttachmentId: return "Invalid attachment id"
        case .serverIdRequired: return "X-Server-Id header is required"
        case .attachmentNotFound: return "Attachment not found"
        case .invalidEventBatch: return "Invalid event batch"
        case .invalidAppVersion: return "Invalid app_version"
        case .invalidPrincipal: return "Invalid principal for this surface"
        case .surfaceUnregistered: return "This internal surface is not registered"
        case .unknownRuntimeProvider: return "Unknown runtime provider"
        }
    }

    public var errorCode: String? {
        switch self {
        case .invalidOrExpiredToken, .computerUnauthorized: return "auth_required"
        case .capabilityNotAuthorized: return "capability_not_authorized"
        case .invalidPrincipal: return "invalid_principal"
        case .surfaceUnregistered: return "auth_policy_unregistered_path"
        default: return nil
        }
    }

    /// The default `{"error": …[, "code": …]}` order covers most cases; the rest
    /// publish their own member order (an `errorCode` member, `code` before
    /// `error`, or a `message`/`retryable` envelope).
    public var errorBody: OrderedJSON? {
        switch self {
        case .uploadsDisabled:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "ATTACHMENT_UPLOAD_DISABLED"),
            ])
        case .fileTooLarge(let maxBytes):
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "ATTACHMENT_TOO_LARGE"),
                OrderedJSONField("maxBytes", maxBytes),
            ])
        case .agentMissing:
            return .object([
                OrderedJSONField("code", "agent_missing"),
                OrderedJSONField("error", errorMessage),
            ])
        case .invalidAttachmentId:
            return .object([
                OrderedJSONField("code", "invalid_attachment_id"),
                OrderedJSONField("error", errorMessage),
            ])
        case .uploadForbidden:
            return .object([
                OrderedJSONField("code", "UPLOAD_FORBIDDEN"),
                OrderedJSONField("message", errorMessage),
                OrderedJSONField("retryable", false),
            ])
        case .uploadSessionNotFound:
            return .object([
                OrderedJSONField("code", "UPLOAD_SESSION_NOT_FOUND"),
                OrderedJSONField("message", errorMessage),
                OrderedJSONField("retryable", false),
            ])
        default:
            return nil
        }
    }
}
