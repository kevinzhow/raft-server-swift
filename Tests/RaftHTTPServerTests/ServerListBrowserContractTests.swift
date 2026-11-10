import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Public JSON contract consumed directly by serverStore and ServerOptionCard.
/// Tests first: identity/order-only rows cannot render the real server chooser.
@Test func serverListProjectsStoredProfileMembershipAndSidebarFacts() async throws {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased(), member = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
    accounts.addAccount(id: owner, email: "server-list-owner@example.test", password: "password123")
    accounts.addAccount(id: member, email: "server-list-member@example.test", password: "password123")
    accounts.markEmailVerified(userId: owner); accounts.markEmailVerified(userId: member)
    accounts.oauth.addOwnedServer(id: server, slug: "typed-server", name: "Stored Workspace Name", ownerId: owner)
    accounts.oauth.addOwnedServer(id: other, slug: "hidden-server", name: "Not a member", ownerId: owner)
    accounts.oauth.addMember(serverId: server, userId: member, role: "member")
    accounts.oauth.setServerProfile(id: server, avatarUrl: "https://assets.example.test/workspace.png", plan: "pro",
        translationEnabled: true, publiclyVisible: false, publicGuestJoinEnabled: false)
    accounts.oauth.setServerPushMuted(serverId: server, userId: member, muted: true)
    accounts.serversAndChannelsStore.setHideHumansFromMembers(serverId: server, hidden: true)
    let agent = UUID().uuidString.lowercased()
    accounts.serversAndChannelsStore.bindOnboardingAgent(serverId: server, agentId: agent)
    accounts.seedServerSwitcherOrder(userId: member, ids: [server], version: 7)
    let token = accounts.mintAccessTokenForTesting(userId: member)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields(); headers[.authorization] = "Bearer \(token)"
            let response = try await client.get("/api/servers", headers: headers)
            #expect(response.status == .ok)
            let actual = try JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [[String: Any]]
            let expected: [[String: Any]] = [[
                "id": server, "name": "Stored Workspace Name", "avatarUrl": "https://assets.example.test/workspace.png",
                "slug": "typed-server", "ownerId": owner, "onboardingAgentId": agent,
                "hideHumansFromMembers": true, "plan": "pro", "role": "member", "serverPushMuted": true,
                "serverOrderVersion": 7, "publicPageLive": false,
            ]]
            #expect((actual as NSArray?) == (expected as NSArray))
            let row = try #require(actual?.first)
            #expect(row["name"] as? String == "Stored Workspace Name")
            #expect(row["publiclyVisible"] == nil)
            #expect(row["publicGuestJoinEnabled"] == nil)
            #expect(row["translationEnabled"] == nil)
            #expect(row["createdAt"] == nil, "history is not fabricated when the current owner has no stored timestamp")
            #expect(row["planDowngradedAt"] == nil)
            #expect(actual?.count == 1)
            accounts.oauth.updateServerName(id: server, name: "Changed Stored Name")
            let changed = try await client.get("/api/servers", headers: headers)
            let changedRows = try JSONSerialization.jsonObject(with: changed.body.data ?? Data()) as? [[String: Any]]
            #expect(changedRows?.first?["name"] as? String == "Changed Stored Name")
            let anonymous = try await client.get("/api/servers")
            #expect(anonymous.status == .unauthorized)
        }
    }
}

