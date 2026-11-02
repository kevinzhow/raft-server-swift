import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func followedListReadsOnlyThreadFollowsAndSurvivesParentMembership() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001014001"
    let ownerId = "11111111-1111-4111-8111-000001014001"
    let memberId = "11111111-1111-4111-8111-000001014002"
    let memberEmail = "follow-list-member@slock.test"
    accounts.addAccount(id: ownerId, email: "follow-list-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: memberEmail, password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "follow-list", name: "Follow List", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "follow-list-room", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "follow-list-room")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parent = accounts.addChannelMessageForTesting(channelId: channel, content: "parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: channel, parentMessageId: parent, name: "thread")
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: memberId, kind: "thread", parentChannelId: channel, parentMessageId: parent, name: "thread")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(memberEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func followed() async throws -> [String] {
                let response = try await client.get(URI(string: "/api/channels/threads/followed"), headers: headers)
                #expect(response.status == .ok)
                return ((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []).compactMap { $0["threadChannelId"] as? String }
            }
            func mutate(_ path: String, _ body: String) async throws {
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/channels/threads/\(path)")) { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .ok)
            }

            #expect(try await followed().isEmpty)
            try await mutate("follow", "{\"parentMessageId\":\"\(parent)\"}")
            #expect(try await followed() == [thread])
            try await mutate("done", "{\"threadChannelId\":\"\(thread)\",\"throughActivitySeq\":\"1\",\"frontierSpace\":\"storage\"}")
            #expect(try await followed().isEmpty)
            try await mutate("undone", "{\"threadChannelId\":\"\(thread)\",\"frontierSpace\":\"storage\"}")
            #expect(try await followed() == [thread])
            try await mutate("unfollow", "{\"threadChannelId\":\"\(thread)\"}")
            #expect(try await followed().isEmpty)
            #expect(accounts.channelMemberIds(channelId: channel).contains(memberId))
        }
    }
}
