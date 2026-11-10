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
