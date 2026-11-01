import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ReadPositionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let channelName: String
    let ownerId: String
    let ownerEmail: String
    let otherId: String
    let otherEmail: String
    let agentId: String
    let apiKey: String
}

private func makeReadPositionFixture(suffix: String) -> ReadPositionFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 500_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 400_000 + number)
    let otherId = String(format: "11111111-1111-4111-8111-%012d", 410_000 + number)
    let ownerEmail = "read-position-owner-\(suffix)@slock.test"
    let otherEmail = "read-position-other-\(suffix)@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (otherId, otherEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "read-position-\(suffix)", name: "Read Position", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: otherId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ReadPos-\(suffix)", runtime: "external")
    let channelName = "read-position-\(suffix)"
    let channel = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    for member in [ownerId, otherId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: member, name: channelName)
    }
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: otherId)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read"], name: "read-position-\(suffix)")
    return ReadPositionFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channel,
        channelName: channelName,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        otherId: otherId,
        otherEmail: otherEmail,
        agentId: agent,
        apiKey: apiKey
    )
}

private func readPositionLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func readPositionHumanSend(
    _ client: any Client,
    token: String,
    serverId: String,
    channelId: String,
    content: String
) async throws -> (id: String, status: HTTPResponse.Status) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
    return (body?["id"] as? String ?? "", response.status)
}

private func readPositionAgentSend(
    _ client: any Client,
    apiKey: String,
    channelName: String,
    content: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/send") { request in
        request.body = .init(string: "{\"target\":\"#\(channelName)\",\"content\":\"\(content)\"}")
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func readPositionEvents(_ client: any Client, apiKey: String) async throws -> (events: [[String: Any]], hasMore: Bool) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get("/internal/agent-api/events", headers: headers)
    #expect(response.status == .ok)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (body["events"] as? [[String: Any]] ?? [], body["has_more"] as? Bool ?? false)
}

@Test func agentReadPositionOnlyPassesMessagesThatWereHandedOver() async throws {
    let fixture = makeReadPositionFixture(suffix: "881")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let ownerToken = try await readPositionLogin(client, email: fixture.ownerEmail)
            let otherToken = try await readPositionLogin(client, email: fixture.otherEmail)

            // 1. A conversation cut at the per-conversation cap reports has_more.
            var sent: [(id: String, seq: Int)] = []
            for index in 0..<10 {
                let response = try await readPositionHumanSend(
                    client,
                    token: ownerToken,
                    serverId: fixture.serverId,
                    channelId: fixture.channelId,
                    content: "unread \(index)"
                )
                #expect(response.status == .ok)
                sent.append((response.id, fixture.accounts.humanMessageSequence(id: response.id) ?? 0))
            }
            let first = try await readPositionEvents(client, apiKey: fixture.apiKey)
            #expect(first.events.compactMap { $0["message_id"] as? String } == sent.prefix(5).map(\.id))
            #expect(first.events.compactMap { $0["seq"] as? Int } == sent.prefix(5).map(\.seq))
            #expect(first.hasMore)
            let second = try await readPositionEvents(client, apiKey: fixture.apiKey)
            #expect(second.events.compactMap { $0["message_id"] as? String } == sent.suffix(5).map(\.id))
            #expect(!second.hasMore)
            #expect(try await readPositionEvents(client, apiKey: fixture.apiKey).events.isEmpty)

            // 2. An agent send over unread messages does not advance its cursor.
            let base = try await readPositionHumanSend(
                client,
                token: ownerToken,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                content: "read"
            )
            let baseSeq = fixture.accounts.humanMessageSequence(id: base.id) ?? 0
            fixture.accounts.setAgentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: baseSeq)
            let unread1 = try await readPositionHumanSend(
                client,
                token: ownerToken,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                content: "not handed over yet 1"
            )
            let unread2 = try await readPositionHumanSend(
                client,
                token: ownerToken,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                content: "not handed over yet 2"
            )
            let own = try await readPositionAgentSend(
                client,
                apiKey: fixture.apiKey,
                channelName: fixture.channelName,
                content: "the agent's reply"
            )
            #expect(own.status == .ok)
            let ownSeq = own.body["seq"] as? Int ?? 0
            let unread2Seq = fixture.accounts.humanMessageSequence(id: unread2.id) ?? 0
            #expect(ownSeq > unread2Seq)
            #expect(fixture.accounts.agentReadCursor(channelId: fixture.channelId, agentId: fixture.agentId) == baseSeq)
            let pulled = try await readPositionEvents(client, apiKey: fixture.apiKey)
            #expect(pulled.events.compactMap { $0["message_id"] as? String } == [unread1.id, unread2.id])
            #expect(!pulled.events.contains { $0["message_id"] as? String == own.body["id"] as? String })
            #expect(try await readPositionEvents(client, apiKey: fixture.apiKey).events.isEmpty)

            // 3. With nothing unread below, the cursor advances to the own message.
            let cleanBase = try await readPositionHumanSend(
                client,
                token: ownerToken,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                content: "read again"
            )
            let cleanSeq = fixture.accounts.humanMessageSequence(id: cleanBase.id) ?? 0
            fixture.accounts.setAgentReadCursorForTesting(agentId: fixture.agentId, channelId: fixture.channelId, seq: cleanSeq)
            let ownClean = try await readPositionAgentSend(
                client,
                apiKey: fixture.apiKey,
                channelName: fixture.channelName,
                content: "reply with nothing pending"
            )
            #expect(ownClean.status == .ok)
            #expect(fixture.accounts.agentReadCursor(channelId: fixture.channelId, agentId: fixture.agentId) == ownClean.body["seq"] as? Int)
            let ownAgain = try await readPositionAgentSend(
                client,
                apiKey: fixture.apiKey,
                channelName: fixture.channelName,
                content: "second reply"
            )
            #expect(fixture.accounts.agentReadCursor(channelId: fixture.channelId, agentId: fixture.agentId) == ownAgain.body["seq"] as? Int)
            #expect(try await readPositionEvents(client, apiKey: fixture.apiKey).events.isEmpty)

            // 4. A human send always advances that human's cursor.
            let otherMessage = try await readPositionHumanSend(
                client,
                token: otherToken,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                content: "from the other human"
            )
            #expect(otherMessage.status == .ok)
            let ownerMessage = try await readPositionHumanSend(
                client,
                token: ownerToken,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                content: "owner writes"
            )
            #expect(ownerMessage.status == .ok)
            let ownerSeq = fixture.accounts.humanMessageSequence(id: ownerMessage.id) ?? 0
            #expect(fixture.accounts.humanReadCursor(channelId: fixture.channelId, userId: fixture.ownerId) == ownerSeq)
        }
    }
}
