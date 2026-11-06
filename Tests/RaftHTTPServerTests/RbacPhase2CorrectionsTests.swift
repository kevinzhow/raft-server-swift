import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct RbacPhase2Fixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerToken: String
    let adminToken: String
    let memberToken: String
    let guestId: String
    let guestToken: String
}

private func makeRbacPhase2Fixture(_ suffix: String) -> RbacPhase2Fixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001090\(suffix)"
    let adminId = "11111111-1111-4111-8111-000001091\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001092\(suffix)"
    let guestId = "11111111-1111-4111-8111-000001093\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001090\(suffix)"
    for (id, email) in [
        (ownerId, "rbac2-owner-\(suffix)@slock.test"),
        (adminId, "rbac2-admin-\(suffix)@slock.test"),
        (memberId, "rbac2-member-\(suffix)@slock.test"),
        (guestId, "rbac2-guest-\(suffix)@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "rbac2-\(suffix)", name: "rbac2-\(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    return RbacPhase2Fixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        adminToken: accounts.mintAccessTokenForTesting(userId: adminId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        guestId: guestId,
        guestToken: accounts.mintAccessTokenForTesting(userId: guestId)
    )
}

private func rbac2Headers(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func rbac2Object(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func serverDetailsGiveRolesTheMemberProfileAndGuestsThePublicProjection() async throws {
    let f = makeRbacPhase2Fixture("001")
    let unsafeAvatar = "https://third-party.example/signed-private-avatar"
    f.accounts.oauth.setServerProfile(
        id: f.serverId,
        avatarUrl: unsafeAvatar,
        plan: "founder",
        translationEnabled: true,
        publiclyVisible: true,
        publicGuestJoinEnabled: true
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for (role, token) in [("owner", f.ownerToken), ("admin", f.adminToken), ("member", f.memberToken)] {
                let response = try await client.get(
                    URI(string: "/api/servers/\(f.serverId)"),
                    headers: rbac2Headers(token, f.serverId)
                )
                #expect(response.status == .ok, "\(role)")
                let body = try rbac2Object(response)
                #expect(body["id"] as? String == f.serverId)
                #expect(body["ownerId"] as? String == f.ownerId)
                #expect(body["plan"] as? String == "founder")
                #expect(body["translationEnabled"] as? Bool == true)
                #expect(body["avatarUrl"] as? String == unsafeAvatar)
            }

            let guest = try await client.get(
                URI(string: "/api/servers/\(f.serverId)"),
                headers: rbac2Headers(f.guestToken, f.serverId)
            )
            #expect(guest.status == .ok)
            let guestBody = try rbac2Object(guest)
            #expect(Array(guestBody.keys).sorted() == ["avatarUrl", "id", "name", "slug"])
            #expect(guestBody["id"] as? String == f.serverId)
            #expect(guestBody["name"] as? String == "rbac2-001")
            #expect(guestBody["slug"] as? String == "rbac2-001")
            #expect(guestBody["avatarUrl"] is NSNull)
            for forbidden in [
                "ownerId", "kind", "onboardingAgentId", "agentAllChannelGreetingEnabled",
                "hideHumansFromMembers", "publiclyVisible", "publicGuestJoinEnabled", "plan",
                "translationEnabled", "planDowngradedAt", "createdAt", "updatedAt",
            ] {
                #expect(guestBody[forbidden] == nil, "\(forbidden)")
            }
        }
    }
}

@Test func serverSettingsRequireOwnerOrAdminWhileSelfStateStaysReadable() async throws {
    let f = makeRbacPhase2Fixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for (role, token) in [("owner", f.ownerToken), ("admin", f.adminToken)] {
                let response = try await client.get(
                    URI(string: "/api/servers/\(f.serverId)/settings"),
                    headers: rbac2Headers(token, f.serverId)
                )
                #expect(response.status == .ok, "\(role)")
            }
            for (role, token) in [("member", f.memberToken), ("guest", f.guestToken)] {
                let settings = try await client.get(
                    URI(string: "/api/servers/\(f.serverId)/settings"),
                    headers: rbac2Headers(token, f.serverId)
                )
                #expect(settings.status == .forbidden, "\(role)")

                let notifications = try await client.get(
                    URI(string: "/api/servers/\(f.serverId)/notification-settings"),
                    headers: rbac2Headers(token, f.serverId)
                )
                #expect(notifications.status == .ok, "\(role)")
            }

            let memberOnboarding = try await client.get(
                URI(string: "/api/servers/\(f.serverId)/onboarding-settings"),
                headers: rbac2Headers(f.memberToken, f.serverId)
            )
            #expect(memberOnboarding.status == .ok)
        }
    }
}

@Test func machineListNeedsMachineReadWhileAGuestRegistrantKeepsExactObjectManagement() async throws {
    let f = makeRbacPhase2Fixture("003")
    let guestMachine = f.accounts.registerMachine(serverId: f.serverId, userId: f.guestId, name: "Guest-owned machine")
    let ownerMachine = f.accounts.registerMachine(serverId: f.serverId, userId: f.ownerId, name: "Owner-owned machine")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for (role, token) in [("owner", f.ownerToken), ("admin", f.adminToken), ("member", f.memberToken)] {
                let response = try await client.get(
                    URI(string: "/api/servers/\(f.serverId)/machines"),
                    headers: rbac2Headers(token, f.serverId)
                )
                #expect(response.status == .ok, "\(role)")
            }
            let guestList = try await client.get(
                URI(string: "/api/servers/\(f.serverId)/machines"),
                headers: rbac2Headers(f.guestToken, f.serverId)
            )
            #expect(guestList.status == .forbidden)

            let ownPatch = try await client.send(
                .patch,
                headers: rbac2Headers(f.guestToken, f.serverId),
                to: URI(string: "/api/servers/\(f.serverId)/machines/\(guestMachine)")
            ) { request in
                request.body = .init(string: "{\"description\":\"still managed by its exact registrant\"}")
            }
            #expect(ownPatch.status == .ok)
            #expect(try rbac2Object(ownPatch)["description"] as? String == "still managed by its exact registrant")

            let foreignPatch = try await client.send(
                .patch,
                headers: rbac2Headers(f.guestToken, f.serverId),
                to: URI(string: "/api/servers/\(f.serverId)/machines/\(ownerMachine)")
            ) { request in
                request.body = .init(string: "{\"description\":\"must not widen to the collection\"}")
            }
            #expect(foreignPatch.status == .forbidden)
        }
    }
}
