import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func unreadSummaryFoldsFollowedThreadsOntoParentChannels() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000970001"
    let ownerId = "11111111-1111-4111-8111-000000970001"
    let replierId = "11111111-1111-4111-8111-000000970002"
    let ownerEmail = "thread-unread-owner@slock.test"
    let replierEmail = "thread-unread-replier@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (replierId, replierEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-unread", name: "Thread Unread", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: replierId, role: "member")
    let quiet = accounts.oauth.createChannel(serverId: serverId, name: "thread-unread-quiet", creatorUserId: ownerId)
    let other = accounts.oauth.createChannel(serverId: serverId, name: "thread-unread-other", creatorUserId: ownerId)
    for channel in [quiet, other] {
        for id in [ownerId, replierId] {
            accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "thread-unread")
            accounts.oauth.addChannelHuman(channelId: channel, userId: id)
        }
    }

    func makeThread(_ channelId: String, _ label: String) -> (parent: String, thread: String) {
        let parent = accounts.addChannelMessageForTesting(channelId: channelId, content: "\(label) parent", senderId: ownerId)
        let thread = accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parent)
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: thread,
            memberId: ownerId,
            kind: "thread",
            parentChannelId: channelId,
            parentMessageId: parent,
            name: "thread"
        )
        accounts.oauth.addChannelHuman(channelId: thread, userId: ownerId)
        return (parent, thread)
    }

    let mentioned = makeThread(quiet, "mentioned")
    let plain = makeThread(quiet, "plain")
    let allRead = makeThread(quiet, "all read")
    let done = makeThread(quiet, "done")
    let notFollowed = makeThread(quiet, "not followed")
    let otherThread = makeThread(other, "other")
    for item in [mentioned, plain, allRead, done, otherThread] {
        accounts.followThreadForTesting(serverId: serverId, userId: ownerId, threadChannelId: item.thread, parentMessageId: item.parent)
    }

    let mention = accounts.addChannelMessageForTesting(channelId: mentioned.thread, content: "@thread-unread-owner look", senderId: replierId)
    accounts.addMessageMention(messageId: mention, targetType: "user", targetId: ownerId)
    _ = accounts.addChannelMessageForTesting(channelId: plain.thread, content: "plain reply", senderId: replierId)
    let readReply = accounts.addChannelMessageForTesting(channelId: allRead.thread, content: "read reply", senderId: replierId)
    accounts.oauth.setChannelReadCursor(channelId: allRead.thread, userId: ownerId, seq: accounts.humanMessageSequence(id: readReply) ?? 1)
    _ = accounts.addChannelMessageForTesting(channelId: done.thread, content: "reply in a done thread", senderId: replierId)
    _ = accounts.addChannelMessageForTesting(channelId: notFollowed.thread, content: "reply in an unfollowed thread", senderId: replierId)
    _ = accounts.addChannelMessageForTesting(channelId: otherThread.thread, content: "reply under the other channel", senderId: replierId)
    _ = accounts.addChannelMessageForTesting(channelId: otherThread.thread, content: "second reply, still one thread", senderId: replierId)
    _ = readReply

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
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let doneResponse = try await client.send(.post, headers: headers, to: "/api/channels/threads/done") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(done.thread)\"}")
            }
            #expect(doneResponse.status == .ok)

            let summaryResponse = try await client.send(.get, headers: headers, to: "/api/channels/unread?summary=1")
            #expect(summaryResponse.status == .ok)
            let summary = (try JSONSerialization.jsonObject(with: Data((summaryResponse.body.string ?? "").utf8)) as? [String: Any]) ?? [:]
            let threadUnread = summary["threadUnread"] as? [String: Any] ?? [:]
            let quietFold = threadUnread[quiet] as? [String: Any]
            #expect(quietFold?["count"] as? Int == 2)
            #expect(quietFold?["hasMention"] as? Bool == true)
            let otherFold = threadUnread[other] as? [String: Any]
            #expect(otherFold?["count"] as? Int == 1)
            #expect(otherFold?["hasMention"] as? Bool == false)

            let channels = summary["channels"] as? [String: Any] ?? [:]
            #expect(channels[quiet] == nil)
            let mentionedEntry = channels[mentioned.thread] as? [String: Any]
            #expect(mentionedEntry?["parentChannelId"] as? String == quiet)
            #expect(mentionedEntry?["hasMention"] as? Bool == true)
            let otherEntry = channels[otherThread.thread] as? [String: Any]
            #expect(otherEntry?["parentChannelId"] as? String == other)
            #expect(otherEntry?["unreadCount"] as? Int == 2)
            #expect(channels[done.thread] == nil)
            #expect(channels[notFollowed.thread] == nil)
            #expect(channels[allRead.thread] == nil)

            let followedResponse = try await client.send(.get, headers: headers, to: "/api/channels/threads/followed")
            let followed = (try JSONSerialization.jsonObject(with: Data((followedResponse.body.string ?? "").utf8)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []
            let byId = Dictionary(uniqueKeysWithValues: followed.compactMap { row -> (String, [String: Any])? in
                guard let id = row["threadChannelId"] as? String else { return nil }
                return (id, row)
            })
            #expect(byId[mentioned.thread]?["hasMention"] as? Bool == true)
            #expect(byId[mentioned.thread]?["firstUnreadMessageId"] as? String == mention)
            #expect(byId[plain.thread]?["hasMention"] as? Bool == false)
            #expect(byId[allRead.thread]?["hasMention"] as? Bool == false)
            #expect(byId[otherThread.thread]?["parentChannelId"] as? String == other)
        }
    }
}
