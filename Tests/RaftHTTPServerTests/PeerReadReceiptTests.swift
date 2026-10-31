import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelDetailExposesOnlyAgentPeerReadStatesWhenEnabled() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111495"
    let memberId = "11111111-1111-4111-8111-111111111496"
    let serverId = "33333333-3333-4333-8333-333333333592"
    accounts.addAccount(id: ownerId, email: "receipts-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "receipts-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "receipts", name: "Receipts", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "receipts-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "receipts-room")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "receipts-agent")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    accounts.setAgentReadCursorForTesting(agentId: agent, channelId: channel, seq: 7)

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
                request.body = .init(string: "{\"email\":\"receipts-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let disabled = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)")
            let disabledBody = try JSONSerialization.jsonObject(with: Data((disabled.body.string ?? "").utf8)) as? [String: Any]
            #expect(disabledBody?["peerReadStates"] == nil)

            accounts.enableReadReceiptsForServer(serverId)
            let enabled = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)")
            let enabledBody = try JSONSerialization.jsonObject(with: Data((enabled.body.string ?? "").utf8)) as? [String: Any]
            let peers = enabledBody?["peerReadStates"] as? [[String: Any]] ?? []
            #expect(peers.count == 1)
            #expect(peers.first?["peerKind"] as? String == "agent")
            #expect(peers.first?["peerId"] as? String == agent)
            #expect(peers.first?["maxReadSeq"] as? Int == 7)
            #expect(!peers.contains { $0["peerKind"] as? String == "human" })

            accounts.oauth.removeChannelAgent(channelId: channel, agentId: agent)
            let afterRemoval = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)")
            let afterBody = try JSONSerialization.jsonObject(with: Data((afterRemoval.body.string ?? "").utf8)) as? [String: Any]
            #expect((afterBody?["peerReadStates"] as? [[String: Any]] ?? []).isEmpty)
        }
    }
}
