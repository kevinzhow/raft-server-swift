import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func rootAndNestedOpenIDConfigurationsMatch() async throws {
    let accounts = EmailLoginDirectory()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let root = try await client.send(.get, headers: HTTPFields(), to: "/.well-known/openid-configuration")
            let nested = try await client.send(.get, headers: HTTPFields(), to: "/api/oauth/.well-known/openid-configuration")
            #expect(root.status == .ok)
            #expect(nested.status == .ok)
            #expect(root.body.string == nested.body.string)
            let body = try JSONSerialization.jsonObject(with: Data((root.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["issuer"] as? String == "http://localhost:3001")
            #expect(body?["authorization_endpoint"] as? String == "http://localhost:3001/api/oauth/authorize")
            #expect((body?["scopes_supported"] as? [String])?.contains("email") == true)
        }
    }
}
