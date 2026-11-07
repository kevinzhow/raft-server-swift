import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

/// Mounts the actual AuthFeature and the actual installation registrations from
/// one composed graph. The production JSON boundary is shared; full Fallback's
/// private decoder middleware is exercised by the separate full-mount test.
func withInstallationSceneApp(
    _ scene: InstallationScene,
    _ test: @escaping @Sendable (any Client) async throws -> Void
) async throws {
    try await withApp { app in
        app.middleware.use(JSONErrorBoundaryMiddleware(), at: .beginning)
        AuthFeature(
            core: scene.services.identity.core,
            identities: scene.services.identity.identities,
            oauthFlows: scene.services.identity.oauthFlows,
            verification: scene.services.identity.verification,
            profile: scene.services.identity.profile,
            invites: scene.services.channels.invites,
            managedLifecycle: scene.services.integrations.lifecycle
        ).register(routes: app)
        let installation = InstallationCredentialRoutes(apps: scene.services.integrations.apps)
        installation.registerMint(routes: app.grouped("api", "oauth"))
        installation.registerReads(routes: app.grouped("api", "app-installation"))
        try await app.testing { client in
            try await test(client)
        }
    }
}
