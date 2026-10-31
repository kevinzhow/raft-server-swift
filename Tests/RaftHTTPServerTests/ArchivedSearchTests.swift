import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func archivedMessagesStaySearchableAndExposeTheArchiveTimestamp() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111404"
    let serverId = "33333333-3333-4333-8333-333333333536"
    accounts.addAccount(id: ownerId, email: "archive-search@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archive-search", name: "Archive Search", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"archive-search@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let created = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"archive-search-room\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let send = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"lorem zephyrglint ipsum\"}")
            }
            let messageId = (try JSONSerialization.jsonObject(with: Data((send.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            func search() async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: "/api/messages/search?q=zephyrglint")
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                let results = body?["results"] as? [[String: Any]] ?? []
                return results.first { $0["id"] as? String == messageId } ?? [:]
            }

            let activeHit = try await search()
            #expect(activeHit["channelArchivedAt"] == nil || activeHit["channelArchivedAt"] is NSNull)

            #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/archive").status == .ok)
            let archivedHit = try await search()
            #expect(archivedHit["channelId"] as? String == channelId)
            #expect(archivedHit["channelArchivedAt"] is String)

            let context = try await client.send(.get, headers: headers, to: "/api/messages/context/\(messageId)?channelId=\(channelId)")
            #expect(context.status == .ok)
            let contextBody = try JSONSerialization.jsonObject(with: Data((context.body.string ?? "").utf8)) as? [String: Any]
            #expect(contextBody?["channelArchived"] as? Bool == true)

            #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/unarchive").status == .ok)
            let restored = try await search()
            #expect(restored["channelArchivedAt"] == nil || restored["channelArchivedAt"] is NSNull)
        }
    }
}
