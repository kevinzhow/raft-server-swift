import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct HistoryContractFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let channelName: String
    let ownerId: String
    let ownerToken: String
    let agentId: String
    let readKey: String
}

private func makeHistoryContractFixture(_ suffix: String) -> HistoryContractFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001170\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001170\(suffix)"
    accounts.addAccount(id: ownerId, email: "history-contract-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "history-contract-\(suffix)", name: "History Contract \(suffix)", ownerId: ownerId)
    let channelName = "history-contract-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "HistoryContractBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    return HistoryContractFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        channelName: channelName,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        agentId: agentId,
        readKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "history-contract-\(suffix)")
    )
}

private func historyRequest(
    _ client: any Client,
    key: String,
    channelRef: String,
    query: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    let encoded = channelRef.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? channelRef
    let response = try await client.get(URI(string: "/internal/agent-api/history?channel=\(encoded)&\(query)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func historyMessageIds(_ body: [String: Any]) -> [String] {
    (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
}

@Test func agentHistoryConsumeFalseReturnsThePageWithoutAdvancing() async throws {
    let f = makeHistoryContractFixture("801")
    let first = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "peek first", senderId: f.ownerId)
    let second = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "peek second", senderId: f.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let peek = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "limit=2&consume=false")
            #expect(peek.status == .ok)
            #expect(historyMessageIds(peek.body) == [first.id, second.id])
            #expect(peek.body["last_read_seq"] as? Int == 0)
            #expect(peek.body["model_seen_up_to_seq"] == nil || peek.body["model_seen_up_to_seq"] is NSNull)
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == 0, "consume=false must not mark the page read")

            let read = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "limit=2")
            #expect(read.status == .ok)
            #expect(read.body["model_seen_up_to_seq"] as? Int == second.seq)
            #expect(read.body["last_read_seq"] as? Int == 0)
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == second.seq)

            let invalid = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "consume=no")
            #expect(invalid.status == .badRequest)
        }
    }
}

@Test func agentHistoryAroundDoesNotAdvanceTheReadCursor() async throws {
    let f = makeHistoryContractFixture("802")
    let first = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "around first", senderId: f.ownerId)
    let second = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "around second", senderId: f.ownerId)
    let third = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "around third", senderId: f.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let around = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "around=\(second.id.prefix(8))&limit=1")
            #expect(around.status == .ok)
            #expect(historyMessageIds(around.body) == [second.id])
            #expect(around.body["has_older"] as? Bool == true)
            #expect(around.body["has_newer"] as? Bool == true)
            #expect(around.body["last_read_seq"] as? Int == 0)
            #expect(around.body["model_seen_up_to_seq"] == nil || around.body["model_seen_up_to_seq"] is NSNull)
            #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == 0)
            #expect(first.seq < second.seq && second.seq < third.seq)
        }
    }
}

@Test func agentHistoryAroundResolvesAnchorsAndFailsClosed() async throws {
    let f = makeHistoryContractFixture("803")
    let createdAt = Date(timeIntervalSince1970: 1_782_545_779.123)
    let message = f.accounts.oauth.createMessageRecord(
        channelId: f.channelId,
        content: "agent-api around target",
        senderId: f.ownerId,
        createdAt: createdAt
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let success = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "around=\(message.id.prefix(8))&limit=1")
            #expect(success.status == .ok)
            let rows = try #require(success.body["messages"] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows[0]["id"] as? String == message.id)
            #expect(rows[0]["content"] as? String == "agent-api around target")
            let stamp = try #require(rows[0]["createdAt"] as? String)
            #expect(stamp.hasSuffix("Z"))
            #expect(rows[0]["timestamp"] == nil)
            #expect(success.body["has_older"] is Bool)
            #expect(success.body["has_newer"] is Bool)

            let missing = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "around=4f9c2210&limit=1")
            #expect(missing.status == .notFound)
            #expect(missing.body["errorCode"] as? String == "NOT_FOUND")
            #expect((missing.body["error"] as? String)?.contains("4f9c2210") == true)

            _ = f.accounts.oauth.createMessageRecord(
                channelId: f.channelId,
                content: "ambiguous around one",
                senderId: f.ownerId,
                id: "aaaaaaaa-1111-4111-8111-111111111111"
            )
            _ = f.accounts.oauth.createMessageRecord(
                channelId: f.channelId,
                content: "ambiguous around two",
                senderId: f.ownerId,
                id: "aaaaaaaa-2222-4222-8222-222222222222"
            )
            let ambiguous = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "around=aaaaaaaa&limit=1")
            #expect(ambiguous.status == .badRequest)
            #expect(ambiguous.body["errorCode"] as? String == "AMBIGUOUS_ID")
            #expect((ambiguous.body["suggestedNextAction"] as? String)?.contains("full message UUID") == true)

            let invalid = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "around=not-a-message-id&limit=1")
            #expect(invalid.status == .badRequest)
            #expect(invalid.body["errorCode"] as? String == "INVALID_ARG")
            #expect((invalid.body["error"] as? String)?.contains("seq, full UUID, or 8-character short id") == true)
        }
    }
}

