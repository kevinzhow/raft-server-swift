import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func messageSyncReturnsNumericSeqAndHonorsTheCursor() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111429"
    let serverId = "33333333-3333-4333-8333-333333333552"
    accounts.addAccount(id: ownerId, email: "sync-seq@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "sync-seq", name: "Sync Seq", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"sync-seq@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"sync-seq-channel\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            for content in ["sync seq first", "sync seq second"] {
                let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
            }
            func sync(_ since: String) async throws -> [[String: Any]] {
                let response = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/sync?since_seq=\(since)&channel_id=\(channelId)"))
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            }

            let all = try await sync("0")
            #expect(all.count == 2)
            #expect(all.compactMap { $0["seq"] as? Int } == [1, 2])
            #expect(all.allSatisfy { $0["seq"] is NSNumber })

            let tail = try await sync("1")
            #expect(tail.count == 1)
            #expect(tail[0]["seq"] as? Int == 2)
        }
    }
}
