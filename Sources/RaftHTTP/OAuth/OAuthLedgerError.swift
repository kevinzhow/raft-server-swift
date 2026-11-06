import Foundation

/// Why an OAuth ledger operation refused, with the exact status, body and
/// cache policy the retired `HTTPReply` projection published.
///
/// The `reason` is the machine-readable case; `cacheControl` is the one header
/// that differs between surfaces sharing a reason (the installation-token and
/// App-installation routes publish `private, no-store`, the agent directory
/// `no-store`, the rest none). `Respond.swift` renders the error through
/// `DomainError.errorBody` / `errorHeaders`, so the bytes match the legacy
/// replies member for member.
public struct OAuthLedgerError: DomainError, Equatable {
    /// Why a requested scope list was refused (`invalid_scope` with detail).
    public struct ScopeRejection: Sendable, Equatable {
        /// `unsupported`, `not_allowed` or `mixed`.
        public var reason: String?
        public var disallowed: [String]
    }

    /// The `invalid_grant` descriptions the token endpoint publishes.
    public enum Grant: Sendable, Equatable {
        case requestInvalidOrExpired
        case codeRedirectOrVerifierInvalid
        case notPKCERequest
        case differentServer
        case identityUnavailable

        var description: String {
            switch self {
            case .requestInvalidOrExpired:
                "The authorization request is invalid or has expired"
            case .codeRedirectOrVerifierInvalid:
                "The authorization code, redirect URI, or PKCE verifier is invalid"
            case .notPKCERequest:
                "This authorization request is not a PKCE request"
            case .differentServer:
                "The authorization was granted for a different Server than this issuer"
            case .identityUnavailable:
                "The authorization identity is no longer available"
            }
        }
    }

    public enum Reason: Sendable, Equatable {
        // Client credentials.
        case clientCredentialsRequired
        case invalidClientCredentials
        // Bearer tokens.
        case missingBearerToken
        case invalidOrExpiredAccessToken
        case wrongIssuerServer
        case agentReadRequired
        case agentTokenRequired
        case resourceBoundTokenRequired(resource: String)
        case insufficientScope(requiredScope: String)
        case crossAgentTarget
        // Installation tokens and credentials.
        case installationIdRequired
        case activeInstallationNotFound
        case noEffectiveReadGroups
        case installationBearerRequired
        case invalidInstallationCredential
        case lacksServerReadAuthority
        case lacksChannelReadAuthority
        // Browser authorize and discovery.
        case invalidRequest(description: String)
        case oidcNotConfigured
        // Human authorization and client lookup.
        case authorizationHeaderMissing
        case sessionTokenInvalid
        case clientIdRequired
        case serverIdRequired
        case clientNotFoundForServer
        case serverNotFound
        case agentNotFound
        case serverHintMismatch
        case invalidRequestBare
        case invalidScopeBare
        case scopeRejected(ScopeRejection)
        case returnUrlNotAllowed
        case notServerMember
        // Agent events.
        case eventKindInvalid
        case eventSummaryRequired
        case eventPayloadNotObject
        // Token exchange.
        case unsupportedGrantType
        case codeRequired
        case accessRequestNotFound
        case invalidGrant(Grant)
        case requestAlreadyConsumed
        case authorizationCodeExpired
        case tokenIssueFailed
        case requestIdRequired
        case authorizationPending
        case resourceRequired
        case resourceMismatch
    }

    public let reason: Reason
    /// `Cache-Control` the legacy reply published, when it published one.
    public let cacheControl: String?

    public init(_ reason: Reason, cacheControl: String? = nil) {
        self.reason = reason
        self.cacheControl = cacheControl
    }

    public var status: UInt {
        switch reason {
        case .clientCredentialsRequired, .invalidClientCredentials, .missingBearerToken,
             .invalidOrExpiredAccessToken, .wrongIssuerServer, .installationBearerRequired,
             .invalidInstallationCredential, .authorizationHeaderMissing, .sessionTokenInvalid:
            401
        case .agentReadRequired, .agentTokenRequired, .resourceBoundTokenRequired, .insufficientScope,
             .crossAgentTarget, .lacksServerReadAuthority, .lacksChannelReadAuthority:
            403
        case .activeInstallationNotFound, .clientNotFoundForServer, .serverNotFound, .agentNotFound,
             .notServerMember, .accessRequestNotFound:
            404
        case .requestAlreadyConsumed:
            409
        case .tokenIssueFailed:
            500
        case .oidcNotConfigured:
            503
        case .installationIdRequired, .noEffectiveReadGroups, .invalidRequest, .clientIdRequired,
             .serverIdRequired, .serverHintMismatch, .invalidRequestBare, .invalidScopeBare, .scopeRejected,
             .returnUrlNotAllowed, .eventKindInvalid, .eventSummaryRequired, .eventPayloadNotObject,
             .unsupportedGrantType, .codeRequired, .invalidGrant, .authorizationCodeExpired,
             .requestIdRequired, .authorizationPending, .resourceRequired, .resourceMismatch:
            400
        }
    }

