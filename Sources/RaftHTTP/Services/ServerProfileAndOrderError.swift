import Foundation

/// Domain failure for the server profile, switcher order, agreement,
/// translation, member-directory and scope-attestation routes.
///
/// Every case is one published refusal. The retired handlers built each body by
/// hand; `Respond.swift` now renders it from `errorMessage`, `errorCode` and
/// `errorBody`, so the bytes are unchanged. Refusals that share a status but
/// differ in text (`Not a member of this server` vs `Forbidden`) stay separate
/// cases.
public enum ServerProfileAndOrderError: DomainError, Equatable {
    /// The plain missing-session refusal (`{"error":"Unauthorized"}`).
    case unauthorized
    /// The `PublicVisits.authRequired` refusal the order/members routes use.
    case authRequired(bearerPresent: Bool)
    /// The machine scope-attestation refusal (`Unauthorized` + `auth_required`).
    case machineUnauthorized
    case notAMember
    case forbidden
    case agreementManageForbidden
    case invalidAgreementRequest
    case agreementTooLong
    case invalidServerOrder
    case notFound
    case translationDisabled
    case invalidTranslationRequest
    case translationProviderNotConfigured
    case llmTranslationUnavailable
    case translationSettingsForbidden
    case translationEnabledNotBoolean
    case invalidServerUpdate
    case serverNameRequired
    case hideHumansNotBoolean
    case userNotFound
    case memberGraphUnavailable
    case scopeAttestationNotConfigured
    case invalidAttestationRequest
    case audienceDerived
    case resourceDerived
    case unsupportedScope(String)
    case bundleContentTypeTooLong
    case bundleContentEncodingTooLong
    case feedbackReportIdNotUUID
    case agentIdNotUUID
    case deploymentEnvironmentNotAllowed(String)
    case deploymentEnvironmentInconsistent(String)
    case agentNotOnMachine
    case evidenceBundleTooLarge
    case outcomeBundleTooLarge
    case invalidScopeAttestationRequest
    case unknownScope

    public var status: UInt {
        switch self {
        case .unauthorized, .authRequired, .machineUnauthorized:
            401
        case .notAMember, .forbidden, .agreementManageForbidden, .translationDisabled,
             .llmTranslationUnavailable, .translationSettingsForbidden, .memberGraphUnavailable,
             .agentNotOnMachine:
            403
        case .notFound, .userNotFound:
            404
        case .translationProviderNotConfigured:
            409
        case .scopeAttestationNotConfigured:
            503
        case .invalidAgreementRequest, .agreementTooLong, .invalidServerOrder,
             .invalidTranslationRequest, .translationEnabledNotBoolean, .invalidServerUpdate,
             .serverNameRequired, .hideHumansNotBoolean, .invalidAttestationRequest,
             .audienceDerived, .resourceDerived, .unsupportedScope, .bundleContentTypeTooLong,
             .bundleContentEncodingTooLong, .feedbackReportIdNotUUID, .agentIdNotUUID,
             .deploymentEnvironmentNotAllowed, .deploymentEnvironmentInconsistent,
             .evidenceBundleTooLarge, .outcomeBundleTooLarge, .invalidScopeAttestationRequest,
             .unknownScope:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized:
            "Unauthorized"
        case .authRequired(let bearerPresent):
            bearerPresent
                ? "Invalid or expired token"
                : "Missing or invalid Authorization header"
        case .machineUnauthorized:
            "Unauthorized"
        case .notAMember:
            "Not a member of this server"
        case .forbidden:
            "Forbidden"
        case .agreementManageForbidden:
            "Only server owners and admins can manage the pre-join agreement"
        case .invalidAgreementRequest:
            "Invalid agreement request"
        case .agreementTooLong:
            "Agreement body must be 5000 characters or fewer"
        case .invalidServerOrder:
            "Invalid server order"
        case .notFound:
            "Not found"
        case .translationDisabled:
            "Translation is disabled for this server"
        case .invalidTranslationRequest:
            "Invalid translation request"
        case .translationProviderNotConfigured:
            "Translation provider is not configured"
        case .llmTranslationUnavailable:
            "LLM translation is not available for this server"
        case .translationSettingsForbidden:
            "Only server owners and admins can update translation settings"
        case .translationEnabledNotBoolean:
            "translationEnabled must be a boolean"
        case .invalidServerUpdate:
            "Invalid server update"
        case .serverNameRequired:
            "Server name is required"
        case .hideHumansNotBoolean:
            "hideHumansFromMembers must be a boolean"
        case .userNotFound:
            "User not found"
        case .memberGraphUnavailable:
            "Member graph is not available"
        case .scopeAttestationNotConfigured:
            "Scope attestation signing is not configured"
        case .invalidAttestationRequest:
            "Invalid attestation request"
        case .audienceDerived:
            "audience is derived from scope"
        case .resourceDerived:
            "resource is derived from scope"
        case .unsupportedScope(let scope):
            "Unsupported scope: \(scope)"
        case .bundleContentTypeTooLong:
            "bundleContentType is too long"
        case .bundleContentEncodingTooLong:
            "bundleContentEncoding is too long"
        case .feedbackReportIdNotUUID:
            "feedbackReportId must be a canonical UUID"
        case .agentIdNotUUID:
            "agentId must be a canonical UUID"
        case .deploymentEnvironmentNotAllowed(let environment):
            "deploymentEnvironment \(environment) is not in the allowed producer set"
        case .deploymentEnvironmentInconsistent(let message):
            message
        case .agentNotOnMachine:
            "Agent does not belong to this machine"
        case .evidenceBundleTooLarge:
            "Evidence bundle is too large"
        case .outcomeBundleTooLarge:
            "Outcome bundle is too large"
        case .invalidScopeAttestationRequest:
            "Invalid scope attestation request"
        case .unknownScope:
            "Unknown scope"
        }
    }

