/// The bearer reader has already checked the exact prefix and nonempty tail.
/// Each endpoint consumes this value in its own single OAuth owner borrow.
struct OAuthPrincipalAttempt: Sendable {
    let token: String
    let scopeServerId: String?
}

/// Endpoint facts copy only projection values, never stored rows or HTTP DTOs.
struct OAuthUserinfoFacts: Sendable {
    let scopes: [String]
    let clientId: String
    let clientName: String
    let serverId: String
    let serverSlug: String
    let sub: String
    let type: String
    let serverRole: String
    let preferredUsername: String
    let name: String
    let avatarUrl: String?
    let description: String?
    let email: String?
    let emailVerified: Bool
}

struct OAuthServerinfoFacts: Sendable {
    let id: String
    let slug: String
    let name: String
    let avatarUrl: String?
    let isPaid: Bool
}

struct OAuthDirectoryEntryFacts: Sendable {
    let id: String
    let handle: String
    let displayName: String
    let avatarUrl: String?
}

struct OAuthDirectoryFacts: Sendable {
    let entries: [OAuthDirectoryEntryFacts]
}

enum OAuthPrincipalFailure: Error, Sendable {
    case invalidOrExpiredAccessToken
    case wrongIssuerServer
    case agentReadRequired
}
