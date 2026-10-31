import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func translationBatchRefusesADisabledServer() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111462"
    let serverId = "33333333-3333-4333-8333-333333333572"
    accounts.addAccount(id: ownerId, email: "translation-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "translation-gate", name: "Translation Gate", ownerId: ownerId)
    accounts.oauth.setServerTranslationEnabled(id: serverId, enabled: false)
    let messageId = UUID().uuidString.lowercased()

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
                request.body = .init(string: "{\"email\":\"translation-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func batch() async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/message-translations:batch") { request in
                    request.body = .init(string: "{\"targetLanguage\":\"en\",\"mode\":\"auto\",\"messageIds\":[\"\(messageId)\"]}")
                }
            }

            let denied = try await batch()
            #expect(denied.status == .forbidden)
            let deniedBody = try JSONSerialization.jsonObject(with: Data((denied.body.string ?? "").utf8)) as? [String: Any]
            #expect(deniedBody?["error"] as? String == "Translation is disabled for this server")

            var anonymous = HTTPFields()
            anonymous[.contentType] = "application/json"
            anonymous[HTTPField.Name("X-Server-Id")!] = serverId
            let unauthenticated = try await client.send(.post, headers: anonymous, to: "/api/message-translations:batch") { request in
                request.body = .init(string: "{\"messageIds\":[]}")
            }
            #expect(unauthenticated.status == .unauthorized)

            accounts.oauth.setServerTranslationEnabled(id: serverId, enabled: true)
            let channel = accounts.oauth.createChannel(serverId: serverId, name: "translation-room", creatorUserId: ownerId)
            let visible = accounts.oauth.createMessageRecord(channelId: channel, content: "你好 visible", senderId: ownerId)
            let otherServer = "33333333-3333-4333-8333-333333333576"
            accounts.oauth.addOwnedServer(id: otherServer, slug: "translation-other", name: "Translation Other", ownerId: ownerId)
            let otherChannel = accounts.oauth.createChannel(serverId: otherServer, name: "other-room", creatorUserId: ownerId)
            let hidden = accounts.oauth.createMessageRecord(channelId: otherChannel, content: "你好 hidden", senderId: ownerId)
            let enabled = try await client.send(.post, headers: headers, to: "/api/message-translations:batch") { request in
                request.body = .init(string: "{\"targetLanguage\":\"en\",\"mode\":\"auto\",\"messageIds\":[\"\(visible.id)\",\"\(hidden.id)\"]}")
            }
            #expect(enabled.status == .ok)
            let enabledBody = try JSONSerialization.jsonObject(with: Data((enabled.body.string ?? "").utf8)) as? [String: Any]
            let results = enabledBody?["results"] as? [[String: Any]] ?? []
            #expect(results.first { $0["messageId"] as? String == visible.id }?["status"] as? String == "translated")
            #expect(results.first { $0["messageId"] as? String == hidden.id }?["status"] as? String == "not_found")
        }
    }
}
