import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct RoleFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerToken: String
    let adminId: String
    let adminToken: String
    let memberToken: String
    let ownerAgentId: String
    let adminAgentId: String
}

private func makeRoleFixture(_ suffix: String) -> RoleFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001340\(suffix)"
    let adminId = "11111111-1111-4111-8111-000001341\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001342\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001340\(suffix)"
    for (id, email) in [
        (ownerId, "role-owner-\(suffix)@slock.test"),
        (adminId, "role-admin-\(suffix)@slock.test"),
        (memberId, "role-member-\(suffix)@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "role-\(suffix)", name: "Role \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let ownerAgentId = accounts.oauth.createAgent(serverId: serverId, name: "owner-managed-agent-role-\(suffix)", creatorUserId: ownerId, runtime: "codx")
    let adminAgentId = accounts.oauth.createAgent(serverId: serverId, name: "admin-managed-agent-role-\(suffix)", creatorUserId: adminId, runtime: "codx")
    return RoleFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        adminId: adminId,
        adminToken: accounts.mintAccessTokenForTesting(userId: adminId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        ownerAgentId: ownerAgentId,
        adminAgentId: adminAgentId
    )
}

private func roleHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func rolePatch(
    _ client: any Client,
    f: RoleFixture,
    token: String,
    agentId: String,
    role: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let response = try await client.send(.patch, headers: roleHeaders(token, f.serverId), to: "/api/agents/\(agentId)") { request in
        request.body = .init(string: "{\"serverRole\":\"\(role)\"}")
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

private func roleGet(
    _ client: any Client,
    f: RoleFixture,
    agentId: String
) async throws -> [String: Any] {
    let response = try await client.get(URI(string: "/api/agents/\(agentId)"), headers: roleHeaders(f.ownerToken, f.serverId))
    return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func agentServerRoleFollowsTheHumanRoleTransitionPolicy() async throws {
    let f = makeRoleFixture("901")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // So the DM notice target already exists for the actor/agent pair.
            _ = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.ownerId, secondUserId: f.ownerAgentId)

            let invalidOwner = try await rolePatch(client, f: f, token: f.ownerToken, agentId: f.ownerAgentId, role: "owner")
            #expect(invalidOwner.status == .badRequest)
            #expect(try await roleGet(client, f: f, agentId: f.ownerAgentId)["serverRole"] as? String == "member")

            let memberDenied = try await rolePatch(client, f: f, token: f.memberToken, agentId: f.ownerAgentId, role: "admin")
            #expect(memberDenied.status == .forbidden)
            #expect(try await roleGet(client, f: f, agentId: f.ownerAgentId)["serverRole"] as? String == "member")

            let ownerPromote = try await rolePatch(client, f: f, token: f.ownerToken, agentId: f.ownerAgentId, role: "admin")
            #expect(ownerPromote.status == .ok)
            #expect(ownerPromote.body["serverRole"] as? String == "admin")
            #expect(try await roleGet(client, f: f, agentId: f.ownerAgentId)["serverRole"] as? String == "admin")

            let adminDemoteDenied = try await rolePatch(client, f: f, token: f.adminToken, agentId: f.ownerAgentId, role: "member")
            #expect(adminDemoteDenied.status == .forbidden)
            #expect(try await roleGet(client, f: f, agentId: f.ownerAgentId)["serverRole"] as? String == "admin")

            let adminPromoteOwn = try await rolePatch(client, f: f, token: f.adminToken, agentId: f.adminAgentId, role: "admin")
            #expect(adminPromoteOwn.status == .ok)
            #expect(adminPromoteOwn.body["serverRole"] as? String == "admin")

            // A no-op request is accepted but posts no notice.
            let noOp = try await rolePatch(client, f: f, token: f.ownerToken, agentId: f.adminAgentId, role: "admin")
            #expect(noOp.status == .ok)

            let ownerDemote = try await rolePatch(client, f: f, token: f.ownerToken, agentId: f.ownerAgentId, role: "member")
            #expect(ownerDemote.status == .ok)
            #expect(ownerDemote.body["serverRole"] as? String == "member")
            #expect(try await roleGet(client, f: f, agentId: f.ownerAgentId)["serverRole"] as? String == "member")

            // Two real changes on the owner-managed agent, one on the admin's.
            let ownerDm = try #require(f.accounts.directChannelIdForTesting(serverId: f.serverId, firstId: f.ownerId, secondId: f.ownerAgentId))
            let notices = f.accounts.channelSystemMessagesForTesting(channelId: ownerDm)
            #expect(notices.count == 2, "refused, invalid, and no-op requests post nothing")
            #expect(notices[0].content.hasSuffix("changed @owner-managed-agent-role-901's server role from member to admin."))
            #expect(notices[1].content.hasSuffix("changed @owner-managed-agent-role-901's server role from admin to member."))
            #expect(notices.allSatisfy { $0.subtype == "agent.server_role_changed" })

            let adminDm = try #require(f.accounts.directChannelIdForTesting(serverId: f.serverId, firstId: f.adminId, secondId: f.adminAgentId))
            let adminNotices = f.accounts.channelSystemMessagesForTesting(channelId: adminDm)
            #expect(adminNotices.count == 1)
            #expect(adminNotices[0].content.hasSuffix("changed @admin-managed-agent-role-901's server role from member to admin."))
        }
    }
}
