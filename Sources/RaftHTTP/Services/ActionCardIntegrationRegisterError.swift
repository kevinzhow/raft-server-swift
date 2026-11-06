import Foundation

/// Domain failure for the action-card prepare/execute and integration
/// app-registration operations.
///
/// Every case publishes the bytes the retired handler built: the default
/// `{"error": …}` object, that same object plus `code` when the domain publishes
/// one, or an explicit `errorBody` where the upstream member key is
/// `errorCode`, where more keys follow, or where the order is not
/// `error`, `code`. `Respond.swift` is the only place one becomes a response.
public enum ActionCardIntegrationRegisterError: DomainError, Equatable {
    // Agent credential refusals (integration app prepare).
    case invalidOrExpiredToken
    case capabilityNotAuthorized(capability: String)
    // Agent credential refusals (prepare-action, the feedback-locator shape).
    case missingAuthorization
    case invalidAccessToken
    case invalidAgentCredential
    // Shared prepare refusals.
    case invalidActionCardRequest
    case targetChannelNotFound
    case requesterAgentNotFound
    case agentNotFound
    case integrationAppNotFound
    case invalidAppRegistrationRequest
    case scopeNotAllowed
    case categoryNotAllowed
    case unsafeDemoUrlRequiresOverride
    case invalidAppMetadata(String)
    case integrationApprovalNotPreparable
    case channelTargetInvalid
    case initialAgentInvalid(index: Int)
    case initialHumanInvalid(index: Int)
    case invalidChannelName
    case targetNotAccessible
    // Execute refusals.
    case unauthorized
    case forbidden
    case notAMember
    case actionCardNotFound
    case onlyAdminsCanInstall
    case onlyAdminsCanRegister
    case stateChanged
    case notExecuted
    case marketplaceAppChanged
    case marketplaceAppIdentityChanged
    case appSetupChanged
    case agentBindingChanged
    case registerAgentBindingChanged
    case agentRegistrationRejected(String)
    case invalidAppRegistration
    case duplicateChannel(reason: String)
    case idempotencyKeyReused

    public var status: UInt {
        switch self {
        case .invalidOrExpiredToken, .missingAuthorization, .invalidAccessToken,
             .invalidAgentCredential, .unauthorized:
            401
        case .capabilityNotAuthorized, .forbidden, .notAMember, .onlyAdminsCanInstall,
             .onlyAdminsCanRegister, .targetNotAccessible:
            403
        case .targetChannelNotFound, .requesterAgentNotFound, .agentNotFound,
             .integrationAppNotFound, .actionCardNotFound:
            404
        case .invalidActionCardRequest, .invalidAppRegistrationRequest, .scopeNotAllowed,
             .categoryNotAllowed, .unsafeDemoUrlRequiresOverride, .invalidAppMetadata,
             .integrationApprovalNotPreparable, .channelTargetInvalid,
             .initialAgentInvalid, .initialHumanInvalid, .invalidChannelName,
             .invalidAppRegistration:
            400
        case .stateChanged, .notExecuted, .marketplaceAppChanged,
             .marketplaceAppIdentityChanged, .appSetupChanged, .agentBindingChanged,
             .registerAgentBindingChanged, .agentRegistrationRejected,
             .duplicateChannel, .idempotencyKeyReused:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidOrExpiredToken:
            "Invalid or expired token"
        case .capabilityNotAuthorized:
            "Agent credential is not authorized for this capability"
        case .missingAuthorization:
            "Missing or invalid Authorization header"
        case .invalidAccessToken:
            "Invalid or expired token"
        case .invalidAgentCredential:
            "Invalid agent credential"
        case .invalidActionCardRequest:
            "Invalid action card request"
        case .targetChannelNotFound:
            "Target channel not found"
        case .requesterAgentNotFound:
            "Requester agent not found"
        case .agentNotFound:
            "Requester agent not found"
        case .integrationAppNotFound:
            "Integration app not found"
        case .invalidAppRegistrationRequest:
            "Invalid app registration request"
        case .scopeNotAllowed:
            "Scope is not allowed for this service"
        case .categoryNotAllowed:
            "Category is not allowed"
        case .unsafeDemoUrlRequiresOverride:
            "Unsafe demo URL requires the override"
        case .invalidAppMetadata(let message):
            message
        case .integrationApprovalNotPreparable:
            "Integration approval cards must be prepared with the raft integration commands"
        case .channelTargetInvalid:
            "channel must belong to this server"
        case .initialAgentInvalid(let index):
            "initialAgents[\(index)] is not an agent on this server"
        case .initialHumanInvalid(let index):
            "initialHumans[\(index)] is not a member of this server"
        case .invalidChannelName:
            "Invalid channel name"
        case .targetNotAccessible:
            "Target channel is not accessible"
        case .unauthorized:
            "Unauthorized"
        case .forbidden:
            "Forbidden"
        case .notAMember:
            "Not a member of this server"
        case .actionCardNotFound:
            "Action card not found"
        case .onlyAdminsCanInstall:
            "Only Server owners and admins can install Marketplace apps"
        case .onlyAdminsCanRegister:
            "Only Server owners and admins can register apps"
        case .stateChanged:
            "The action card state changed"
        case .notExecuted:
            "The action card is not executed"
        case .marketplaceAppChanged:
            "Marketplace app is no longer installable with this card; prepare a fresh login request"
        case .marketplaceAppIdentityChanged:
            "Marketplace app identity changed; prepare a fresh login request"
        case .appSetupChanged:
            "The App setup declaration changed; prepare a fresh request"
        case .agentBindingChanged:
            "Requesting agent identity changed; prepare a fresh login request"
        case .registerAgentBindingChanged:
            "Requesting agent no longer exists; prepare a fresh request"
        case .agentRegistrationRejected(let message):
            message
        case .invalidAppRegistration:
            "Invalid app registration"
        case .duplicateChannel(let reason):
            reason
        case .idempotencyKeyReused:
            "This idempotencyKey was already used for a different request"
        }
    }

