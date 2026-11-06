import Foundation

/// Maps the OAuth ledger's untyped integration-client rows into the typed
/// snapshot the agent delivery service consumes.
///
/// `OAuthLedger.integrationServices` exposes `[[String: Any]]` because its
/// callers predate the DTO layer. This bridge lives in `Support/` so a service
/// method never has to name that dictionary shape; the service only sees
/// `AgentIntegrationServiceSnapshot`.
enum AgentIntegrationProjection {
    static func snapshot(_ service: [String: Any]) -> AgentIntegrationServiceSnapshot {
        AgentIntegrationServiceSnapshot(
            id: service["id"] as? String,
            clientId: service["clientId"] as? String,
            name: (service["name"] as? String).map(EmailLoginDirectory.inertThirdPartyText),
            description: service["description"] as? String,
            homepageUrl: service["homepageUrl"] as? String,
            agentManifestUrl: service["agentManifestUrl"] as? String,
            agentManifestUrlSource: service["agentManifestUrlSource"] as? String,
            allowedScopes: service["allowedScopes"] as? [String],
            whenToUse: (service["whenToUse"] as? String).map(EmailLoginDirectory.inertThirdPartyText),
            appType: service["appType"] as? String
        )
    }
}
