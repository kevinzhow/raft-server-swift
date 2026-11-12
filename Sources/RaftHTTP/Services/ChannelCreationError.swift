/// Published create-channel validation before any channel or membership write.
/// Upstream routes/channels.ts:942-997 validates visibility and every selected
/// initial principal before channelService.createChannel commits the bootstrap.
enum ChannelCreationError: DomainError, Equatable {
    case invalidVisibility
    case agentOutsideServer
    case userOutsideServer

    var status: UInt { 400 }
    var errorMessage: String {
        switch self {
        case .invalidVisibility: "visibility must be one of: public, private, joint"
        case .agentOutsideServer: "Agent not found in this server"
        case .userOutsideServer: "User is not a member of this server"
        }
    }
}
