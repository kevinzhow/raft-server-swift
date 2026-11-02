import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentApiSearchUsesBoundIdentityAndFiltersVisibility() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001024001"
    let ownerId = "11111111-1111-4111-8111-000001024001"
    let ownerEmail = "agent-search-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-search", name: "Agent Search", ownerId: ownerId)
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "search-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: ownerId, name: "search-public")
    accounts.oauth.addChannelHuman(channelId: publicChannel, userId: ownerId)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "search-private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private", name: "search-private")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
    let hiddenChannel = accounts.oauth.createChannel(serverId: serverId, name: "search-hidden", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: hiddenChannel, memberId: ownerId, kind: "private", name: "search-hidden")
    accounts.oauth.addChannelHuman(channelId: hiddenChannel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "SearchBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: privateChannel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "search")

    _ = accounts.addChannelMessageForTesting(channelId: publicChannel, content: "agent-search-marker public from owner", senderId: ownerId)
    _ = accounts.addChannelMessageForTesting(channelId: publicChannel, content: "agent-search-marker second public", senderId: ownerId)
    _ = accounts.addChannelMessageForTesting(channelId: privateChannel, content: "agent-search-marker private visible", senderId: ownerId)
    _ = accounts.addChannelMessageForTesting(channelId: hiddenChannel, content: "agent-search-marker hidden private", senderId: ownerId)

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
            func search(_ query: String) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
                let response = try await client.get(URI(string: "/internal/agent-api/search?\(query)"), headers: headers)
                return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }

            let publicResult = try await search("q=agent-search-marker&channel=%23search-public&sender=agent-search-owner&sort=recent&limit=5")
            #expect(publicResult.status == .ok)
            let publicResults = publicResult.body["results"] as? [[String: Any]] ?? []
            #expect(publicResults.count == 2)
            #expect(publicResults.allSatisfy { $0["senderName"] as? String == "agent-search-owner" })
            #expect(publicResults.allSatisfy { $0["senderType"] as? String == "human" })
            #expect(publicResults.allSatisfy { $0["channelName"] as? String == "search-public" })
            #expect(publicResult.body["hasMore"] as? Bool == false)

            let limited = try await search("q=agent-search-marker&channel=%23search-public&limit=1")
            #expect((limited.body["results"] as? [[String: Any]] ?? []).count == 1)
            #expect(limited.body["hasMore"] as? Bool == true)

            let privateResult = try await search("q=agent-search-marker&channel=%23search-private")
            #expect((privateResult.body["results"] as? [[String: Any]] ?? []).count == 1)

            let hidden = try await search("q=agent-search-marker&channel=%23search-hidden")
            #expect((hidden.body["results"] as? [[String: Any]] ?? []).isEmpty)

            let sendOnly = accounts.mintAgentCredential(agentId: agent, scopes: ["send"], name: "send")
            var sendHeaders = HTTPFields()
            sendHeaders[.authorization] = "Bearer \(sendOnly)"
            let denied = try await client.get(URI(string: "/internal/agent-api/search?q=agent-search-marker"), headers: sendHeaders)
            #expect(denied.status == .forbidden)
        }
    }
}