    public var errorMessage: String {
        switch reason {
        case .clientCredentialsRequired: "Client credentials are required"
        case .invalidClientCredentials: "Invalid client credentials"
        case .missingBearerToken: "Missing bearer token"
        case .invalidOrExpiredAccessToken: "Invalid or expired access token"
        case .wrongIssuerServer: "Access token was issued for a different Server than this issuer"
        case .agentReadRequired: "agent:read permission is required from an enabled App"
        case .agentTokenRequired: "agent token required"
        case .resourceBoundTokenRequired: "resource-bound token required"
        case .insufficientScope: "insufficient_scope"
        case .crossAgentTarget: "token cannot target a different agent"
        case .installationIdRequired: "installation_id is required"
        case .activeInstallationNotFound: "Active installation not found"
        case .noEffectiveReadGroups: "Installation has no effective read groups"
        case .installationBearerRequired: "Installation bearer token is required"
        case .invalidInstallationCredential: "Invalid, expired, or stale installation credential"
        case .lacksServerReadAuthority: "Installation credential lacks server read authority"
        case .lacksChannelReadAuthority: "Installation credential lacks channel read authority"
        case .invalidRequest: "invalid_request"
        case .oidcNotConfigured: "oidc_not_configured"
        case .authorizationHeaderMissing: "Missing or invalid Authorization header"
        case .sessionTokenInvalid: "Invalid or expired token"
        case .clientIdRequired: "clientId is required"
        case .serverIdRequired: "serverId is required"
        case .clientNotFoundForServer: "OAuth client not found for server"
        case .serverNotFound: "Server not found"
        case .agentNotFound: "Agent not found"
        case .serverHintMismatch: "server does not match the selected Server"
        case .invalidRequestBare: "invalid_request"
        case .invalidScopeBare, .scopeRejected: "invalid_scope"
        case .returnUrlNotAllowed: "returnUrl is not allowed"
        case .notServerMember: "User is not a member of this server"
        case .eventKindInvalid: "kind must be event or notification"
        case .eventSummaryRequired: "summary is required"
        case .eventPayloadNotObject: "payload must be an object"
        case .unsupportedGrantType: "Unsupported grant type"
        case .codeRequired: "code is required"
        case .accessRequestNotFound: "Access request not found"
        case .invalidGrant: "invalid_grant"
        case .requestAlreadyConsumed: "request_already_consumed"
        case .authorizationCodeExpired: "authorization_code_expired"
        case .tokenIssueFailed: "Failed to issue access token"
        case .requestIdRequired: "requestId is required"
        case .authorizationPending: "authorization_pending"
        case .resourceRequired: "resource is required for requested scopes"
        case .resourceMismatch: "resource does not match requested server"
        }
    }

    public var responseHeaders: [String: String] {
        guard let cacheControl else { return [:] }
        return ["Cache-Control": cacheControl]
    }

    public var errorBody: OrderedJSON? {
        var body = OrderedJSONObject()
        body.append("error", errorMessage)
        switch reason {
        case .authorizationHeaderMissing, .sessionTokenInvalid:
            body.append("code", "auth_required")
        case .resourceBoundTokenRequired(let resource):
            body.append("resource", resource)
        case .insufficientScope(let required):
            body.append("required_scope", required)
        case .invalidRequest(let description):
            body.append("error_description", description)
        case .invalidGrant(let grant):
            body.append("error_description", grant.description)
        case .requestAlreadyConsumed:
            body.append(
                "error_description",
                "This Login with Raft request is one-time and has already been exchanged. Discard it and obtain a fresh request before retrying."
            )
            body.append("next_action", "obtain_fresh_request")
        case .authorizationCodeExpired:
            body.append(
                "error_description",
                "This Login with Raft authorization code has expired. Obtain a fresh human authorization before retrying."
            )
            body.append("next_action", "obtain_fresh_authorization")
        case .scopeRejected(let rejection):
            let scopeList = rejection.disallowed.joined(separator: ", ")
            let code: String
            let description: String
            switch rejection.reason {
            case "unsupported":
                code = "OAUTH_SCOPE_UNSUPPORTED"
                description = "Raft does not support the requested OAuth scope: \(scopeList). Update the requested scopes and try again."
            case "not_allowed":
                code = "OAUTH_SCOPE_NOT_ALLOWED"
                description = "This OAuth client is not allowed to request: \(scopeList). Update the client's allowed scopes and try again."
            default:
                code = "OAUTH_SCOPE_INVALID"
                description = "Some requested OAuth scopes are unsupported or not allowed for this client: \(scopeList). Update the requested scopes or client permissions and try again."
            }
            body.append("errorCode", code)
            body.append("error_description", description)
            body.append("disallowedScopes", .array(rejection.disallowed.map(OrderedJSON.string)))
        default:
            break
        }
        return body.json
    }
}
