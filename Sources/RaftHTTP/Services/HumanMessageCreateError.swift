import Foundation

/// Domain failures of the human-message create surface: the v1/v2 create
/// route, the mention actions, the forward lookup and the forward write.
///
/// Each case is one published refusal. The create and mention-action routes
/// answer a missing or unusable session with the public `auth_required` body and
/// `Cache-Control: no-store`; the forward and agent routes answer with the plain
/// bearer-check bodies, so those are separate cases that differ only in the
/// published text or headers. `messageWriteRejected` carries a refusal the
/// message write itself rendered (a `randomId` or attachment conflict), whose
/// body is published verbatim.
public enum HumanMessageCreateError: DomainError, Equatable {
    /// Create and user mention actions: no usable bearer session.
    case authRequired(bearerPresent: Bool)
    /// Forward and agent routes: no `Bearer` header.
    case missingAuthorization
    /// Forward and agent routes: an unknown token or a revoked session family.
    case invalidToken
    /// A retired account.
    case unauthorized
    case emailVerificationRequired
    case notServerMember
    case invalidMessageBody
    case channelNotFound
    case forbidden
    case channelArchived
    case referencesNotEnabled
    case appNotInstalled
    case mentionBindingConflict
    case invalidRandomId
    case actionMustBeNotifyOrAdd
    case resolutionIdsRequired
    case missingServerIdHeader
    case forwardInvalidRequest
    case messageTooLong
    case forwardIdempotencyConflict
    case sourceMessageNotFound
    case mustJoinChannel
    // Public ForwardRequestError codes belong only to the Forward path.
    case forwardMessageNotFound
    case forwardSourceNotFound
    case forwardDestinationNotFound
    case forwardDestinationMembershipRequired
    case forwardCrossServerSource
    case forwardUnsupportedSource
    case forwardedSourceNotSupported
    case unsupportedSourceMessage
    case crossSourceBundle
    case messageWriteRejected(status: UInt, body: String)

    public var status: UInt {
        switch self {
        case .authRequired, .missingAuthorization, .invalidToken, .unauthorized:
            401
        case .emailVerificationRequired, .notServerMember, .forbidden, .mustJoinChannel,
             .forwardDestinationMembershipRequired:
            403
        case .channelNotFound, .sourceMessageNotFound, .forwardMessageNotFound,
             .forwardSourceNotFound, .forwardDestinationNotFound:
            404
        case .channelArchived, .forwardIdempotencyConflict:
            409
        case .invalidMessageBody, .referencesNotEnabled, .appNotInstalled, .mentionBindingConflict,
             .invalidRandomId, .actionMustBeNotifyOrAdd, .resolutionIdsRequired,
             .missingServerIdHeader, .forwardInvalidRequest, .messageTooLong,
             .forwardedSourceNotSupported, .unsupportedSourceMessage, .crossSourceBundle,
             .forwardCrossServerSource, .forwardUnsupportedSource:
            400
        case .messageWriteRejected(let status, _):
            status
        }
    }

    public var errorMessage: String {
        switch self {
        case .authRequired(let bearerPresent):
            bearerPresent ? "Invalid or expired token" : "Missing or invalid Authorization header"
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidToken:
            "Invalid or expired token"
        case .unauthorized:
            "Unauthorized"
        case .emailVerificationRequired:
            "Email verification required"
        case .notServerMember:
            "Not a member of this server"
        case .invalidMessageBody:
            "Invalid message request body"
        case .channelNotFound, .forwardDestinationNotFound:
            "Channel not found"
        case .forbidden:
            "Forbidden"
        case .channelArchived:
            "This channel is archived"
        case .referencesNotEnabled:
            "Computer and App references are not enabled in this server"
        case .appNotInstalled:
            "App reference is not installed in this server"
        case .mentionBindingConflict:
            "A mention handle is bound to more than one target"
        case .invalidRandomId:
            "randomId must be a non-empty string with at most 128 characters"
        case .actionMustBeNotifyOrAdd:
            "action must be notify or add"
        case .resolutionIdsRequired:
            "resolutionIds must include at least one id"
        case .missingServerIdHeader:
            "Missing X-Server-Id header"
        case .forwardInvalidRequest:
            "Destination channel and full source message ids are required"
        case .messageTooLong:
            "Message content exceeds maximum length of 32000 characters"
        case .forwardIdempotencyConflict:
            "This forward request id was already used for different content"
        case .sourceMessageNotFound, .forwardSourceNotFound:
            "Source message not found"
        case .forwardMessageNotFound:
            "Message not found"
        case .mustJoinChannel, .forwardDestinationMembershipRequired:
            "You must join this channel to send messages"
        case .forwardCrossServerSource:
            "Forwarding across servers is not supported"
        case .forwardUnsupportedSource:
            "Forwarding from this thread is not supported"
        case .forwardedSourceNotSupported:
            "Forwarded messages can't be forwarded. Select the original message instead."
        case .unsupportedSourceMessage:
            "Only ordinary chat messages can be forwarded"
        case .crossSourceBundle:
            "Forwarded bundles must come from a single source"
        case .messageWriteRejected:
            ""
        }
    }

