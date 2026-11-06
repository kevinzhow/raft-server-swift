import Foundation

/// Domain failure for the onboarding identity adoption, the hosted runtime
/// reads and writes, and the provider account connections.
///
/// Every case is one published refusal. The retired handlers built the bodies
/// by hand; `Respond.swift` renders them from `errorMessage`, `errorCode` and
/// `errorBody`, so the bytes are unchanged.
public enum MachinesAndHostedRuntimeError: DomainError, Equatable {
    case unauthorized
    case agentNotFound
    /// `403` naming the capability the action needs.
    case authorityRequired(String)
    case notOnboardingAgent
    case nameTaken
    case hostedRuntimeMissing
    case usageInvalidQuery
    case usageNotReady
    case modelInvalid
    case modelPickerDisabled
    case modelLocked
    case modelNotOffered
    case modelRequired
    case modelNotReady
    case nothingToRetry
    // Provider account connections.
    case connectionProviderUnknown
    case connectionForbidden
    case connectionNotProviderBacked
    case connectionAgentNotActive(state: String)
    case connectionInvalid(String)
    case connectionAccessInvalid
    case connectionPendingInvalid(providerCode: String?, providerMessage: String?)
    case connectionConnectorNotFound
    case connectionConnectorForbidden
    case connectionUnsupported
    case connectionAgentMissingAtProvider(providerMessage: String?)
    case connectionProviderRefused(message: String, providerCode: String?, providerMessage: String?, providerStatus: Int)
    case connectionProviderError(providerCode: String?, providerMessage: String?, providerStatus: Int?)
    case connectionConnectorDisconnectPartial(failedCount: Int)

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .authorityRequired, .modelPickerDisabled, .connectionForbidden,
             .connectionConnectorForbidden:
            403
        case .agentNotFound, .hostedRuntimeMissing, .connectionProviderUnknown,
             .connectionPendingInvalid, .connectionConnectorNotFound:
            404
        case .notOnboardingAgent, .usageInvalidQuery, .modelInvalid, .connectionNotProviderBacked,
             .connectionInvalid, .connectionAccessInvalid:
            400
        case .nameTaken, .usageNotReady, .modelLocked, .modelRequired, .modelNotReady,
             .nothingToRetry, .connectionAgentNotActive, .connectionUnsupported,
             .connectionAgentMissingAtProvider, .connectionProviderRefused:
            409
        case .modelNotOffered:
            422
        case .connectionProviderError, .connectionConnectorDisconnectPartial:
            502
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .agentNotFound:
            "Agent not found"
        case .authorityRequired(let message):
            message
        case .notOnboardingAgent:
            "Agent is not this server's onboarding agent"
        case .nameTaken:
            "Agent name is already taken"
        case .hostedRuntimeMissing:
            "Agent is not a cloud agent"
        case .usageInvalidQuery:
            "Invalid usage query"
        case .usageNotReady, .modelNotReady:
            "The cloud runtime is not ready"
        case .modelInvalid:
            "`model` must be a model id or null"
        case .modelPickerDisabled:
            "This server does not pick a cloud agent model"
        case .modelLocked:
            "An administrator has set this agent's model"
        case .modelNotOffered:
            "The provider does not offer this model"
        case .modelRequired:
            "The provider refused the picked model; retry with `model` set to an offered id, or null for the default"
        case .nothingToRetry:
            "Nothing to retry"
        case .connectionProviderUnknown:
            "Unknown connection provider"
        case .connectionForbidden:
            "Only the agent's creator or a server owner/admin can manage its connections"
        case .connectionNotProviderBacked:
            "Agent is not a cloud agent"
        case .connectionAgentNotActive:
            "The agent is not provisioned on its provider yet"
        case .connectionInvalid(let message):
            message
        case .connectionAccessInvalid:
            "access must be \"private\" when present"
        case .connectionPendingInvalid:
            "The connection link expired or is invalid; start again"
        case .connectionConnectorNotFound:
            "That connection does not exist on this server"
        case .connectionConnectorForbidden:
            "Only the connection's creator or a server admin can assign or disconnect it"
        case .connectionUnsupported:
            "The provider does not support connections"
        case .connectionAgentMissingAtProvider:
            "This agent no longer exists at its provider; connections are unavailable. Recreate the agent."
        case .connectionProviderRefused(let message, _, _, _):
            message
        case .connectionProviderError:
            "The provider could not complete the request"
        case .connectionConnectorDisconnectPartial:
            "Disconnect partially completed; retry to finish"
        }
    }

    public var errorCode: String? {
        switch self {
        case .hostedRuntimeMissing:
            "hosted_runtime_missing"
        case .usageInvalidQuery:
            "hosted_runtime_usage_invalid_query"
        case .usageNotReady:
            "hosted_runtime_usage_not_ready"
        case .modelInvalid:
            "hosted_runtime_model_invalid"
        case .modelPickerDisabled:
            "model_picker_disabled"
        case .modelLocked:
            "hosted_runtime_model_locked"
        case .modelNotOffered:
            "hosted_runtime_model_not_offered"
        case .modelRequired:
            "hosted_runtime_model_required"
        case .modelNotReady:
            "hosted_runtime_model_not_ready"
        case .nothingToRetry:
            "hosted_runtime_nothing_to_retry"
        case .connectionProviderUnknown:
            "agent_connection_provider_unknown"
        case .connectionForbidden:
            "agent_connection_forbidden"
        case .connectionNotProviderBacked:
            "agent_connection_not_provider_backed"
        case .connectionAgentNotActive:
            "agent_connection_agent_not_active"
        case .connectionInvalid, .connectionAccessInvalid:
            "agent_connection_invalid"
        case .connectionPendingInvalid:
            "agent_connection_pending_invalid"
        case .connectionConnectorNotFound:
            "agent_connection_connector_not_found"
        case .connectionConnectorForbidden:
            "agent_connection_connector_forbidden"
        case .connectionUnsupported:
            "agent_connection_unsupported"
        case .connectionAgentMissingAtProvider:
            "agent_connection_agent_missing_at_provider"
        case .connectionProviderRefused:
            "agent_connection_provider_refused"
        case .connectionProviderError:
            "agent_connection_provider_error"
        case .connectionConnectorDisconnectPartial:
            "agent_connection_connector_disconnect_partial"
        case .unauthorized, .agentNotFound, .authorityRequired, .notOnboardingAgent, .nameTaken:
            nil
        }
    }

    /// The refusals that publish members after `code`.
    public var errorBody: OrderedJSON? {
        switch self {
        case .connectionAgentNotActive(let state):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "agent_connection_agent_not_active"),
                OrderedJSONField("state", state),
            ])
        case .connectionPendingInvalid(let providerCode, let providerMessage):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "agent_connection_pending_invalid"),
                OrderedJSONField("providerCode", optional: providerCode),
                OrderedJSONField("providerMessage", optional: providerMessage),
            ])
        case .connectionAgentMissingAtProvider(let providerMessage):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "agent_connection_agent_missing_at_provider"),
                OrderedJSONField("providerMessage", optional: providerMessage),
            ])
        case .connectionProviderRefused(_, let providerCode, let providerMessage, let providerStatus):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "agent_connection_provider_refused"),
                OrderedJSONField("providerCode", optional: providerCode),
                OrderedJSONField("providerMessage", optional: providerMessage),
                OrderedJSONField("providerStatus", providerStatus),
            ])
        case .connectionProviderError(let providerCode, let providerMessage, let providerStatus):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "agent_connection_provider_error"),
                OrderedJSONField("providerCode", optional: providerCode),
                OrderedJSONField("providerMessage", optional: providerMessage),
                OrderedJSONField("providerStatus", optional: providerStatus),
            ])
        case .connectionConnectorDisconnectPartial(let failedCount):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "agent_connection_connector_disconnect_partial"),
                OrderedJSONField("failedCount", failedCount),
            ])
        default:
            nil
        }
    }
}
