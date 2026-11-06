import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentChannelsListViewerVisibleMemberships() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111565"
    let serverId = "33333333-3333-4333-8333-333333333630"
    accounts.addAccount(id: ownerId, email: "agent-channels-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-channels", name: "Agent Channels", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "channels-agent")
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "alpha-public", creatorUserId: ownerId)
    accounts.oauth.updateChannel(id: publicChannel, name: nil, description: "visible public channel", systemMessage: nil)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "beta-private", creatorUserId: ownerId, type: "private")
    accounts.oauth.setChannelType(id: privateChannel, type: "private")
    let jointChannel = accounts.oauth.createChannel(serverId: serverId, name: "gamma-joint", creatorUserId: ownerId, type: "joint")
    accounts.oauth.setChannelType(id: jointChannel, type: "joint")
    let hiddenPrivate = accounts.oauth.createChannel(serverId: serverId, name: "delta-hidden-private", creatorUserId: ownerId, type: "private")
    accounts.oauth.setChannelType(id: hiddenPrivate, type: "private")
    for channel in [publicChannel, privateChannel, jointChannel, hiddenPrivate] {
        accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    }
    for channel in [privateChannel, jointChannel] {
        accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    }
    accounts.oauth.setActivityMuted(channelId: privateChannel, userId: agent, muted: true)
    let parentMessageId = UUID().uuidString.lowercased()
    let thread = accounts.oauth.createThreadChannel(parentChannelId: publicChannel, parentMessageId: parentMessageId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: ownerId, name: "alpha-public")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private", name: "beta-private")
    accounts.addPostableChannel(serverId: serverId, channelId: jointChannel, memberId: ownerId, kind: "joint", name: "gamma-joint")
    accounts.oauth.addChannelAgent(channelId: thread, agentId: agent)

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
                request.body = .init(string: "{\"email\":\"agent-channels-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: "/api/agents/\(agent)/channels")
            #expect(response.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let byName = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
                guard let name = row["name"] as? String else { return nil }
                return (name, row)
            })
            #expect(byName["alpha-public"]?["type"] as? String == "channel")
            #expect(byName["alpha-public"]?["description"] as? String == "visible public channel")
            #expect(byName["beta-private"]?["type"] as? String == "private")
            #expect(byName["beta-private"]?["activityMuted"] as? Bool == true)
            #expect(byName["gamma-joint"]?["type"] as? String == "joint")
            #expect(byName["gamma-joint"]?["description"] == nil || byName["gamma-joint"]?["description"] is NSNull)
            #expect(byName["delta-hidden-private"] == nil)
            #expect(!rows.contains { $0["id"] as? String == thread })
            #expect(!rows.contains { $0["name"] as? String == "all" })
            #expect(rows.allSatisfy { $0["createdAt"] is String })
        }
    }
}
