import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// A focused app mounts only the actual production AuthFeature and its concrete
/// scene services. It does not claim the private full-Fallback decoder boundary.
func withAuthSceneApp(
    _ scene: AuthScene,
    publicServerDirectory: PublicServerDirectory? = nil,
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
            managedLifecycle: scene.services.integrations.lifecycle,
            publicServerDirectory: publicServerDirectory
        ).register(routes: app)
        try await app.testing { client in
            try await test(client)
        }
    }
}

func authSceneHeaders(token: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    return headers
}

func authSceneJSON(_ response: ClientResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
}

func authScenePost(
    _ client: any Client, _ path: String, token: String? = nil, body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: authSceneHeaders(token: token), to: URI(string: path)) {
        $0.body = .init(string: body)
    }
}
