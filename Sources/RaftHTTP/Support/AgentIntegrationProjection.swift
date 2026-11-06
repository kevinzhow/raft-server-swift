import Foundation

/// Maps the OAuth ledger's typed integration-service rows into the snapshot the
/// agent delivery service consumes. Third-party text is made inert here, so the
/// service only ever sees `AgentIntegrationServiceSnapshot`.
enum AgentIntegrationProjection {
    static func snapshot(_ service: IntegrationServiceRow) -> AgentIntegrationServiceSnapshot {
        AgentIntegrationServiceSnapshot(
            id: service.id,
            clientId: service.clientId,
            name: ThirdPartyText.inertThirdPartyText(service.name),
            description: service.description,
            homepageUrl: service.homepageUrl,
            agentManifestUrl: service.agentManifestUrl,
            agentManifestUrlSource: service.agentManifestUrlSource,
            allowedScopes: service.allowedScopes,
            whenToUse: service.whenToUse.map(ThirdPartyText.inertThirdPartyText),
            appType: service.appType
        )
    }
}
