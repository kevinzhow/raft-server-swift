import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The complete `/api/servers/:id` route surface registered after the pinned
/// lockdown (`routes/servers.ts:994`). Every entry runs
/// `requireServerMatchesParam` (`middleware/auth.ts:416-470`); the lab routes
/// are deliberately absent because upstream mounts them before the lockdown.
private struct FunneledRoute: Sendable {
    let method: HTTPRequest.Method
    let suffix: String
}

private let machineId = "44444444-4444-4444-8444-444444444401"
private let agentId = "55555555-5555-4555-8555-555555555502"
private let memberId = "11111111-1111-4111-8111-111111119902"
private let inviteId = "66666666-6666-4666-8666-666666666603"
private let linkId = "77777777-7777-4777-8777-777777777704"
private let incidentId = "88888888-8888-4888-8888-888888888805"

/// All 67 distinct funneled routes (the duplicate `DELETE .../machines/:machineId`
/// registration shares one middleware instance).
private let funneledRoutes: [FunneledRoute] = [
    .init(method: .get, suffix: ""),
    .init(method: .patch, suffix: ""),
    .init(method: .delete, suffix: ""),
    .init(method: .get, suffix: "agreement"),
    .init(method: .put, suffix: "agreement"),
    .init(method: .get, suffix: "apps"),
    .init(method: .post, suffix: "avatar"),
    .init(method: .post, suffix: "leave"),
    .init(method: .get, suffix: "settings"),
    .init(method: .get, suffix: "onboarding-settings"),
    .init(method: .patch, suffix: "onboarding-settings"),
    .init(method: .get, suffix: "setup-projection"),
    .init(method: .post, suffix: "setup-transition"),
    .init(method: .post, suffix: "setup-reset"),
    .init(method: .post, suffix: "setup-handoff"),
    .init(method: .get, suffix: "product-analytics-settings"),
    .init(method: .patch, suffix: "product-analytics-settings"),
    .init(method: .get, suffix: "translation-settings"),
    .init(method: .patch, suffix: "translation-settings"),
    .init(method: .get, suffix: "notification-settings"),
    .init(method: .patch, suffix: "notification-settings"),
    .init(method: .post, suffix: "scope-attestation"),
    .init(method: .get, suffix: "usage"),
    .init(method: .get, suffix: "members"),
    .init(method: .get, suffix: "member-graph"),
    .init(method: .get, suffix: "sidebar-order"),
    .init(method: .patch, suffix: "sidebar-order"),
    .init(method: .patch, suffix: "members/\(memberId)"),
    .init(method: .get, suffix: "members/\(memberId)/profile"),
    .init(method: .delete, suffix: "members/\(memberId)"),
    .init(method: .get, suffix: "invites"),
    .init(method: .post, suffix: "invites"),
    .init(method: .delete, suffix: "invites/\(inviteId)"),
    .init(method: .get, suffix: "join-links"),
    .init(method: .post, suffix: "join-links"),
    .init(method: .delete, suffix: "join-links/\(linkId)"),
    .init(method: .get, suffix: "system-notifications"),
    .init(method: .get, suffix: "system-notifications-v2"),
    .init(method: .post, suffix: "system-notifications-v2/\(incidentId)/seen"),
    .init(method: .post, suffix: "system-notifications-v2/\(incidentId)/dismiss"),
    .init(method: .get, suffix: "machines"),
    .init(method: .post, suffix: "machines"),
    .init(method: .patch, suffix: "machines/\(machineId)"),
    .init(method: .delete, suffix: "machines/\(machineId)"),
    .init(method: .post, suffix: "machines/\(machineId)/rotate-key"),
    .init(method: .post, suffix: "machines/\(machineId)/computer/start"),
    .init(method: .post, suffix: "machines/\(machineId)/computer-lifecycle-operations"),
    .init(method: .get, suffix: "machines/\(machineId)/workspaces"),
    .init(method: .get, suffix: "machines/\(machineId)/runtime-options"),
    .init(method: .get, suffix: "machines/\(machineId)/runtime-account-usage/codex"),
    .init(method: .post, suffix: "machines/\(machineId)/runtime-account-usage/codex/refresh"),
    .init(method: .get, suffix: "machines/\(machineId)/runtime-form-definitions/codex"),
    .init(method: .get, suffix: "machines/\(machineId)/runtime-forms/v2/codex"),
    .init(method: .get, suffix: "machines/\(machineId)/runtime-form-definitions/codex/option-sources/source"),
    .init(method: .get, suffix: "machines/\(machineId)/runtime-forms/v2/codex/option-sources/source"),
    .init(method: .post, suffix: "machines/\(machineId)/runtimes/rescan"),
    .init(method: .get, suffix: "model-label-catalog"),
    .init(method: .get, suffix: "machines/\(machineId)/runtime-models/codex"),
    .init(method: .get, suffix: "machines/\(machineId)/agents/\(agentId)/diagnostic/mention-delivery/msg1"),
    .init(method: .post, suffix: "machines/\(machineId)/agents/\(agentId)/diagnostic/mention-delivery/msg1/redrive"),
    .init(method: .get, suffix: "machines/\(machineId)/agents/\(agentId)/diagnostic/session-transcript"),
    .init(method: .post, suffix: "machines/\(machineId)/agents/\(agentId)/feedback/report/transcript"),
    .init(method: .delete, suffix: "machines/\(machineId)/workspaces/directory"),
    .init(method: .get, suffix: "public-visibility"),
    .init(method: .patch, suffix: "public-visibility"),
    .init(method: .patch, suffix: "public-search"),
    .init(method: .patch, suffix: "public-guest-join"),
]

