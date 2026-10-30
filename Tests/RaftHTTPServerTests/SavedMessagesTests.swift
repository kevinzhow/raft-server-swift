import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func savedMessagesFilterAndPageAfterFiltering() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111293"
    let serverId = "33333333-3333-4333-8333-333333333474"
    accounts.addAccount(id: ownerId, email: "saved-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "saved-filter", name: "Saved Filter Server", ownerId: ownerId)
    let channelA = accounts.oauth.createChannel(serverId: serverId, name: "saved-alpha-room", creatorUserId: ownerId)
    let channelB = accounts.oauth.createChannel(serverId: serverId, name: "saved-beta-room", creatorUserId: ownerId)
    let alphaOne = accounts.oauth.createMessageRecord(channelId: channelA, content: "alpha first result", senderId: ownerId).id
    let alphaTwo = accounts.oauth.createMessageRecord(channelId: channelA, content: "alpha second result", senderId: ownerId).id
    let beta = accounts.oauth.createMessageRecord(channelId: channelB, content: "beta only result", senderId: ownerId).id
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channelA, parentMessageId: alphaOne)
    let threadReply = accounts.oauth.createMessageRecord(channelId: thread, content: "thread bookmark match", senderId: ownerId).id

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
                request.body = .init(string: "{\"email\":\"saved-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            for messageId in [alphaOne, alphaTwo, beta, threadReply] {
                let response = try await client.send(.post, headers: headers, to: "/api/channels/saved") { request in
                    request.body = .init(string: "{\"messageId\":\"\(messageId)\"}")
                }
                #expect(response.status == .ok)
            }

            func saved(_ query: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: URI(string: "/api/channels/saved\(query)"))
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let newest = try await saved("")
            let oldest = try await saved("?sort=asc")
            let newestIds = (newest["saved"] as? [[String: Any]] ?? []).compactMap { $0["messageId"] as? String }
            let oldestIds = (oldest["saved"] as? [[String: Any]] ?? []).compactMap { $0["messageId"] as? String }
            #expect(oldestIds == newestIds.reversed())

            let alphaPage = try await saved("?q=alpha&limit=1")
            #expect((alphaPage["saved"] as? [[String: Any]])?.count == 1)
            #expect(alphaPage["total"] as? Int == 3)
            #expect(alphaPage["hasMore"] as? Bool == true)

            let betaPage = try await saved("?channelId=\(channelB)&q=beta&limit=1")
            #expect((betaPage["saved"] as? [[String: Any]])?.compactMap { $0["messageId"] as? String } == [beta])
            #expect(betaPage["total"] as? Int == 1)
            #expect(betaPage["hasMore"] as? Bool == false)

            let threadPage = try await saved("?channelId=\(channelA)&q=thread%20bookmark")
            #expect(threadPage["total"] as? Int == 1)
            let entry = (threadPage["saved"] as? [[String: Any]])?.first ?? [:]
            #expect(entry["messageId"] as? String == threadReply)
            #expect(entry["channelType"] as? String == "thread")
            #expect(entry["parentChannelId"] as? String == channelA)
            #expect(entry["parentMessageId"] as? String == alphaOne)
            #expect(entry["parentMessagePreview"] as? String == "alpha first result")
            #expect(entry["replyCount"] as? Int == 1)
        }
    }
}
