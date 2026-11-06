import Foundation

/// Domain failure for the provider/OAuth flow surface: provider discovery, the
/// mobile and native-Apple handoffs, the web callback leg, the installation
/// lookup and the feature-flag evaluation.
///
/// Every case is one published refusal. The retired handlers built each body by
/// hand; most publish `error` then `code` (the default projection), a handful
/// publish `code` first and supply `errorBody`. The mobile callback answers a
/// plain-text `400`, and the account-link `409` carries a structured body, so
/// both are expressed here too (`errorBody` / `errorHeaders`).
public enum OAuthFlowsError: DomainError, Equatable {
    // MARK: Shared
    case missingAuthorization
    case invalidToken
    case notFound
    case providerNotConfigured(provider: String)
    case appleNotConfigured
    case returnURINotAllowed

    // MARK: Provider discovery and mobile start
    case platformInvalid
    case invalidMobileStart

    // MARK: Mobile callback (text/plain)
    case invalidMobileRequest

    // MARK: Native Apple
    case nativeAppleInvalidRequest
    case nativeAppleRequiresS256
    case nativeAppleInvalidCredential
    case nativeAppleAuthRequired
    case nativeAppleLinkMismatch
    case nativeAppleRequestExpired
    case nativeAppleRequestConsumed

    // MARK: Mobile completion
    case invalidMobileCompletion
    case handoffCodeConsumed
    case handoffCodeExpired
    case pkceMismatch
    case pendingLinkExpired
    case pendingLinkAccountMismatch
    case providerMismatch
    case modeMismatch
    case mobileLinkMismatch
    case legalAcceptanceRequired
    case termsChanged
    /// `409`: the OAuth identity matches an existing account that has to prove
    /// ownership before the provider is linked.
    case accountLinkRequired(
        pendingLinkToken: String,
        provider: String,
        email: String,
        expiresAt: String,
        hasPassword: Bool,
        providers: [String],
        returnUri: String
    )

    // MARK: Installation lookup
    case clientCredentialsRequired
    case invalidClientCredentials
    case serverIdRequired
    case serverIdMustBeServerId
    case installationNotFound

