import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func guestRoleTransitionNeedsTheGateAndProtectsAdminTargets() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111401"
    let adminId = "11111111-1111-4111-8111-111111111402"
    let memberId = "11111111-1111-4111-8111-111111111403"
    let serverId = "33333333-3333-4333-8333-333333333535"
    for (id, email) in [
        (ownerId, "guest-role-owner@slock.test"),
        (adminId, "guest-role-admin@slock.test"),
        (memberId, "guest-role-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "guest-role", name: "Guest Role", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let allChannel = accounts.oauth.allChannelId(serverId: serverId) ?? ""
    accounts.oauth.addChannelHuman(channelId: allChannel, userId: memberId)

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
            let ownerToken = try await login("guest-role-owner@slock.test")
            let adminToken = try await login("guest-role-admin@slock.test")
            func patch(_ token: String, _ targetId: String, _ role: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: "/api/servers/\(serverId)/members/\(targetId)") { request in
                    request.body = .init(string: "{\"role\":\"\(role)\"}")
                }
            }
            func body(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let gated = try await patch(adminToken, memberId, "guest")
            #expect(gated.status == .forbidden)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == "member")

            accounts.enableGuestRoleTransitions(serverId: serverId)
            let demote = try await patch(adminToken, memberId, "guest")
            #expect(demote.status == .ok)
            #expect(try body(demote)["ok"] as? Bool == true)
            #expect(try body(demote)["changed"] as? Bool == true)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == "guest")
            #expect(!accounts.oauth.channelHumanIds(channelId: allChannel).contains(memberId))

            let restore = try await patch(adminToken, memberId, "member")
            #expect(restore.status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == "member")

            #expect(try await patch(adminToken, ownerId, "member").status == .forbidden)
            #expect(try await patch(adminToken, adminId, "admin").status == .forbidden)
            #expect(try await patch(adminToken, memberId, "owner").status == .forbidden)
            #expect(try await patch(ownerToken, ownerId, "guest").status == .badRequest)
        }
    }
}