    public var errorCode: String? {
        switch self {
        case .authRequired, .missingAuthorization, .invalidToken:
            "auth_required"
        case .channelArchived:
            "channel_archived"
        case .mentionBindingConflict:
            "mention_binding_conflict"
        case .forwardIdempotencyConflict:
            "idempotency_conflict"
        case .forwardedSourceNotSupported:
            "forwarded_source_not_supported"
        case .unsupportedSourceMessage:
            "unsupported_source_message"
        case .crossSourceBundle:
            "cross_source_bundle"
        case .forwardMessageNotFound, .forwardSourceNotFound:
            "source_not_found"
        case .forwardDestinationNotFound, .forwardDestinationMembershipRequired:
            "destination_unavailable"
        case .forwardCrossServerSource:
            "cross_server_source"
        case .forwardUnsupportedSource:
            "unsupported_source"
        case .unauthorized, .emailVerificationRequired, .notServerMember, .invalidMessageBody,
             .channelNotFound, .forbidden, .referencesNotEnabled, .appNotInstalled,
             .invalidRandomId, .actionMustBeNotifyOrAdd, .resolutionIdsRequired,
             .missingServerIdHeader, .forwardInvalidRequest, .messageTooLong,
             .sourceMessageNotFound, .mustJoinChannel, .messageWriteRejected:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .messageWriteRejected(_, let body):
            .raw(body)
        case .authRequired, .missingAuthorization, .invalidToken, .unauthorized,
             .emailVerificationRequired, .notServerMember, .invalidMessageBody, .channelNotFound,
             .forbidden, .channelArchived, .referencesNotEnabled, .appNotInstalled,
             .mentionBindingConflict, .invalidRandomId, .actionMustBeNotifyOrAdd,
             .resolutionIdsRequired, .missingServerIdHeader, .forwardInvalidRequest,
             .messageTooLong, .forwardIdempotencyConflict, .sourceMessageNotFound,
             .mustJoinChannel, .forwardedSourceNotSupported, .unsupportedSourceMessage,
             .crossSourceBundle, .forwardMessageNotFound, .forwardSourceNotFound,
             .forwardDestinationNotFound, .forwardDestinationMembershipRequired,
             .forwardCrossServerSource, .forwardUnsupportedSource:
            nil
        }
    }

    /// The public create surface marks its session refusal `no-store`, as the
    /// shared public reply helper did.
    public var responseHeaders: [String: String] {
        switch self {
        case .authRequired:
            ["Cache-Control": "no-store"]
        case .missingAuthorization, .invalidToken, .unauthorized, .emailVerificationRequired,
             .notServerMember, .invalidMessageBody, .channelNotFound, .forbidden, .channelArchived,
             .referencesNotEnabled, .appNotInstalled, .mentionBindingConflict, .invalidRandomId,
             .actionMustBeNotifyOrAdd, .resolutionIdsRequired, .missingServerIdHeader,
             .forwardInvalidRequest, .messageTooLong, .forwardIdempotencyConflict,
             .sourceMessageNotFound, .mustJoinChannel, .forwardedSourceNotSupported,
             .unsupportedSourceMessage, .crossSourceBundle, .messageWriteRejected,
             .forwardMessageNotFound, .forwardSourceNotFound, .forwardDestinationNotFound,
             .forwardDestinationMembershipRequired, .forwardCrossServerSource, .forwardUnsupportedSource:
            [:]
        }
    }
}
