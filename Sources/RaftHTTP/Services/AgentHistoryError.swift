import Foundation

/// Typed refusals of the agent history read and the machine channel
/// join/leave. Bodies that carry `errorCode` (not `code`) and a
/// `suggestedNextAction` publish them through `errorBody` in the legacy order.
public enum AgentHistoryError: DomainError, Equatable {
    case missingAuthorization
    case invalidToken
    case channelRequired
    case channelNotVisible
    case agentNotFound
    case eventAddressAmbiguous
    case eventExpired
    /// The anchor message has no thread; both texts are printed as given.
    case noThreadOnMessage(suffix: String, channelName: String)
    case invalidConsume
    case unreadWithAnchor(target: String)
    case anchorNotFound(String)
    case anchorAmbiguous(String)
    case anchorInvalid(String)
    /// A bare `dm:@name` held by both a human member and a live agent, reported
    /// through `DmTargetResolutionError.ambiguous`.
    case dmTargetAmbiguous(name: String)
    /// A `dm:@rawPeer` whose `~suffix` is not the exact lowercase `agent` or
    /// `human`, reported through `DmTargetResolutionError.invalidPeerKind`.
    /// `rawPeer` is the whole peer spelling including the suffix (the pinned
    /// error names it) and `suffix` is the rejected kind, if any.
    case dmTargetInvalidPeerKind(rawPeer: String, suffix: String?)

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidToken: 401
        case .channelRequired, .invalidConsume, .unreadWithAnchor, .anchorAmbiguous, .anchorInvalid,
             .dmTargetInvalidPeerKind: 400
        case .channelNotVisible, .agentNotFound, .noThreadOnMessage, .anchorNotFound: 404
        case .eventAddressAmbiguous, .dmTargetAmbiguous: 409
        case .eventExpired: 410
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization: "Missing or invalid Authorization header"
        case .invalidToken: "Invalid or expired token"
        case .channelRequired: "channel is required"
        case .channelNotVisible: "Channel not found or not visible"
        case .agentNotFound: "Agent not found"
        case .eventAddressAmbiguous:
            "That 8-character event address matches more than one of your events. Use the full event id, printed as `event_id:` in the event body."
        case .eventExpired: "This third-party event has expired and its payload is no longer retained."
        case .noThreadOnMessage(let suffix, let name): "There is no thread on message \(suffix) in #\(name)"
        case .invalidConsume: "consume must be true or false"
        case .unreadWithAnchor: "unread cannot be combined with an anchor"
        case .anchorNotFound(let message), .anchorAmbiguous(let message), .anchorInvalid(let message): message
        case .dmTargetAmbiguous(let name):
            DMTargetResolutionWire.ambiguous(name).message
        case .dmTargetInvalidPeerKind(let rawPeer, let suffix):
            DMTargetResolutionWire.invalidPeerKind(rawPeer: rawPeer, suffix: suffix).message
        }
    }

    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidToken: "auth_required"
        default: nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .eventAddressAmbiguous:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "AMBIGUOUS_ID"),
                OrderedJSONField("suggestedNextAction", "raft message read --target 'agent-event:<full-event-id>'"),
            ])
        case .eventExpired:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "EXPIRED"),
            ])
        case .noThreadOnMessage(let suffix, let name):
            // The legacy text printed the anchor and channel name unescaped.
            let nextAction = "raft message read --target '#\(name)' --around \(suffix)"
            return .raw(
                "{\"error\":\"\(errorMessage)\",\"suggestedNextAction\":\(OrderedJSON.string(nextAction).render())}"
            )
        case .invalidConsume:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "INVALID_ARG"),
            ])
        case .unreadWithAnchor(let target):
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "INVALID_ARG"),
                OrderedJSONField("suggestedNextAction", "raft message read --target '\(target)' --unread"),
            ])
        case .anchorNotFound(let message):
            return .object([
                OrderedJSONField("error", message),
                OrderedJSONField("errorCode", "NOT_FOUND"),
            ])
        case .anchorAmbiguous(let message):
            return .object([
                OrderedJSONField("error", message),
                OrderedJSONField("errorCode", "AMBIGUOUS_ID"),
                OrderedJSONField(
                    "suggestedNextAction",
                    "Use the full message UUID instead of the 8-character short id."
                ),
            ])
        case .anchorInvalid(let message):
            return .object([
                OrderedJSONField("error", message),
                OrderedJSONField("errorCode", "INVALID_ARG"),
            ])
        case .dmTargetAmbiguous(let name):
            return DMTargetResolutionWire.ambiguous(name).body
        case .dmTargetInvalidPeerKind(let rawPeer, let suffix):
            return DMTargetResolutionWire.invalidPeerKind(rawPeer: rawPeer, suffix: suffix).body
        default:
            return nil
        }
    }
}
