import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct UnifiedStoreFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let channelName: String
    let ownerId: String
    let ownerToken: String
    let agentId: String
    let agentKey: String
}

private func makeUnifiedStoreFixture(_ suffix: String) -> UnifiedStoreFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001180\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001180\(suffix)"
    accounts.addAccount(id: ownerId, email: "unified-store-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "unified-store-\(suffix)", name: "Unified Store \(suffix)", ownerId: ownerId)
    let channelName = "unified-store-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "UnifiedStoreBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    return UnifiedStoreFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        channelName: channelName,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send"], name: "unified-store-\(suffix)")
    )
}

private func unifiedHumanHeaders(_ f: UnifiedStoreFixture) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.ownerToken)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = f.serverId
    return headers
}

private func unifiedAgentHeaders(_ f: UnifiedStoreFixture) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.agentKey)"
    headers[.contentType] = "application/json"
    return headers
}

private func unifiedJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func unifiedHistory(
    _ client: any Client,
    f: UnifiedStoreFixture,
    channelRef: String,
    query: String
) async throws -> [String: Any] {
    let encoded = channelRef.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? channelRef
    let response = try await client.get(
        URI(string: "/internal/agent-api/history?channel=\(encoded)&\(query)"),
        headers: unifiedAgentHeaders(f)
    )
    return try unifiedJSON(response)
}

@Test func agentHistorySeesHTTPHumanMessagesWithServerSequence() async throws {
    let f = makeUnifiedStoreFixture("901")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.send(.post, headers: unifiedHumanHeaders(f), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(f.channelId)\",\"content\":\"real human traffic\",\"timezone\":\"Asia/Shanghai\"}")
            }
            let humanId = try #require(try unifiedJSON(response)["id"] as? String)
            let humanSeq = try #require(f.accounts.humanMessageSequence(id: humanId))

            let body = try await unifiedHistory(client, f: f, channelRef: "#\(f.channelName)", query: "limit=10&consume=false")
            let rows = try #require(body["messages"] as? [[String: Any]])
            let row = try #require(rows.first { $0["id"] as? String == humanId })
            #expect(row["seq"] as? Int == humanSeq)
            #expect(row["content"] as? String == "real human traffic")
            #expect(row["senderType"] as? String == "user")
            #expect(row["senderTimezone"] as? String == "Asia/Shanghai")
            #expect((row["createdAt"] as? String)?.hasSuffix("Z") == true)
        }
    }
}

@Test func historyBrowseAdvancesTheUnreadCursorButNotTheSendFreshnessProof() async throws {
    let f = makeUnifiedStoreFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            func postHuman(_ content: String) async throws -> (id: String, seq: Int) {
                let response = try await client.send(.post, headers: unifiedHumanHeaders(f), to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(f.channelId)\",\"content\":\"\(content)\"}")
                }
                let id = try #require(try unifiedJSON(response)["id"] as? String)
                return (id, try #require(f.accounts.humanMessageSequence(id: id)))
            }
            let baseline = try await postHuman("history browse baseline")
            let fresh = try await postHuman("history browse fresh")

            let browse = try await unifiedHistory(client, f: f, channelRef: "#\(f.channelName)", query: "limit=2")
            #expect((browse["messages"] as? [[String: Any]] ?? []).count == 2)
            #expect(browse["last_read_seq"] as? Int == 0)
            #expect(browse["model_seen_up_to_seq"] as? Int == fresh.seq)
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == fresh.seq)

            // The read cursor is not a model-seen proof: the send below still holds.
            let send = try await client.send(.post, headers: unifiedAgentHeaders(f), to: "/internal/agent-api/send") { request in
                request.body = .init(string: "{\"target\":\"#\(f.channelName)\",\"content\":\"send after browse\",\"seenUpToSeq\":\(baseline.seq)}")
            }
            let held = try unifiedJSON(send)
            #expect(held["state"] as? String == "held")
            #expect(held["newMessageCount"] as? Int == 1)
            let heldRows = try #require(held["heldMessages"] as? [[String: Any]])
            #expect(heldRows.first?["id"] as? String == fresh.id)
        }
    }
}

@Test func agentSendIsVisibleOnBothAgentHistoryAndTheHumanChannelPage() async throws {
    let f = makeUnifiedStoreFixture("903")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let send = try await client.send(.post, headers: unifiedAgentHeaders(f), to: "/internal/agent-api/send") { request in
                request.body = .init(string: "{\"target\":\"#\(f.channelName)\",\"content\":\"agent reply from the unified store\"}")
            }
            let sent = try unifiedJSON(send)
            #expect(sent["state"] as? String == "sent")
            let messageId = try #require(sent["messageId"] as? String)
            let messageSeq = try #require(sent["messageSeq"] as? Int)

            let history = try await unifiedHistory(client, f: f, channelRef: "#\(f.channelName)", query: "limit=10&consume=false")
            let historyRow = try #require((history["messages"] as? [[String: Any]])?.first { $0["id"] as? String == messageId })
            #expect(historyRow["seq"] as? Int == messageSeq)
            #expect(historyRow["senderType"] as? String == "agent")

            let humanPage = try await client.get(
                URI(string: "/api/messages/channel/\(f.channelId)"),
                headers: unifiedHumanHeaders(f)
            )
            let humanRows = try #require(try unifiedJSON(humanPage)["messages"] as? [[String: Any]])
            #expect(humanRows.contains { $0["id"] as? String == messageId && $0["content"] as? String == "agent reply from the unified store" })
        }
    }
}

@Test func agentThreadTargetResolvesAHumanMessagePostedOverHTTP() async throws {
    let f = makeUnifiedStoreFixture("904")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let parentResponse = try await client.send(.post, headers: unifiedHumanHeaders(f), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(f.channelId)\",\"content\":\"http thread parent\"}")
            }
            let parentId = try #require(try unifiedJSON(parentResponse)["id"] as? String)
            let parentSeq = try #require(f.accounts.humanMessageSequence(id: parentId))

            let send = try await client.send(.post, headers: unifiedAgentHeaders(f), to: "/internal/agent-api/send") { request in
                request.body = .init(string: "{\"target\":\"#\(f.channelName):\(parentId.prefix(8))\",\"content\":\"thread reply over the unified store\",\"seenUpToSeq\":\(parentSeq)}")
            }
            let sent = try unifiedJSON(send)
            #expect(sent["state"] as? String == "sent")
            #expect(sent["messageSeq"] as? Int != nil)

            let threadHistory = try await unifiedHistory(
                client,
                f: f,
                channelRef: "#\(f.channelName):\(parentId.prefix(8))",
                query: "limit=10&consume=false"
            )
            let rows = try #require(threadHistory["messages"] as? [[String: Any]])
            #expect(rows.contains { $0["content"] as? String == "thread reply over the unified store" })
        }
    }
}
