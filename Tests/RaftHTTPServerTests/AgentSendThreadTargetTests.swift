import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ThreadSendFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001108001"
    let ownerId = "11111111-1111-4111-8111-000001108001"
    var agentId = ""
    var channelId = ""
    var channelName = "thread-send-room"
    var key = ""

    mutating func seed() {
        accounts.addAccount(id: ownerId, email: "thread-send-owner@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "thread-send", name: "Thread Send", ownerId: ownerId)
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "ThreadBot", creatorUserId: ownerId, runtime: "claude")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId, type: "channel")
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: channelName, humanIds: [ownerId], agentIds: [agentId])
        key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "thread-send")
    }
}

private func threadSend(_ client: any Client, _ fixture: ThreadSendFixture, _ target: String, _ content: String, seen: Int) async throws -> (ClientResponse, [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.key)"
    headers[.contentType] = "application/json"
    let body = try JSONSerialization.data(withJSONObject: ["target": target, "content": content, "seenUpToSeq": seen])
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
        request.body = .init(data: body)
    }
    return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
}

@Test func threadTargetsCreateAndJoinTheRightThread() async throws {
    var fixture = ThreadSendFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let parent = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: fixture.ownerId, content: "fresh thread parent")
    let parentSeq = accounts.messageSeqForTesting(messageId: parent) ?? 0
    let parent2 = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: fixture.ownerId, content: "threadId-target parent")
    let parent2Seq = accounts.messageSeqForTesting(messageId: parent2) ?? 0
    let existingThread = accounts.oauth.createThreadChannel(parentChannelId: fixture.channelId, parentMessageId: parent2)
    accounts.addThreadChannel(serverId: fixture.serverId, threadChannelId: existingThread, parentChannelId: fixture.channelId, parentMessageId: parent2, memberId: fixture.ownerId)
    accounts.addPostableChannel(serverId: fixture.serverId, channelId: existingThread, memberId: fixture.agentId, kind: "thread", parentChannelId: fixture.channelId, parentMessageId: parent2, name: "thread")

    let systemParent = accounts.addHumanMessageForTesting(channelId: fixture.channelId, senderId: "system", content: "system thread parent", messageType: "system", senderType: "system")
    let systemSeq = accounts.messageSeqForTesting(messageId: systemParent) ?? 0
    let systemThread = accounts.oauth.createThreadChannel(parentChannelId: fixture.channelId, parentMessageId: systemParent)
    accounts.addThreadChannel(serverId: fixture.serverId, threadChannelId: systemThread, parentChannelId: fixture.channelId, parentMessageId: systemParent, memberId: fixture.ownerId)
    accounts.addPostableChannel(serverId: fixture.serverId, channelId: systemThread, memberId: fixture.agentId, kind: "thread", parentChannelId: fixture.channelId, parentMessageId: systemParent, name: "thread")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let fresh = try await threadSend(client, fixture, "#\(fixture.channelName):\(parent.prefix(8))", "first thread reply", seen: parentSeq)
            #expect(fresh.0.status == .ok)
            #expect(fresh.1["state"] as? String == "sent")
            let freshId = try #require(fresh.1["messageId"] as? String)
            let freshChannel = try #require(accounts.messageChannelIdForTesting(messageId: freshId))
            #expect(freshChannel != fixture.channelId)
            #expect(accounts.oauth.channelType(id: freshChannel) == "thread")

            let joined = try await threadSend(client, fixture, "#\(fixture.channelName):\(existingThread.prefix(8))", "reply via threadId", seen: parent2Seq)
            #expect(joined.0.status == .ok)
            let joinedId = try #require(joined.1["messageId"] as? String)
            #expect(accounts.messageChannelIdForTesting(messageId: joinedId) == existingThread)

            let systemReply = try await threadSend(client, fixture, "#\(fixture.channelName):\(systemParent.prefix(8))", "reply to system thread", seen: systemSeq)
            #expect(systemReply.0.status == .ok)
            let systemReplyId = try #require(systemReply.1["messageId"] as? String)
            let systemReplyChannel = try #require(accounts.messageChannelIdForTesting(messageId: systemReplyId))
            #expect(accounts.oauth.channelType(id: systemReplyChannel) == "thread")
            let followers = accounts.threadFollowerIdsForTesting(threadChannelId: existingThread)
            #expect(!followers.contains("system"))
        }
    }
}
