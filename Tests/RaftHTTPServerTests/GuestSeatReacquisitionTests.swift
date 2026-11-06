import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

@Test func guestToMemberPromotionNeedsAnOpenPaidSeat() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111419"
    let guestId = "11111111-1111-4111-8111-111111111420"
    let serverId = "33333333-3333-4333-8333-333333333544"
    accounts.addAccount(id: ownerId, email: "guest-seat-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: guestId, email: "guest-seat-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "guest-seat", name: "Guest Seat", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    accounts.setServerSeats(serverId: serverId, seats: 1)
    accounts.enableGuestRoleTransitions(serverId: serverId)

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
                request.body = .init(string: "{\"email\":\"guest-seat-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func promote() async throws -> ClientResponse {
                try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/members/\(guestId)") { request in
                    request.body = .init(string: "{\"role\":\"member\"}")
                }
            }

            let refused = try await promote()
            #expect(refused.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((refused.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "human_seat_limit_reached")
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: guestId) == "guest")

            accounts.setServerSeats(serverId: serverId, seats: 2)
            #expect(try await promote().status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: guestId) == "member")
        }
    }
}
