import Foundation

/// Captured at the route's original deployment-read point. Unlike discovery,
/// a token exchange retains an empty origin and its relative scoped issuer.
public struct OAuthAuthorizationTokenContext: Sendable {
    let issuer: String
    let scopeServerId: String?
}

enum OAuthHumanScopeSelection: Sendable {
    case defaults
    case invalid
    case values([String])
}

struct OAuthHumanAuthorizationAttempt: Sendable {
    let human: OAuthHuman
    let clientKey: String
    let serverId: String
    let oidc: Bool
    let serverHint: String?
    let nonce: String?
    let codeChallenge: String?
    let codeChallengeMethod: String?
    let scopes: OAuthHumanScopeSelection
    let returnUrl: String?
}

struct OAuthHumanAuthorizationReceipt: Sendable {
    let code: String
    let clientId: String
    let clientAppType: String
    let clientName: String
    let serverId: String
    let serverSlug: String
    let role: String
    let scopes: [String]
    let returnUrl: String?
}

struct OAuthConsentAttempt: Sendable {
    let userId: String
    let clientId: String
    let serverId: String
    let scope: String
}

struct OAuthConsentScopeValidation: Sendable {
    let allowed: Bool
    let reason: String?
    let disallowedScopes: [String]
}

enum OAuthConsentReceipt: Sendable {
    case ready(
        clientId: String, appType: String, name: String, description: String?,
        homepageUrl: String?, returnUrl: String?, allowedScopes: [String],
        marketplace: Bool, scopeValidation: OAuthConsentScopeValidation?
    )
    case installRequired(
        id: String, clientId: String, appType: String, name: String, description: String?,
        homepageUrl: String?, returnUrl: String?, allowedScopes: [String]?,
        serverId: String, canInstall: Bool
    )
}

struct OAuthCodeRedemptionAttempt: Sendable {
    let code: String
    let isOIDC: Bool
    let verifierPresent: Bool
    let verifier: String?
    let redirectURI: String?
    let clientId: String
    let clientSecret: String
    let scopeServerId: String?
}

/// No AccessRequest record escapes the transaction. Signing uses these copied
/// claims after access-token append and request consumption have committed.
struct OAuthCodeRedemptionReceipt: Sendable {
    let userId: String
    let humanName: String
    let humanEmail: String
    let nonce: String?
    let accessToken: String
    let issuedAt: Date
    let expiresAt: Date
    let scopes: [String]
    let clientKey: String
    let serverId: String
    let serverSlug: String
    let role: String
}

struct OAuthAgentRedemptionAttempt: Sendable {
    let requestId: String
    let clientId: String
    let clientSecret: String
    let scopeServerId: String?
    let resource: String?
}

struct OAuthAgentRedemptionReceipt: Sendable {
    let accessToken: String
    let scopes: [String]
    let resource: String?
}

struct OAuthAuthorizationScopeRejection: Sendable {
    let reason: String?
    let disallowed: [String]
}

enum OAuthAuthorizationInvalidGrant: Sendable {
    case requestInvalidOrExpired
    case codeRedirectOrVerifierInvalid
    case notPKCERequest
    case differentServer
    case identityUnavailable
}

/// Store refusals carry domain facts, never status codes, headers or JSON.
enum OAuthAuthorizationFailure: Error, Sendable {
    case clientNotFoundForServer
    case serverHintMismatch
    case invalidRequestBare
    case invalidScopeBare
    case scopeRejected(OAuthAuthorizationScopeRejection)
    case returnUrlNotAllowed
    case notServerMember
    case invalidClientCredentials
    case invalidGrant(OAuthAuthorizationInvalidGrant)
    case accessRequestNotFound
    case requestAlreadyConsumed
    case authorizationCodeExpired
    case authorizationPending
    case resourceRequired
    case resourceMismatch
}
