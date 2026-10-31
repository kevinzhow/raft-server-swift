import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelMemberRoutesAddAndRemoveAgentsWhileLegacyRoutesStayGone() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111332"
    let serverId = "33333333-3333-4333-8333-333333333498"
    accounts.addAccount(id: ownerId, email: "members-mutate@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "member-mutate", name: "Member Mutate", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "member-mutate-room", creatorUserId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "member-mutate-agent")
    let otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "member-mutate-other")

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
                request.body = .init(string: "{\"email\":\"members-mutate@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let legacyAdd = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/agents") { request in
                request.body = .init(string: "{\"agentId\":\"\(otherAgentId)\"}")
            }
            #expect(legacyAdd.status == .notFound)
            let legacyRemove = try await client.send(.delete, headers: headers, to: "/api/channels/\(channelId)/agents/\(agentId)")
            #expect(legacyRemove.status == .notFound)

            let added = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/members") { request in
                request.body = .init(string: "{\"agentId\":\"\(otherAgentId)\"}")
            }
            #expect(added.status == .ok)
            #expect(accounts.oauth.channelAgentIds(channelId: channelId).contains(otherAgentId))

            accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            let removed = try await client.send(.delete, headers: headers, to: "/api/channels/\(channelId)/members/agent/\(otherAgentId)")
            #expect(removed.status == .ok)
            #expect(accounts.oauth.channelAgentIds(channelId: channelId) == [agentId])
        }
    }
}