/// A newly admitted human has no server yet. Login and refresh must both be
/// usable before the first create, without enrollment in the legacy directory.
@Test(arguments: [false, true])
func serverListEmptyHumanSupportsLoginRefreshAndFirstCreate(hasPublicDirectory: Bool) async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased()
    let email = "empty-server-list@example.test"
    accounts.addAccount(id: userId, email: email, password: "password123")
    accounts.markEmailVerified(userId: userId)
    let visits: PublicVisitDirectory? = hasPublicDirectory ? PublicVisitDirectory() : nil
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            publicVisits: visits, emailAccounts: accounts
        ))
        try await app.testing { client in
            var jsonHeaders = HTTPFields()
            jsonHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: jsonHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let session = try #require(JSONSerialization.jsonObject(with: login.body.data ?? Data()) as? [String: Any])
            let access = try #require(session["accessToken"] as? String)
            let refresh = try #require(session["refreshToken"] as? String)
            var headers = jsonHeaders
            headers[.authorization] = "Bearer \(access)"
            let me = try await client.get("/api/auth/me", headers: headers)
            #expect(me.status == .ok)
            let user = try #require(JSONSerialization.jsonObject(with: me.body.data ?? Data()) as? [String: Any])
            #expect(user["id"] as? String == userId)
            #expect(user["emailVerified"] as? Bool == true)
            #expect(user["profileSetupCompletedAt"] as? String != nil)

            let empty = try await client.get("/api/servers", headers: headers)
            #expect(empty.status == .ok)
            #expect(empty.body.string == "[]")
            let order = try await client.get("/api/servers/order", headers: headers)
            #expect(order.status == .ok)
            let orderBody = try #require(JSONSerialization.jsonObject(with: order.body.data ?? Data()) as? [String: Any])
            #expect(orderBody["serverOrder"] as? [String] == [])
            #expect(orderBody["serverOrderVersion"] as? Int == 0)

            let renewed = try await client.send(.post, headers: jsonHeaders, to: "/api/auth/refresh") { request in
                request.body = .init(string: "{\"refreshToken\":\"\(refresh)\"}")
            }
            #expect(renewed.status == .ok)
            let renewedBody = try #require(JSONSerialization.jsonObject(with: renewed.body.data ?? Data()) as? [String: Any])
            let renewedAccess = try #require(renewedBody["accessToken"] as? String)
            headers[.authorization] = "Bearer \(renewedAccess)"
            let stillEmpty = try await client.get("/api/servers", headers: headers)
            #expect(stillEmpty.status == .ok)
            #expect(stillEmpty.body.string == "[]")

            let created = try await client.send(.post, headers: headers, to: "/api/servers") { request in
                request.body = .init(string: "{\"name\":\"First Workspace\",\"slug\":\"first-workspace\"}")
            }
            #expect(created.status == .ok)
            let createdBody = try #require(JSONSerialization.jsonObject(with: created.body.data ?? Data()) as? [String: Any])
            let serverId = try #require(createdBody["id"] as? String)
            #expect(UUID(uuidString: serverId) != nil)
            let populated = try await client.get("/api/servers", headers: headers)
            #expect(populated.status == .ok)
            let rows = try #require(JSONSerialization.jsonObject(with: populated.body.data ?? Data()) as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows.first?["id"] as? String == serverId)
            #expect(rows.first?["ownerId"] as? String == userId)
            #expect(rows.first?["name"] as? String == "First Workspace")
            #expect(rows.first?["role"] as? String == "owner")

            let anonymous = try await client.get("/api/servers")
            #expect(anonymous.status == .unauthorized)
            headers[.authorization] = "Bearer invalid-session"
            let invalid = try await client.get("/api/servers", headers: headers)
            #expect(invalid.status == .unauthorized)
        }
    }
}

@Test func serverListKeepsOAuthPriorityAndRecognizedLegacyMembership() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased(), oauthServer = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "mixed-server-list@example.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: oauthServer, slug: "oauth-first", name: "OAuth Workspace", ownerId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let visits = PublicVisitDirectory()
    visits.addServer(id: "legacy-server", slug: "legacy-space", publiclyVisible: true,
        publicEnabled: true, memberIds: [userId], name: "Legacy Workspace")
    visits.addUser(PublicVisitUser(id: userId, shareUsageData: nil, analyticsId: nil))
    visits.addToken(token, userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            publicVisits: visits, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields(); headers[.authorization] = "Bearer \(token)"
            let ordered = try await client.get("/api/servers", headers: headers)
            #expect(ordered.status == .ok)
            let orderedRows = try #require(JSONSerialization.jsonObject(with: ordered.body.data ?? Data()) as? [[String: Any]])
            #expect(orderedRows.count == 1)
            #expect(orderedRows.first?["id"] as? String == oauthServer)
            #expect(orderedRows.first?["name"] as? String == "OAuth Workspace")
            accounts.oauth.removeMember(serverId: oauthServer, userId: userId)
            let legacy = try await client.get("/api/servers", headers: headers)
            #expect(legacy.status == .ok)
            let legacyRows = try #require(JSONSerialization.jsonObject(with: legacy.body.data ?? Data()) as? [[String: Any]])
            #expect(legacyRows.count == 1)
            #expect(legacyRows.first?["id"] as? String == "legacy-server")
            #expect(legacyRows.first?["slug"] as? String == "legacy-space")
            #expect(legacyRows.first?["publicPageLive"] as? Bool == true)
            #expect(legacyRows.first?["publiclyVisible"] == nil)
        }
    }
}

