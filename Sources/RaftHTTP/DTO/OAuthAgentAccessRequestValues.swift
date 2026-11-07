/// Parsed App credentials and request shape. Invalid selectors/scopes remain
/// markers so the owner can preserve client/server/agent/installation precedence.
struct AppAgentAccessRequestAttempt: Sendable {
    let clientId: String
    let clientSecret: String
    let serverSlug: String
    let selector: AppAgentAccessSelector
    let scopeCandidates: [String]?
    let initiatedByAgent: Bool
}

enum AppAgentAccessSelector: Sendable {
    case id(String)
    case name(String)
    case invalidId
}

/// Decisions from a single OAuth owner transaction, without HTTP projection.
enum AppAgentAccessRequestOutcome: Sendable {
    case invalidClient
    case serverUnavailable
    case agentUnavailable
    case appUnavailableOnServer
    case invalidScopes
    case completed(AppAgentAccessRequestReceipt)
}

/// Copies the response facts while the owner still holds the transaction lock.
/// The integration service builds the published DTO after the lock is released.
struct AppAgentAccessRequestReceipt: Sendable {
    let requestId: String
    let status: String
    let clientId: String
    let clientAppType: String
    let clientName: String
    let agentId: String
    let agentName: String
    let agentDisplayName: String
    let serverId: String
    let serverSlug: String
    let scopes: [String]
}
