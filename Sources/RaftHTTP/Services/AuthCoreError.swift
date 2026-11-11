import Foundation

/// Domain failure for the session core: social completion, register, staging
/// retirement, device grants, refresh and logout.
///
/// Every case publishes the bytes the retired handler built. Most answer the
/// canonical `{"error": …[, "code": …]}` object; the cases below that differ
/// (`code` first, the legal object, the issue list, the link-required handle)
/// supply their own `errorBody`.
public enum AuthCoreError: DomainError, Equatable {
    case notFound
    case socialCompletionCodeRequired
    case socialCompletionServerError(correlationId: String)
    case socialCompletionInvalid
    case linkAuthRequired
    case linkUserMismatch
    case pendingLinkExpired
    case pendingLinkAccountMismatch
    case accountLinkRequired(AccountLinkRequiredBody)
    case legalAcceptanceRequired
    case termsChanged
    case socialEmailExists(provider: String)
    case registerBodyInvalid([AuthRequestIssue])
    case stagingRegistrationUnavailable
    case nameInvalid(String)
    case reservedName
    case passwordTooShort
    case emailAlreadyRegistered
    case missingAuthorization
    case invalidToken
    case retirementOwnershipMismatch
    case invalidRetirementCapability
    case userNotFound
    case unsupportedAccount
    case retirementReceiptUnavailable
    case deviceLoginDisabled
    case clientNameInvalid
    case deviceLoginURLUnavailable
    case userCodeRequired
    case deviceUpdateFailed(code: String, status: UInt)
    case deviceNotReady(code: String, status: UInt)
    case deviceCodeRequired
    case refreshTokenRequired
    case invalidRefreshBinding
    case invalidRefreshToken

    public var status: UInt {
        switch self {
        case .notFound, .userNotFound, .deviceLoginDisabled: 404
        case .socialCompletionCodeRequired, .socialCompletionInvalid, .registerBodyInvalid, .nameInvalid,
             .reservedName, .passwordTooShort, .clientNameInvalid, .userCodeRequired, .deviceCodeRequired,
             .refreshTokenRequired, .invalidRefreshBinding: 400
        case .linkAuthRequired, .missingAuthorization, .invalidToken, .invalidRefreshToken: 401
        case .linkUserMismatch, .pendingLinkAccountMismatch, .stagingRegistrationUnavailable,
             .retirementOwnershipMismatch, .invalidRetirementCapability, .unsupportedAccount: 403
        case .pendingLinkExpired: 410
        case .accountLinkRequired, .termsChanged, .socialEmailExists, .emailAlreadyRegistered: 409
        case .legalAcceptanceRequired: 422
        case .retirementReceiptUnavailable, .socialCompletionServerError: 500
        case .deviceLoginURLUnavailable: 503
        case .deviceUpdateFailed(_, let status), .deviceNotReady(_, let status): status
        }
    }

    public var errorMessage: String {
        switch self {
        case .notFound: "Not found"
        case .socialCompletionCodeRequired: "Sign-in completion code is required"
        case .socialCompletionServerError: "Failed to complete sign-in"
        case .socialCompletionInvalid: "Invalid or expired social auth completion"
        case .linkAuthRequired: "Authentication is required to link an account"
        case .linkUserMismatch: "Social auth link does not match the authenticated user"
        case .pendingLinkExpired: "This sign-in link expired. Sign in again to connect the account."
        case .pendingLinkAccountMismatch: "The pending link belongs to a different account"
        case .accountLinkRequired: ""
        case .legalAcceptanceRequired: "LEGAL_ACCEPTANCE_REQUIRED"
        case .termsChanged: "TERMS_CHANGED"
        case .socialEmailExists(let provider):
            "An account with this email already exists. Sign in with email and password first, then connect \(provider) in Settings."
        case .registerBodyInvalid: "Invalid email registration body"
        case .stagingRegistrationUnavailable: "Staging self-account registration is unavailable"
        case .nameInvalid(let message): message
        case .reservedName: "This username is reserved. Choose another name."
        case .passwordTooShort: "Password must be at least 8 characters"
        case .emailAlreadyRegistered: "Email already registered"
        case .missingAuthorization: "Missing or invalid Authorization header"
        case .invalidToken: "Invalid or expired token"
        case .retirementOwnershipMismatch: "User ownership mismatch"
        case .invalidRetirementCapability: "Invalid retirement capability"
        case .userNotFound: "User not found"
        case .unsupportedAccount: "Unsupported account"
        case .retirementReceiptUnavailable: "Retirement receipt unavailable"
        case .deviceLoginDisabled: "Device login is not enabled"
        case .clientNameInvalid: "clientName must be a string up to 200 chars"
        case .deviceLoginURLUnavailable: "Device login URL is not configured"
        case .userCodeRequired: "userCode is required"
        case .deviceUpdateFailed: "Device authorization could not be updated"
        case .deviceNotReady: "Device authorization not ready"
        case .deviceCodeRequired: "deviceCode is required"
        case .refreshTokenRequired: "Refresh token is required"
        case .invalidRefreshBinding: "Invalid refresh replay binding"
        case .invalidRefreshToken: "Invalid or expired refresh token"
        }
    }