/// The eight guest-hidden path families from `routes/servers.ts:996-1004`,
/// expanded to the registered method/path pairs (`use` is prefix-based, so the
/// two `invites` and two `join-links` DELETE routes are covered as well).
private let guestHiddenRoutes: [FunneledRoute] = [
    .init(method: .get, suffix: "apps"),
    .init(method: .get, suffix: "settings"),
    .init(method: .get, suffix: "onboarding-settings"),
    .init(method: .patch, suffix: "onboarding-settings"),
    .init(method: .get, suffix: "setup-projection"),
    .init(method: .get, suffix: "usage"),
    .init(method: .get, suffix: "member-graph"),
    .init(method: .get, suffix: "invites"),
    .init(method: .post, suffix: "invites"),
    .init(method: .delete, suffix: "invites/\(inviteId)"),
    .init(method: .get, suffix: "join-links"),
    .init(method: .post, suffix: "join-links"),
    .init(method: .delete, suffix: "join-links/\(linkId)"),
]

private func serverPath(_ serverId: String, _ suffix: String) -> String {
    suffix.isEmpty ? "/api/servers/\(serverId)" : "/api/servers/\(serverId)/\(suffix)"
}

private func assertScopeReply(
    _ response: ClientResponse,
    status: HTTPResponse.Status,
    body: String
) {
    #expect(response.status == status)
    #expect(response.body.string == body)
    #expect(response.headers[.contentLength] == String(body.utf8.count))
    #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
    #expect(response.headers[.cacheControl] == "private, no-store")
}

