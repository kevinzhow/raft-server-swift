import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentMentionsPageNewestFirstWithHasMore() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111502"
    let serverId = "33333333-3333-4333-8333-333333333597"
    accounts.addAccount(id: ownerId, email: "mention-limit-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-limit", name: "Mention Limit", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "mention-limit", creatorUserId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "MentionLimitBot")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["mentions"], name: "mentions")
    let ids = (1...3).map { _ in UUID().uuidString.lowercased() }
    for id in ids {
        accounts.addStoredMentionForTesting(channelId: channel, messageId: id, targetId: agent, targetType: "agent")
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            let exact = try await client.send(.get, headers: headers, to: URI(string: "/internal/agent-api/mentions?limit=2"))
            #expect(exact.status == .ok)
            let exactBody = try JSONSerialization.jsonObject(with: Data((exact.body.string ?? "").utf8)) as? [String: Any]
            let exactIds = (exactBody?["mentions"] as? [[String: Any]] ?? []).compactMap { $0["messageId"] as? String }
            #expect(exactBody?["has_more"] as? Bool == true)
            let third = ids[2]
            let second = ids[1]
            let first = ids[0]
            #expect(exactIds == [third, second])

            let all = try await client.send(.get, headers: headers, to: URI(string: "/internal/agent-api/mentions?limit=3"))
            let allBody = try JSONSerialization.jsonObject(with: Data((all.body.string ?? "").utf8)) as? [String: Any]
            #expect(allBody?["has_more"] as? Bool == false)
            let allIds = (allBody?["mentions"] as? [[String: Any]] ?? []).compactMap { $0["messageId"] as? String }
            #expect(allIds == [third, second, first])
        }
    }
}
