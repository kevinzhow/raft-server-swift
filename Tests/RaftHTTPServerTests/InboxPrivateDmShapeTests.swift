import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func inboxProjectsPrivateChannelsDmKindAndPrivateThreadParents() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001013001"
    let ownerId = "11111111-1111-4111-8111-000001013001"
    let peerId = "11111111-1111-4111-8111-000001013002"
    let ownerEmail = "private-inbox-owner@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (peerId, "private-inbox-peer@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "private-inbox", name: "Private Inbox", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "private-inbox-room", creatorUserId: ownerId, type: "private")
    for id in [ownerId, peerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: id, kind: "private", name: "private-inbox-room")
        accounts.oauth.addChannelHuman(channelId: privateChannel, userId: id)
    }
    let ordinary = accounts.oauth.createMessageRecord(channelId: privateChannel, content: "ordinary private activity", senderId: peerId)
    let mention = accounts.oauth.createMessageRecord(channelId: privateChannel, content: "private mention for owner", senderId: peerId)
    accounts.addStoredMentionForTesting(channelId: privateChannel, messageId: mention.id, targetId: ownerId, handle: "owner")
    let parent = accounts.oauth.createMessageRecord(channelId: privateChannel, content: "private parent with thread", senderId: peerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: privateChannel, parentMessageId: parent.id)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: privateChannel, parentMessageId: parent.id, name: "thread")
    accounts.oauth.addChannelHuman(channelId: thread, userId: ownerId)
    let reply = accounts.oauth.createMessageRecord(channelId: thread, content: "private thread reply", senderId: peerId)
    accounts.followThreadForTesting(serverId: serverId, userId: ownerId, threadChannelId: thread, parentMessageId: parent.id)

    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    accounts.addDirectMessage(serverId: serverId, channelId: dm, participantIds: [ownerId, peerId])
    let dmMessage = accounts.oauth.createMessageRecord(channelId: dm, content: "dm activity still appears", senderId: peerId)

    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: privateChannel, messageId: ordinary.id)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: thread, messageId: reply.id)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: dm, messageId: dmMessage.id)

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

            let all = try await client.get(URI(string: "/api/channels/inbox?filter=all&limit=30"), headers: headers)
            let items = (try JSONSerialization.jsonObject(with: Data((all.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let privateItem = try #require(items.first { $0["kind"] as? String == "channel" && $0["channelId"] as? String == privateChannel })
            #expect(privateItem["channelType"] as? String == "private")
            #expect(privateItem["firstUnreadMessageId"] as? String == ordinary.id)
            #expect(privateItem["firstMentionMessageId"] as? String == mention.id)
            #expect(privateItem["hasMention"] as? Bool == true)

            let dmItem = try #require(items.first { $0["kind"] as? String == "dm" && $0["channelId"] as? String == dm })
            #expect(dmItem["channelType"] as? String == "dm")
            #expect(dmItem["lastMessageId"] as? String == dmMessage.id)

            let threadItem = try #require(items.first { $0["kind"] as? String == "thread" && $0["threadChannelId"] as? String == thread })
            #expect(threadItem["parentChannelType"] as? String == "private")
            #expect(threadItem["latestActivityMessageId"] as? String == reply.id)

            let mentions = try await client.get(URI(string: "/api/channels/inbox?filter=mentions&limit=30"), headers: headers)
            let mentionItems = (try JSONSerialization.jsonObject(with: Data((mentions.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            #expect(mentionItems.contains { $0["kind"] as? String == "channel" && $0["channelId"] as? String == privateChannel })
        }
    }
}