/// Every funneled route applies the same pre-handler order: authentication
/// (global), non-UUID 404 before the header, missing/mismatched header 400,
/// then live membership 403. Unknown and soft-deleted servers are refused as
/// non-members; only an owner's DELETE retry on the server root is exempt.
@Test func everyFunneledServerRouteAppliesThePinnedScopeFunnel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111119901"
    let serverId = "33333333-3333-4333-8333-333333339901"
    let otherServerId = "33333333-3333-4333-8333-333333339902"
    let deletedServerId = "33333333-3333-4333-8333-333333339903"
    let unknownServerId = "33333333-3333-4333-8333-333333339999"
    let memberUserId = "11111111-1111-4111-8111-111111119902"
    let guestUserId = "11111111-1111-4111-8111-111111119903"
    let outsiderId = "11111111-1111-4111-8111-111111119904"
    for (id, email) in [
        (ownerId, "funnel-owner@slock.test"),
        (memberUserId, "funnel-member@slock.test"),
        (guestUserId, "funnel-guest@slock.test"),
        (outsiderId, "funnel-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "funnel-live", name: "Funnel Live", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "funnel-other", name: "Funnel Other", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberUserId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestUserId, role: "guest")
    accounts.oauth.addOwnedServer(id: deletedServerId, slug: "funnel-deleted", name: "Funnel Deleted", ownerId: ownerId)
    accounts.oauth.deleteServer(id: deletedServerId)

    let owner = accounts.mintAccessTokenForTesting(userId: ownerId)
    let outsider = accounts.mintAccessTokenForTesting(userId: outsiderId)
    let guest = accounts.mintAccessTokenForTesting(userId: guestUserId)
    let member = accounts.mintAccessTokenForTesting(userId: memberUserId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func call(
                _ route: FunneledRoute,
                server: String,
                bearer: String?,
                header: String?
            ) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                if let header { headers[HTTPField.Name("X-Server-Id")!] = header }
                return try await client.send(
                    route.method,
                    headers: headers,
                    to: URI(string: serverPath(server, route.suffix))
                )
            }

            for route in funneledRoutes {
                // A non-UUID path id names no server before the header is read.
                let malformed = try await call(route, server: "not-a-uuid", bearer: owner, header: "not-a-uuid")
                assertScopeReply(malformed, status: .notFound, body: "{\"error\":\"Server not found\"}")

                let missingHeader = try await call(route, server: serverId, bearer: owner, header: nil)
                assertScopeReply(missingHeader, status: .badRequest, body: "{\"error\":\"Missing X-Server-Id header\"}")

                let mismatched = try await call(route, server: serverId, bearer: owner, header: otherServerId)
                assertScopeReply(mismatched, status: .badRequest,
                    body: "{\"error\":\"X-Server-Id must match server id in URL\"}")

                let nonMember = try await call(route, server: serverId, bearer: outsider, header: serverId)
                assertScopeReply(nonMember, status: .forbidden, body: "{\"error\":\"Not a member of this server\"}")

                // The membership query joins the live server row, so an
                // unknown server refuses exactly like a non-member.
                let unknown = try await call(route, server: unknownServerId, bearer: owner, header: unknownServerId)
                assertScopeReply(unknown, status: .forbidden, body: "{\"error\":\"Not a member of this server\"}")

                if !(route.method == .delete && route.suffix.isEmpty) {
                    let deleted = try await call(route, server: deletedServerId, bearer: owner, header: deletedServerId)
                    assertScopeReply(deleted, status: .forbidden, body: "{\"error\":\"Not a member of this server\"}")
                }

                // Authentication still precedes the funnel for every shape.
                let anonymous = try await call(route, server: serverId, bearer: nil, header: serverId)
                assertScopeReply(anonymous, status: .unauthorized,
                    body: "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            }

            // The sole exemption: a live owner may retry DELETE on an already
            // soft-deleted server so the deletion service can finish cleanup.
            let deletedOwnerRetry = try await call(
                .init(method: .delete, suffix: ""),
                server: deletedServerId, bearer: owner, header: deletedServerId
            )
            assertScopeReply(deletedOwnerRetry, status: .ok, body: "{\"ok\":true}")
            let deletedMemberRetry = try await call(
                .init(method: .delete, suffix: ""),
                server: deletedServerId, bearer: member, header: deletedServerId
            )
            assertScopeReply(deletedMemberRetry, status: .forbidden, body: "{\"error\":\"Not a member of this server\"}")
        }
    }
}

/// The eight guest-hidden surface families refuse a live guest after the
/// membership check. Members and admins are not affected (their handler decides).
@Test func guestHiddenServerSurfacesRefuseGuests() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111120901"
    let guestUserId = "11111111-1111-4111-8111-111111120902"
    let memberUserId = "11111111-1111-4111-8111-111111120903"
    let serverId = "33333333-3333-4333-8333-333333340901"
    for (id, email) in [
        (ownerId, "guest-hidden-owner@slock.test"),
        (guestUserId, "guest-hidden-guest@slock.test"),
        (memberUserId, "guest-hidden-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "guest-hidden", name: "Guest Hidden", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestUserId, role: "guest")
    accounts.oauth.addMember(serverId: serverId, userId: memberUserId, role: "member")
    let guest = accounts.mintAccessTokenForTesting(userId: guestUserId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            for route in guestHiddenRoutes {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(guest)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                let response = try await client.send(
                    route.method,
                    headers: headers,
                    to: URI(string: serverPath(serverId, route.suffix))
                )
                assertScopeReply(
                    response,
                    status: .forbidden,
                    body: "{\"error\":\"Guests cannot access server management data\"}"
                )
            }
        }
    }
}

/// A request that passes the funnel reaches the route's own handler. These are
/// the representative member-readable routes plus three handler-local refusals
/// whose bodies differ from the funnel's `Not a member of this server`.
@Test func memberRequestsWithMatchingScopeReachTheirHandlers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111121901"
    let memberUserId = "11111111-1111-4111-8111-111111121902"
    let serverId = "33333333-3333-4333-8333-333333341901"
    for (id, email) in [
        (ownerId, "reach-owner@slock.test"),
        (memberUserId, "reach-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "reach-handler", name: "Reach Handler", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberUserId, role: "member")
    let member = accounts.mintAccessTokenForTesting(userId: memberUserId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func get(_ suffix: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(member)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.get, headers: headers, to: URI(string: serverPath(serverId, suffix)))
            }

            for suffix in [
                "", "members", "member-graph", "model-label-catalog", "sidebar-order",
                "machines", "notification-settings", "system-notifications", "system-notifications-v2",
            ] {
                let response = try await get(suffix)
                #expect(response.status == .ok, "\(suffix)")
                #expect(response.headers[.contentType] == "application/json; charset=utf-8", "\(suffix)")
            }

            // `GET /settings` is owner/admin-only in the handler.
            let settings = try await get("settings")
            assertScopeReply(settings, status: .forbidden, body: "{\"error\":\"Forbidden\"}")

            // The pre-join agreement read reaches its handler's own projection
            // (the existing member-readable behavior; this slice does not
            // change handler authority).
            let agreement = try await get("agreement")
            assertScopeReply(agreement, status: .ok, body: "{\"agreement\":null}")

            // `DELETE /:id` passes the member funnel and reaches its
            // owner-only handler refusal.
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(member)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let deleteAsMember = try await client.send(
                .delete, headers: headers, to: URI(string: serverPath(serverId, ""))
            )
            assertScopeReply(
                deleteAsMember,
                status: .forbidden,
                body: "{\"error\":\"Only the server owner can delete a server\"}"
            )
        }
    }
}

