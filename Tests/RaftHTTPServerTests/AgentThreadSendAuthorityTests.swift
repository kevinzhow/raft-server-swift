import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentThreadSendRequiresParentChannelMembership() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111560"
    let serverId = "33333333-3333-4333-8333-333333333627"
    accounts.addAccount(id: ownerId, email: "agent-send-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-send", name: "Agent Send", ownerId: ownerId)
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "agent-send-parent", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "agent-send-parent")
    let parentMessageId = UUID().uuidString.lowercased()
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: parentMessageId)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, parentMessageId: parentMessageId, name: "thread")
    let memberAgent = accounts.oauth.createAgent(serverId: serverId, name: "member-agent")
    accounts.oauth.addChannelAgent(channelId: parent, agentId: memberAgent)
    let followerAgent = accounts.oauth.createAgent(serverId: serverId, name: "follower-agent")
    accounts.oauth.addChannelAgent(channelId: thread, agentId: followerAgent)
    let memberKey = accounts.registerMachineForAgent(serverId: serverId, agentId: memberAgent)
    let followerKey = accounts.registerMachineForAgent(serverId: serverId, agentId: followerAgent)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func send(_ key: String, _ agent: String) async throws -> Int {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/internal/agent/\(agent)/send") { request in
                    request.body = .init(string: "{\"target\":\"#agent-send-parent:\(parentMessageId.prefix(8))\",\"content\":\"agent reply\"}")
                }
                return response.status.code
            }
            let memberStatus = try await send(memberKey, memberAgent)
            let followerStatus = try await send(followerKey, followerAgent)
            #expect(memberStatus == 200)
            #expect(followerStatus == 403)
        }
    }
}
