import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelDisplayPrefsRequireChannelMembershipExceptForAll() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111286"
    let memberId = "11111111-1111-4111-8111-111111111287"
    let outsiderId = "11111111-1111-4111-8111-111111111288"
    let serverId = "33333333-3333-4333-8333-333333333471"
    for (id, email) in [
        (ownerId, "display-owner@slock.test"),
        (memberId, "display-member@slock.test"),
        (outsiderId, "display-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-display", name: "Channel Display Settings", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "display-target", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
    let allChannelId = accounts.oauth.allChannelId(serverId: serverId) ?? ""

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
            let memberToken = try await login("display-member@slock.test")
            let outsiderToken = try await login("display-outsider@slock.test")

            let initial = try await client.send(.get, headers: headers(memberToken), to: "/api/channels/\(channelId)/message-display-settings")
            #expect(initial.status == .ok)
            let initialBody = try JSONSerialization.jsonObject(with: Data((initial.body.string ?? "").utf8)) as? [String: Any]
            #expect(initialBody?["collapseLongMessages"] as? Bool == true)
            #expect(initialBody?["prefsVersion"] as? Int == 0)

            let invalid = try await client.send(.patch, headers: headers(memberToken), to: "/api/channels/\(channelId)/message-display-settings") { request in
                request.body = .init(string: "{\"collapseLongMessages\":\"no\"}")
            }
            #expect(invalid.status == .badRequest)

            let unjoined = try await client.send(.get, headers: headers(outsiderToken), to: "/api/channels/\(channelId)/message-display-settings")
            #expect(unjoined.status == .notFound)

            let allGet = try await client.send(.get, headers: headers(outsiderToken), to: "/api/channels/\(allChannelId)/message-display-settings")
            #expect(allGet.status == .ok)
            let allPatch = try await client.send(.patch, headers: headers(outsiderToken), to: "/api/channels/\(allChannelId)/message-display-settings") { request in
                request.body = .init(string: "{\"collapseLongMessages\":false}")
            }
            #expect(allPatch.status == .ok)
            let allBody = try JSONSerialization.jsonObject(with: Data((allPatch.body.string ?? "").utf8)) as? [String: Any]
            #expect(allBody?["collapseLongMessages"] as? Bool == false)
            #expect(allBody?["prefsVersion"] as? Int == 1)
        }
    }
}