/// The lab sub-router is mounted before the lockdown (`routes/servers.ts:993`)
/// and keeps its own scope contract: the funnel's `Server not found`/missing
/// header bodies must not appear on the lab routes.
@Test func labRoutesAreNotFunneled() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111122901"
    let serverId = "33333333-3333-4333-8333-333333342901"
    accounts.addAccount(id: ownerId, email: "labs-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "labs-unfunneled", name: "Labs Unfunneled", ownerId: ownerId)
    let owner = accounts.mintAccessTokenForTesting(userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func call(server: String, header: String?) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(owner)"
                if let header { headers[HTTPField.Name("X-Server-Id")!] = header }
                return try await client.send(.get, headers: headers, to: URI(string: serverPath(server, "labs")))
            }

            // The labs service owns the missing/mismatched header refusal and
            // publishes its code, not the funnel's plain 400 bodies.
            let missing = try await call(server: serverId, header: nil)
            assertScopeReply(
                missing, status: .forbidden,
                body: "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}"
            )
            let mismatched = try await call(server: serverId, header: "33333333-3333-4333-8333-333333342999")
            assertScopeReply(
                mismatched, status: .forbidden,
                body: "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}"
            )

            // A non-UUID id is not short-circuited to the funnel's 404; the lab
            // handler answers its own refusal.
            let malformed = try await call(server: "not-a-uuid", header: "not-a-uuid")
            #expect(malformed.status == .forbidden)
            #expect(malformed.body.string == "{\"error\":\"Forbidden\"}")
        }
    }
}
