import Foundation

/// The channel SOS route's request-level refusals. Per-agent stop failures use
/// the response `results[].error` field instead of failing the request.
public enum ChannelAgentControlError: DomainError, Equatable {
    case controlRuntimeRequired
    case channelNotFound

    public var status: UInt {
        switch self {
        case .controlRuntimeRequired: 403
        case .channelNotFound: 404
        }
    }

    public var errorMessage: String {
        switch self {
        case .controlRuntimeRequired:
            "The `controlAgentRuntime` capability is required to stop all agents in a channel"
        case .channelNotFound:
            "Channel not found"
        }
    }

    public var errorCode: String? { nil }
}

/// Channel conversion is not implemented by this port; the pinned default
/// (feature flag absent or off) answers the documented disabled 404 before any
/// channel or job lookup. The conversion routes use that default.
public enum ChannelConversionError: DomainError, Equatable {
    case disabled

    public var status: UInt { 404 }

    public var errorMessage: String { "Channel to Joint conversion is not enabled" }

    public var errorCode: String? { "channel_to_joint_conversion_disabled" }
}
