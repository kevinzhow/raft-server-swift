import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverDetailsProjectTheGuestViewDownToPublicFields() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111254"
    let adminId = "11111111-1111-4111-8111-111111111255"
    let memberId = "11111111-1111-4111-8111-111111111256"
    let guestId = "11111111-1111-4111-8111-111111111257"
    let serverId = "33333333-3333-4333-8333-333333333449"
    for (id, email) in [
        (ownerId, "server-owner@slock.test"),
        (adminId, "server-admin@slock.test"),
        (memberId, "server-member@slock.test"),
        (guestId, "server-guest@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "server-details", name: "Server Details", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let unsafeAvatar = "https://third-party.example/signed-private-avatar"
    accounts.oauth.setServerProfile(
        id: serverId,
        avatarUrl: unsafeAvatar,
        plan: "founder",
        translationEnabled: true,
        publiclyVisible: true,
        publicGuestJoinEnabled: true
    )

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
            func details(_ token: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)")
            }

            for email in ["server-owner@slock.test", "server-admin@slock.test", "server-member@slock.test"] {
                let token = try await login(email)
                let response = try await details(token)
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                #expect(body?["id"] as? String == serverId)
                #expect(body?["ownerId"] as? String == ownerId)
                #expect(body?["plan"] as? String == "founder")
                #expect(body?["translationEnabled"] as? Bool == true)
                #expect(body?["avatarUrl"] as? String == unsafeAvatar)
            }

            let guestToken = try await login("server-guest@slock.test")
            let guest = try await details(guestToken)
            #expect(guest.status == .ok)
            let guestBody = try JSONSerialization.jsonObject(with: Data((guest.body.string ?? "").utf8)) as? [String: Any]
            #expect(guestBody.map { $0.keys.sorted() } == ["avatarUrl", "id", "name", "slug"])
            #expect(guestBody?["avatarUrl"] == nil || guestBody?["avatarUrl"] is NSNull)
            #expect(guestBody?["name"] as? String == "Server Details")
            #expect(guestBody?["slug"] as? String == "server-details")
            for key in ["ownerId", "plan", "translationEnabled", "publiclyVisible", "publicGuestJoinEnabled"] {
                #expect(guestBody?[key] == nil)
            }
        }
    }
}
