import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func savedMessagesDropPrivateRowsAfterMembershipRemoval() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111491"
    let memberId = "11111111-1111-4111-8111-111111111492"
    let serverId = "33333333-3333-4333-8333-333333333590"
    accounts.addAccount(id: ownerId, email: "saved-private-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "saved-private-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "saved-private", name: "Saved Private", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

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
            let ownerToken = try await login("saved-private-owner@slock.test")
            let memberToken = try await login("saved-private-member@slock.test")
            let channel = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"saved-private-room\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, name: "saved-private-room")
            accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
            #expect(try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(channelId)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }.status == .ok)
            let message = accounts.oauth.createMessageRecord(channelId: channelId, content: "saved private secret", senderId: ownerId)

            let save = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/saved") { request in
                request.body = .init(string: "{\"messageId\":\"\(message.id)\"}")
            }
            #expect(save.status == .ok)
            let before = try await client.send(.get, headers: headers(memberToken), to: "/api/channels/saved")
            let beforeBody = try JSONSerialization.jsonObject(with: Data((before.body.string ?? "").utf8)) as? [String: Any]
            #expect((beforeBody?["saved"] as? [[String: Any]] ?? []).contains { $0["messageId"] as? String == message.id })

            accounts.removeChannelMember(channelId: channelId, memberId: memberId)
            _ = accounts.oauth.removeChannelHuman(channelId: channelId, userId: memberId)

            let after = try await client.send(.get, headers: headers(memberToken), to: "/api/channels/saved")
            let afterBody = try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [String: Any]
            #expect(afterBody?["total"] as? Int == 0)
            #expect((afterBody?["saved"] as? [[String: Any]] ?? []).isEmpty)

            let check = try await client.send(.post, headers: headers(memberToken), to: "/api/channels/saved/check") { request in
                request.body = .init(string: "{\"messageIds\":[\"\(message.id)\"]}")
            }
            #expect(check.status == .ok)
            let checkBody = try JSONSerialization.jsonObject(with: Data((check.body.string ?? "").utf8)) as? [String: Any]
            #expect((checkBody?["savedIds"] as? [String] ?? []).isEmpty)
        }
    }
}
