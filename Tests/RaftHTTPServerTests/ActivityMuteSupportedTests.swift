import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func activityMuteSupportedIsWithheldForDMsOnEverySurface() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111435"
    let peerId = "11111111-1111-4111-8111-111111111436"
    let serverId = "33333333-3333-4333-8333-333333333556"
    accounts.addAccount(id: ownerId, email: "dm-mute-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "dm-mute-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "dm-mute", name: "DM Mute", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")

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
                request.body = .init(string: "{\"email\":\"dm-mute-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"mute-claim-channel\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let dm = try await client.send(.post, headers: headers, to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"userId\":\"\(peerId)\"}")
            }
            #expect(dm.status == .ok)
            let dmBody = try JSONSerialization.jsonObject(with: Data((dm.body.string ?? "").utf8)) as? [String: Any]
            let dmId = dmBody?["id"] as? String ?? ""
            // The create route returns the DM channel row; the capability flag
            // is a list/detail/settings field and is withheld here.
            #expect(dmBody?["activityMuteSupported"] == nil)

            func settings(_ channelId: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: "/api/channels/\(channelId)/notification-settings")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func patchMute(_ channelId: String) async throws -> [String: Any] {
                let response = try await client.send(.patch, headers: headers, to: "/api/channels/\(channelId)/notification-settings") { request in
                    request.body = .init(string: "{\"activityMuted\":true}")
                }
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func detail(_ channelId: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: "/api/channels/\(channelId)")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            #expect(try await settings(dmId)["activityMuteSupported"] as? Bool == false)
            #expect(try await patchMute(dmId)["activityMuteSupported"] as? Bool == false)
            #expect(try await detail(dmId)["activityMuteSupported"] as? Bool == false)
            let dmList = try await client.send(.get, headers: headers, to: "/api/channels/dm")
            let dmRows = try JSONSerialization.jsonObject(with: Data((dmList.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(dmRows.first { $0["id"] as? String == dmId }?["activityMuteSupported"] as? Bool == false)

            #expect(try await settings(channelId)["activityMuteSupported"] as? Bool == true)
            #expect(try await patchMute(channelId)["activityMuteSupported"] as? Bool == true)
            #expect(try await detail(channelId)["activityMuteSupported"] as? Bool == true)
            let list = try await client.send(.get, headers: headers, to: "/api/channels")
            let rows = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.first { $0["id"] as? String == channelId }?["activityMuteSupported"] as? Bool == true)
            #expect(rows.first { $0["id"] as? String == dmId } == nil,
                "upstream GET /api/channels excludes DMs; the DM directory is GET /api/channels/dm")
        }
    }
}
