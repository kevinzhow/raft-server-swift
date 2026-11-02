import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentMessageResolveProjectsJointStorageToTheLocalChannel() async throws {
    let accounts = EmailLoginDirectory()
    let hostServer = "33333333-3333-4333-8333-000001033001"
    let peerServer = "33333333-3333-4333-8333-000001033002"
    let hostOwner = "11111111-1111-4111-8111-000001033001"
    let peerOwner = "11111111-1111-4111-8111-000001033002"
    accounts.addAccount(id: hostOwner, email: "joint-resolve-host@slock.test", password: "password123")
    accounts.markEmailVerified(userId: hostOwner)
    accounts.addAccount(id: peerOwner, email: "joint-resolve-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerOwner)
    accounts.oauth.addOwnedServer(id: hostServer, slug: "joint-resolve-host", name: "Joint Resolve Host", ownerId: hostOwner)
    accounts.oauth.addOwnedServer(id: peerServer, slug: "joint-resolve-peer", name: "Joint Resolve Peer", ownerId: peerOwner)
    let canonical = accounts.oauth.createChannel(serverId: hostServer, name: "joint-resolve-storage", creatorUserId: hostOwner)
    accounts.addPostableChannel(serverId: hostServer, channelId: canonical, memberId: hostOwner, name: "joint-resolve-storage")
    accounts.oauth.addChannelHuman(channelId: canonical, userId: hostOwner)
    let hostProjection = accounts.oauth.createChannel(serverId: hostServer, name: "joint-room", creatorUserId: hostOwner, type: "joint")
    accounts.addPostableChannel(serverId: hostServer, channelId: hostProjection, memberId: hostOwner, kind: "joint", name: "joint-room")
    accounts.oauth.addChannelHuman(channelId: hostProjection, userId: hostOwner)
    let peerProjection = accounts.oauth.createChannel(serverId: peerServer, name: "joint-room", creatorUserId: peerOwner, type: "joint")
    accounts.addPostableChannel(serverId: peerServer, channelId: peerProjection, memberId: peerOwner, kind: "joint", name: "joint-room")
    accounts.oauth.addChannelHuman(channelId: peerProjection, userId: peerOwner)
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: canonical, serverId: hostServer)
    accounts.addJointChannelProjection(localChannelId: peerProjection, canonicalChannelId: canonical, serverId: peerServer)
    let message = "eeeeeeee-1111-4111-8111-111111111111"
    _ = accounts.addChannelMessageForTesting(id: message, channelId: canonical, content: "joint storage resolve target", senderId: hostOwner)
    let agent = accounts.oauth.createAgent(serverId: peerServer, name: "JointResolveBot", runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "joint")

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
            let response = try await client.get(URI(string: "/internal/agent-api/messages/eeeeeeee/resolve"), headers: headers)
            #expect(response.status == .ok)
            let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let resolved = try #require(body["message"] as? [String: Any])
            #expect(resolved["message_id"] as? String == message)
            #expect(resolved["channel_id"] as? String == peerProjection)
            #expect(resolved["channel_name"] as? String == "joint-room")
            #expect(resolved["channel_type"] as? String == "channel")
            #expect(resolved["content"] as? String == "joint storage resolve target")
        }
    }
}
