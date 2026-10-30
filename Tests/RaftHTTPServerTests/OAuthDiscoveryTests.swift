import Foundation
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

@Test func oauthDiscoveryExposesPublicRaftScopesAndHidesReservedOnes() async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        ))
        try await app.testing { client in
            let response = try await client.get("/api/oauth/.well-known/openid-configuration")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            let scopes = body?["scopes_supported"] as? [String]
            #expect(scopes == [
                "openid",
                "profile",
                "email",
                "identity",
                "agent:read",
                "agent:event:write",
                "agent:notification:write",
            ])
            #expect(scopes?.contains("agent:action_request:write") == false)
            #expect(scopes?.contains("app_admin") == false)
            #expect(scopes?.contains("winbox:opencli:twitter") == false)
        }
    }
}
