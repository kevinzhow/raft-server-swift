import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

@Test func serverInviteCarriesItsRoleAndFailsGuestClosed() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111416"
    let serverId = "33333333-3333-4333-8333-333333333542"
    accounts.addAccount(id: ownerId, email: "invite-role-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "invite-role", name: "Invite Role", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"invite-role-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func invite(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/invites") { request in
                    request.body = .init(string: body)
                }
            }
            func json(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func listed() async throws -> [[String: Any]] {
                let response = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/invites")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            }

            let defaulted = try await invite("{\"email\":\"invite-default@slock.test\"}")
            #expect(defaulted.status == .ok)
            #expect(try json(defaulted)["role"] as? String == "member")

            let bogus = try await invite("{\"email\":\"invite-bogus@slock.test\",\"role\":\"owner\"}")
            #expect(bogus.status == .badRequest)
            #expect(try json(bogus)["error"] as? String == "role must be one of: member, guest")

            let gateOff = try await invite("{\"email\":\"invite-guest-off@slock.test\",\"role\":\"guest\"}")
            #expect(gateOff.status == .badRequest)
            #expect(try json(gateOff)["error"] as? String == "Guest access is not enabled for this server")
            #expect(try await listed().contains { $0["invitedEmail"] as? String == "invite-guest-off@slock.test" } == false)

            accounts.enableGuestRoleTransitions(serverId: serverId)
            let guest = try await invite("{\"email\":\"invite-guest@slock.test\",\"role\":\"guest\"}")
            #expect(guest.status == .ok)
            #expect(try json(guest)["role"] as? String == "guest")
            let guestRow = try await listed().first { $0["invitedEmail"] as? String == "invite-guest@slock.test" }
            #expect(guestRow?["role"] as? String == "guest")
        }
    }
}
