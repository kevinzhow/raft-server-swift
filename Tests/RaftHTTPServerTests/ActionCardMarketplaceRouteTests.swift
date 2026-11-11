import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct MarketplaceRouteFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelName: String
    let ownerName: String
    let key: String
    let createdAt: Date
}

private func makeMarketplaceRouteFixture(_ suffix: String) -> MarketplaceRouteFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-0000010610\(suffix)"
    let ownerId = "11111111-1111-4111-8111-0000010610\(suffix)"
    let ownerName = "route-owner-\(suffix)"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "route-\(suffix)", name: "Route \(suffix)", ownerId: ownerId)
    let channelName = "route-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "RouteBot\(suffix)", runtime: "codex")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, name: channelName)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.setAgentGrantsForTesting(agentId: agentId, scopes: ["task:write"])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "tasks"], name: "route-\(suffix)")
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    _ = accounts.addChannelMessageForTesting(
        channelId: channelId,
        content: "hello route",
        senderId: ownerId,
        createdAt: createdAt
    )
    return MarketplaceRouteFixture(
        accounts: accounts,
        serverId: serverId,
        channelName: channelName,
        ownerName: ownerName,
        key: key,
        createdAt: createdAt
    )
}

@Test func agentInboxRouteKeepsThePublishedBytesAndHeaders() async throws {
    let fixture = makeMarketplaceRouteFixture("01")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.key)"
            let response = try await client.get(
                URI(string: "/internal/agent-api/inbox/conversations"),
                headers: headers
            )
            #expect(response.status == .ok)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expected = "{\"view\":\"unread\",\"items\":[{\"target\":\"#route-room-01\",\"kind\":\"channel\",\"unread\":1,\"mentions\":0,\"lastReadSeq\":0,\"activitySeq\":1,\"latestSenderName\":\"route-owner-01\",\"latestAt\":\"\(formatter.string(from: fixture.createdAt))\"}],\"totals\":{\"conversations\":1,\"dms\":0,\"mentions\":0},\"hasMore\":false,\"nextBeforeSeq\":null}"
            #expect(response.body.string == expected)
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[HTTPField.Name("Content-Length")!] == String(expected.utf8.count))
        }
    }
}

@Test func agentTaskDeleteRouteKeepsThePublishedErrorBytes() async throws {
    let fixture = makeMarketplaceRouteFixture("02")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let key = fixture.key
            func post(_ body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/internal/agent-api/tasks/delete") { request in
                    request.body = .init(string: body)
                }
            }

            let invalid = try await post("{\"channel\":123}")
            #expect(invalid.status == .badRequest)
            #expect(invalid.body.string == #"{"error":"Invalid agent-api taskDelete body","code":"agent_api_contract_invalid","issues":[{"path":"channel","message":"Invalid input: expected string, received number"},{"path":"task_number","message":"Invalid input: expected number, received undefined"}]}"#)

            let missing = try await post("{\"channel\":\"#route-room-02\",\"task_number\":99}")
            #expect(missing.status == .notFound)
            #expect(missing.body.string == "{\"error\":\"Task not found\"}")
            #expect(missing.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(missing.headers[.contentType] == "application/json; charset=utf-8")
            #expect(missing.headers[HTTPField.Name("Content-Length")!] == String("{\"error\":\"Task not found\"}".utf8.count))
        }
    }
}
