import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func followedThreadsCarryUnreadAndTaskClaimState() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111444"
    let claimantId = "11111111-1111-4111-8111-111111111445"
    let serverId = "33333333-3333-4333-8333-333333333561"
    accounts.addAccount(id: ownerId, email: "followed-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: claimantId, email: "followed-claimant@slock.test", password: "password123")
    accounts.markEmailVerified(userId: claimantId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "followed", name: "Followed", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: claimantId, role: "member")

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
                request.body = .init(string: "{\"email\":\"followed-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"followed-channel\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let parentMessageId = UUID().uuidString.lowercased()
            let threadId = UUID().uuidString.lowercased()
            accounts.addPostableChannel(serverId: serverId, channelId: threadId, memberId: ownerId, kind: "thread", parentChannelId: channelId, parentMessageId: parentMessageId, name: "thread")
            accounts.addPostableChannel(serverId: serverId, channelId: threadId, memberId: claimantId, kind: "thread", parentChannelId: channelId, parentMessageId: parentMessageId, name: "thread")
            let readReply = accounts.oauth.createMessageRecord(channelId: threadId, content: "already read reply", senderId: ownerId)
            _ = accounts.oauth.createMessageRecord(channelId: threadId, content: "unread reply", senderId: claimantId)
            accounts.oauth.setChannelReadCursor(channelId: threadId, userId: ownerId, seq: readReply.seq)
            accounts.followThreadForTesting(serverId: serverId, userId: ownerId, threadChannelId: threadId, parentMessageId: parentMessageId)
            accounts.addTaskForTesting(channelId: channelId, title: "parent task", messageId: parentMessageId, assigneeType: "user", assigneeId: claimantId)

            let response = try await client.send(.get, headers: headers, to: "/api/channels/threads/followed")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let threads = body?["threads"] as? [[String: Any]] ?? []
            #expect(threads.count == 1)
            let row = threads[0]
            #expect(row["threadChannelId"] as? String == threadId)
            #expect(row["unreadCount"] as? Int == 1)
            #expect(row["taskId"] is String)
            #expect(row["taskClaimedByType"] as? String == "user")
            #expect(row["taskClaimedById"] as? String == claimantId)
            #expect(row["taskClaimedByName"] as? String == "followed-claimant")
        }
    }
}
