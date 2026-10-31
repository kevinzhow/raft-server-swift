import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func privateToPublicRestoresThreadPermalinkForNonMembers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111545"
    let outsiderId = "11111111-1111-4111-8111-111111111546"
    let serverId = "33333333-3333-4333-8333-333333333620"
    accounts.addAccount(id: ownerId, email: "perma-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: outsiderId, email: "perma-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "perma", name: "Perma", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")

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
            let ownerToken = try await login("perma-owner@slock.test")
            let outsiderToken = try await login("perma-outsider@slock.test")
            let created = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"mcdonalds-club\"}")
            }
            let channel = (try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let privateChannel = try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(privateChannel.status == .ok)
            let parent = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"parent message\"}")
            }
            let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let thread = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channel)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
            }
            let threadId = (try JSONSerialization.jsonObject(with: Data((thread.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
            let reply = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(threadId)\",\"content\":\"reply while private\"}")
            }
            #expect(reply.status == .ok)

            #expect(try await client.send(.get, headers: headers(outsiderToken), to: "/api/channels/\(channel)").status == .notFound)
            #expect(try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"visibility\":\"public\"}")
            }.status == .ok)

            let details = try await client.send(.get, headers: headers(outsiderToken), to: "/api/channels/\(channel)")
            #expect(details.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((details.body.string ?? "").utf8)) as? [String: Any])?["type"] as? String == "channel")
            let openThread = try await client.send(.get, headers: headers(outsiderToken), to: "/api/channels/\(channel)/threads/\(parentId)")
            #expect(openThread.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((openThread.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String == threadId)
            let history = try await client.send(.get, headers: headers(outsiderToken), to: "/api/messages/channel/\(threadId)")
            #expect(history.status == .ok)
            #expect((history.body.string ?? "").contains("reply while private"))
        }
    }
}
