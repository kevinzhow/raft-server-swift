import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelReadRoutesKeepAMonotonicCursorAndVersion() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111450"
    let memberId = "11111111-1111-4111-8111-111111111451"
    let serverId = "33333333-3333-4333-8333-333333333564"
    accounts.addAccount(id: ownerId, email: "read-state-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "read-state-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "read-state", name: "Read State", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "read-state-target", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: memberId)
    let first = accounts.oauth.createMessageRecord(channelId: channel, content: "first read-state message", senderId: ownerId)
    let second = accounts.oauth.createMessageRecord(channelId: channel, content: "second read-state message", senderId: ownerId)

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
                request.body = .init(string: "{\"email\":\"read-state-member@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func read(_ seq: Int) async throws -> [String: Any] {
                let response = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/read") { request in
                    request.body = .init(string: "{\"seq\":\(seq)}")
                }
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let firstRead = try await read(first.seq)
            #expect(firstRead["ok"] as? Bool == true)
            #expect(firstRead["maxReadSeq"] as? Int == first.seq)
            #expect(firstRead["readStateVersion"] as? Int == 1)

            let unreadBeforeAll = try await client.send(.get, headers: headers, to: "/api/channels/unread")
            #expect((try JSONSerialization.jsonObject(with: Data((unreadBeforeAll.body.string ?? "").utf8)) as? [String: Any])?[channel] as? Int == 1)

            let readAll = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/read-all")
            #expect(readAll.status == .ok)
            let readAllBody = try JSONSerialization.jsonObject(with: Data((readAll.body.string ?? "").utf8)) as? [String: Any]
            #expect(readAllBody?["seq"] as? Int == second.seq)
            #expect(readAllBody?["readStateVersion"] as? Int == 2)

            let repeated = try await read(first.seq)
            #expect(repeated["maxReadSeq"] as? Int == second.seq)
            #expect(repeated["readStateVersion"] as? Int == 2)

            let unreadAfterAll = try await client.send(.get, headers: headers, to: "/api/channels/unread")
            #expect((try JSONSerialization.jsonObject(with: Data((unreadAfterAll.body.string ?? "").utf8)) as? [String: Any])?[channel] == nil)
        }
    }
}
