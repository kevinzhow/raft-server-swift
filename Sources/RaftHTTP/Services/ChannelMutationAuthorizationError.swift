/// channels.ts:2552-2553 publishes the capability refusal for every requested
/// update field before updateChannel changes the channel.
enum ChannelMutationAuthorizationError: DomainError, Equatable {
    case capabilityRequired
    var status: UInt { 403 }
    var errorMessage: String { "You do not have permission to update channels" }
}
