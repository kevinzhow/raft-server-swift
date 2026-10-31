import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadMembersUseTheParentChannelRoster() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111547"
    let memberId = "11111111-1111-4111-8111-111111111548"
    let followerId = "11111111-1111-4111-8111-111111111549"
    let serverId = "33333333-3333-4333-8333-333333333621"
    for (id, email) in [
        (ownerId, "thread-members-owner@slock.test"),
        (memberId, "thread-members-member@slock.test"),
        (followerId, "thread-members-follower@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-members", name: "Thread Members", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: followerId, role: "member")
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "parent-room", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: id, name: "parent-room")
        accounts.oauth.addChannelHuman(channelId: parent, userId: id)
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "agent-a")
    accounts.oauth.addChannelAgent(channelId: parent, agentId: agent)
    let parentMessageId = UUID().uuidString.lowercased()
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: parentMessageId)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, parentMessageId: parentMessageId, name: "thread")
    accounts.oauth.addChannelHuman(channelId: thread, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: thread, agentId: agent)
    accounts.followThreadForTesting(serverId: serverId, userId: followerId, threadChannelId: thread, parentMessageId: parentMessageId)
    let key = accounts.registerMachineForAgent(serverId: serverId, agentId: agent)

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
                request.body = .init(string: "{\"email\":\"thread-members-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let roster = try await client.send(.get, headers: headers, to: "/api/channels/\(thread)/members")
            #expect(roster.status == .ok)
            let rosterBody = try JSONSerialization.jsonObject(with: Data((roster.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let humanIds = (rosterBody["humans"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
            let agentIds = (rosterBody["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
            #expect(humanIds == [ownerId, memberId].sorted())
            #expect(agentIds == [agent])
            #expect(!humanIds.contains(followerId))

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(key)"
            let shortId = String(parentMessageId.prefix(8))
            for reference in ["%23parent-room", "%23parent-room%3A\(shortId)"] {
                let response = try await client.send(.get, headers: agentHeaders, to: URI(string: "/internal/agent/\(agent)/channel-members?channel=\(reference)"))
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                let names = (body["humans"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
                #expect(names == ["thread-members-member", "thread-members-owner"])
                #expect(!names.contains("thread-members-follower"))
                let agentNames = (body["agents"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                #expect(agentNames == ["agent-a"])
                let channel = body["channel"] as? [String: Any]
                #expect(channel?["type"] as? String == (reference.contains("%3A") ? "thread" : "channel"))
            }
        }
    }
}
