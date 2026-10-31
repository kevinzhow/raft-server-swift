import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func mentionInThreadAutoFollowsTheMentionedHumansAndAgents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111550"
    let memberId = "11111111-1111-4111-8111-111111111551"
    let serverId = "33333333-3333-4333-8333-333333333622"
    accounts.addAccount(id: ownerId, email: "mention-follow-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "mention-follow-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-follow", name: "Mention Follow", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "mention-follow-parent", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "mention-follow-parent")
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: memberId, name: "mention-follow-parent")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "mention-follow-agent")
    accounts.oauth.addChannelAgent(channelId: parent, agentId: agent)
    let parentMessageId = UUID().uuidString.lowercased()
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: parentMessageId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: id, kind: "thread", parentChannelId: parent, parentMessageId: parentMessageId, name: "thread")
    }
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
            func login(_ email: String) async throws -> String {
                let response = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("mention-follow-owner@slock.test")
            let memberToken = try await login("mention-follow-member@slock.test")
            let sent = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"hello @member @agent\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(memberId)\",\"name\":\"member\"},{\"type\":\"agent\",\"id\":\"\(agent)\",\"name\":\"agent\"}]}")
            }
            #expect(sent.status == .ok)
            let followers = accounts.threadFollowerIdsForTesting(threadChannelId: thread)
            #expect(followers.contains(ownerId))
            #expect(followers.contains(memberId))
            #expect(followers.contains(agent))

            let followed = try await client.send(.get, headers: headers(memberToken), to: "/api/channels/threads/followed")
            let body = try JSONSerialization.jsonObject(with: Data((followed.body.string ?? "").utf8)) as? [String: Any]
            #expect((body?["threads"] as? [[String: Any]] ?? []).contains { $0["threadChannelId"] as? String == thread })
        }
    }
}
