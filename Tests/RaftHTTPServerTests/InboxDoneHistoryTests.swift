import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func inboxDoneHistoryListsSearchesSortsAndRestoresBothKinds() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001000001"
    let ownerId = "11111111-1111-4111-8111-000001000001"
    let authorId = "11111111-1111-4111-8111-000001000002"
    let ownerEmail = "done-history-owner@slock.test"
    let authorEmail = "done-history-author@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (authorId, authorEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "done-history", name: "Done History", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: authorId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "done-history", creatorUserId: ownerId)
    for id in [ownerId, authorId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "done-history")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parent = accounts.addChannelMessageForTesting(channelId: channel, content: "thread parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: channel, parentMessageId: parent, name: "thread")
    accounts.followThreadForTesting(serverId: serverId, userId: ownerId, threadChannelId: thread, parentMessageId: parent)

    let channelActivity = accounts.addChannelMessageForTesting(channelId: channel, content: "channel activity that can move between Active and Done", senderId: authorId)
    let threadActivity = accounts.addChannelMessageForTesting(channelId: thread, content: "thread activity that can move between Active and Done", senderId: authorId)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: channel, messageId: channelActivity)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: thread, messageId: threadActivity)

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
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let channelDone = try await client.send(.post, headers: headers, to: "/api/channels/inbox/done") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\"}")
            }
            #expect(channelDone.status == .ok)
            let threadDone = try await client.send(.post, headers: headers, to: "/api/channels/threads/done") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
            }
            #expect(threadDone.status == .ok)

            let done = try await client.get(URI(string: "/api/channels/inbox/done?limit=30"), headers: headers)
            #expect(done.status == .ok)
            let doneBody = (try JSONSerialization.jsonObject(with: Data((done.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let items = doneBody["items"] as? [[String: Any]] ?? []
            #expect(items.contains { $0["kind"] as? String == "channel" && $0["channelId"] as? String == channel })
            #expect(items.contains { $0["kind"] as? String == "thread" && $0["threadChannelId"] as? String == thread })
            #expect(items.allSatisfy { $0["doneAt"] is String })
            #expect(doneBody["hasMore"] as? Bool == false)
            #expect(doneBody["totalCount"] is NSNull)

            func identity(_ item: [String: Any]) -> String {
                item["kind"] as? String == "thread"
                    ? "thread:\(item["threadChannelId"] as? String ?? "")"
                    : "channel:\(item["channelId"] as? String ?? "")"
            }
            let asc = try await client.get(URI(string: "/api/channels/inbox/done?limit=30&sort=asc"), headers: headers)
            let ascItems = (try JSONSerialization.jsonObject(with: Data((asc.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            #expect(ascItems.map(identity) == items.map(identity).reversed())

            let searched = try await client.get(URI(string: "/api/channels/inbox/done?q=thread%20activity"), headers: headers)
            let searchedItems = (try JSONSerialization.jsonObject(with: Data((searched.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            #expect(searchedItems.map { $0["kind"] as? String } == ["thread"])

            let scoped = try await client.get(URI(string: "/api/channels/inbox/done?channelId=\(channel)&q=channel%20activity&limit=1"), headers: headers)
            let scopedBody = (try JSONSerialization.jsonObject(with: Data((scoped.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect((scopedBody["items"] as? [[String: Any]] ?? []).map { $0["channelId"] as? String } == [channel])
            #expect(scopedBody["hasMore"] as? Bool == false)

            let channelUndone = try await client.send(.post, headers: headers, to: "/api/channels/inbox/undone") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\"}")
            }
            #expect(channelUndone.status == .ok)
            let threadUndone = try await client.send(.post, headers: headers, to: "/api/channels/threads/undone") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
            }
            #expect(threadUndone.status == .ok)

            let restored = try await client.get(URI(string: "/api/channels/inbox/done"), headers: headers)
            let restoredItems = (try JSONSerialization.jsonObject(with: Data((restored.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            #expect(!restoredItems.contains { $0["channelId"] as? String == channel || $0["threadChannelId"] as? String == thread })

            let active = try await client.get(URI(string: "/api/channels/inbox?filter=all"), headers: headers)
            let activeItems = (try JSONSerialization.jsonObject(with: Data((active.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            #expect(activeItems.contains { $0["kind"] as? String == "channel" && ($0["channelId"] as? String) == channel })
            #expect(activeItems.contains { $0["kind"] as? String == "thread" && ($0["threadChannelId"] as? String) == thread })
        }
    }
}
