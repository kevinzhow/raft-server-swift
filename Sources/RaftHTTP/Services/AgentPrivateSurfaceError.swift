import Foundation

/// Domain failure for the agent records and their private surfaces.
///
/// Every case is one published refusal. The retired handlers built the bodies by
/// hand; `Respond.swift` renders them from `errorMessage`, `errorCode` and
/// `errorBody`, so the bytes are unchanged. Several refusals publish `code`
/// before `error` and supply `errorBody` for that order.
public enum AgentPrivateSurfaceError: DomainError, Equatable {
    case unauthorized
    /// `Unauthorized` with `code: auth_required` (the assistant-owner route).
    case authRequired
    case notAMember
    case forbidden
    case agentNotFound
    /// `404` with `code` first: the management routes' missing agent.
    case agentMissing
    // Creation.
    case invalidAgent
    case reservedName
    case onboardingRequiresAdmin
    case onboardingAgentExists(agentId: String)
    case cindyExists
    case nameTaken
    case externalWithMachine
    case unknownRuntimeProvider
    case providerOnlyForExternal
    case runtimeProviderDisabled
    case grokRuntimeDisabled
    case invalidMachineId
    case machineNotInServer
    case grokCapabilityUnavailable
    case invalidRuntimeConfig(String)
    case runtimeFormFailure(status: UInt, message: String, code: String, pointer: String?)
    case runtimeProviderNotConfigured
    case invalidProviderConnectionId
    case providerConnectionUnavailable
    case modelNotAvailable
    case deprecatedRuntime(String)
    case runtimeConfigModelNameRequired
    case runtimeConfigProviderNotSupportedForCursor
    case runtimeConfigProviderAPIKeyRequired
    case invalidEnvVars(String)
    case commandNotSupported(runtime: String)
    case builtinCatalogUnavailable
    // Credentials, avatar and status.
    case insufficientCredentialRole
    case agentNotExternalCoded
    case agentNotExternal
    case invalidCreator
    case avatarTooLarge(maxBytes: Int)
    case bootstrapDisabled
    case bootstrapTokenRequired
    case tokenInvalid
    // Wake hints and push webhook.
    case missingAuthorizationHeader
    case invalidToken
    case sinceInvalid
    case webhookFieldsRequired
    // Patch.
    case invalidAgentUpdate
    case invalidRestartMode(String)
    case externalRuntimeImmutable
    case serverRoleMustBeString
    case invalidServerRole
    case onlyOwnerCanDemoteAdmin
    case onlyOwnerCanPromote
    // Assistant ownership.
    case assistantRequiresCreator
    case assistantNotEnabled
    case assistantAlreadySet
    case assistantHasChannels
    case assistantReadNotEnabled
    case channelNotVisible

