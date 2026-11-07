import Foundation

/// Invalid fields remain markers until their original position in the owner's
/// token/resource/scope/target validation sequence. Payload text is Foundation's
/// original sorted JSON, never a re-encoded numeric value tree.
struct AppAgentEventAttempt: Sendable {
    let bearerToken: String
    let kind: AppAgentEventKind?
    let target: String?
    let summary: String?
    let payloadJSON: String?
    let externalEventId: String?
}

enum AppAgentEventKind: String, Sendable {
    case event
    case notification

    var requiredScope: String {
        self == .event ? "agent:event:write" : "agent:notification:write"
    }
}

/// Refusals and commit results from the same principal-validation/claim lock.
/// The integration service owns HTTP errors, response status and date formatting.
enum AppAgentEventOutcome: Sendable {
    case invalidToken
    case agentTokenRequired
    case resourceRequired(String)
    case invalidKind
    case insufficientScope(String)
    case crossAgentTarget
    case summaryRequired
    case invalidPayload
    case created(AppAgentEventReceipt)
    case reclaimed(AppAgentEventReceipt)
    case duplicate(AppAgentEventReceipt)
}

struct AppAgentEventReceipt: Sendable {
    let id: String
    let expiresAt: Date
    let payloadHash: String
}
