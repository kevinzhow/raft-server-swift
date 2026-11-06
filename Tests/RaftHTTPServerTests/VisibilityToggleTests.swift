import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func visibilityToggleUpdatesListDetailAndHistory() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111522"
    let memberId = "11111111-1111-4111-8111-111111111523"
    let serverId = "33333333-3333-4333-8333-333333333606"
    accounts.addAccount(id: ownerId, email: "toggle-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "toggle-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "toggle", name: "Toggle", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "toggle-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "toggle-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "toggle-agent")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)

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
            let ownerToken = try await login("toggle-owner@slock.test")
            let memberToken = try await login("toggle-member@slock.test")
            let sent = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"toggle room message\"}")
            }
            let messageId = (try JSONSerialization.jsonObject(with: Data((sent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            func list(_ token: String) async throws -> [[String: Any]] {
                let response = try await client.send(.get, headers: headers(token), to: "/api/channels")
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            }
            let allRow = try await list(ownerToken).first { $0["name"] as? String == "all" }
            #expect(allRow?["joined"] as? Bool == true)
            let reserved = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"all\"}")
            }
            #expect(reserved.status == .badRequest)
            let memberToggle = try await client.send(.patch, headers: headers(memberToken), to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(memberToggle.status == .forbidden)
            let invalidToggle = try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"visibility\":\"secret\"}")
            }
            #expect(invalidToggle.status == .badRequest)

            let publicRow = try await list(memberToken).first { $0["id"] as? String == channel }
            #expect(publicRow?["type"] as? String == "channel")
            #expect(publicRow?["joined"] as? Bool == false)
            #expect(try await client.send(.get, headers: headers(memberToken), to: "/api/messages/channel/\(channel)").status == .ok)

            let toPrivate = try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }
            #expect(toPrivate.status == .ok)
            let privateBody = try JSONSerialization.jsonObject(with: Data((toPrivate.body.string ?? "").utf8)) as? [String: Any]
            #expect(privateBody?["type"] as? String == "private")
            #expect(!(try await list(memberToken)).contains { $0["id"] as? String == channel })
            #expect(try await client.send(.get, headers: headers(memberToken), to: "/api/channels/\(channel)").status == .notFound)
            #expect(try await client.send(.get, headers: headers(memberToken), to: "/api/messages/channel/\(channel)").status == .notFound)
            #expect((try await list(ownerToken).first { $0["id"] as? String == channel })?["type"] as? String == "private")
            #expect(accounts.oauth.channelAgentIds(channelId: channel).contains(agent))

            let toPublic = try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"visibility\":\"public\"}")
            }
            #expect(toPublic.status == .ok)
            #expect((try await list(memberToken).first { $0["id"] as? String == channel })?["joined"] as? Bool == false)
            let restored = try await client.send(.get, headers: headers(memberToken), to: "/api/messages/channel/\(channel)")
            #expect(restored.status == .ok)
            #expect((restored.body.string ?? "").contains(messageId))
        }
    }
}
