import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Every `method path` pair the auth slice owns. This is the complete list of
/// `app.get/post/patch/delete/on("api", "auth", ...)` registrations in
/// `FallbackApplication.configure` at extraction time (36 routes).
private let expectedAuthRoutes: [(HTTPRequest.Method, String)] = [
    (.get, "GET /api/auth/invite-info"),
    (.post, "POST /api/auth/mobile/oauth/apple/native/start"),
    (.post, "POST /api/auth/mobile/oauth/apple/native/authorize"),
    (.post, "POST /api/auth/mobile/oauth/start"),
    (.post, "POST /api/auth/mobile/oauth/:provider/link/start"),
    (.post, "POST /api/auth/mobile/oauth/:provider/link/complete"),
    (.get, "GET /api/auth/:provider/start"),
    (.post, "POST /api/auth/:provider/link/start"),
    (.post, "POST /api/auth/:provider/callback"),
    (.get, "GET /api/auth/:provider/callback"),
    (.post, "POST /api/auth/mobile/oauth/complete"),
    (.post, "POST /api/auth/:provider/complete"),
    (.post, "POST /api/auth/device/authorize"),
    (.post, "POST /api/auth/device/approve"),
    (.post, "POST /api/auth/device/token"),
    (.post, "POST /api/auth/staging-self-account/retire"),
    (.post, "POST /api/auth/register"),
    (.post, "POST /api/auth/refresh"),
    (.post, "POST /api/auth/logout"),
    (.get, "GET /api/auth/identities"),
    (.delete, "DELETE /api/auth/identities/:provider"),
    (.post, "POST /api/auth/reset-password"),
    (.post, "POST /api/auth/pending-link/cancel"),
    (.post, "POST /api/auth/login"),
    (.post, "POST /api/auth/app-login/start"),
    (.get, "GET /api/auth/app-login/requests/:requestId"),
    (.post, "POST /api/auth/app-login/requests/:requestId/approve"),
    (.post, "POST /api/auth/app-login/requests/:requestId/deny"),
    (.post, "POST /api/auth/app-login/complete"),
    (.get, "GET /api/auth/providers"),
    (.get, "GET /api/auth/me"),
    (.post, "POST /api/auth/me/avatar"),
    (.post, "POST /api/auth/me/complete-profile"),
    (.post, "POST /api/auth/me/timezone-observation"),
    (.patch, "PATCH /api/auth/me"),
    (.post, "POST /api/auth/accept-invite"),
]

@Test func authFeatureRegistersEveryAuthRoute() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        emailAccounts: EmailLoginDirectory()
    )
    try await withApp { app in
        try await app.register(collection: AuthFeature(services: services))

        let registered = Set(app.routes.all.map { route in
            "\(route.method.rawValue) /" + route.path.map { "\($0)" }.joined(separator: "/")
        })
        let expected = Set(expectedAuthRoutes.map { $0.1 })

        // The list is authoritative: reject an accidental duplicate or gap in
        // the table itself before comparing it to the router.
        #expect(expectedAuthRoutes.count == 36)
        #expect(expected.count == 36)

        // One route per table entry, and no route outside `/api/auth/...`.
        #expect(app.routes.all.count == expected.count)
        #expect(registered == expected)
        #expect(app.routes.all.allSatisfy { $0.path.first?.description == "api" && $0.path.dropFirst().first?.description == "auth" })
    }
}
