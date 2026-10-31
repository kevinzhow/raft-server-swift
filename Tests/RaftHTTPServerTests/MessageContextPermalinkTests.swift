import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func messageContextResolvesAShortIdForANonChannelMember() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111456"
    let recipientId = "11111111-1111-4111-8111-111111111457"
    let serverId = "33333333-3333-4333-8333-333333333568"
    accounts.addAccount(id: ownerId, email: "permalink-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: recipientId, email: "permalink-recipient@slock.test", password: "password123")
    accounts.markEmailVerified(userId: recipientId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "permalink-server", name: "Permalink", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: recipientId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("permalink-owner@slock.test")
            let recipientToken = try await login("permalink-recipient@slock.test")
            let channel = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"permalink-target\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let message = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"public channel permalink target\"}")
            }
            let messageId = (try JSONSerialization.jsonObject(with: Data((message.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let shortId = String(messageId.prefix(8))

            let response = try await client.send(.get, headers: headers(recipientToken), to: URI(string: "/api/messages/context/\(shortId)?channelId=\(channelId)"))
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["channelId"] as? String == channelId)
            #expect(body?["targetMessageId"] as? String == messageId)
            let messages = body?["messages"] as? [[String: Any]] ?? []
            #expect(messages.contains { $0["id"] as? String == messageId && $0["content"] as? String == "public channel permalink target" })

            #expect(try await client.send(.get, headers: headers(recipientToken), to: URI(string: "/api/messages/context/not-a-uuid?channelId=\(channelId)")).status == .badRequest)
        }
    }
}
