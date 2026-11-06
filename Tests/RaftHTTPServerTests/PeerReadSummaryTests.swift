import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func manyAgentPeersCollapseIntoAReadSummary() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111516"
    let serverId = "33333333-3333-4333-8333-333333333603"
    accounts.addAccount(id: ownerId, email: "summary-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "summary", name: "Summary", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "summary-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "summary-room")
    var agents: [String] = []
    for index in 0...50 {
        let agent = accounts.oauth.createAgent(serverId: serverId, name: "summary-agent-\(index)")
        accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
        agents.append(agent)
    }
    accounts.enableReadReceiptsForServer(serverId)
    accounts.setAgentReadCursorForTesting(agentId: agents[0], channelId: channel, seq: 5)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"summary-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let summaryDetail = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)")
            let body = try JSONSerialization.jsonObject(with: Data((summaryDetail.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(body["peerReadStates"] == nil)
            let summary = body["peerReadSummary"] as? [String: Any]
            #expect(summary?["peerCount"] as? Int == 51)
            let buckets = summary?["readCountAtSeq"] as? [[String: Any]] ?? []
            #expect(buckets.count == 2)
            #expect(buckets[0]["seq"] as? Int == 0)
            #expect(buckets[0]["count"] as? Int == 50)
            #expect(buckets[1]["seq"] as? Int == 5)
            #expect(buckets[1]["count"] as? Int == 1)

            accounts.oauth.removeChannelAgent(channelId: channel, agentId: agents[50])
            let bounded = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)")
            let boundedBody = try JSONSerialization.jsonObject(with: Data((bounded.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(boundedBody["peerReadSummary"] == nil)
            #expect((boundedBody["peerReadStates"] as? [[String: Any]] ?? []).count == 50)
        }
    }
}
