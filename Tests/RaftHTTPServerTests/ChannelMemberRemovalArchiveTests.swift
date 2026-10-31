import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func removingChannelMembersIsFrozenWhileArchived() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111476"
    let memberId = "11111111-1111-4111-8111-111111111477"
    let serverId = "33333333-3333-4333-8333-333333333583"
    accounts.addAccount(id: ownerId, email: "removal-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "removal-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "removal-archive", name: "Removal Archive", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

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
                request.body = .init(string: "{\"email\":\"removal-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"removal-room\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, name: "removal-room")
            accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
            let agent = accounts.oauth.createAgent(serverId: serverId, name: "removal-agent")
            accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)

            #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/archive").status == .ok)
            let frozenAgent = try await client.send(.delete, headers: headers, to: "/api/channels/\(channelId)/members/agent/\(agent)")
            #expect(frozenAgent.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((frozenAgent.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "channel_archived")
            let frozenHuman = try await client.send(.delete, headers: headers, to: "/api/channels/\(channelId)/members/user/\(memberId)")
            #expect(frozenHuman.status == .conflict)
            #expect(accounts.oauth.channelHumanIds(channelId: channelId).contains(memberId))

            #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/unarchive").status == .ok)
            #expect(try await client.send(.delete, headers: headers, to: "/api/channels/\(channelId)/members/agent/\(agent)").status == .ok)
            #expect(!accounts.oauth.channelAgentIds(channelId: channelId).contains(agent))
            #expect(try await client.send(.delete, headers: headers, to: "/api/channels/\(channelId)/members/user/\(memberId)").status == .ok)
            #expect(!accounts.oauth.channelHumanIds(channelId: channelId).contains(memberId))
        }
    }
}
