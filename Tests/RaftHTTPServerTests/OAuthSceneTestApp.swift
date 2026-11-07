import RaftHTTP
import RaftHTTPServer
import TestSupport
import Vapor

/// The actual OAuth and Auth Features consume one composed owner graph and the
/// production JSON boundary. Tests retain their existing app/client lifetimes.
func configureOAuthScene(_ app: Application, scene: OAuthScene) {
    app.middleware.use(JSONErrorBoundaryMiddleware(), at: .beginning)
    OAuthFeature(
        oauthFlows: scene.services.identity.oauthFlows,
        issuerMetadata: scene.services.identity.issuerMetadata,
        authorization: scene.services.identity.authorization,
        principal: scene.services.identity.principal,
        apps: scene.services.integrations.apps
    ).register(routes: app)
    AuthFeature(
        core: scene.services.identity.core,
        identities: scene.services.identity.identities,
        oauthFlows: scene.services.identity.oauthFlows,
        verification: scene.services.identity.verification,
        profile: scene.services.identity.profile,
        invites: scene.services.channels.invites,
        managedLifecycle: scene.services.integrations.lifecycle
    ).register(routes: app)
}
