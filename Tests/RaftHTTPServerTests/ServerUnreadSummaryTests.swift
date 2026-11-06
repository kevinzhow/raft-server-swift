import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverUnreadSummaryCountsJoinedChannelsAcrossServers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111468"
    let memberId = "11111111-1111-4111-8111-111111111469"
    let serverId = "33333333-3333-4333-8333-333333333577"
    accounts.addAccount(id: ownerId, email: "summary-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "summary-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "unread-summary", name: "Unread Summary", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.setServerPushMuted(serverId: serverId, userId: memberId, muted: true)

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
            let ownerToken = try await login("summary-owner@slock.test")
            let memberToken = try await login("summary-member@slock.test")
            func createChannel(_ name: String) async throws -> String {
                let response = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                    request.body = .init(string: "{\"name\":\"\(name)\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            }
            func send(_ channelId: String, _ content: String) async throws {
                let response = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
            }
            let joined = try await createChannel("joined-room")
            accounts.oauth.addChannelHuman(channelId: joined, userId: memberId)
            accounts.addPostableChannel(serverId: serverId, channelId: joined, memberId: memberId, name: "joined-room")
            let hidden = try await createChannel("hidden-room")
            try await send(joined, "joined unread 1")
            try await send(joined, "joined unread 2")
            for index in 1...3 { try await send(hidden, "hidden unread \(index)") }

            var memberHeaders = HTTPFields()
            memberHeaders[.authorization] = "Bearer \(memberToken)"
            let response = try await client.send(.get, headers: memberHeaders, to: "/api/servers/unread-summary")
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "private, no-store")
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let row = body.first { $0["serverId"] as? String == serverId }
            #expect(row?["unreadCount"] as? Int == 2)
            #expect(row?["activityUnreadCount"] as? Int == 2)
            #expect(row?["serverPushMuted"] as? Bool == true)
        }
    }
}
