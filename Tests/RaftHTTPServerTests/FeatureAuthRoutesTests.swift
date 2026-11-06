import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Every `method path` pair the auth slice owns. This is the complete list of
/// `app.get/post/patch/delete/on("api", "auth", ...)` registrations in
/// `FallbackApplication.configure` at extraction time (38 routes).
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
    (.post, "POST /api/auth/verify-email"),
    (.post, "POST /api/auth/resend-verification"),
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
        try await app.register(collection: AuthFeature(
            core: services.emailAccounts.authCore,
            identities: services.emailAccounts.authIdentities,
            oauthFlows: services.emailAccounts.oauthFlows,
            verification: services.emailAccounts.authVerification,
            profile: services.emailAccounts.authProfile,
            invites: services.emailAccounts.joinLinksAndInvites,
            managedLifecycle: services.emailAccounts.managedMCPLifecycle,
            publicServerDirectory: services.publicServerDirectory
        ))

        let registered = Set(app.routes.all.map { route in
            "\(route.method.rawValue) /" + route.path.map { "\($0)" }.joined(separator: "/")
        })
        let expected = Set(expectedAuthRoutes.map { $0.1 })

        // The list is authoritative: reject an accidental duplicate or gap in
        // the table itself before comparing it to the router.
        #expect(expectedAuthRoutes.count == 38)
        #expect(expected.count == 38)

        // One route per table entry, and no route outside `/api/auth/...`.
        #expect(app.routes.all.count == expected.count)
        #expect(registered == expected)
        #expect(app.routes.all.allSatisfy { $0.path.first?.description == "api" && $0.path.dropFirst().first?.description == "auth" })
    }
}

@Test func authFeatureKeepsPublicDirectoryInvitePrecedenceAnd404Fallback() async throws {
    let accounts = EmailLoginDirectory()
    let directory = PublicServerDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111660"
    let serverId = "33333333-3333-4333-8333-333333333680"
    let users = [
        ("11111111-1111-4111-8111-111111111661", "auth-public-success@slock.test"),
        ("11111111-1111-4111-8111-111111111662", "auth-public-fallback@slock.test"),
        ("11111111-1111-4111-8111-111111111663", "auth-public-refused@slock.test"),
    ]
    accounts.addAccount(id: ownerId, email: "auth-public-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "auth-root-server", name: "Auth Root Server", ownerId: ownerId)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    _ = directory.addServer(id: "external-server", name: "External Server", slug: "external-server", ownerId: ownerId, ownerToken: ownerToken)
    var tokens: [String] = []
    for (id, email) in users {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        let token = accounts.mintAccessTokenForTesting(userId: id)
        directory.addAccount(id: id, email: email, token: token)
        tokens.append(token)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicServerDirectory: directory, emailAccounts: accounts))
        try await app.testing { client in
            func post(_ path: String, authorization: String, body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(authorization)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: URI(string: path)) { $0.body = .init(string: body) }
            }
            func joinToken() async throws -> String {
                let created = try await post("/api/servers/\(serverId)/join-links", authorization: ownerToken, body: "{}")
                #expect(created.status == .ok)
                let object = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
                return try #require(object?["token"] as? String)
            }
            let publicToken = try await joinToken()
            directory.addEmailInvite(serverId: "external-server", email: users[0].1, role: "guest", rawToken: publicToken, expiresAt: Date().addingTimeInterval(3600))
            let accepted = try await post("/api/auth/accept-invite", authorization: tokens[0], body: "{\"token\":\"\(publicToken)\"}")
            #expect(accepted.status == .ok)
            #expect(accepted.body.string == #"{"serverId":"external-server","serverName":"External Server"}"#)

            let fallbackToken = try await joinToken()
            directory.addEmailInvite(serverId: "missing-external-server", email: users[1].1, role: "guest", rawToken: fallbackToken, expiresAt: Date().addingTimeInterval(3600))
            let fallback = try await post("/api/auth/accept-invite", authorization: tokens[1], body: "{\"token\":\"\(fallbackToken)\"}")
            #expect(fallback.status == .ok)
            #expect(fallback.body.string == "{\"ok\":true,\"serverId\":\"\(serverId)\"}")

            let refusedToken = try await joinToken()
            directory.addEmailInvite(serverId: "external-server", email: "somebody-else@slock.test", role: "guest", rawToken: refusedToken, expiresAt: Date().addingTimeInterval(3600))
            let refused = try await post("/api/auth/accept-invite", authorization: tokens[2], body: "{\"token\":\"\(refusedToken)\"}")
            #expect(refused.status == .badRequest)
            #expect(refused.body.string == #"{"error":"This invite was sent to a different email address"}"#)
        }
    }
}