    public var status: UInt {
        switch self {
        case .runtimeFormFailure(let status, _, _, _):
            status
        case .unauthorized, .authRequired, .tokenInvalid, .missingAuthorizationHeader, .invalidToken:
            401
        case .notAMember, .forbidden, .onboardingRequiresAdmin, .runtimeProviderDisabled, .grokRuntimeDisabled,
             .insufficientCredentialRole, .assistantRequiresCreator, .assistantNotEnabled,
             .assistantReadNotEnabled, .onlyOwnerCanDemoteAdmin, .onlyOwnerCanPromote:
            403
        case .agentNotFound, .agentMissing, .bootstrapDisabled, .channelNotVisible:
            404
        case .onboardingAgentExists, .cindyExists, .nameTaken, .runtimeProviderNotConfigured, .grokCapabilityUnavailable,
             .providerConnectionUnavailable, .builtinCatalogUnavailable, .assistantAlreadySet,
             .assistantHasChannels:
            409
        case .invalidAgent, .reservedName, .externalWithMachine, .unknownRuntimeProvider,
             .invalidMachineId, .machineNotInServer, .invalidRuntimeConfig,
             .providerOnlyForExternal, .invalidProviderConnectionId, .modelNotAvailable,
             .deprecatedRuntime, .runtimeConfigModelNameRequired,
             .runtimeConfigProviderNotSupportedForCursor, .runtimeConfigProviderAPIKeyRequired,
             .invalidEnvVars, .commandNotSupported, .agentNotExternalCoded, .agentNotExternal,
             .invalidCreator, .avatarTooLarge, .bootstrapTokenRequired, .sinceInvalid,
             .webhookFieldsRequired, .invalidAgentUpdate, .invalidRestartMode,
             .externalRuntimeImmutable, .serverRoleMustBeString, .invalidServerRole:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .runtimeFormFailure(_, let message, _, _):
            message
        case .unauthorized, .authRequired:
            "Unauthorized"
        case .notAMember:
            "Not a member of this server"
        case .forbidden:
            "Forbidden"
        case .agentNotFound, .agentMissing:
            "Agent not found"
        case .invalidAgent:
            "Invalid Agent"
        case .reservedName:
            "This username is reserved. Choose another name."
        case .onboardingRequiresAdmin:
            "Only server owners and admins can create the onboarding agent"
        case .onboardingAgentExists:
            "Onboarding agent already exists"
        case .cindyExists:
            "Cindy agent already exists"
        case .nameTaken:
            "Agent name is already taken"
        case .externalWithMachine:
            "External agents cannot be assigned to a Computer"
        case .unknownRuntimeProvider:
            "Unknown runtime provider"
        case .providerOnlyForExternal:
            "provider is only for external agents"
        case .runtimeProviderDisabled:
            "The hosted runtime provider is not enabled for this server"
        case .grokRuntimeDisabled:
            "Grok Build is not enabled on this server"
        case .invalidMachineId:
            "Invalid machineId: must be a UUID"
        case .machineNotInServer:
            "Machine not found in this server"
        case .grokCapabilityUnavailable:
            "Grok Build is not available on this computer"
        case .invalidRuntimeConfig(let message):
            message
        case .runtimeProviderNotConfigured:
            "The hosted runtime provider is not configured for this deployment"
        case .invalidProviderConnectionId:
            "Invalid provider connection id"
        case .providerConnectionUnavailable:
            "Provider connection is not available"
        case .modelNotAvailable:
            "The selected model is not available on this Computer"
        case .deprecatedRuntime(let runtime):
            "Runtime is deprecated and cannot be selected: \(runtime)"
        case .runtimeConfigModelNameRequired:
            "runtimeConfig.model.name is required"
        case .runtimeConfigProviderNotSupportedForCursor:
            "runtimeConfig.provider is not supported for runtime: cursor"
        case .runtimeConfigProviderAPIKeyRequired:
            "runtimeConfig.provider.apiKey is required"
        case .invalidEnvVars(let message):
            message
        case .commandNotSupported(let runtime):
            "runtimeConfig.command is not supported for runtime: \(runtime)"
        case .builtinCatalogUnavailable:
            "The target Computer's Built-in model catalog is unavailable. Retry after the Computer reconnects."
        case .insufficientCredentialRole:
            "issueAgentCredentials requires human creator authority"
        case .agentNotExternalCoded:
            "Only external Agents get bootstrap tokens"
        case .agentNotExternal:
            "Agent is not external"
        case .invalidCreator:
            "Invalid creator"
        case .avatarTooLarge:
            "Avatar image must be 5 MB or smaller"
        case .bootstrapDisabled:
            "Self-hosted runner bootstrap is not enabled"
        case .bootstrapTokenRequired:
            "bootstrapToken is required"
        case .tokenInvalid:
            "token_invalid"
        case .missingAuthorizationHeader:
            "Missing or invalid Authorization header"
        case .invalidToken:
            "Invalid or expired token"
        case .sinceInvalid:
            "since / Last-Event-ID must be a non-negative integer (messageSeq) or 'latest'"
        case .webhookFieldsRequired:
            "url and secret are required"
        case .invalidAgentUpdate:
            "Invalid Agent update"
        case .invalidRestartMode(let mode):
            "Invalid restart mode: \(mode)"
        case .externalRuntimeImmutable:
            "External agent runtime fields are immutable"
        case .serverRoleMustBeString:
            "serverRole must be a string"
        case .invalidServerRole:
            "Invalid server role"
        case .onlyOwnerCanDemoteAdmin:
            "Only the owner can demote an admin agent"
        case .onlyOwnerCanPromote:
            "Only the owner can promote this agent"
        case .assistantRequiresCreator:
            "Only the agent creator can lend assistant ownership"
        case .assistantNotEnabled:
            "Assistant ownership is not enabled"
        case .assistantAlreadySet:
            "This user already has an assistant"
        case .assistantHasChannels:
            "An assistant can only be in its DM with its owner"
        case .assistantReadNotEnabled:
            "Assistant ownership is not enabled for this agent"
        case .channelNotVisible:
            "Channel not found or not visible"
        }
    }

