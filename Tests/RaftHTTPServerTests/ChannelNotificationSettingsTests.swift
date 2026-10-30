import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func activityMuteIsPerUserAndBumpsPrefsVersionOnce() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111282"
    let memberId = "11111111-1111-4111-8111-111111111283"
    let serverId = "33333333-3333-4333-8333-333333333469"
    accounts.addAccount(id: ownerId, email: "mute-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "mute-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-mute", name: "Channel Mute", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "mute-target", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
    accounts.oauth.createChannelMessage(channelId: channelId, content: "pre-mute activity baseline")

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
            let memberToken = try await login("mute-member@slock.test")
            let ownerToken = try await login("mute-owner@slock.test")
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func get(_ token: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers(token), to: "/api/channels/\(channelId)/notification-settings")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func patch(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: "/api/channels/\(channelId)/notification-settings") { request in
                    request.body = .init(string: body)
                }
            }

            let initial = try await get(memberToken)
            #expect(initial["activityMuted"] as? Bool == false)
            #expect(initial["muteFromSeq"] == nil || initial["muteFromSeq"] is NSNull)
            #expect(initial["prefsVersion"] as? Int == 0)
            #expect(initial["activityMuteSupported"] as? Bool == true)

            let invalid = try await patch(memberToken, "{\"activityMuted\":\"yes\"}")
            #expect(invalid.status == .badRequest)

            let muted = try await patch(memberToken, "{\"activityMuted\":true}")
            #expect(muted.status == .ok)
            let mutedBody = try JSONSerialization.jsonObject(with: Data((muted.body.string ?? "").utf8)) as? [String: Any]
            #expect(mutedBody?["activityMuted"] as? Bool == true)
            #expect(mutedBody?["muteFromSeq"] as? Int == 2)
            #expect(mutedBody?["prefsVersion"] as? Int == 1)
            #expect(mutedBody?["activityMuteSupported"] as? Bool == true)

            let repeated = try await patch(memberToken, "{\"activityMuted\":true}")
            #expect((try JSONSerialization.jsonObject(with: Data((repeated.body.string ?? "").utf8)) as? [String: Any])?["prefsVersion"] as? Int == 1)

            let ownerSettings = try await get(ownerToken)
            #expect(ownerSettings["activityMuted"] as? Bool == false)
            #expect(ownerSettings["prefsVersion"] as? Int == 0)

            let list = try await client.send(.get, headers: headers(memberToken), to: "/api/channels")
            let rows = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let row = rows.first { $0["id"] as? String == channelId }
            #expect(row?["activityMuted"] as? Bool == true)
            #expect(row?["muteFromSeq"] as? Int == 2)
            #expect(row?["prefsVersion"] as? Int == 1)
            #expect(row?["activityMuteSupported"] as? Bool == true)
        }
    }
}
