import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func messagePageCursorsFilterAndRejectInvalidPairs() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111470"
    let serverId = "33333333-3333-4333-8333-333333333578"
    accounts.addAccount(id: ownerId, email: "message-cursor@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "message-cursor", name: "Message Cursor", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"message-cursor@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"cursor-room\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            for content in ["one", "two", "three"] {
                let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
            }
            func page(_ query: String) async throws -> ([[String: Any]], Int, String?) {
                let response = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(channelId)\(query)"))
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return (body?["messages"] as? [[String: Any]] ?? [], response.status.code, body?["code"] as? String)
            }

            let before = try await page("?limit=2&before=3")
            #expect(before.1 == 200)
            #expect(before.0.compactMap { $0["content"] as? String } == ["one", "two"])

            let after = try await page("?after=1")
            #expect(after.1 == 200)
            #expect(after.0.compactMap { $0["content"] as? String } == ["two", "three"])

            let zero = try await page("?before=0")
            #expect(zero.1 == 200)
            #expect(zero.0.isEmpty)

            for query in ["?after=abc", "?after=1.5", "?after=-1", "?before=1&after=1"] {
                let invalid = try await page(query)
                #expect(invalid.1 == 400)
                #expect(invalid.2 == "invalid_message_page_cursor")
            }
        }
    }
}
