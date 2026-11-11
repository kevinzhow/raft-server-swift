import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func directChannelsNeverClaimActivityMuteSupport() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111289"
    let peerId = "11111111-1111-4111-8111-111111111290"
    let serverId = "33333333-3333-4333-8333-333333333472"
    accounts.addAccount(id: ownerId, email: "dm-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "dm-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "dm-mute", name: "DM Mute Claim", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "mute-claim-channel", creatorUserId: ownerId)

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
                request.body = .init(string: "{\"email\":\"dm-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            func json(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func settings(_ channelId: String) async throws -> ClientResponse {
                try await client.send(.get, headers: headers, to: "/api/channels/\(channelId)/notification-settings")
            }
            func patchSettings(_ channelId: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers, to: "/api/channels/\(channelId)/notification-settings") { request in
                    request.body = .init(string: "{\"activityMuted\":true}")
                }
            }

            let dmResponse = try await client.send(.post, headers: headers, to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"userId\":\"\(peerId)\"}")
            }
            #expect(dmResponse.status == .ok)
            let dm = try json(dmResponse)
            let dmId = dm["id"] as? String ?? ""
            // The create route returns the DM channel row (upstream
            // findOrCreateUserDM); the capability flag is published by the
            // list, detail and notification-settings exits.
            #expect(dm["activityMuteSupported"] == nil)
            #expect(dm["peerType"] as? String == "user")
            #expect(dm["peerName"] as? String == "dm-peer")

            #expect(try json(try await settings(dmId))["activityMuteSupported"] as? Bool == false)
            #expect(try json(try await patchSettings(dmId))["activityMuteSupported"] as? Bool == false)
            let detail = try await client.send(.get, headers: headers, to: "/api/channels/\(dmId)")
            #expect(try json(detail)["activityMuteSupported"] as? Bool == false)

            let dmList = try await client.send(.get, headers: headers, to: "/api/channels/dm")
            let rows = try JSONSerialization.jsonObject(with: Data((dmList.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let listed = rows.first { $0["id"] as? String == dmId }
            #expect(listed?["activityMuteSupported"] as? Bool == false)

            #expect(try json(try await settings(channelId))["activityMuteSupported"] as? Bool == true)
            #expect(try json(try await patchSettings(channelId))["activityMuteSupported"] as? Bool == true)
            let channelDetail = try await client.send(.get, headers: headers, to: "/api/channels/\(channelId)")
            #expect(try json(channelDetail)["activityMuteSupported"] as? Bool == true)
        }
    }
}
