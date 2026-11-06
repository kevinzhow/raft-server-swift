import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AppAccessFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001081001"
    let ownerId = "11111111-1111-4111-8111-000001081001"
    let creatorId = "11111111-1111-4111-8111-000001081002"
    let memberId = "11111111-1111-4111-8111-000001081003"
    var creatorAgent = ""
    var scopes = ["agent:notification:write"]

    init() throws {
        for (id, email) in [(ownerId, "owner"), (creatorId, "creator"), (memberId, "member")] {
            accounts.addAccount(id: id, email: "\(email)@app-access.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "agent-app-access", name: "Agent App Access", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: creatorId, role: "member")
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
        let agent = accounts.oauth.createAgent(
            serverId: serverId, name: "CreatorBot", creatorUserId: creatorId, runtime: "claude"
        )
        creatorAgent = agent
    }

    func app(userId: String, key: String) throws -> CreatedOAuthClient {
        try accounts.oauth.createClient(
            serverId: serverId, createdByUserId: userId, name: "App \(key)", clientId: key,
            allowedScopes: scopes
        )
    }

}

@Test func automaticAgentGrantsNeedAuthorityAndAPersonsRevokeSticks() async throws {
    let fixture = try AppAccessFixture()
    let accounts = fixture.accounts
    let memberApp = try fixture.app(userId: fixture.memberId, key: "aam-member")
    let creatorApp = try fixture.app(userId: fixture.creatorId, key: "aam-creator")
    let ownerApp = try fixture.app(userId: fixture.ownerId, key: "aam-owner")

    func request(_ client: CreatedOAuthClient, agentName: String? = nil, agentId: String? = nil,
                 initiatedByAgent: Bool = false) async -> (Int, [String: Any]) {
        var payload: [String: Any] = [
            "clientId": client.clientId, "clientSecret": client.clientSecret,
            "serverSlug": "agent-app-access", "scopes": ["agent:notification:write"],
        ]
        if let agentName { payload["agentName"] = agentName }
        if let agentId { payload["agentId"] = agentId }
        if initiatedByAgent { payload["initiatedByAgent"] = true }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let reply = accounts.oauth.requestAgentAccess(authorization: nil, body: String(decoding: data, as: UTF8.self))
        let body = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any] ?? [:]
        return (reply.status, body)
    }

    let foreign = await request(memberApp, agentName: "CreatorBot")
    #expect(foreign.0 == 200)
    #expect(foreign.1["status"] as? String == "pending")
    #expect(accounts.oauth.agentGrantRowsForTesting(agentId: fixture.creatorAgent).isEmpty)

    let own = await request(creatorApp, agentName: "CreatorBot")
    #expect(own.1["status"] as? String == "approved")
    func grants(for client: CreatedOAuthClient) -> [OAuthLedger.AgentGrantRow] {
        accounts.oauth.agentGrantRowsForTesting(agentId: fixture.creatorAgent)
            .filter { $0.clientRecordId == client.id }
    }
    let grant = try #require(grants(for: creatorApp).first)
    #expect(grant.grantSource == "app_request")

    let byOwner = await request(ownerApp, agentName: "CreatorBot")
    #expect(byOwner.1["status"] as? String == "approved")

    // The creator revokes; the app's next request waits for a person.
    let revoked = accounts.oauth.revokeAgentGrant(userId: fixture.creatorId, grantId: grant.id)
    #expect(revoked?.status == 200)
    let afterRevoke = await request(creatorApp, agentName: "CreatorBot")
    #expect(afterRevoke.1["status"] as? String == "pending")
    #expect(grants(for: creatorApp).isEmpty)

    // Granting again clears the block; the next request reuses that grant.
    let regrant = try #require(accounts.oauth.createAgentGrant(
        userId: fixture.creatorId, agentId: fixture.creatorAgent, clientRecordId: creatorApp.id,
        scopes: ["agent:notification:write"]
    ))
    #expect(regrant.status == 201)
    #expect(grants(for: creatorApp).first?.grantSource == "person")
    #expect(accounts.oauth.autoGrantBlockCountForTesting(agentId: fixture.creatorAgent) == 0)
    let reused = await request(creatorApp, agentName: "CreatorBot")
    #expect(reused.1["status"] as? String == "approved")
    #expect(grants(for: creatorApp).count == 1)
}

