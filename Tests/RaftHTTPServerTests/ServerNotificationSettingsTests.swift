import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverNotificationSettingsArePerMemberWithModePrecedence() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111377"
    let memberId = "11111111-1111-4111-8111-111111111378"
    let serverId = "33333333-3333-4333-8333-333333333520"
    accounts.addAccount(id: ownerId, email: "notify-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "notify-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "notify", name: "Notify", ownerId: ownerId)
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
            let ownerToken = try await login("notify-owner@slock.test")
            let memberToken = try await login("notify-member@slock.test")
            func get(_ token: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers(token), to: "/api/servers/\(serverId)/notification-settings")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func patch(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: "/api/servers/\(serverId)/notification-settings") { request in
                    request.body = .init(string: body)
                }
            }

            let initial = try await get(memberToken)
            #expect(initial["serverPushMuted"] as? Bool == false)
            #expect(initial["serverPushMentionsOnly"] as? Bool == false)
            #expect(initial["serverPushMode"] as? String == "all")
            #expect(initial["prefsVersion"] as? Int == 0)

            #expect(try await patch(memberToken, "{\"serverPushMuted\":\"yes\"}").status == .badRequest)
            #expect(try await patch(memberToken, "{\"serverPushMode\":\"important\"}").status == .badRequest)

            let mentions = try await patch(memberToken, "{\"serverPushMode\":\"mentions\"}")
            #expect(mentions.status == .ok)
            let mentionsBody = try JSONSerialization.jsonObject(with: Data((mentions.body.string ?? "").utf8)) as? [String: Any]
            #expect(mentionsBody?["serverPushMuted"] as? Bool == false)
            #expect(mentionsBody?["serverPushMentionsOnly"] as? Bool == true)
            #expect(mentionsBody?["serverPushMode"] as? String == "mentions")
            #expect(mentionsBody?["prefsVersion"] as? Int == 1)

            let muted = try await patch(memberToken, "{\"serverPushMuted\":true}")
            let mutedBody = try JSONSerialization.jsonObject(with: Data((muted.body.string ?? "").utf8)) as? [String: Any]
            #expect(mutedBody?["serverPushMuted"] as? Bool == true)
            #expect(mutedBody?["serverPushMentionsOnly"] as? Bool == false)
            #expect(mutedBody?["serverPushMode"] as? String == "none")
            #expect(mutedBody?["prefsVersion"] as? Int == 2)

            let repeated = try await patch(memberToken, "{\"serverPushMuted\":true}")
            let repeatedBody = try JSONSerialization.jsonObject(with: Data((repeated.body.string ?? "").utf8)) as? [String: Any]
            #expect(repeatedBody?["prefsVersion"] as? Int == 2)

            let all = try await patch(memberToken, "{\"serverPushMode\":\"all\"}")
            let allBody = try JSONSerialization.jsonObject(with: Data((all.body.string ?? "").utf8)) as? [String: Any]
            #expect(allBody?["serverPushMuted"] as? Bool == false)
            #expect(allBody?["serverPushMode"] as? String == "all")
            #expect(allBody?["prefsVersion"] as? Int == 3)

            let ownerView = try await get(ownerToken)
            #expect(ownerView["serverPushMode"] as? String == "all")
            #expect(ownerView["prefsVersion"] as? Int == 0)
        }
    }
}
