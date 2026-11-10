import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// `/api/servers/:id/*` is mounted behind `requireAuth` + `requireVerified`
/// (`app.ts:483`) and the router-wide `requireServerMatchesParam` lockdown
/// (`routes/servers.ts:1005`, defined at `middleware/auth.ts:416`); the
/// guest-hidden middleware (`routes/servers.ts:1010–1031`) runs after it. The
/// three setup handlers therefore only see a live member with a matching
/// `X-Server-Id`. These are the published HTTP statuses and bodies.
@Test func setupRoutesApplyThePinnedServerScopeFunnel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = UUID().uuidString.lowercased()
    let adminId = UUID().uuidString.lowercased()
    let memberId = UUID().uuidString.lowercased()
    let guestId = UUID().uuidString.lowercased()
    let outsiderId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    let otherServerId = UUID().uuidString.lowercased()
    accounts.addAccount(id: ownerId, email: "scope-owner@example.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "scope-funnel", name: "Scope Funnel", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "scope-other", name: "Scope Other", ownerId: ownerId)
    for (id, email, role) in [
        (adminId, "scope-admin@example.test", "admin"),
        (memberId, "scope-member@example.test", "member"),
        (guestId, "scope-guest@example.test", "guest"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
    }
    accounts.addAccount(id: outsiderId, email: "scope-outsider@example.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    // A soft-deleted server keeps its stale membership row. The pinned
    // lockdown joins the live server row, so this is not a live membership.
    let deletedServerId = UUID().uuidString.lowercased()
    accounts.oauth.addOwnedServer(id: deletedServerId, slug: "scope-deleted", name: "Scope Deleted", ownerId: ownerId)
    accounts.oauth.deleteServer(id: deletedServerId)
    let owner = accounts.mintAccessTokenForTesting(userId: ownerId)
    let outsider = accounts.mintAccessTokenForTesting(userId: outsiderId)
    let guest = accounts.mintAccessTokenForTesting(userId: guestId)
    let unknownServerId = UUID().uuidString.lowercased()

    let routes: [(path: String, method: HTTPRequest.Method)] = [
        ("setup-projection", .get), ("setup-transition", .post), ("setup-handoff", .post),
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func call(
                _ route: (path: String, method: HTTPRequest.Method),
                serverId: String,
                header: String?,
                bearer: String?,
                action: String? = nil
            ) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                if let header { headers[HTTPField.Name("X-Server-Id")!] = header }
                if action != nil { headers[.contentType] = "application/json" }
                return try await client.send(
                    route.method,
                    headers: headers,
                    to: URI(string: "/api/servers/\(serverId)/\(route.path)")
                ) { request in
                    if let action { request.body = .init(string: "{\"action\":\"\(action)\"}") }
                }
            }

            for route in routes {
                // requireAuth precedes the router: an anonymous caller is 401
                // even when the path/header checks would also fail.
                let anonymous = try await call(route, serverId: serverId, header: nil, bearer: nil)
                #expect(anonymous.status == .unauthorized, "\(route.path)")
                let anonymousWithHeader = try await call(route, serverId: serverId, header: serverId, bearer: nil)
                #expect(anonymousWithHeader.status == .unauthorized, "\(route.path)")

                // A non-UUID names no server, before the header check.
                let malformed = try await call(route, serverId: "not-a-uuid", header: nil, bearer: owner)
                #expect(malformed.status == .notFound, "\(route.path)")
                #expect(malformed.body.string == "{\"error\":\"Server not found\"}", "\(route.path)")

                let missingHeader = try await call(route, serverId: serverId, header: nil, bearer: owner)
                #expect(missingHeader.status == .badRequest, "\(route.path)")
                #expect(missingHeader.body.string == "{\"error\":\"Missing X-Server-Id header\"}", "\(route.path)")

                let mismatched = try await call(route, serverId: serverId, header: otherServerId, bearer: owner)
                #expect(mismatched.status == .badRequest, "\(route.path)")
                #expect(mismatched.body.string == "{\"error\":\"X-Server-Id must match server id in URL\"}", "\(route.path)")

                let nonMember = try await call(route, serverId: serverId, header: serverId, bearer: outsider)
                #expect(nonMember.status == .forbidden, "\(route.path)")
                #expect(nonMember.body.string == "{\"error\":\"Not a member of this server\"}", "\(route.path)")

                let unknownServer = try await call(route, serverId: unknownServerId, header: unknownServerId, bearer: owner)
                #expect(unknownServer.status == .forbidden, "\(route.path)")
                #expect(unknownServer.body.string == "{\"error\":\"Not a member of this server\"}", "\(route.path)")

                let deletedServer = try await call(route, serverId: deletedServerId, header: deletedServerId, bearer: owner)
                #expect(deletedServer.status == .forbidden, "\(route.path)")
                #expect(deletedServer.body.string == "{\"error\":\"Not a member of this server\"}", "\(route.path)")
            }

            // Only `setup-projection` is in the guest-hidden surface list; the
            // other two reach their handler and answer owner-only.
            let guestProjection = try await call(routes[0], serverId: serverId, header: serverId, bearer: guest)
            #expect(guestProjection.status == .forbidden)
            #expect(guestProjection.body.string == "{\"error\":\"Guests cannot access server management data\"}")
            for route in [routes[1], routes[2]] {
                let guestHandler = try await call(route, serverId: serverId, header: serverId, bearer: guest, action: "start")
                #expect(guestHandler.status == .forbidden, "\(route.path)")
                #expect(guestHandler.body.string == "{\"error\":\"INSUFFICIENT_PERMISSION\"}", "\(route.path)")
            }
        }
    }
}

