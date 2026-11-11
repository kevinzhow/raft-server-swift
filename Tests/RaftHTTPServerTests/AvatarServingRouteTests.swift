import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

// MARK: - GET /api/avatars/:namespace/:filename

/// `routes/agents.ts:3707-3733`: the filename must be lowercase hex plus
/// `.webp` (400 otherwise), and without the CDN object store the route answers
/// the same 500 `{"error":"Storage not configured"}` the pinned handler uses.
/// This deployment has no avatar object bucket, so no fabricated bytes are
/// served.
@Test func avatarObjectRouteValidatesTheFilenameAndReportsMissingStorage() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let storedName = String(repeating: "a", count: 32)
            let missingStorage = try await client.get(URI(string: "/api/avatars/users/\(storedName).webp"))
            #expect(missingStorage.status == .internalServerError)
            #expect(missingStorage.body.string == #"{"error":"Storage not configured"}"#)

            for filename in ["not-hex.webp", "AAAAAA.webp", "abcdef.png", "abcdef.webp.png", "abc"] {
                let invalid = try await client.get(URI(string: "/api/avatars/users/\(filename)"))
                #expect(invalid.status == .badRequest, Comment(rawValue: filename))
                #expect(invalid.body.string == #"{"error":"Invalid filename"}"#)
            }

            // The static pixel route keeps its precedence over the parameter
            // route: an invalid pixel key is still the pixel route's 400.
            let pixel = try await client.get(URI(string: "/api/avatars/pixel/not-a-key.svg"))
            #expect(pixel.status == .badRequest)
            #expect(pixel.body.string == #"{"error":"Invalid pixel avatar key"}"#)
        }
    }
}
