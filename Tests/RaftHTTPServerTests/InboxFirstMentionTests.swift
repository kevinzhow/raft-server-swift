import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func inboxFirstMentionIsTheEarliestUnreadMentionAndAdvancesWithReadState() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001008001"
    let ownerId = "11111111-1111-4111-8111-000001008001"
    let authorId = "11111111-1111-4111-8111-000001008002"
    let ownerEmail = "first-mention-owner@slock.test"
    let authorEmail = "first-mention-author@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (authorId, authorEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "first-mention", name: "First Mention", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: authorId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "first-mention", creatorUserId: ownerId)
    for id in [ownerId, authorId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "first-mention")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let early = accounts.oauth.createMessageRecord(channelId: channel, content: "earlier unread, no mention", senderId: authorId)
    let mention = accounts.oauth.createMessageRecord(channelId: channel, content: "later message that mentions owner", senderId: authorId)
    let later = accounts.oauth.createMessageRecord(channelId: channel, content: "even later, still no mention", senderId: authorId)
    accounts.addStoredMentionForTesting(channelId: channel, messageId: mention.id, targetId: ownerId, handle: "owner")
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: channel, messageId: early.id)

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
            func row() async throws -> [String: Any] {
                let response = try await client.get(URI(string: "/api/channels/inbox?filter=all"), headers: headers)
                let items = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
                return try #require(items.first { $0["kind"] as? String == "channel" && $0["channelId"] as? String == channel })
            }

            let initial = try await row()
            #expect(initial["hasMention"] as? Bool == true)
            #expect(initial["firstUnreadMessageId"] as? String == early.id)
            #expect(initial["firstMentionMessageId"] as? String == mention.id)
            #expect(initial["firstMentionMessageId"] as? String != later.id)

            accounts.oauth.setChannelReadCursor(channelId: channel, userId: ownerId, seq: 2)
            let advanced = try await row()
            #expect(advanced["firstMentionMessageId"] is NSNull)
        }
    }
}

@Test func inboxMentionOnlyRowAnchorsTheMentionWithoutUnread() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001008002"
    let ownerId = "11111111-1111-4111-8111-000001008001"
    let authorId = "11111111-1111-4111-8111-000001008002"
    let ownerEmail = "mention-only-owner@slock.test"
    let authorEmail = "mention-only-author@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (authorId, authorEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-only", name: "Mention Only", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: authorId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "mention-only-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: authorId, name: "mention-only-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: authorId)
    let message = accounts.oauth.createMessageRecord(channelId: channel, content: "public mention in a room I am not in", senderId: authorId)
    accounts.addStoredMentionForTesting(channelId: channel, messageId: message.id, targetId: ownerId, handle: "owner")
    accounts.oauth.setChannelReadCursor(channelId: channel, userId: ownerId, seq: message.seq)

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
            let response = try await client.get(URI(string: "/api/channels/inbox?filter=all"), headers: headers)
            let items = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let row = try #require(items.first { $0["kind"] as? String == "channel" && $0["channelId"] as? String == channel })
            #expect(row["unreadCount"] as? Int == 0)
            #expect(row["hasMention"] as? Bool == true)
            #expect(row["firstMentionMessageId"] as? String == message.id)
        }
    }
}
