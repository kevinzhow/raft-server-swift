import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AgentContextFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let agentId: String
    let managedId: String
    let readKey: String
    let managedKey: String
    let sendOnlyKey: String
}

private func makeAgentContextFixture(suffix: String) -> AgentContextFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 170_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 200_000 + number)
    accounts.addAccount(id: ownerId, email: "context-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    let slug = "context-\(suffix)"
    accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Context Test Server", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "ctx-external-\(suffix)",
        displayName: "Context External",
        description: "Reviews pull requests",
        runtime: "external"
    )
    let managed = accounts.oauth.createAgent(serverId: serverId, name: "ctx-managed-\(suffix)", runtime: "claude")
    let readKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send"], name: "ctx-\(suffix)")
    let managedKey = accounts.mintAgentCredential(agentId: managed, scopes: ["read"], name: "ctx-managed-\(suffix)")
    let sendOnlyKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send"], name: "ctx-send-\(suffix)")
    return AgentContextFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: slug,
        agentId: agent,
        managedId: managed,
        readKey: readKey,
        managedKey: managedKey,
        sendOnlyKey: sendOnlyKey
    )
}

private func agentContextGet(_ client: any Client, key: String) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    let response = try await client.get("/internal/agent-api/context", headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

@Test func agentContextProjectsIdentityPromptAndRolloutFlags() async throws {
    let fixture = makeAgentContextFixture(suffix: "831")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let defaults = try await agentContextGet(client, key: fixture.managedKey)
            #expect(defaults.status == .ok)
            #expect(defaults.body["features"] as? NSDictionary == ["reminderApp": false, "vaultApp": false] as NSDictionary)
            #expect((defaults.body["agent"] as? [String: Any])?["external"] as? Bool == false)
            #expect((defaults.body["agent"] as? [String: Any])?["name"] as? String == "ctx-managed-831")
            #expect(defaults.body["prompt"] is NSNull)

            let external = try await agentContextGet(client, key: fixture.readKey)
            #expect(external.status == .ok)
            let agent = try #require(external.body["agent"] as? [String: Any])
            #expect(agent as NSDictionary == [
                "id": fixture.agentId,
                "name": "ctx-external-831",
                "displayName": "Context External",
                "description": "Reviews pull requests",
                "runtime": "external",
                "external": true,
                "assistantOf": NSNull(),
                "serverRole": "member",
            ] as NSDictionary)
            #expect(external.body["server"] as? NSDictionary == [
                "id": fixture.serverId,
                "slug": fixture.serverSlug,
                "name": "Context Test Server",
            ] as NSDictionary)
            #expect((external.body["credential"] as? [String: Any])?["capabilities"] as? [String] == ["read", "send"])

            let prompt = try #require(external.body["prompt"] as? [String: Any])
            #expect(prompt["audience"] as? String == "self-hosted-runner")
            let text = try #require(prompt["text"] as? String)
            #expect(text.contains("Your server role is member. Permission checks always use your current role"))
            #expect(text.contains("You are \"Context External\" (@ctx-external-831), an external AI agent in the Raft server \"Context Test Server\""))
            #expect(text.contains("Initial role: Reviews pull requests."))
            #expect(text.contains("reminders_unsupported_for_external_agents"))
            #expect(!text.contains("<your-handle>"))
            #expect(!text.contains("<your-display-name>"))

            let denied = try await agentContextGet(client, key: fixture.sendOnlyKey)
            #expect(denied.status == .forbidden)
            #expect(denied.body["code"] as? String == "capability_not_authorized")
            #expect(denied.body["requiredCapability"] as? String == "read")

            fixture.accounts.createFeatureFlagForTesting(key: "reminder_app", defaultEnabled: false)
            fixture.accounts.addFeatureFlagRuleForTesting(
                key: "reminder_app",
                stage: "server",
                decision: "allow",
                values: [fixture.serverId]
            )
            let flagged = try await agentContextGet(client, key: fixture.readKey)
            #expect(flagged.body["features"] as? NSDictionary == ["reminderApp": true, "vaultApp": false] as NSDictionary)
        }
    }
}
