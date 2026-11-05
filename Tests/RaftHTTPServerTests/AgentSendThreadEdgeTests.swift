import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ThreadEdgeFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001112001"
    let ownerId = "11111111-1111-4111-8111-000001112001"
    var agentId = ""
    var channelId = ""
    var channelName = "thread-edge-room"
    var key = ""

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "thread-edge-owner@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "thread-edge", name: "Thread Edge", ownerId: ownerId)
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "ThreadEdgeBot", creatorUserId: ownerId, runtime: "claude")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId, type: "channel")
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: channelName, humanIds: [ownerId], agentIds: [agentId])
        key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "thread-edge")
    }
}

private func edgeSend(_ client: any Client, key: String, target: String, content: String, seen: Int) async throws -> (ClientResponse, [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    let data = try JSONSerialization.data(withJSONObject: ["target": target, "content": content, "seenUpToSeq": seen])
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
        request.body = .init(data: data)
    }
    return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
}

@Test func threadEdgeCasesReuseCloakAndRequireMembership() async throws {
    var fixture = ThreadEdgeFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let parent = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: fixture.ownerId, content: "opened thread parent")
    let parentSeq = accounts.messageSeqForTesting(messageId: parent) ?? 0
    let existingThread = accounts.oauth.createThreadChannel(parentChannelId: fixture.channelId, parentMessageId: parent)
    accounts.addThreadChannel(serverId: fixture.serverId, threadChannelId: existingThread, parentChannelId: fixture.channelId, parentMessageId: parent, memberId: fixture.ownerId)
    accounts.addPostableChannel(serverId: fixture.serverId, channelId: existingThread, memberId: fixture.agentId, kind: "thread", parentChannelId: fixture.channelId, parentMessageId: parent, name: "thread")

    let privateChannelId = accounts.oauth.createChannel(serverId: fixture.serverId, name: "hidden-thread-parent", creatorUserId: fixture.ownerId, type: "private")
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: fixture.ownerId)
    let hiddenParent = accounts.addHumanMessageForTesting(channelId: privateChannelId, senderId: fixture.ownerId, content: "hidden private parent")
    let hiddenSeq = accounts.messageSeqForTesting(messageId: hiddenParent) ?? 0

    let dmId = accounts.seedDMForTesting(serverId: fixture.serverId, humanUserId: fixture.ownerId, agentId: fixture.agentId)
    let dmParent = accounts.addHumanMessageForTesting(channelId: dmId, senderId: fixture.ownerId, content: "fresh DM thread parent")
    let dmSeq = accounts.messageSeqForTesting(messageId: dmParent) ?? 0

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let reused = try await edgeSend(client, key: fixture.key, target: "#\(fixture.channelName):\(parent.prefix(8))", content: "reply in opened empty thread", seen: parentSeq)
            #expect(reused.0.status == .ok)
            let reusedId = try #require(reused.1["messageId"] as? String)
            #expect(accounts.messageChannelIdForTesting(messageId: reusedId) == existingThread)

            let privateTarget = "#hidden-thread-parent:\(hiddenParent.prefix(8))"
            let cloaked = try await edgeSend(client, key: fixture.key, target: privateTarget, content: "should cloak", seen: hiddenSeq)
            #expect(cloaked.0.status == .notFound)
            #expect(((cloaked.1["error"] as? String) ?? "").contains("Thread target not found or not replyable"))

            let missing = try await edgeSend(client, key: fixture.key, target: "#\(fixture.channelName):deadbeef", content: "missing parent", seen: 0)
            #expect(missing.0.status == .notFound)
            #expect(((missing.1["error"] as? String) ?? "").contains("parent message must exist"))

            let dmReply = try await edgeSend(client, key: fixture.key, target: "dm:@thread-edge-owner:\(dmParent.prefix(8))", content: "first DM thread reply", seen: dmSeq)
            #expect(dmReply.0.status == .ok)
            let dmReplyId = try #require(dmReply.1["messageId"] as? String)
            let dmThreadChannel = try #require(accounts.messageChannelIdForTesting(messageId: dmReplyId))
            #expect(dmThreadChannel != dmId)
            #expect(accounts.oauth.channelType(id: dmThreadChannel) == "thread")
            let followers = accounts.threadFollowerIdsForTesting(threadChannelId: dmThreadChannel)
            #expect(followers.contains(fixture.ownerId))
            #expect(followers.contains(fixture.agentId))

            var outsider = EmailLoginDirectory()
            outsider.oauth.addOwnedServer(id: "33333333-3333-4333-8333-000001112002", slug: "outsider", name: "Outsider", ownerId: fixture.ownerId)
            _ = outsider
        }
    }
}
