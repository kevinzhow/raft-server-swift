import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func appAdminRoutesAreNotPartOfThePublicApi() async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        ))
        try await app.testing { client in
            let response = try await client.get("/api/app-admin/me")
            #expect(response.status == .notFound)
        }
    }
}