    public var errorCode: String? {
        switch self {
        case .authRequired, .machineUnauthorized:
            "auth_required"
        case .agentNotOnMachine:
            "agent_not_on_machine"
        case .evidenceBundleTooLarge:
            "evidence_bundle_too_large"
        case .outcomeBundleTooLarge:
            "outcome_bundle_too_large"
        case .unauthorized, .notAMember, .forbidden, .agreementManageForbidden,
             .invalidAgreementRequest, .agreementTooLong, .invalidServerOrder, .notFound,
             .translationDisabled, .invalidTranslationRequest, .translationProviderNotConfigured,
             .llmTranslationUnavailable, .translationSettingsForbidden,
             .translationEnabledNotBoolean, .invalidServerUpdate, .serverNameRequired,
             .hideHumansNotBoolean, .userNotFound, .memberGraphUnavailable,
             .scopeAttestationNotConfigured, .invalidAttestationRequest, .audienceDerived,
             .resourceDerived, .unsupportedScope, .bundleContentTypeTooLong,
             .bundleContentEncodingTooLong, .feedbackReportIdNotUUID, .agentIdNotUUID,
             .deploymentEnvironmentNotAllowed, .deploymentEnvironmentInconsistent,
             .invalidScopeAttestationRequest, .unknownScope:
            nil
        }
    }

    /// The two refusals that interpolated the caller-supplied text into the body
    /// without escaping it. The published bytes are kept as they were (a quote
    /// in the value prints a quote), so these two cases render raw.
    public var errorBody: OrderedJSON? {
        switch self {
        case .unsupportedScope(let scope):
            .raw("{\"error\":\"Unsupported scope: \(scope)\"}")
        case .deploymentEnvironmentNotAllowed(let environment):
            .raw("{\"error\":\"deploymentEnvironment \(environment) is not in the allowed producer set\"}")
        case .unauthorized, .authRequired, .machineUnauthorized, .notAMember, .forbidden,
             .agreementManageForbidden, .invalidAgreementRequest, .agreementTooLong,
             .invalidServerOrder, .notFound, .translationDisabled, .invalidTranslationRequest,
             .translationProviderNotConfigured, .llmTranslationUnavailable,
             .translationSettingsForbidden, .translationEnabledNotBoolean, .invalidServerUpdate,
             .serverNameRequired, .hideHumansNotBoolean, .userNotFound, .memberGraphUnavailable,
             .scopeAttestationNotConfigured, .invalidAttestationRequest, .audienceDerived,
             .resourceDerived, .bundleContentTypeTooLong, .bundleContentEncodingTooLong,
             .feedbackReportIdNotUUID, .agentIdNotUUID, .deploymentEnvironmentInconsistent,
             .agentNotOnMachine, .evidenceBundleTooLarge, .outcomeBundleTooLarge,
             .invalidScopeAttestationRequest, .unknownScope:
            nil
        }
    }

    /// `PublicVisits.authRequired` answered with `Cache-Control: no-store`.
    public var responseHeaders: [String: String] {
        switch self {
        case .authRequired:
            ["Cache-Control": "no-store"]
        default:
            [:]
        }
    }
}

// MARK: - Injected dependencies

/// Everything the server-profile surface reads that another domain owns.
///
/// The ledgers belong to their stores and the OAuth ledger; the human session
/// lookup and the machine-credential lookup belong to domains that have not
/// migrated, and the wall clock, the id generator and the process environment
/// are injected so the byte-exact attestation and translation paths can be
/// tested. `live(directory:)` wires them at the composition root.
struct ServerProfileAndOrderDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var machineIdForCredential: @Sendable (String?) -> String?
    var oauth: OAuthLedger
    var channels: ServersAndChannelsStore
    var messages: MessagesAndThreadsStore
    var profiles: AuthProfileStore
    var machines: MachinesAndComputersStore
    var agents: AgentsRuntimeStore
    var environment: @Sendable () -> [String: String]
    var now: @Sendable () -> Date
    var makeUUID: @Sendable () -> String

    static func live(directory source: EmailLoginDirectory) -> ServerProfileAndOrderDependencies {
        ServerProfileAndOrderDependencies(
            sessionUserId: { source.sessionUserId(authorization: $0) },
            machineIdForCredential: { source.machineIdForCredential(authorization: $0) },
            oauth: source.oauth,
            channels: source.serversAndChannelsStore,
            messages: source.messagesAndThreadsStore,
            profiles: source.authProfileStore,
            machines: source.machinesAndComputersStore,
            agents: source.agentsRuntimeStore,
            environment: { ProcessInfo.processInfo.environment },
            now: { Date() },
            makeUUID: { UUID().uuidString.lowercased() }
        )
    }
}