    public var errorCode: String? {
        switch self {
        case .authRequired, .missingAuthorizationHeader, .invalidToken:
            "auth_required"
        case .runtimeProviderDisabled:
            "agent_runtime_provider_disabled"
        case .grokRuntimeDisabled:
            "grok_runtime_disabled"
        case .grokCapabilityUnavailable:
            "runtime_capability_unavailable"
        case .runtimeProviderNotConfigured:
            "agent_runtime_provider_not_configured"
        case .bootstrapDisabled:
            "self_hosted_runner_bootstrap_disabled"
        case .bootstrapTokenRequired:
            "missing_bootstrap_token"
        case .tokenInvalid:
            "token_invalid"
        case .sinceInvalid:
            "since_invalid"
        case .channelNotVisible:
            "channel_not_found"
        case .agentMissing:
            "agent_missing"
        case .builtinCatalogUnavailable:
            "builtin_catalog_unavailable"
        case .insufficientCredentialRole:
            "insufficient_role"
        case .agentNotExternalCoded:
            "agent_not_external"
        case .assistantRequiresCreator:
            "assistant_requires_creator"
        case .assistantNotEnabled, .assistantReadNotEnabled:
            "assistant_not_enabled"
        case .assistantAlreadySet:
            "assistant_already_set"
        case .assistantHasChannels:
            "assistant_has_channels"
        default:
            nil
        }
    }

    /// The refusals whose published order is not `error` then `code`, or that
    /// carry members after it.
    public var errorBody: OrderedJSON? {
        switch self {
        case .runtimeFormFailure(_, let message, let code, let pointer):
            .object([
                .init("error", message),
                pointer.map { value in
                    .init("issues", .array([.object([.init("code", code), .init("pointer", value)])]))
                } ?? .init("code", code),
            ])
        case .agentMissing, .builtinCatalogUnavailable, .insufficientCredentialRole,
             .agentNotExternalCoded, .assistantRequiresCreator, .assistantNotEnabled,
             .assistantAlreadySet, .assistantHasChannels, .assistantReadNotEnabled:
            .object([
                OrderedJSONField("code", errorCode ?? ""),
                OrderedJSONField("error", errorMessage),
            ])
        case .onboardingAgentExists(let agentId):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("onboardingAgentId", agentId),
            ])
        case .invalidProviderConnectionId:
            issues(pointer: "/formValues/providerId", code: "provider_connection_id_invalid")
        case .providerConnectionUnavailable:
            issues(pointer: "/formValues/providerId", code: "provider_connection_unavailable")
        case .modelNotAvailable:
            issues(pointer: "/formValues/model", code: "model_not_available")
        // Restart errors contain raw request text; use the shared JSON escaper.
        case .invalidRestartMode:
            .object([OrderedJSONField("error", errorMessage)])
        // Preserve the legacy command refusal's existing wire representation.
        case .commandNotSupported(let runtime):
            .raw("{\"error\":\"runtimeConfig.command is not supported for runtime: \(runtime)\"}")
        case .avatarTooLarge(let maxBytes):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "PROFILE_AVATAR_TOO_LARGE"),
                OrderedJSONField("maxBytes", maxBytes),
            ])
        default:
            nil
        }
    }

    private func issues(pointer: String, code: String) -> OrderedJSON {
        .object([
            OrderedJSONField("error", errorMessage),
            OrderedJSONField("issues", .array([
                .object([
                    OrderedJSONField("pointer", pointer),
                    OrderedJSONField("code", code),
                ]),
            ])),
        ])
    }
}

/// A real template-conversion failure. One occurrence identity links body/header.
struct AgentValueCoercionFailure: DomainError {
    let errorMessage: String
    let correlationId = UUID().uuidString.lowercased()
    var status: UInt { 500 }
    var responseHeaders: [String: String] { ["X-Slock-Error-Id": correlationId] }
    var errorBody: OrderedJSON? {
        .object([.init("error", errorMessage), .init("correlationId", correlationId)])
    }
}
