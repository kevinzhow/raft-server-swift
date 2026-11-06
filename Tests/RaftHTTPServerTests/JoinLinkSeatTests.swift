import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

@Test func joinLinksReportSeatExhaustionAndAcceptWhenASeatOpens() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111417"
    let inviteeId = "11111111-1111-4111-8111-111111111418"
    let serverId = "33333333-3333-4333-8333-333333333543"
    accounts.addAccount(id: ownerId, email: "seat-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: inviteeId, email: "seat-invitee@slock.test", password: "password123")
    accounts.markEmailVerified(userId: inviteeId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "seat-limit", name: "Seat Limit", ownerId: ownerId)
    accounts.setServerSeats(serverId: serverId, seats: 1)

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
            let ownerToken = try await login("seat-owner@slock.test")
            let inviteeToken = try await login("seat-invitee@slock.test")

            let memberInvite = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"blocked-member@slock.test\"}")
            }
            #expect(memberInvite.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((memberInvite.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String ?? "").contains("Seat limit reached (1/1 on Pro plan)"))

            accounts.enableGuestRoleTransitions(serverId: serverId)
            let guestInvite = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"guest-invite@slock.test\",\"role\":\"guest\"}")
            }
            #expect(guestInvite.status == .ok)

            let linkResponse = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/join-links") { request in
                request.body = .init(string: "{\"maxUses\":null,\"expiresAt\":null}")
            }
            #expect(linkResponse.status == .ok)
            let token = (try JSONSerialization.jsonObject(with: Data((linkResponse.body.string ?? "").utf8)) as? [String: Any])?["token"] as? String ?? ""
            #expect(!token.isEmpty)

            let info = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/api/auth/invite-info?token=\(token)"))
            #expect(info.status == .ok)
            let infoBody = try JSONSerialization.jsonObject(with: Data((info.body.string ?? "").utf8)) as? [String: Any]
            #expect(infoBody?["humanSeatLimitReached"] as? Bool == true)
            #expect(((infoBody?["humanSeatLimitMessage"] as? String) ?? "").contains("Seat limit reached (1/1 on Pro plan)"))

            let refused = try await client.send(.post, headers: headers(inviteeToken), to: "/api/auth/accept-invite") { request in
                request.body = .init(string: "{\"token\":\"\(token)\"}")
            }
            #expect(refused.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((refused.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String ?? "").contains("Seat limit reached (1/1 on Pro plan)"))

            accounts.setServerSeats(serverId: serverId, seats: 5)
            let accepted = try await client.send(.post, headers: headers(inviteeToken), to: "/api/auth/accept-invite") { request in
                request.body = .init(string: "{\"token\":\"\(token)\"}")
            }
            #expect(accepted.status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: inviteeId) == "member")
        }
    }
}
