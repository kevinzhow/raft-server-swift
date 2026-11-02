import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct FollowedPageFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let replierId: String
    let channelId: String
    let threadIds: [String]
    let unreadReplyIds: [String]
    let parentCreatedAt: [String]
}

private func makeFollowedPageFixture() -> FollowedPageFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000960001"
    let ownerId = "11111111-1111-4111-8111-000000960001"
    let replierId = "11111111-1111-4111-8111-000000960002"
    let ownerEmail = "followed-page-owner@slock.test"
    let replierEmail = "followed-page-replier@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (replierId, replierEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "followed-page", name: "Followed Page", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: replierId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "followed-page", creatorUserId: ownerId)
    for id in [ownerId, replierId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "followed-page")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var threadIds: [String] = []
    var replyIds: [String] = []
    var createdAt: [String] = []
    for index in 0..<5 {
        let parent = accounts.addChannelMessageForTesting(
            channelId: channel,
            content: "page parent \(index)",
            senderId: ownerId
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
        accounts.setHumanMessageCreatedAt(messageId: parent, createdAt: date)
        createdAt.append(formatter.string(from: date))
        let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: thread,
            memberId: ownerId,
            kind: "thread",
            parentChannelId: channel,
            parentMessageId: parent,
            name: "thread"
        )
        let reply = accounts.addChannelMessageForTesting(
            channelId: thread,
            content: "page reply \(index)",
            senderId: replierId
        )
        if index % 2 == 1 {
            accounts.oauth.setChannelReadCursor(channelId: thread, userId: ownerId, seq: 1)
        }
        accounts.followThreadForTesting(
            serverId: serverId,
            userId: ownerId,
            threadChannelId: thread,
            parentMessageId: parent
        )
        threadIds.append(thread)
        replyIds.append(reply)
    }
    accounts.addMessageMention(messageId: replyIds[0], targetType: "user", targetId: ownerId)
    return FollowedPageFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        replierId: replierId,
        channelId: channel,
        threadIds: threadIds,
        unreadReplyIds: replyIds,
        parentCreatedAt: createdAt
    )
}

private func followedPageLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func followedPageGet(
    _ client: any Client,
    token: String,
    serverId: String,
    query: String
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return try await client.get(URI(string: "/api/channels/threads/followed\(query)"), headers: headers)
}

private func followedPageObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func followedThreadsPageNewestFirstWithCursorAndUnreadFilter() async throws {
    let fixture = makeFollowedPageFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await followedPageLogin(client, email: fixture.ownerEmail)

            let full = try await followedPageGet(client, token: token, serverId: fixture.serverId, query: "")
            #expect(full.status == .ok)
            let fullBody = try followedPageObject(full)
            let fullThreads = fullBody["threads"] as? [[String: Any]] ?? []
            #expect(fullThreads.count == 5)
            #expect(fullBody["next"] == nil)

            var seen: [String] = []
            var cursor: String?
            for _ in 0..<4 {
                var query = "?limit=2"
                if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                    query += "&cursor=\(encoded)"
                }
                let response = try await followedPageGet(client, token: token, serverId: fixture.serverId, query: query)
                #expect(response.status == .ok)
                let body = try followedPageObject(response)
                seen += (body["threads"] as? [[String: Any]] ?? []).compactMap { $0["threadChannelId"] as? String }
                cursor = body["next"] as? String
                if cursor == nil { break }
            }
            #expect(seen == fixture.threadIds.reversed())
            #expect(cursor == nil)

            let unread = try await followedPageGet(client, token: token, serverId: fixture.serverId, query: "?unreadOnly=1")
            #expect(unread.status == .ok)
            let unreadThreads = try followedPageObject(unread)["threads"] as? [[String: Any]] ?? []
            #expect(Set(unreadThreads.compactMap { $0["threadChannelId"] as? String }) == Set([
                fixture.threadIds[0], fixture.threadIds[2], fixture.threadIds[4],
            ]))
            #expect(unreadThreads.allSatisfy { ($0["unreadCount"] as? Int ?? 0) > 0 })
            for row in unreadThreads {
                guard let id = row["threadChannelId"] as? String,
                      let index = fixture.threadIds.firstIndex(of: id) else { continue }
                #expect(row["parentMessageCreatedAt"] as? String == fixture.parentCreatedAt[index])
                #expect(row["parentChannelId"] as? String == fixture.channelId)
            }
            let mentioned = try #require(unreadThreads.first { $0["threadChannelId"] as? String == fixture.threadIds[0] })
            #expect(mentioned["hasMention"] as? Bool == true)
            #expect(mentioned["firstUnreadMessageId"] as? String == fixture.unreadReplyIds[0])
            let plain = try #require(unreadThreads.first { $0["threadChannelId"] as? String == fixture.threadIds[2] })
            #expect(plain["hasMention"] as? Bool == false)

            let unreadPage = try await followedPageGet(client, token: token, serverId: fixture.serverId, query: "?unreadOnly=1&limit=2")
            let unreadPageBody = try followedPageObject(unreadPage)
            #expect((unreadPageBody["threads"] as? [[String: Any]] ?? []).compactMap { $0["threadChannelId"] as? String } == [
                fixture.threadIds[4], fixture.threadIds[2],
            ])
            #expect(unreadPageBody["next"] is String)

            #expect(try await followedPageGet(client, token: token, serverId: fixture.serverId, query: "?limit=0").status == .badRequest)
            #expect(try await followedPageGet(client, token: token, serverId: fixture.serverId, query: "?limit=201").status == .badRequest)
            #expect(try await followedPageGet(client, token: token, serverId: fixture.serverId, query: "?limit=2&cursor=not-a-cursor").status == .badRequest)
            #expect(try await followedPageGet(client, token: token, serverId: fixture.serverId, query: "?cursor=v1:2").status == .badRequest)
        }
    }
}