    // MARK: Feature flags
    case emailVerificationRequired
    case featureFlagKeysInvalid
    case featureFlagServerIdInvalid
    case notAServerMember
    case featureFlagPlatformInvalid

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidToken, .nativeAppleAuthRequired,
             .clientCredentialsRequired, .invalidClientCredentials:
            401
        case .notFound, .providerNotConfigured, .appleNotConfigured, .installationNotFound:
            404
        case .nativeAppleLinkMismatch, .mobileLinkMismatch, .pendingLinkAccountMismatch,
             .emailVerificationRequired, .notAServerMember:
            403
        case .handoffCodeConsumed, .handoffCodeExpired, .pendingLinkExpired,
             .nativeAppleRequestExpired, .nativeAppleRequestConsumed:
            410
        case .termsChanged, .accountLinkRequired:
            409
        case .legalAcceptanceRequired:
            422
        case .returnURINotAllowed, .platformInvalid, .invalidMobileStart, .invalidMobileRequest,
             .nativeAppleInvalidRequest, .nativeAppleRequiresS256, .nativeAppleInvalidCredential,
             .invalidMobileCompletion, .pkceMismatch, .providerMismatch, .modeMismatch,
             .serverIdRequired, .serverIdMustBeServerId, .featureFlagKeysInvalid,
             .featureFlagServerIdInvalid, .featureFlagPlatformInvalid:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization: "Missing or invalid Authorization header"
        case .invalidToken: "Invalid or expired token"
        case .notFound: "Not found"
        case .providerNotConfigured(let provider): "\(Self.label(provider)) sign-in is not configured"
        case .appleNotConfigured: "Apple sign-in is not configured"
        case .returnURINotAllowed: "Mobile OAuth return URI is not allowed"
        case .platformInvalid: "platform must be web or mobile"
        case .invalidMobileStart: "Invalid mobile OAuth start"
        case .invalidMobileRequest: "Invalid mobile OAuth request"
        case .nativeAppleInvalidRequest: "Native Apple sign-in requires the iOS platform and app environment"
        case .nativeAppleRequiresS256: "Native Apple sign-in requires an S256 challenge"
        case .nativeAppleInvalidCredential: "Apple sign-in credential was invalid"
        case .nativeAppleAuthRequired: "Apple account linking requires authentication"
        case .nativeAppleLinkMismatch: "Apple account linking does not match the authenticated user"
        case .nativeAppleRequestExpired: "Apple sign-in request expired"
        case .nativeAppleRequestConsumed: "Apple sign-in request was already used"
        case .invalidMobileCompletion: "Invalid mobile OAuth completion"
        case .handoffCodeConsumed: ""
        case .handoffCodeExpired: "Mobile OAuth code has expired"
        case .pkceMismatch: "PKCE verifier did not match the OAuth request"
        case .pendingLinkExpired: "This sign-in link expired. Sign in again to connect the account."
        case .pendingLinkAccountMismatch: "The pending link belongs to a different account"
        case .providerMismatch: "Mobile OAuth code does not match the requested provider"
        case .modeMismatch: "Mobile OAuth code does not match the requested mode"
        case .mobileLinkMismatch: "Mobile OAuth link request does not match the authenticated user"
        case .legalAcceptanceRequired: "LEGAL_ACCEPTANCE_REQUIRED"
        case .termsChanged: "TERMS_CHANGED"
        case .accountLinkRequired: ""
        case .clientCredentialsRequired: "Client credentials are required"
        case .invalidClientCredentials: "Invalid client credentials"
        case .serverIdRequired: "server_id is required"
        case .serverIdMustBeServerId: "server_id must be a Server ID"
        case .installationNotFound: "Active installation not found"
        case .emailVerificationRequired: "Email verification required"
        case .featureFlagKeysInvalid: "keys must contain 1-50 valid feature flag keys"
        case .featureFlagServerIdInvalid: "serverId must be a valid UUID"
        case .notAServerMember: "Not a member of this server"
        case .featureFlagPlatformInvalid: "platform must be web or mobile"
        }
    }

    /// The machine code published after the message (`error`, then `code`).
    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidToken: "auth_required"
        case .pendingLinkExpired: "pending_link_expired"
        case .pendingLinkAccountMismatch: "pending_link_account_mismatch"
        default: nil
        }
    }

    /// Cache policy of the installation-lookup refusals.
    public var responseHeaders: [String: String] {
        switch self {
        case .clientCredentialsRequired, .invalidClientCredentials, .serverIdRequired,
             .serverIdMustBeServerId, .installationNotFound:
            ["Cache-Control": "private, no-store"]
        default:
            [:]
        }
    }

    public var errorHeaders: ResponseHeaders {
        switch self {
        case .invalidMobileRequest:
            // The callback leg answers plain text, not JSON.
            .exact([
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": "text/plain; charset=utf-8",
            ])
        default:
            .standard(extra: responseHeaders)
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .invalidMobileRequest:
            return .raw(errorMessage)
        case .platformInvalid:
            return codeFirst("platform_invalid")
        case .returnURINotAllowed:
            return codeFirst("return_uri_not_allowed")
        case .appleNotConfigured:
            return codeFirst("provider_not_configured")
        case .nativeAppleInvalidRequest, .nativeAppleRequiresS256:
            return codeFirst("invalid_request")
        case .nativeAppleInvalidCredential:
            return codeFirst("native_apple_invalid_credential")
        case .nativeAppleAuthRequired:
            return codeFirst("auth_required")
        case .nativeAppleLinkMismatch, .mobileLinkMismatch:
            return codeFirst("link_user_mismatch")
        case .nativeAppleRequestExpired:
            return codeFirst("native_apple_request_expired")
        case .nativeAppleRequestConsumed:
            return codeFirst("native_apple_request_consumed")
        case .handoffCodeConsumed:
            return .object([OrderedJSONField("code", "handoff_code_consumed")])
        case .handoffCodeExpired:
            return codeFirst("handoff_code_expired")
        case .pkceMismatch:
            return codeFirst("pkce_mismatch")
        case .providerMismatch:
            return codeFirst("provider_mismatch")
        case .modeMismatch:
            return codeFirst("mode_mismatch")
        case .legalAcceptanceRequired, .termsChanged:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("legal", Self.legal),
            ])
        case .accountLinkRequired(let token, let provider, let email, let expiresAt, let hasPassword, let providers, let returnUri):
            return .object([
                OrderedJSONField("code", "account_link_required"),
                OrderedJSONField("pendingLinkToken", token),
                OrderedJSONField("provider", provider),
                OrderedJSONField("email", email),
                OrderedJSONField("expiresAt", expiresAt),
                OrderedJSONField("signInMethods", .object([
                    OrderedJSONField("password", hasPassword),
                    OrderedJSONField("providers", .array(providers.map(OrderedJSON.string))),
                ])),
                OrderedJSONField("returnUri", returnUri),
            ])
        default:
            return nil
        }
    }

    /// `{"code":…,"error":…}`: the published order of the code-led refusals.
    private func codeFirst(_ code: String) -> OrderedJSON {
        .object([OrderedJSONField("code", code), OrderedJSONField("error", errorMessage)])
    }

    private static func label(_ provider: String) -> String {
        switch provider {
        case "google": "Google"
        case "github": "GitHub"
        case "apple": "Apple"
        default: provider
        }
    }

    private static var legal: OrderedJSON {
        .object([
            OrderedJSONField("termsVersion", AuthLegalPolicy.termsVersion),
            OrderedJSONField("privacyVersion", AuthLegalPolicy.privacyVersion),
            OrderedJSONField("termsUrl", AuthLegalPolicy.termsURL),
            OrderedJSONField("privacyUrl", AuthLegalPolicy.privacyURL),
        ])
    }
}