/// A live member/admin passes the scope funnel and reaches the handler-level
/// projection: members and admins read the non-blocking `none` projection,
/// while every setup mutation stays owner-only.
@Test func setupRoutesReachTheirHandlersOnlyAfterLiveMemberScope() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = UUID().uuidString.lowercased()
    let adminId = UUID().uuidString.lowercased()
    let memberId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    accounts.addAccount(id: ownerId, email: "reach-owner@example.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "reach-handler", name: "Reach Handler", ownerId: ownerId)
    for (id, email, role) in [
        (adminId, "reach-admin@example.test", "admin"),
        (memberId, "reach-member@example.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
    }
    let owner = accounts.mintAccessTokenForTesting(userId: ownerId)
    let admin = accounts.mintAccessTokenForTesting(userId: adminId)
    let member = accounts.mintAccessTokenForTesting(userId: memberId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func headers(_ bearer: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(bearer)"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func projection(_ bearer: String) async throws -> [String: Any] {
                let response = try await client.send(
                    .get, headers: headers(bearer), to: "/api/servers/\(serverId)/setup-projection"
                )
                #expect(response.status == .ok)
                return try #require(JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any])
            }
            func transition(_ bearer: String, _ action: String) async throws -> ClientResponse {
                var fields = headers(bearer)
                fields[.contentType] = "application/json"
                return try await client.send(
                    .post, headers: fields, to: "/api/servers/\(serverId)/setup-transition"
                ) { request in
                    request.body = .init(string: "{\"action\":\"\(action)\"}")
                }
            }
            func handoff(_ bearer: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(bearer), to: "/api/servers/\(serverId)/setup-handoff")
            }

            let memberProjection = try await projection(member)
            #expect(memberProjection["surface"] as? String == "none")
            #expect(memberProjection["blocksChat"] as? Bool == false)
            #expect(memberProjection["gateReason"] as? String == "insufficient_permission")
            let adminProjection = try await projection(admin)
            #expect(adminProjection["surface"] as? String == "none")
            #expect(adminProjection["gateReason"] as? String == "insufficient_permission")
            let ownerProjection = try await projection(owner)
            #expect(ownerProjection["surface"] as? String == "computer_runtime")
            #expect(ownerProjection["phase"] as? String == "not_started")

            // The route validates the action before actor authority, exactly as
            // the pinned handler does; the scope funnel already passed.
            for denied in [member, admin] {
                let invalidForMember = try await transition(denied, "advance")
                #expect(invalidForMember.status == .badRequest)
                #expect(invalidForMember.body.string == "{\"error\":\"INVALID_SETUP_ACTION\"}")
                let refusedStart = try await transition(denied, "start")
                #expect(refusedStart.status == .forbidden)
                #expect(refusedStart.body.string == "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
                let refusedComplete = try await transition(denied, "complete")
                #expect(refusedComplete.status == .forbidden)
                #expect(refusedComplete.body.string == "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
                let refusedHandoff = try await handoff(denied)
                #expect(refusedHandoff.status == .forbidden)
                #expect(refusedHandoff.body.string == "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
            }

            // Handler-local validation still runs after the scope funnel.
            let invalidAction = try await transition(owner, "advance")
            #expect(invalidAction.status == .badRequest)
            #expect(invalidAction.body.string == "{\"error\":\"INVALID_SETUP_ACTION\"}")
            let started = try await transition(owner, "start")
            #expect(started.status == .ok)
            let startedBody = try #require(JSONSerialization.jsonObject(with: started.body.data ?? Data()) as? [String: Any])
            #expect(startedBody["phase"] as? String == "in_progress")
            let handoffResponse = try await handoff(owner)
            #expect(handoffResponse.status == .ok)
            let handoffBody = try #require(JSONSerialization.jsonObject(with: handoffResponse.body.data ?? Data()) as? [String: Any])
            #expect(handoffBody["surface"] as? String == "computer_runtime")
        }
    }
}

