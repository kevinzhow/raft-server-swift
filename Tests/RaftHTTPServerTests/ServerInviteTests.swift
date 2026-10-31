import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverInviteRejectsAnInvalidEmailAndAcceptsAValidOne() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111344"
    let memberId = "11111111-1111-4111-8111-111111111345"
    let serverId = "33333333-3333-4333-8333-333333333503"
    accounts.addAccount(id: ownerId, email: "invite-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "invite-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "invite", name: "Invite", ownerId: ownerId)
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
            let ownerToken = try await login("invite-owner@slock.test")
            let memberToken = try await login("invite-member@slock.test")

            let invalid = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"not-an-email\"}")
            }
            #expect(invalid.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((invalid.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Enter a valid email address")

            let accepted = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"invitee@slock.test\"}")
            }
            #expect(accepted.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((accepted.body.string ?? "").utf8)) as? [String: Any]
            let invite = body?["invite"] as? [String: Any]
            #expect((invite?["id"] as? String)?.isEmpty == false)
            #expect(invite?["email"] as? String == "invitee@slock.test")
            #expect(invite?["status"] as? String == "pending")

            let forbidden = try await client.send(.post, headers: headers(memberToken), to: "/api/servers/\(serverId)/invites") { request in
                request.body = .init(string: "{\"email\":\"another@slock.test\"}")
            }
            #expect(forbidden.status == .forbidden)
        }
    }
}