    /// The default body is `error` then `code`. Key `errorCode`, the extra
    /// `requiredCapability`/`reason`/`mismatch` members, and the
    /// `code`-before-`error` ordering need the explicit tree.
    public var errorBody: OrderedJSON? {
        switch self {
        case .invalidOrExpiredToken:
            Self.body("error", errorMessage, "code", "auth_required")
        case .capabilityNotAuthorized(let capability):
            Self.body(
                "error", errorMessage,
                "code", "capability_not_authorized",
                "requiredCapability", capability
            )
        case .missingAuthorization:
            FeedbackLocatorError.authErrorBody(
                error: errorMessage,
                code: "auth_required"
            )
        case .invalidAccessToken, .invalidAgentCredential:
            FeedbackLocatorError.authErrorBody(
                error: errorMessage,
                code: "auth_required"
            )
        case .invalidActionCardRequest, .invalidChannelName:
            Self.body("error", errorMessage, "code", "INVALID_PAYLOAD")
        case .targetChannelNotFound:
            Self.body("error", errorMessage, "code", "TARGET_NOT_FOUND")
        case .requesterAgentNotFound, .agentNotFound:
            Self.body("error", errorMessage, "code", "AGENT_NOT_FOUND")
        case .integrationAppNotFound:
            .object([OrderedJSONField("error", errorMessage)])
        case .invalidAppRegistrationRequest, .invalidAppMetadata:
            Self.body("error", errorMessage, "errorCode", "INVALID_APP_METADATA")
        case .scopeNotAllowed:
            Self.body("error", errorMessage, "errorCode", "INVALID_SCOPE")
        case .categoryNotAllowed:
            Self.body("error", errorMessage, "errorCode", "INVALID_CATEGORY")
        case .unsafeDemoUrlRequiresOverride:
            Self.body(
                "error", errorMessage,
                "errorCode", "UNSAFE_DEMO_URL_REQUIRES_OVERRIDE"
            )
        case .integrationApprovalNotPreparable:
            Self.body("error", errorMessage, "errorCode", "ACTION_TYPE_NOT_PREPARABLE")
        case .channelTargetInvalid, .initialAgentInvalid, .initialHumanInvalid:
            Self.body("error", errorMessage, "code", "INVALID_PAYLOAD")
        case .targetNotAccessible:
            Self.body("error", errorMessage, "code", "TARGET_NOT_ACCESSIBLE")
        case .unauthorized, .forbidden, .notAMember:
            .object([OrderedJSONField("error", errorMessage)])
        case .actionCardNotFound:
            Self.body("error", errorMessage, "code", "NOT_FOUND")
        case .onlyAdminsCanInstall, .onlyAdminsCanRegister:
            Self.body("error", errorMessage, "errorCode", "FORBIDDEN")
        case .stateChanged, .notExecuted:
            Self.body("error", errorMessage, "code", "STATE_MISMATCH")
        case .marketplaceAppChanged, .marketplaceAppIdentityChanged:
            Self.body("error", errorMessage, "errorCode", "MARKETPLACE_APP_CHANGED")
        case .appSetupChanged:
            Self.body("error", errorMessage, "errorCode", "APP_SETUP_CHANGED")
        case .agentBindingChanged, .registerAgentBindingChanged:
            Self.body("error", errorMessage, "errorCode", "AGENT_BINDING_CHANGED")
        case .agentRegistrationRejected:
            Self.body("error", errorMessage, "errorCode", "APP_REGISTRATION_REJECTED")
        case .invalidAppRegistration:
            Self.body("error", errorMessage, "errorCode", "INVALID_APP_METADATA")
        case .duplicateChannel(let reason):
            .object([
                OrderedJSONField("error", reason),
                OrderedJSONField("code", "ACTION_FAILED"),
                OrderedJSONField("reason", reason),
            ])
        case .idempotencyKeyReused:
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "idempotency_key_reused"),
                OrderedJSONField("mismatch", "request"),
                OrderedJSONField(
                    "suggestedNextAction",
                    "Retry with a new idempotencyKey."
                ),
            ])
        }
    }

    /// The two-member `{"error": …}` / `{"error": …, "code"/"errorCode": …}`
    /// bodies, in published order.
    private static func body(
        _ firstKey: String,
        _ firstValue: String,
        _ secondKey: String,
        _ secondValue: String
    ) -> OrderedJSON {
        .object([
            OrderedJSONField(firstKey, firstValue),
            OrderedJSONField(secondKey, secondValue),
        ])
    }

    private static func body(
        _ firstKey: String,
        _ firstValue: String,
        _ secondKey: String,
        _ secondValue: String,
        _ thirdKey: String,
        _ thirdValue: String
    ) -> OrderedJSON {
        .object([
            OrderedJSONField(firstKey, firstValue),
            OrderedJSONField(secondKey, secondValue),
            OrderedJSONField(thirdKey, thirdValue),
        ])
    }
}