/// `POST /api/servers/:id/setup-reset` sits under the same router-wide
/// `requireServerMatchesParam` lockdown as the other setup routes
/// (`routes/servers.ts:994`) and is *not* in the guest-hidden surface list
/// (`routes/servers.ts:996–1004`), so a live Guest reaches the handler and gets
/// its owner-only refusal. Handler-local reset authority then applies: a live
/// owner passes, every other role is `INSUFFICIENT_PERMISSION`, and a server
/// that already has an agent stays `SERVER_ALREADY_SET_UP`.
@Test func setupResetAppliesThePinnedServerScopeFunnel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = UUID().uuidString.lowercased()
    let adminId = UUID().uuidString.lowercased()
    let memberId = UUID().uuidString.lowercased()
    let guestId = UUID().uuidString.lowercased()
    let outsiderId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    let otherServerId = UUID().uuidString.lowercased()
    accounts.addAccount(id: ownerId, email: "reset-scope-owner@example.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "reset-scope", name: "Reset Scope", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "reset-scope-other", name: "Reset Scope Other", ownerId: ownerId)
    for (id, email, role) in [
        (adminId, "reset-scope-admin@example.test", "admin"),
        (memberId, "reset-scope-member@example.test", "member"),
        (guestId, "reset-scope-guest@example.test", "guest"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
    }
    accounts.addAccount(id: outsiderId, email: "reset-scope-outsider@example.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    // One attached computer gives the owner's successful reset an observable
    // `revokedComputers` count instead of an empty projection.
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "reset-scope-machine")
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, attachedByUserId: ownerId)
    // A soft-deleted server keeps its stale owner/member rows, but the pinned
    // lockdown joins the live server row: it is not a live membership.
    let deletedServerId = UUID().uuidString.lowercased()
    accounts.oauth.addOwnedServer(id: deletedServerId, slug: "reset-scope-deleted", name: "Reset Scope Deleted", ownerId: ownerId)
    accounts.oauth.deleteServer(id: deletedServerId)
    let owner = accounts.mintAccessTokenForTesting(userId: ownerId)
    let admin = accounts.mintAccessTokenForTesting(userId: adminId)
    let member = accounts.mintAccessTokenForTesting(userId: memberId)
    let guest = accounts.mintAccessTokenForTesting(userId: guestId)
    let outsider = accounts.mintAccessTokenForTesting(userId: outsiderId)
    let unknownServerId = UUID().uuidString.lowercased()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func reset(
                _ bearer: String?,
                serverId: String,
                header: String?
            ) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                if let header { headers[HTTPField.Name("X-Server-Id")!] = header }
                return try await client.send(
                    .post, headers: headers, to: URI(string: "/api/servers/\(serverId)/setup-reset")
                )
            }

            // `requireAuth` is mounted before the router: an anonymous caller
            // is 401 even when the path/header checks would also fail.
            #expect(try await reset(nil, serverId: serverId, header: nil).status == .unauthorized)
            #expect(try await reset(nil, serverId: serverId, header: serverId).status == .unauthorized)

            // A non-UUID names no server, before the header check.
            let malformed = try await reset(owner, serverId: "not-a-uuid", header: nil)
            #expect(malformed.status == .notFound)
            #expect(malformed.body.string == "{\"error\":\"Server not found\"}")

            let missingHeader = try await reset(owner, serverId: serverId, header: nil)
            #expect(missingHeader.status == .badRequest)
            #expect(missingHeader.body.string == "{\"error\":\"Missing X-Server-Id header\"}")

            let mismatched = try await reset(owner, serverId: serverId, header: otherServerId)
            #expect(mismatched.status == .badRequest)
            #expect(mismatched.body.string == "{\"error\":\"X-Server-Id must match server id in URL\"}")

            let nonMember = try await reset(outsider, serverId: serverId, header: serverId)
            #expect(nonMember.status == .forbidden)
            #expect(nonMember.body.string == "{\"error\":\"Not a member of this server\"}")

            let unknownServer = try await reset(owner, serverId: unknownServerId, header: unknownServerId)
            #expect(unknownServer.status == .forbidden)
            #expect(unknownServer.body.string == "{\"error\":\"Not a member of this server\"}")

            let deletedServer = try await reset(owner, serverId: deletedServerId, header: deletedServerId)
            #expect(deletedServer.status == .forbidden)
            #expect(deletedServer.body.string == "{\"error\":\"Not a member of this server\"}")

            // `setup-reset` is not guest-hidden, so a live Guest reaches the
            // handler and gets its owner-only refusal.
            for denied in [admin, member, guest] {
                let refused = try await reset(denied, serverId: serverId, header: serverId)
                #expect(refused.status == .forbidden)
                #expect(refused.body.string == "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
            }

            // A live owner reaches the handler: the actual reset output.
            let resetResponse = try await reset(owner, serverId: serverId, header: serverId)
            #expect(resetResponse.status == .ok)
            let resetBody = try #require(
                JSONSerialization.jsonObject(with: resetResponse.body.data ?? Data()) as? [String: Any]
            )
            #expect(resetBody["phase"] as? String == "not_started")
            #expect(resetBody["revokedComputers"] as? Int == 1)

            // Handler-local boundary: an agent makes the reset a 409.
            let agent = accounts.oauth.createAgent(serverId: serverId, name: "reset-scope-agent")
            accounts.addServerAgent(serverId: serverId, id: agent, name: "reset-scope-agent", avatarUrl: nil, status: "inactive")
            let alreadySetUp = try await reset(owner, serverId: serverId, header: serverId)
            #expect(alreadySetUp.status == .conflict)
            #expect(alreadySetUp.body.string == "{\"error\":\"SERVER_ALREADY_SET_UP\"}")
        }
    }
}