@Test func agentHistoryKeepsEightDigitPaginationSeqsDistinctFromAroundShortIds() async throws {
    let f = makeHistoryContractFixture("804")
    let decimalPrefix = f.accounts.oauth.createMessageRecord(
        channelId: f.channelId,
        content: "numeric short-id around target",
        senderId: f.ownerId,
        id: "63508141-1111-4111-8111-111111111111"
    )
    let afterTarget = f.accounts.oauth.createMessageRecord(
        channelId: f.channelId,
        content: "message after 8-digit pagination anchor",
        senderId: f.ownerId,
        seq: 10_018_628
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let around = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "around=63508141&limit=1")
            #expect(around.status == .ok)
            #expect(historyMessageIds(around.body) == [decimalPrefix.id])

            let after = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "after=10015971&limit=1")
            #expect(after.status == .ok)
            let afterRows = try #require(after.body["messages"] as? [[String: Any]])
            #expect(afterRows.map { $0["id"] as? String } == [afterTarget.id])
            #expect(afterRows.first?["seq"] as? Int == 10_018_628)

            let before = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "before=10015971&limit=1")
            #expect(before.status == .ok)
            #expect((before.body["messages"] as? [[String: Any]])?.count == 1)
        }
    }
}

@Test func agentHistoryPageBoundariesDistinguishExactLimitFromAnotherPage() async throws {
    let f = makeHistoryContractFixture("805")
    let first = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "page one", senderId: f.ownerId)
    let second = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "page two", senderId: f.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let exact = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "limit=2")
            #expect(historyMessageIds(exact.body) == [first.id, second.id])
            #expect(exact.body["has_more"] as? Bool == false)
            #expect(exact.body["has_older"] as? Bool == false)
            #expect(exact.body["has_newer"] as? Bool == false)
            #expect(exact.body["model_seen_up_to_seq"] as? Int == second.seq)

            let third = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "page three from caller", senderId: f.agentId)
            let over = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "limit=2")
            #expect(historyMessageIds(over.body) == [second.id, third.id])
            #expect(over.body["has_more"] as? Bool == true)
            #expect(over.body["has_older"] as? Bool == true)
            #expect(over.body["has_newer"] as? Bool == false)
            #expect(over.body["last_read_seq"] as? Int == second.seq)

            let after = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "after=\(first.seq)&limit=1")
            #expect(historyMessageIds(after.body) == [second.id])
            #expect(after.body["has_more"] as? Bool == true)
            #expect(after.body["has_older"] as? Bool == false)
            #expect(after.body["has_newer"] as? Bool == true)
        }
    }
}

@Test func agentHistoryCarriesTheHumanSenderTimezoneOnlyOnAgentReads() async throws {
    let f = makeHistoryContractFixture("806")
    let zoned = f.accounts.oauth.createMessageRecord(
        channelId: f.channelId,
        content: "zoned human send",
        senderId: f.ownerId,
        senderTimezone: "Asia/Shanghai"
    )
    let plain = f.accounts.oauth.createMessageRecord(channelId: f.channelId, content: "agent reply without a zone", senderId: f.agentId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let agentApi = try await historyRequest(client, key: f.readKey, channelRef: "#\(f.channelName)", query: "limit=10&consume=false")
            #expect(agentApi.status == .ok)
            let rows = try #require(agentApi.body["messages"] as? [[String: Any]])
            let zonedRow = try #require(rows.first { $0["id"] as? String == zoned.id })
            let plainRow = try #require(rows.first { $0["id"] as? String == plain.id })
            #expect(zonedRow["senderTimezone"] as? String == "Asia/Shanghai")
            #expect(plainRow["senderTimezone"] == nil || plainRow["senderTimezone"] is NSNull)
        }
    }
}
