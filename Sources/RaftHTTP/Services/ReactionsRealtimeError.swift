import Foundation

/// Domain failure for the Done/Undone, read-all, Activity page and agent
/// wake/event routes.
///
/// Every case is one published refusal. The Done frontier refusals publish
/// their machine-readable `code` before `error`, so they supply `errorBody`;
/// the agent refusals use the default `error`, `code` order.
public enum ReactionsRealtimeError: DomainError, Equatable {
    /// The Done/Undone/read-all routes' plain missing-session refusal.
    case unauthorized
    case invalidDoneRequest
    case invalidUndoneRequest
    case doneFrontierUnmappable
    case doneFrontierRequired
    case doneFrontierAboveInt4
    case doneFrontierBeyondLatest
    case scopeNotFound
    case notAThread
    case notServerMember
    /// `GET /api/channels/inbox`: no usable bearer. `bearer` records whether the
    /// header carried the `Bearer ` prefix, which selects the published text.
    case inboxAuthRequired(bearer: Bool)
    /// Agent routes: no `Bearer ` header.
    case agentAuthorizationMissing
    /// Agent routes: unknown credential, missing scope or retired agent.
    case agentTokenInvalid
    case sinceInvalid

    public var status: UInt {
        switch self {
        case .unauthorized, .inboxAuthRequired, .agentAuthorizationMissing, .agentTokenInvalid:
            401
        case .invalidDoneRequest, .invalidUndoneRequest, .doneFrontierUnmappable,
             .doneFrontierRequired, .notAThread, .sinceInvalid:
            400
        case .doneFrontierAboveInt4, .doneFrontierBeyondLatest:
            409
        case .scopeNotFound:
            404
        case .notServerMember:
            403
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .invalidDoneRequest:
            "Invalid inbox done request"
        case .invalidUndoneRequest:
            "Invalid inbox undone request"
        case .doneFrontierUnmappable:
            "frontierSpace must be storage"
        case .doneFrontierRequired:
            "throughActivitySeq must be a canonical positive decimal string"
        case .doneFrontierAboveInt4:
            "Done frontier exceeds the int4 authority"
        case .doneFrontierBeyondLatest:
            "Done frontier is beyond the latest activity"
        case .scopeNotFound:
            "Inbox scope not found"
        case .notAThread:
            "Inbox scope is not a thread"
        case .notServerMember:
            "Not a member of this server"
        case .inboxAuthRequired(let bearer):
            bearer ? "Invalid or expired token" : "Missing or invalid Authorization header"
        case .agentAuthorizationMissing:
            "Missing or invalid Authorization header"
        case .agentTokenInvalid:
            "Invalid or expired token"
        case .sinceInvalid:
            "since must be a non-negative integer or 'latest'"
        }
    }

    /// Machine-readable code for the default `error`, `code` body.
    public var errorCode: String? {
        switch self {
        case .inboxAuthRequired, .agentAuthorizationMissing, .agentTokenInvalid:
            "auth_required"
        case .sinceInvalid:
            "since_invalid"
        case .unauthorized, .invalidDoneRequest, .invalidUndoneRequest, .doneFrontierUnmappable,
             .doneFrontierRequired, .doneFrontierAboveInt4, .doneFrontierBeyondLatest,
             .scopeNotFound, .notAThread, .notServerMember:
            nil
        }
    }

    /// The frontier and scope refusals publish `code` before `error`.
    public var errorBody: OrderedJSON? {
        let code: String
        switch self {
        case .doneFrontierUnmappable:
            code = "DONE_FRONTIER_UNMAPPABLE"
        case .doneFrontierRequired:
            code = "DONE_FRONTIER_REQUIRED"
        case .doneFrontierAboveInt4:
            code = "DONE_FRONTIER_ABOVE_INT4_AUTHORITY"
        case .doneFrontierBeyondLatest:
            code = "DONE_FRONTIER_BEYOND_LATEST"
        case .notAThread:
            code = "NOT_A_THREAD"
        case .unauthorized, .invalidDoneRequest, .invalidUndoneRequest, .scopeNotFound,
             .notServerMember, .inboxAuthRequired, .agentAuthorizationMissing,
             .agentTokenInvalid, .sinceInvalid:
            return nil
        }
        return .object([
            OrderedJSONField("code", code),
            OrderedJSONField("error", errorMessage),
        ])
    }

    /// The Activity page is `private, no-store`, including its refusals.
    public var responseHeaders: [String: String] {
        switch self {
        case .inboxAuthRequired:
            ["Cache-Control": "private, no-store"]
        case .unauthorized, .invalidDoneRequest, .invalidUndoneRequest, .doneFrontierUnmappable,
             .doneFrontierRequired, .doneFrontierAboveInt4, .doneFrontierBeyondLatest,
             .scopeNotFound, .notAThread, .notServerMember, .agentAuthorizationMissing,
             .agentTokenInvalid, .sinceInvalid:
            [:]
        }
    }
}
