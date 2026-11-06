import Foundation

/// Domain failure for the saved-message, direct-channel, read-state and agent
/// channel-mute routes. The shared channel refusals (`Not a member of this
/// server`, `Channel not found`, `Forbidden`, the archived refusal and the
/// agent bearer refusals) are thrown as `ChannelMembershipError`, and a missing
/// agent capability as `FeedbackLocatorError`.
public enum ManagedMCPToolExecutionError: DomainError, Equatable {
    case unauthorized
    case invalidSavedCheckRequest
    case invalidDirectMessagePeer
    case agentNotFoundInServer
    case directMessageTargetNotFound
    case displayPreferencesOnParentChannel
    case collapseLongMessagesNotBoolean
    case invalidReadSeq
    case invalidResumeRequest
    case agentIdsNotArray
    case invalidChannelTarget
    case agentNotChannelMember

    public var status: UInt {
        switch self {
        case .unauthorized: 401
        case .agentNotChannelMember: 403
        case .agentNotFoundInServer, .directMessageTargetNotFound: 404
        case .invalidSavedCheckRequest, .invalidDirectMessagePeer, .displayPreferencesOnParentChannel,
             .collapseLongMessagesNotBoolean, .invalidReadSeq, .invalidResumeRequest,
             .agentIdsNotArray, .invalidChannelTarget:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .invalidSavedCheckRequest: "Invalid saved check request"
        case .invalidDirectMessagePeer: "Invalid DM peer"
        case .agentNotFoundInServer: "Agent not found in this server"
        case .directMessageTargetNotFound: "DM target not found"
        case .displayPreferencesOnParentChannel: "Display preferences are stored on the parent channel"
        case .collapseLongMessagesNotBoolean: "collapseLongMessages must be a boolean"
        case .invalidReadSeq: "seq must be a non-negative integer"
        case .invalidResumeRequest: "Invalid resume request"
        case .agentIdsNotArray: "agentIds must be an array of agent ids"
        case .invalidChannelTarget: "Invalid channel target"
        case .agentNotChannelMember: "Agent is not a member of this channel"
        }
    }

    public var errorCode: String? {
        switch self {
        case .agentNotChannelMember: "not_channel_member"
        case .unauthorized, .invalidSavedCheckRequest, .invalidDirectMessagePeer, .agentNotFoundInServer,
             .directMessageTargetNotFound, .displayPreferencesOnParentChannel,
             .collapseLongMessagesNotBoolean, .invalidReadSeq, .invalidResumeRequest,
             .agentIdsNotArray, .invalidChannelTarget:
            nil
        }
    }
}
