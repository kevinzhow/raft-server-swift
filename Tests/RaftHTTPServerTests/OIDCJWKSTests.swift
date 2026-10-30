import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func jwksPublishesOneES256VerificationKeyWithoutThePrivateScalar() async throws {
    let accounts = EmailLoginDirectory()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let response = try await client.send(.get, headers: HTTPFields(), to: "/api/oauth/jwks")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let keys = body?["keys"] as? [[String: Any]] ?? []
            #expect(keys.count == 1)
            let key = keys.first ?? [:]
            #expect(key["kty"] as? String == "EC")
            #expect(key["crv"] as? String == "P-256")
            #expect(key["use"] as? String == "sig")
            #expect(key["alg"] as? String == "ES256")
            #expect(key["d"] == nil)
            #expect((key["x"] as? String)?.isEmpty == false)
            #expect((key["y"] as? String)?.isEmpty == false)
        }
    }
}
