import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ChannelCardFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let agentId: String
    let apiKey: String
    let opsId: String
    let incidentId: String
    let anchorId: String
    let dmId: String
}

private func makeChannelCardFixture(suffix: String) throws -> ChannelCardFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 600_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 970_000 + number)
    let ownerName = "card-owner-\(suffix)"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-card-\(suffix)", name: "Channel Card Test", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "CardBot-\(suffix)", runtime: "claude")
    let ops = accounts.oauth.createChannel(
        serverId: serverId,
        name: "ops",
        creatorUserId: ownerId,
        description: "Release coordination. Post go/no-go here."
    )
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: ops, memberId: member, name: "ops")
    }
    accounts.oauth.addChannelHuman(channelId: ops, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: ops, agentId: agent)
    let anchor = accounts.oauth.createMessageRecord(channelId: ops, content: "deploy at 5?", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: ops, parentMessageId: anchor.id)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: thread,
            memberId: member,
            kind: "thread",
            parentChannelId: ops,
            parentMessageId: anchor.id,
            name: "thread"
        )
    }
    _ = accounts.oauth.createMessageRecord(channelId: thread, content: "yes", senderId: ownerId)

    let incident = accounts.oauth.createChannel(
        serverId: serverId,
        name: "incident",
        creatorUserId: ownerId,
        type: "private"
    )
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: incident, memberId: member, kind: "private", name: "incident")
    }
    accounts.oauth.addChannelHuman(channelId: incident, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: incident, agentId: agent)
    _ = accounts.oauth.createMessageRecord(channelId: incident, content: "postmortem draft", senderId: ownerId)
    accounts.oauth.setChannelArchived(id: incident, archivedAt: Date())

    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: agent)
    accounts.oauth.addChannelHuman(channelId: dm, userId: agent)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: dm, memberId: member, kind: "dm", name: "dm")
    }
    _ = accounts.oauth.createMessageRecord(channelId: dm, content: "hello", senderId: ownerId)

    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read"], name: "glimpse-card-\(suffix)")
    return ChannelCardFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: ownerName,
        agentId: agent,
        apiKey: apiKey,
        opsId: ops,
        incidentId: incident,
        anchorId: anchor.id,
        dmId: dm
    )
}

private func channelCardRead(_ client: any Client, apiKey: String, target: String) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
    let response = try await client.get(
        URI(string: "/internal/agent-api/history?channel=\(encoded)&consume=false"),
        headers: headers
    )
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

@Test func agentHistoryCarriesTheChannelCardIncludingThreadsButNotDMs() async throws {
    let fixture = try makeChannelCardFixture(suffix: "741")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let opsCard: [String: Any] = [
                "id": fixture.opsId,
                "name": "ops",
                "type": "channel",
                "description": "Release coordination. Post go/no-go here.",
                "archived": false,
            ]

            let channelRead = try await channelCardRead(client, apiKey: fixture.apiKey, target: "#ops")
            #expect(channelRead.status == .ok)
            #expect(channelRead.body["channel_card"] as? NSDictionary == opsCard as NSDictionary)

            let threadRead = try await channelCardRead(
                client,
                apiKey: fixture.apiKey,
                target: "#ops:\(String(fixture.anchorId.prefix(8)))"
            )
            #expect(threadRead.status == .ok)
            #expect(threadRead.body["channel_card"] as? NSDictionary == opsCard as NSDictionary)

            let archivedRead = try await channelCardRead(client, apiKey: fixture.apiKey, target: "#incident")
            #expect(archivedRead.status == .ok)
            #expect(archivedRead.body["channel_card"] as? NSDictionary == [
                "id": fixture.incidentId,
                "name": "incident",
                "type": "private",
                "description": NSNull(),
                "archived": true,
            ] as NSDictionary)

            let dmRead = try await channelCardRead(client, apiKey: fixture.apiKey, target: "dm:@\(fixture.ownerName)")
            #expect(dmRead.status == .ok)
            #expect(dmRead.body["channel_card"] == nil)
            #expect((dmRead.body["messages"] as? [[String: Any]])?.isEmpty == false)
        }
    }
}
