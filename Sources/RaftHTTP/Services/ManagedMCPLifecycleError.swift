import Foundation

/// Domain failure for the read mutations, joint-invite accept, channel list,
/// profile completion, server create/details/analytics, provider connections
/// and push registration surfaces.
///
/// Every case is one published refusal; the retired handlers wrote the bodies by
/// hand and `Respond.swift` now renders them from `errorMessage` and
/// `errorCode`, so the bytes (`error`, then `code`) are unchanged.
public enum ManagedMCPLifecycleError: DomainError, Equatable {
    case unauthorized
    case notFound
    case channelNotFound
    case notAMember
    case forbidden
    case inviteNotFound
    case serverNotFound
    // Read mutations.
    case invalidMutationId
    case invalidMutationPayload
    case mutationPayloadMismatch
    // Profile and server.
    case profileSetupInvalid
    case profileSetupNameReserved
    case profileSetupAlreadyCompleted
    case profileSetupNameTaken
    case profileSetupRequired
    case invalidServerRequest
    case slugTaken
    case slugTooShort
    case productAnalyticsNotBoolean
    // Provider connections.
    case providerConnectionsDisabled
    case invalidProviderConnection
    case rotateCredentialSeparately
    case apiKeyRequired
    case providerConnectionNotFound
    case providerProbeRetired
    // Push.
    case invalidPushRegistration
    case invalidPushSubscription
    case invalidCapability
    case capabilityNoLongerValid
    case installationIdRequired

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .notFound, .channelNotFound, .inviteNotFound, .serverNotFound,
             .providerConnectionsDisabled, .providerConnectionNotFound:
            404
        case .notAMember, .forbidden, .profileSetupRequired, .capabilityNoLongerValid:
            403
        case .mutationPayloadMismatch, .profileSetupAlreadyCompleted, .profileSetupNameTaken,
             .slugTaken:
            409
        case .providerProbeRetired:
            410
        case .invalidMutationId, .invalidMutationPayload, .profileSetupInvalid,
             .profileSetupNameReserved, .invalidServerRequest, .slugTooShort,
             .productAnalyticsNotBoolean, .invalidProviderConnection, .rotateCredentialSeparately,
             .apiKeyRequired, .invalidPushRegistration, .invalidPushSubscription,
             .invalidCapability, .installationIdRequired:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .notFound: "Not found"
        case .channelNotFound: "Channel not found"
        case .notAMember: "Not a member of this server"
        case .forbidden: "Forbidden"
        case .inviteNotFound: "Invite not found"
        case .serverNotFound: "Server not found"
        case .invalidMutationId: "Invalid mutation id"
        case .invalidMutationPayload: "Invalid mutation payload"
        case .mutationPayloadMismatch: "Mutation id reused with a different payload"
        case .profileSetupInvalid: "name and displayName are required"
        case .profileSetupNameReserved: "This username is reserved. Choose another name."
        case .profileSetupAlreadyCompleted: "Profile setup is already completed"
        case .profileSetupNameTaken: "That username is taken"
        case .profileSetupRequired: "Profile setup required"
        case .invalidServerRequest: "Invalid server request"
        case .slugTaken: "Slug is already taken"
        case .slugTooShort: "Slug must be at least 5 characters"
        case .productAnalyticsNotBoolean: "productAnalyticsEnabled must be a boolean"
        case .providerConnectionsDisabled: "Provider connections are not enabled"
        case .invalidProviderConnection: "Invalid provider connection"
        case .rotateCredentialSeparately: "Rotate the credential separately from provider configuration"
        case .apiKeyRequired: "apiKey is required"
        case .providerConnectionNotFound: "Provider connection not found"
        case .providerProbeRetired: "Provider probing is retired"
        case .invalidPushRegistration: "Invalid push registration"
        case .invalidPushSubscription: "Invalid push subscription"
        case .invalidCapability: "Invalid capability"
        case .capabilityNoLongerValid: "Capability is no longer valid"
        case .installationIdRequired: "Valid installationId is required"
        }
    }

    public var errorCode: String? {
        switch self {
        case .invalidMutationId: "INVALID_MUTATION_ID"
        case .invalidMutationPayload: "INVALID_MUTATION_PAYLOAD"
        case .mutationPayloadMismatch: "MUTATION_ID_PAYLOAD_MISMATCH"
        case .profileSetupInvalid: "PROFILE_SETUP_INVALID"
        case .profileSetupNameReserved: "PROFILE_SETUP_NAME_RESERVED"
        case .profileSetupAlreadyCompleted: "PROFILE_SETUP_ALREADY_COMPLETED"
        case .profileSetupNameTaken: "PROFILE_SETUP_NAME_TAKEN"
        case .profileSetupRequired: "PROFILE_SETUP_REQUIRED"
        case .providerConnectionsDisabled: "provider_connections_disabled"
        case .providerProbeRetired: "provider_connection_retired"
        default: nil
        }
    }
}
