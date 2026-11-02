import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentApiThreadListAndUnfollowScopeVisibility() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001028001"
    let ownerId = "11111111-1111-4111-8111-000001028001"
    let ownerEmail = "agent-thread-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-thread", name: "Agent Thread", ownerId: ownerId)
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "thread-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: ownerId, name: "thread-public")
    accounts.oauth.addChannelHuman(channelId: publicChannel, userId: ownerId)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "thread-private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private", name: "thread-private")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
    let hiddenChannel = accounts.oauth.createChannel(serverId: serverId, name: "thread-hidden", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: hiddenChannel, memberId: ownerId, kind: "private", name: "thread-hidden")
    accounts.oauth.addChannelHuman(channelId: hiddenChannel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ThreadBot", runtime: "codex")
    let otherAgent = accounts.oauth.createAgent(serverId: serverId, name: "OtherThreadBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: privateChannel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "threads")

    func thread(_ channelId: String, _ content: String) -> (parent: String, thread: String) {
        let parent = accounts.addChannelMessageForTesting(channelId: channelId, content: content, senderId: ownerId)
        let threadId = accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parent)
        accounts.addPostableChannel(serverId: serverId, channelId: threadId, memberId: ownerId, kind: "thread", parentChannelId: channelId, parentMessageId: parent, name: "thread")
        accounts.oauth.addChannelHuman(channelId: threadId, userId: ownerId)
        return (parent, threadId)
    }
    let active = thread(publicChannel, "agent-api followed thread parent")
    let unfollowed = thread(publicChannel, "agent-api unfollowed thread parent")
    let other = thread(publicChannel, "agent-api other agent followed thread parent")
    let hidden = thread(hiddenChannel, "agent-api hidden followed thread parent")
    let privateThread = thread(privateChannel, "agent-api private followed thread parent")
    let followedAt = Date(timeIntervalSince1970: 1_789_000_000)
    accounts.followThreadForAgentTesting(serverId: serverId, agentId: agent, threadChannelId: active.thread, parentMessageId: active.parent, reason: "manual", followedAt: followedAt)
    accounts.followThreadForAgentTesting(serverId: serverId, agentId: agent, threadChannelId: unfollowed.thread, parentMessageId: unfollowed.parent, reason: "mentioned", followedAt: followedAt.addingTimeInterval(-3600), unfollowedAt: followedAt.addingTimeInterval(-1800))
    accounts.followThreadForAgentTesting(serverId: serverId, agentId: otherAgent, threadChannelId: other.thread, parentMessageId: other.parent, reason: "manual", followedAt: followedAt.addingTimeInterval(-7200))
    accounts.followThreadForAgentTesting(serverId: serverId, agentId: agent, threadChannelId: hidden.thread, parentMessageId: hidden.parent, reason: "manual", followedAt: followedAt.addingTimeInterval(1800))
    accounts.followThreadForAgentTesting(serverId: serverId, agentId: agent, threadChannelId: privateThread.thread, parentMessageId: privateThread.parent, reason: "manual", followedAt: followedAt.addingTimeInterval(60))

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
            headers[.contentType] = "application/json"
            func list() async throws -> [[String: Any]] {
                let response = try await client.get(URI(string: "/internal/agent-api/threads"), headers: headers)
                #expect(response.status == .ok)
                return ((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any])?["threads"] as? [[String: Any]] ?? []
            }
            func unfollow(_ thread: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/internal/agent-api/threads/unfollow") { request in
                    request.body = .init(string: "{\"thread\":\"\(thread)\"}")
                }
            }
            let initial = try await list()
            #expect(initial.map { $0["threadChannelId"] as? String } == [privateThread.thread, active.thread])
            let first = try #require(initial.last)
            #expect(first["target"] as? String == "#thread-public:\(String(active.parent.prefix(8)))")
            #expect(first["parentChannelRef"] as? String == "#thread-public")
            #expect(first["reason"] as? String == "manual")
            #expect(first["doneAt"] is NSNull)

            #expect(try await unfollow(active.thread).status == .ok)
            let afterUnfollow = try await list()
            #expect(afterUnfollow.map { $0["threadChannelId"] as? String } == [initial.first?["threadChannelId"] as? String])

            #expect(try await unfollow(active.thread).status == .ok)
            #expect(try await unfollow(hidden.thread).status == .notFound)
            #expect(try await unfollow(hiddenChannel).status == .notFound)
            let hiddenRef = try await unfollow("#thread-hidden:\(String(hidden.parent.prefix(8)))")
            #expect(hiddenRef.status == .notFound)
            #expect(try (JSONSerialization.jsonObject(with: Data((hiddenRef.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Thread not found")
        }
    }
}