    public var errorCode: String? {
        switch self {
        case .pendingLinkExpired: "pending_link_expired"
        case .pendingLinkAccountMismatch: "pending_link_account_mismatch"
        case .missingAuthorization, .invalidToken: "auth_required"
        case .deviceLoginDisabled: "device_login_disabled"
        case .clientNameInvalid: "client_name_invalid"
        case .deviceLoginURLUnavailable: "DEVICE_LOGIN_URL_UNAVAILABLE"
        case .userCodeRequired: "user_code_required"
        case .deviceCodeRequired: "device_code_required"
        case .deviceUpdateFailed(let code, _), .deviceNotReady(let code, _): code
        default: nil
        }
    }

    public var responseHeaders: [String: String] {
        switch self {
        case .socialCompletionServerError(let correlationId):
            return ["X-Slock-Error-Id": correlationId]
        default:
            return [:]
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .socialCompletionServerError(let correlationId):
            // `sendJsonServerError` (`errorResponse.ts:138-197`) adds only the
            // correlation id for a route that passes no `code`.
            return .object([
                OrderedJSONField("error", "Failed to complete sign-in"),
                OrderedJSONField("correlationId", correlationId),
            ])
        case .linkAuthRequired:
            // `code` precedes `error` in this published body.
            return .object([
                OrderedJSONField("code", "auth_required"),
                OrderedJSONField("error", errorMessage),
            ])
        case .linkUserMismatch:
            return .object([
                OrderedJSONField("code", "link_user_mismatch"),
                OrderedJSONField("error", errorMessage),
            ])
        case .accountLinkRequired(let handle):
            return handle.jsonBody
        case .legalAcceptanceRequired, .termsChanged:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("legal", Self.legalObject),
            ])
        case .registerBodyInvalid(let issues):
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "email_register_body_invalid"),
                OrderedJSONField("issues", .array(issues.map(\.json))),
            ])
        default:
            return nil
        }
    }

    /// The current legal document versions and URLs a refusal publishes.
    private static var legalObject: OrderedJSON {
        .object([
            OrderedJSONField("termsVersion", AuthLegalPolicy.termsVersion),
            OrderedJSONField("privacyVersion", AuthLegalPolicy.privacyVersion),
            OrderedJSONField("termsUrl", AuthLegalPolicy.termsURL),
            OrderedJSONField("privacyUrl", AuthLegalPolicy.privacyURL),
        ])
    }
}

/// The `account_link_required` 409 body: a pending-link handle instead of an
/// `error` message.
public struct AccountLinkRequiredBody: Sendable, Equatable {
    public var pendingLinkToken: String
    public var provider: String
    public var email: String
    public var expiresAt: String
    public var hasPassword: Bool
    public var providers: [String]
    public var returnTo: String

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("code", "account_link_required"),
            OrderedJSONField("pendingLinkToken", pendingLinkToken),
            OrderedJSONField("provider", provider),
            OrderedJSONField("email", email),
            OrderedJSONField("expiresAt", expiresAt),
            OrderedJSONField("signInMethods", .object([
                OrderedJSONField("password", hasPassword),
                OrderedJSONField("providers", .array(providers.map(OrderedJSON.string))),
            ])),
            OrderedJSONField("returnTo", returnTo),
        ])
    }
}