@Test func creatorAndOwnersManageAppAccessWhileOtherMembersCannot() async throws {
    let fixture = try AppAccessFixture()
    let accounts = fixture.accounts
    let memberApp = try fixture.app(userId: fixture.memberId, key: "aab-member")
    let ownerApp = try fixture.app(userId: fixture.ownerId, key: "aab-owner")

    func request(_ client: CreatedOAuthClient) async -> (Int, [String: Any]) {
        let payload: [String: Any] = [
            "clientId": client.clientId, "clientSecret": client.clientSecret,
            "serverSlug": "agent-app-access", "scopes": ["agent:notification:write"], "agentName": "CreatorBot",
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let reply = accounts.oauth.requestAgentAccess(authorization: nil, body: String(decoding: data, as: UTF8.self))
        let body = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any] ?? [:]
        return (reply.status, body)
    }

    let pending = await request(memberApp)
    #expect(pending.1["status"] as? String == "pending")
    let requestId = try #require(pending.1["requestId"] as? String)

    #expect(accounts.oauth.approveAgentAccessRequest(userId: fixture.memberId, requestId: requestId, remember: true)?.status == 403)
    #expect(accounts.oauth.agentGrantRowsForTesting(agentId: fixture.creatorAgent).isEmpty)
    #expect(accounts.oauth.approveAgentAccessRequest(userId: fixture.creatorId, requestId: requestId, remember: true)?.status == 200)
    #expect(accounts.oauth.agentGrantRowsForTesting(agentId: fixture.creatorAgent).count == 1)

    #expect(accounts.oauth.grantableApps(userId: fixture.memberId, agentId: fixture.creatorAgent)?.isEmpty == true)
    let creatorApps = try #require(accounts.oauth.grantableApps(userId: fixture.creatorId, agentId: fixture.creatorAgent))
    #expect(creatorApps.map(\.recordId).sorted() == [memberApp.id, ownerApp.id].sorted())

    let ownerGrant = try #require(accounts.oauth.createAgentGrant(
        userId: fixture.ownerId, agentId: fixture.creatorAgent, clientRecordId: ownerApp.id,
        scopes: ["agent:notification:write"]
    ))
    #expect(ownerGrant.status == 201)
    #expect(accounts.oauth.agentGrantListVisible(userId: fixture.memberId, agentId: fixture.creatorAgent)?.isEmpty == true)
    let visible = try #require(accounts.oauth.agentGrantListVisible(userId: fixture.ownerId, agentId: fixture.creatorAgent))
    #expect(Set(visible.map(\.grantSource)) == ["person"])
}

@Test func anAgentsOwnLoginGetsAnAutomaticGrantButNotAfterAPersonRevoked() async throws {
    let fixture = try AppAccessFixture()
    let accounts = fixture.accounts
    let memberApp = try fixture.app(userId: fixture.memberId, key: "aac-member")

    func request(initiatedByAgent: Bool) async -> (Int, [String: Any]) {
        let payload: [String: Any] = [
            "clientId": memberApp.clientId, "clientSecret": memberApp.clientSecret,
            "serverSlug": "agent-app-access", "scopes": ["agent:notification:write"],
            "agentName": "CreatorBot", "initiatedByAgent": initiatedByAgent,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let reply = accounts.oauth.requestAgentAccess(authorization: nil, body: String(decoding: data, as: UTF8.self))
        let body = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any] ?? [:]
        return (reply.status, body)
    }

    let login = await request(initiatedByAgent: true)
    #expect(login.1["status"] as? String == "approved")
    let grant = try #require(accounts.oauth.agentGrantRowsForTesting(agentId: fixture.creatorAgent).first)
    #expect(grant.grantSource == "agent_login")
    #expect(accounts.oauth.revokeAgentGrant(userId: fixture.creatorId, grantId: grant.id)?.status == 200)
    let blocked = await request(initiatedByAgent: true)
    #expect(blocked.1["status"] as? String == "pending")
}

@Test func requestsAgentAcceptsTheAgentIdInsteadOfItsName() async throws {
    let fixture = try AppAccessFixture()
    let accounts = fixture.accounts
    let ownerApp = try fixture.app(userId: fixture.ownerId, key: "aaf-owner")

    func post(_ extra: [String: Any]) async -> (Int, [String: Any]) {
        var payload: [String: Any] = [
            "clientId": ownerApp.clientId, "clientSecret": ownerApp.clientSecret,
            "serverSlug": "agent-app-access", "scopes": ["agent:notification:write"],
        ]
        payload.merge(extra) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let reply = accounts.oauth.requestAgentAccess(authorization: nil, body: String(decoding: data, as: UTF8.self))
        let body = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8))) as? [String: Any] ?? [:]
        return (reply.status, body)
    }

    let byId = await post(["agentId": fixture.creatorAgent])
    #expect(byId.0 == 200)
    #expect(byId.1["status"] as? String == "approved")
    #expect(accounts.oauth.agentGrantRowsForTesting(agentId: fixture.creatorAgent).count == 1)
    #expect((await post(["agentId": fixture.creatorAgent, "agentName": "someone-else"])).0 == 200)
    #expect((await post(["agentId": "not-a-uuid"])).0 == 404)
    #expect((await post(["agentId": UUID().uuidString])).0 == 404)
}
