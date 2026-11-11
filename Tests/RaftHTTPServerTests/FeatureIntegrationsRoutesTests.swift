import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// The integrations slice must expose its upstream route pairs without the full
/// `configure(_:services:)` mount. This locks the collection's own registration
/// contract: every `api/integrations`, `api/mcp`, `api/provider-connections`,
/// `api/agent-runtime-providers` and `api/app-installation` pair, and nothing
/// else. End-to-end behavior stays with the existing route tests once the Lead
/// mounts the collection.
@Suite
struct FeatureIntegrationsRoutesTests {
    /// Complete table of the 44 registrations extracted from
    /// `FallbackApplication.configure` at extraction time.
    private let expectedIntegrationsRoutes: [(HTTPRequest.Method, String)] = [
        (.get, "api/mcp/servers"),
        (.post, "api/mcp/servers"),
        (.post, "api/mcp/servers/test-configuration"),
        (.patch, "api/mcp/servers/:id"),
        (.delete, "api/mcp/servers/:id"),
        (.get, "api/mcp/oauth/callback"),
        (.get, "api/mcp/oauth/client-metadata"),
        (.get, "api/mcp/agents/:agentId"),
        (.put, "api/mcp/agents/:agentId/assignments"),
        (.put, "api/mcp/agents/:agentId/assignments/:mcpServerId"),
        (.get, "api/integrations/clients"),
        (.post, "api/integrations/requests/:requestId/approve"),
        (.post, "api/integrations/agents/:agentId/grants"),
        (.get, "api/integrations/agents/:agentId/grants"),
        (.get, "api/integrations/agents/:agentId/grantable-apps"),
        (.get, "api/integrations/agents/:agentId/events"),
        (.get, "api/integrations/agents/:agentId/events/:eventId"),
        (.post, "api/integrations/grants/:grantId/revoke"),
        (.get, "api/integrations/clients/:clientId/setup"),
        (.patch, "api/integrations/clients/:clientId"),
        (.post, "api/integrations/clients/:clientId/logo"),
        (.delete, "api/integrations/clients/:clientId/logo"),
        (.post, "api/integrations/marketplace/:clientId/install"),
        (.delete, "api/integrations/marketplace/:clientId/install"),
        (.get, "api/integrations/marketplace"),
        (.post, "api/integrations/clients/:clientId/app-notifications/permissions/review"),
        (.get, "api/integrations/agents/:agentId"),
        (.get, "api/integrations/clients/:clientId/agent-jwt"),
        (.put, "api/integrations/clients/:clientId/agent-jwt"),
        (.get, "api/integrations/clients/:clientId/app-notifications"),
        (.get, "api/integrations/clients/:clientId/share-link"),
        (.get, "api/integrations/marketplace/:clientId/install/app-notifications"),
        (.get, "api/agent-runtime-providers/:kind"),
        (.get, "api/provider-connections"),
        (.post, "api/provider-connections/:id/test"),
        (.get, "api/provider-connections/:id/models"),
        (.get, "api/provider-connections/:id/agents"),
        (.delete, "api/provider-connections/:id/agents/:agentId"),
        (.delete, "api/provider-connections/:id"),
        (.patch, "api/provider-connections/:id"),
        (.post, "api/provider-connections/:id/credentials/rotate"),
        (.post, "api/provider-connections"),
        (.get, "api/app-installation/server"),
        (.get, "api/app-installation/channels"),
    ]

    @Test func featureIntegrationsRoutesAreRegisteredOnABareApplication() async throws {
        let services = FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        )

        try await withApp { app in
            try await app.register(collection: IntegrationsFeature(
                controlPlane: services.emailAccounts.managedMCPControlPlane,
                identities: services.emailAccounts.authIdentities,
                apps: services.emailAccounts.integrationsAndAppAccess,
                cardPrepare: services.emailAccounts.actionCardPrepare,
                agentsLifecycle: services.emailAccounts.agentsLifecycle,
                providerConnections: services.emailAccounts.managedMCPProviderConnections,
                actionCards: services.emailAccounts.actionCards
            ))

            let registered = Set(app.routes.all.map { "\($0.method.rawValue) \($0.path.string)" })
            let expected = Set(expectedIntegrationsRoutes.map { "\($0.0.rawValue) \($0.1)" })

            // The table is authoritative: reject an accidental duplicate or gap
            // in the table itself before comparing it to the router.
            #expect(expectedIntegrationsRoutes.count == 44)
            #expect(expected.count == 44)

            // One route per table entry, and no route outside the five
            // extracted families.
            #expect(app.routes.all.count == expected.count)
            #expect(registered == expected)
            #expect(app.routes.all.allSatisfy { route in
                let components = route.path.map { $0.description }
                let families: Set<String> = [
                    "integrations",
                    "mcp",
                    "provider-connections",
                    "agent-runtime-providers",
                    "app-installation",
                ]
                return components.count >= 2
                    && components[0] == "api"
                    && families.contains(components[1])
            })
        }
    }
}
