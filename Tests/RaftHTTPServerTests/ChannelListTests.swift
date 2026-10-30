import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelListCarriesJoinedFlagsAndLastMessageTimes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111278"
    let serverId = "33333333-3333-4333-8333-333333333465"
    accounts.addAccount(id: ownerId, email: "channels-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "channels-trace", name: "Channels Trace Server", ownerId: ownerId)
    let joinedChannel = accounts.oauth.createChannel(serverId: serverId, name: "joined-channel", creatorUserId: ownerId)
    let joinedAt = accounts.oauth.createChannelMessage(channelId: joinedChannel, content: "joined latest message", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let notJoinedChannel = accounts.oauth.createChannel(serverId: serverId, name: "not-joined-channel", creatorUserId: "00000000-0000-4000-8000-000000000000")
    _ = accounts.oauth.createChannelMessage(channelId: notJoinedChannel, content: "not joined latest message", createdAt: Date(timeIntervalSince1970: 1_700_000_100))

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
                request.body = .init(string: "{\"email\":\"channels-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let response = try await client.send(.get, headers: headers, to: "/api/channels")
            #expect(response.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.count == 3)
            #expect(rows.first { $0["name"] as? String == "all" }?["joined"] as? Bool == true)
            #expect(rows.first { $0["name"] as? String == "joined-channel" }?["joined"] as? Bool == true)
            #expect(rows.first { $0["name"] as? String == "not-joined-channel" }?["joined"] as? Bool == false)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(rows.first { $0["id"] as? String == joinedChannel }?["lastMessageAt"] as? String == formatter.string(from: joinedAt))
            #expect(rows.first { $0["id"] as? String == notJoinedChannel }?["lastMessageAt"] as? String == formatter.string(from: Date(timeIntervalSince1970: 1_700_000_100)))
        }
    }
}
