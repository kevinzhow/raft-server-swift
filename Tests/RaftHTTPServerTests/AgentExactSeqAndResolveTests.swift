import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ExactSeqFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let channelName: String
    let ownerId: String
    let ownerToken: String
    let agentId: String
    let agentKey: String
}

private func makeExactSeqFixture(_ suffix: String) -> ExactSeqFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001190\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001190\(suffix)"
    accounts.addAccount(id: ownerId, email: "exact-seq-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "exact-seq-\(suffix)", name: "Exact Seq \(suffix)", ownerId: ownerId)
    let channelName = "exact-seq-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ExactSeqBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    return ExactSeqFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        channelName: channelName,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send"], name: "exact-seq-\(suffix)")
    )
}

private func exactSeqHumanHeaders(_ f: ExactSeqFixture) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.ownerToken)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = f.serverId
    return headers
}

private func exactSeqAgentHeaders(_ f: ExactSeqFixture) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.agentKey)"
    headers[.contentType] = "application/json"
    return headers
}

private func exactSeqJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@discardableResult
private func exactSeqPostHuman(
    _ client: any Client,
    _ f: ExactSeqFixture,
    content: String,
    timezone: String? = nil
) async throws -> (id: String, seq: Int) {
    let zone = timezone.map { ",\"timezone\":\"\($0)\"" } ?? ""
    let response = try await client.send(.post, headers: exactSeqHumanHeaders(f), to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(f.channelId)\",\"content\":\"\(content)\"\(zone)}")
    }
    let id = try #require(try exactSeqJSON(response)["id"] as? String)
    return (id, try #require(f.accounts.humanMessageSequence(id: id)))
}

@Test func agentApiSendAcceptsSparseSeenExactSeqsWhenNothingElseIsUnseen() async throws {
    let f = makeExactSeqFixture("701")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await exactSeqPostHuman(client, f, content: "body rendered by message check")
            let second = try await exactSeqPostHuman(client, f, content: "another rendered body")
            let send = try await client.send(.post, headers: exactSeqAgentHeaders(f), to: "/internal/agent-api/send") { request in
                request.body = .init(string: "{\"target\":\"#\(f.channelName)\",\"content\":\"reply after message check\",\"seenExactSeqs\":[\(first.seq),\(second.seq)]}")
            }
            let body = try exactSeqJSON(send)
            #expect(send.status == .ok)
            #expect(body["state"] as? String == "sent")
            #expect(body["messageId"] as? String != nil)
        }
    }
}

@Test func agentApiHistoryHiddenOlderGapStaysUnreadAndExactSeqSendHoldsForIt() async throws {
    let f = makeExactSeqFixture("702")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var unread: [(id: String, seq: Int)] = []
            for index in 1...51 {
                unread.append(try await exactSeqPostHuman(client, f, content: "gapped unread \(index)"))
            }
            let history = try await client.get(
                URI(string: "/internal/agent-api/history?channel=%23\(f.channelName)"),
                headers: exactSeqAgentHeaders(f)
            )
            let readBody = try exactSeqJSON(history)
            let rows = try #require(readBody["messages"] as? [[String: Any]])
            #expect(rows.count == 50, "the default latest window is 50 rows")
            #expect(readBody["has_older"] as? Bool == true)
            #expect(readBody["last_read_seq"] as? Int == 0)
            #expect(readBody["model_seen_up_to_seq"] == nil || readBody["model_seen_up_to_seq"] is NSNull)
            #expect(rows.compactMap { $0["id"] as? String } == unread.dropFirst().map(\.id))
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == 0, "the hidden older row stays unread")

            let seenSeqs = rows.compactMap { $0["seq"] as? Int }
            let send = try await client.send(.post, headers: exactSeqAgentHeaders(f), to: "/internal/agent-api/send") { request in
                request.body = .init(string: "{\"target\":\"#\(f.channelName)\",\"content\":\"send after seeing only the latest 50\",\"seenExactSeqs\":[\(seenSeqs.map(String.init).joined(separator: ","))]}")
            }
            let sendBody = try exactSeqJSON(send)
            #expect(send.status == .ok)
            #expect(sendBody["state"] as? String == "held")
            #expect(sendBody["newMessageCount"] as? Int == 1)
            let heldRows = try #require(sendBody["heldMessages"] as? [[String: Any]])
            #expect(heldRows.compactMap { $0["id"] as? String } == [unread[0].id])
        }
    }
}

@Test func agentMessageResolveCarriesTheHumanSenderTimezone() async throws {
    let f = makeExactSeqFixture("703")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let zoned = try await exactSeqPostHuman(client, f, content: "zoned human send", timezone: "Asia/Shanghai")
            let plain = try await exactSeqPostHuman(client, f, content: "plain human send")
            for (id, expected) in [(zoned.id, "Asia/Shanghai")] {
                let response = try await client.get(
                    URI(string: "/internal/agent-api/messages/\(id)/resolve"),
                    headers: exactSeqAgentHeaders(f)
                )
                #expect(response.status == .ok)
                let message = try #require(try exactSeqJSON(response)["message"] as? [String: Any])
                #expect(message["sender_timezone"] as? String == expected)
            }
            let plainResponse = try await client.get(
                URI(string: "/internal/agent-api/messages/\(plain.id)/resolve"),
                headers: exactSeqAgentHeaders(f)
            )
            let plainMessage = try #require(try exactSeqJSON(plainResponse)["message"] as? [String: Any])
            #expect(plainMessage["sender_timezone"] == nil || plainMessage["sender_timezone"] is NSNull)

            let humanPage = try await client.get(
                URI(string: "/api/messages/channel/\(f.channelId)"),
                headers: exactSeqHumanHeaders(f)
            )
            let humanRows = try #require(try exactSeqJSON(humanPage)["messages"] as? [[String: Any]])
            let humanRow = try #require(humanRows.first { $0["id"] as? String == zoned.id })
            #expect(humanRow["senderTimezone"] == nil, "a human client never receives another user's zone")
        }
    }
}
