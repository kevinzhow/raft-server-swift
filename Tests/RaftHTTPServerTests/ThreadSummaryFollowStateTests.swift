import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func threadSummariesTellTheViewerWhetherTheyFollowEachThread() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000000810001"
    let serverId = "33333333-3333-4333-8333-000000810001"
    accounts.addAccount(id: ownerId, email: "summary-followed-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "summary-followed", name: "Summary Followed", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "summary-followed", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "summary-followed")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)

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
                request.body = .init(string: "{\"email\":\"summary-followed-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            func make(_ label: String) async throws -> (parent: String, thread: String) {
                let parentResponse = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"\(label)\"}")
                }
                let parentId = (try JSONSerialization.jsonObject(with: Data((parentResponse.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
                let threadResponse = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/threads") { request in
                    request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
                }
                let threadId = (try JSONSerialization.jsonObject(with: Data((threadResponse.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
                _ = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(threadId)\",\"content\":\"\(label) reply\"}")
                }
                return (parentId, threadId)
            }
            let followed = try await make("followed")
            let done = try await make("done")
            let unfollowed = try await make("unfollowed")
            let never = try await make("never")

            func mutate(_ thread: String, _ path: String) async throws {
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
                }
                #expect(response.status == .ok)
            }
            try await mutate(followed.thread, "/api/channels/threads/follow")
            try await mutate(done.thread, "/api/channels/threads/follow")
            try await mutate(done.thread, "/api/channels/threads/done")
            try await mutate(unfollowed.thread, "/api/channels/threads/follow")
            try await mutate(unfollowed.thread, "/api/channels/threads/unfollow")
            accounts.removeThreadFollowForTesting(serverId: serverId, userId: ownerId, threadChannelId: never.thread)

            let response = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)/threads")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect((body[followed.parent] as? [String: Any])?["followed"] as? Bool == true)
            #expect((body[done.parent] as? [String: Any])?["followed"] as? Bool == true)
            #expect((body[unfollowed.parent] as? [String: Any])?["followed"] as? Bool == false)
            #expect((body[never.parent] as? [String: Any])?["followed"] as? Bool == false)
        }
    }
}
