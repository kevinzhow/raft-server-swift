import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AgentEventReadFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let mineId: String
    let otherId: String
    let apiKey: String
}

private func makeAgentEventReadFixture(suffix: String) throws -> AgentEventReadFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 300_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 900_000 + number)
    accounts.addAccount(id: ownerId, email: "agent-event-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-event-\(suffix)", name: "Agent Event Read", ownerId: ownerId)
    let mine = accounts.oauth.createAgent(serverId: serverId, name: "EventReader-\(suffix)")
    let other = accounts.oauth.createAgent(serverId: serverId, name: "OtherOwner-\(suffix)")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Agent Event Client",
        clientId: "agent-event-client-\(suffix)",
        allowedScopes: ["openid", "agent:event:write", "agent:notification:write"]
    )
    let clientRecordId = created.id
    let hour: TimeInterval = 60 * 60
    let live = "aaaaaaaa-1111-4111-8111-111111111111"
    let expired = "bbbbbbbb-2222-4222-8222-222222222222"
    let foreign = "cccccccc-3333-4333-8333-333333333333"
    let collideA = "abcd1234-1111-4111-8111-111111111111"
    let collideB = "abcd1234-2222-4222-8222-222222222222"
    accounts.oauth.addThirdPartyAgentEventForTesting(
        id: live,
        serverId: serverId,
        agentId: mine,
        clientRecordId: clientRecordId,
        summary: "your move: g6",
        payloadJSON: "{\"move\":\"g6\"}",
        expiresAt: Date().addingTimeInterval(hour)
    )
    accounts.oauth.addThirdPartyAgentEventForTesting(
        id: expired,
        serverId: serverId,
        agentId: mine,
        clientRecordId: clientRecordId,
        summary: "stale turn",
        payloadJSON: "{\"move\":\"e4\"}",
        expiresAt: Date().addingTimeInterval(-hour)
    )
    accounts.oauth.addThirdPartyAgentEventForTesting(
        id: foreign,
        serverId: serverId,
        agentId: other,
        clientRecordId: clientRecordId,
        summary: "not for you",
        payloadJSON: "{\"secret\":\"x\"}",
        expiresAt: Date().addingTimeInterval(hour)
    )
    for (id, summary, which) in [
        (collideA, "collide A", "A"),
        (collideB, "collide B", "B"),
    ] {
        accounts.oauth.addThirdPartyAgentEventForTesting(
            id: id,
            serverId: serverId,
            agentId: mine,
            clientRecordId: clientRecordId,
            summary: summary,
            payloadJSON: "{\"which\":\"\(which)\"}",
            expiresAt: Date().addingTimeInterval(hour)
        )
    }
    let apiKey = accounts.mintAgentCredential(agentId: mine, scopes: ["send", "read"], name: "agent-event-read-\(suffix)")
    return AgentEventReadFixture(accounts: accounts, serverId: serverId, mineId: mine, otherId: other, apiKey: apiKey)
}

private func agentEventRead(_ client: any Client, apiKey: String, target: String) async throws -> (status: HTTPResponse.Status, text: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get(
        URI(string: "/internal/agent-api/history?channel=\(target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target)"),
        headers: headers
    )
    return (response.status, response.body.string ?? "")
}

@Test func agentEventReadReturnsOwnBodyAndHidesForeignEvents() async throws {
    let fixture = try makeAgentEventReadFixture(suffix: "711")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let live = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:aaaaaaaa")
            #expect(live.status == .ok)
            let body = (try? JSONSerialization.jsonObject(with: Data(live.text.utf8))) as? [String: Any]
            let messages = body?["messages"] as? [[String: Any]] ?? []
            #expect(messages.count == 1)
            #expect(live.text.contains("your move: g6"))
            #expect(live.text.contains("\"g6\""))
            #expect(live.text.contains("payload_hash:"))
            #expect(live.text.contains("resource: urn:raft:server:\(fixture.serverId):agent-inbound"))

            let expired = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:bbbbbbbb")
            #expect(expired.status == HTTPResponse.Status(code: 410, reasonPhrase: "Gone"))
            #expect(expired.text.contains("\"errorCode\":\"EXPIRED\""))

            let foreign = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:cccccccc")
            let unknown = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:0123abcd")
            #expect(foreign.status == .notFound)
            #expect(unknown.status == .notFound)
            #expect(foreign.text == unknown.text)
            #expect(!foreign.text.contains("cccccccc"))
            #expect(!foreign.text.contains("not for you"))

            let foreignFull = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:cccccccc-3333-4333-8333-333333333333")
            let unknownFull = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:99999999-9999-4999-8999-999999999999")
            #expect(foreignFull.status == .notFound)
            #expect(foreignFull.text == unknownFull.text)
            #expect(!foreignFull.text.contains("not for you"))
        }
    }
}

@Test func agentEventShortAddressCollisionNamesTheConditionAndFullIdsResolve() async throws {
    let fixture = try makeAgentEventReadFixture(suffix: "712")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let short = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:abcd1234")
            #expect(short.status == .conflict)
            #expect(short.text.contains("\"errorCode\":\"AMBIGUOUS_ID\""))
            #expect(short.text.contains("suggestedNextAction"))

            let a = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:abcd1234-1111-4111-8111-111111111111")
            let b = try await agentEventRead(client, apiKey: fixture.apiKey, target: "agent-event:abcd1234-2222-4222-8222-222222222222")
            #expect(a.status == .ok)
            #expect(b.status == .ok)
            #expect(a.text.contains("\"which\":\"A\""))
            #expect(b.text.contains("\"which\":\"B\""))
            #expect(!a.text.contains("collide B"))
            #expect(!b.text.contains("collide A"))
            #expect(a.text.contains("event_id: abcd1234-1111-4111-8111-111111111111"))
            #expect(b.text.contains("event_id: abcd1234-2222-4222-8222-222222222222"))
        }
    }
}
