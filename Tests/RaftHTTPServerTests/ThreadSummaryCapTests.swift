import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadSummariesKeepTheNewestHundredParents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111539"
    let serverId = "33333333-3333-4333-8333-333333333616"
    accounts.addAccount(id: ownerId, email: "thread-cap-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-cap", name: "Thread Cap", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "thread-cap", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "thread-cap")
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
                request.body = .init(string: "{\"email\":\"thread-cap-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            var parentIds: [String] = []
            for index in 0...100 {
                let parent = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"parent \(index)\"}")
                }
                let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
                parentIds.append(parentId)
                let thread = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/threads") { request in
                    request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
                }
                #expect(thread.status == .ok)
            }
            let summaries = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)/threads")
            let body = try JSONSerialization.jsonObject(with: Data((summaries.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(body.count == 100)
            #expect(body[parentIds[0]] == nil)
            #expect(body[parentIds[1]] != nil)
            #expect(body[parentIds[100]] != nil)
        }
    }
}