/// The canonical admitted Auth principal selects the legacy membership rows.
/// The public directory's own bearer-to-user map is a different identity
/// domain; a token that it maps to another subject must not leak that
/// subject's servers.
@Test func serverCollectionProjectsTheCanonicalSubjectNotTheDirectoryBearerMapping() async throws {
    let accounts = EmailLoginDirectory()
    let canonical = UUID().uuidString.lowercased()
    let legacyOther = UUID().uuidString.lowercased()
    accounts.addAccount(id: canonical, email: "canonical-collection@example.test", password: "password123")
    accounts.markEmailVerified(userId: canonical)
    let token = accounts.mintAccessTokenForTesting(userId: canonical)
    let visits = PublicVisitDirectory()
    visits.addUser(PublicVisitUser(id: legacyOther, shareUsageData: nil, analyticsId: nil))
    visits.addServer(id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeee01", slug: "legacy-other",
        publiclyVisible: true, publicEnabled: true, memberIds: [legacyOther], name: "Other Subject")
    visits.addToken(token, userId: legacyOther)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            publicVisits: visits, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields(); headers[.authorization] = "Bearer \(token)"
            let hidden = try await client.get("/api/servers", headers: headers)
            #expect(hidden.status == .ok)
            #expect(hidden.body.string == "[]", "the legacy bearer mapping must not select another subject")

            visits.addServer(id: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeee02", slug: "legacy-canonical",
                publiclyVisible: false, publicEnabled: false, memberIds: [canonical], name: "Canonical Subject")
            let projected = try await client.get("/api/servers", headers: headers)
            #expect(projected.status == .ok)
            let rows = try #require(JSONSerialization.jsonObject(with: projected.body.data ?? Data()) as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows.first?["id"] as? String == "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeee02")
            #expect(rows.first?["slug"] as? String == "legacy-canonical")
            #expect(rows.first?["role"] as? String == "member")
            #expect(rows.first?["publicPageLive"] as? Bool == false)
            #expect(rows.first?["publiclyVisible"] == nil)
        }
    }
}

/// Collection list, switcher order and create are user-scoped, not
/// server-scoped: `X-Server-Id` is neither required nor allowed to narrow or
/// reject them. Anonymous refusal keeps the published `auth_required` body.
@Test func serverCollectionStaysUserScopedWithoutTenantHeader() async throws {
    let accounts = EmailLoginDirectory()
    let userId = UUID().uuidString.lowercased(), server = UUID().uuidString.lowercased()
    accounts.addAccount(id: userId, email: "scoped-collection@example.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: server, slug: "scoped-one", name: "Scoped One", ownerId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let unrelated = UUID().uuidString.lowercased()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = unrelated
            let list = try await client.get("/api/servers", headers: headers)
            #expect(list.status == .ok)
            let rows = try #require(JSONSerialization.jsonObject(with: list.body.data ?? Data()) as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows.first?["id"] as? String == server)

            let order = try await client.get("/api/servers/order", headers: headers)
            #expect(order.status == .ok)
            let orderBody = try #require(JSONSerialization.jsonObject(with: order.body.data ?? Data()) as? [String: Any])
            #expect(orderBody["serverOrder"] as? [String] == [server])

            let created = try await client.send(.post, headers: headers, to: "/api/servers") { request in
                request.body = .init(string: "{\"name\":\"Second Workspace\",\"slug\":\"second-workspace\"}")
            }
            #expect(created.status == .ok)
            let createdBody = try #require(JSONSerialization.jsonObject(with: created.body.data ?? Data()) as? [String: Any])
            let createdId = try #require(createdBody["id"] as? String)
            let after = try await client.get("/api/servers", headers: headers)
            #expect(after.status == .ok)
            let afterRows = try #require(JSONSerialization.jsonObject(with: after.body.data ?? Data()) as? [[String: Any]])
            #expect(Set(afterRows.compactMap { $0["id"] as? String }) == Set([server, createdId]))

            let anonymous = try await client.get("/api/servers")
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.body.string == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            var invalidHeaders = HTTPFields()
            invalidHeaders[.authorization] = "Bearer invalid-session"
            let invalid = try await client.get("/api/servers", headers: invalidHeaders)
            #expect(invalid.status == .unauthorized)
            #expect(invalid.body.string == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
    }
}
