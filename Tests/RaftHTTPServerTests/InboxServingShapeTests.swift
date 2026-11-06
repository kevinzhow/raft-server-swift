import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func inboxServingPageAggregatesScopesAndPaginates() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111624"
    let peerId = "11111111-1111-4111-8111-111111111625"
    let serverId = "33333333-3333-4333-8333-333333333669"
    accounts.addAccount(id: ownerId, email: "inbox-serving@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "inbox-serving-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inbox-serving", name: "Inbox Serving", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")

    let parent = accounts.oauth.createChannel(serverId: serverId, name: "inbox-parent", creatorUserId: ownerId)
    let thread = accounts.oauth.createChannel(serverId: serverId, name: "inbox-thread", creatorUserId: ownerId, type: "thread")
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "inbox-parent")
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, parentMessageId: "parent-message", name: "inbox-thread")
    accounts.addPostableChannel(serverId: serverId, channelId: dm, memberId: ownerId, kind: "dm", name: "")

    let firstParent = accounts.oauth.createMessageRecord(channelId: parent, content: "first parent activity", senderId: peerId)
    let secondParent = accounts.oauth.createMessageRecord(channelId: parent, content: "second parent activity", senderId: peerId)
    let threadReply = accounts.oauth.createMessageRecord(channelId: thread, content: "thread reply activity", senderId: peerId)
    let dmReply = accounts.oauth.createMessageRecord(channelId: dm, content: "dm activity", senderId: peerId)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: parent, messageId: firstParent.id)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: parent, messageId: secondParent.id)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: thread, messageId: threadReply.id)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: dm, messageId: dmReply.id)
    accounts.addStoredMentionForTesting(channelId: parent, messageId: firstParent.id, targetId: ownerId)
    accounts.followThreadForTesting(serverId: serverId, userId: ownerId, threadChannelId: thread, parentMessageId: "parent-message")

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
                request.body = .init(string: "{\"email\":\"inbox-serving@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            func inbox(_ query: String = "") async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: URI(string: "/api/channels/inbox\(query)"))
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let all = try await inbox()
            #expect(Set(all.keys) == ["items", "hasMore", "totalCount", "totalUnreadCount", "activeUnreadCount", "groups"])
            #expect(all["totalCount"] as? Int == 3)
            #expect(all["totalUnreadCount"] as? Int == 4)
            #expect(all["activeUnreadCount"] as? Int == 4)
            #expect(all["hasMore"] as? Bool == false)
            let items = all["items"] as? [[String: Any]] ?? []
            #expect(items.count == 3)
            let parentItem = items.first { $0["channelId"] as? String == parent }
            #expect(parentItem?["kind"] as? String == "channel")
            #expect(parentItem?["lastMessageId"] as? String == secondParent.id)
            #expect(parentItem?["firstUnreadMessageId"] as? String == firstParent.id)
            #expect(parentItem?["firstMentionMessageId"] as? String == firstParent.id)
            #expect(parentItem?["unreadCount"] as? Int == 2)
            #expect(parentItem?["hasMention"] as? Bool == true)
            let threadItem = items.first { $0["threadChannelId"] as? String == thread }
            #expect(threadItem?["kind"] as? String == "thread")
            #expect(threadItem?["parentChannelId"] as? String == parent)
            #expect(threadItem?["latestActivityMessageId"] as? String == threadReply.id)
            #expect(threadItem?["firstMentionMessageId"] is NSNull)
            #expect(threadItem?["isFollowing"] as? Bool == true)
            let groups = all["groups"] as? [[String: Any]] ?? []
            #expect(groups.count == 2)
            #expect(groups.first { $0["channelId"] as? String == parent }?["count"] as? Int == 2)
            #expect(groups.first { $0["channelId"] as? String == dm }?["channelType"] as? String == "dm")

            let limited = try await inbox("?limit=1")
            #expect((limited["items"] as? [[String: Any]] ?? []).count == 1)
            #expect(limited["hasMore"] as? Bool == true)
            #expect(limited["totalCount"] as? Int == 3)
            #expect(limited["totalUnreadCount"] as? Int == 4)
            #expect((limited["groups"] as? [[String: Any]] ?? []).count == 2)

            let parentOnly = try await inbox("?channelId=\(parent)")
            #expect((parentOnly["items"] as? [[String: Any]] ?? []).count == 2)
            #expect(parentOnly["totalCount"] as? Int == 2)
            #expect(parentOnly["totalUnreadCount"] as? Int == 3)

            let searched = try await inbox("?q=thread%20reply")
            #expect((searched["items"] as? [[String: Any]] ?? []).count == 1)
            #expect(searched["totalCount"] as? Int == 1)

            let unreadMentions = try await inbox("?filter=unread_mentions")
            #expect((unreadMentions["items"] as? [[String: Any]] ?? []).map { $0["channelId"] as? String } == [parent])
            #expect(unreadMentions["totalUnreadCount"] as? Int == 2)
            #expect(unreadMentions["activeUnreadCount"] as? Int == 4)

            let read = try await client.send(.post, headers: headers, to: "/api/channels/\(parent)/read-all") { request in
                request.body = .init(string: "{}")
            }
            #expect(read.status == .ok)
            let mentionsAfterRead = try await inbox("?filter=mentions")
            #expect((mentionsAfterRead["items"] as? [[String: Any]] ?? []).contains { $0["channelId"] as? String == parent })
            let unreadMentionsAfterRead = try await inbox("?filter=unread_mentions")
            #expect(!((unreadMentionsAfterRead["items"] as? [[String: Any]] ?? []).contains { $0["channelId"] as? String == parent }))
        }
    }
}
