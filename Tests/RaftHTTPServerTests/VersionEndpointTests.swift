import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func versionEndpointReturnsTheBuildIdentityWithoutAuth() async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            serverVersion: "1.21.23",
            releaseEnvironment: [
                "SLOCK_RELEASE_SHA": "0123456789abcdef0123456789abcdef01234567",
                "SLOCK_BUILD_AT": "2026-07-13T04:52:55Z",
                "SLOCK_RELEASE_BRANCH": "staging",
            ],
            emailAccounts: EmailLoginDirectory()
        ))
        try await app.testing { client in
            let response = try await client.get("/api/version")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["version"] as? String == "1.21.23")
            #expect(body?["sha"] as? String == "0123456789abcdef0123456789abcdef01234567")
            #expect(body?["builtAt"] as? String == "2026-07-13T04:52:55Z")
            #expect(body?["branch"] as? String == "staging")
        }
    }
}

@Test func versionEndpointFailsExplicitlyWhenTheShaIsMissing() async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            releaseEnvironment: [
                "SLOCK_BUILD_AT": "2026-07-13T04:52:55Z",
                "SLOCK_RELEASE_BRANCH": "staging",
            ],
            emailAccounts: EmailLoginDirectory()
        ))
        try await app.testing { client in
            let response = try await client.get("/api/version")
            #expect(response.status == .serviceUnavailable)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "Build identity unavailable")
            #expect(body?["code"] as? String == "build_identity_unavailable")
            #expect(body?["detail"] as? String == "RAFT_RELEASE_SHA is missing or disagrees with its legacy alias")
            #expect(body?["sha"] == nil || body?["sha"] is NSNull)
            #expect(body?["builtAt"] as? String == "2026-07-13T04:52:55Z")
            #expect(body?["branch"] as? String == "staging")
        }
    }
}
