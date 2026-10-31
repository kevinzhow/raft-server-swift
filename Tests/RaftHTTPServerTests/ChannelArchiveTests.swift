import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func archiveFreezesMessageWritesAndUnarchiveRestoresThem() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111331"
    let serverId = "33333333-3333-4333-8333-333333333497"
    accounts.addAccount(id: ownerId, email: "archive-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archive", name: "Archive", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"archive-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let created = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"archive-room\"}")
            }
            #expect(created.status == .ok)
            let channelId = (try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            func sendMessage() async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"hello\"}")
                }
            }
            #expect(try await sendMessage().status == .ok)

            let archived = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/archive")
            #expect(archived.status == .ok)
            let archivedBody = try JSONSerialization.jsonObject(with: Data((archived.body.string ?? "").utf8)) as? [String: Any]
            #expect(archivedBody?["archivedAt"] is String)

            let frozen = try await sendMessage()
            #expect(frozen.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((frozen.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "channel_archived")

            func frozenCode(_ response: ClientResponse) throws -> String? {
                try (JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String
            }
            let renamed = try await client.send(.patch, headers: headers, to: "/api/channels/\(channelId)") { request in
                request.body = .init(string: "{\"name\":\"renamed-room\"}")
            }
            #expect(renamed.status == .conflict)
            #expect(try frozenCode(renamed) == "channel_archived")

            let notification = try await client.send(.patch, headers: headers, to: "/api/channels/\(channelId)/notification-settings") { request in
                request.body = .init(string: "{\"activityMuted\":true}")
            }
            #expect(notification.status == .conflict)
            #expect(try frozenCode(notification) == "channel_archived")

            let display = try await client.send(.patch, headers: headers, to: "/api/channels/\(channelId)/message-display-settings") { request in
                request.body = .init(string: "{\"collapseLongMessages\":false}")
            }
            #expect(display.status == .conflict)
            #expect(try frozenCode(display) == "channel_archived")

            let tasks = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"frozen\"}]}")
            }
            #expect(tasks.status == .conflict)
            #expect(try frozenCode(tasks) == "channel_archived")

            let archivedAgain = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/archive")
            #expect(archivedAgain.status == .ok)

            let unarchived = try await client.send(.post, headers: headers, to: "/api/channels/\(channelId)/unarchive")
            #expect(unarchived.status == .ok)
            let unarchivedBody = try JSONSerialization.jsonObject(with: Data((unarchived.body.string ?? "").utf8)) as? [String: Any]
            #expect(unarchivedBody?["archivedAt"] == nil || unarchivedBody?["archivedAt"] is NSNull)
            #expect(try await sendMessage().status == .ok)
        }
    }
}
