import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func onlyAnOwnerCanGrantOrRevokeOwnerOnAnotherMember() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111380"
    let adminId = "11111111-1111-4111-8111-111111111381"
    let memberId = "11111111-1111-4111-8111-111111111382"
    let serverId = "33333333-3333-4333-8333-333333333523"
    for (id, email) in [
        (ownerId, "member-role-owner@slock.test"),
        (adminId, "member-role-admin@slock.test"),
        (memberId, "member-role-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "member-role", name: "Member Role", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
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
            let ownerToken = try await login("member-role-owner@slock.test")
            let adminToken = try await login("member-role-admin@slock.test")
            func patchRole(_ token: String, _ targetId: String, _ role: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: "/api/servers/\(serverId)/members/\(targetId)") { request in
                    request.body = .init(string: "{\"role\":\"\(role)\"}")
                }
            }

            #expect(try await patchRole(adminToken, memberId, "owner").status == .forbidden)
            #expect(try await patchRole(ownerToken, memberId, "owner").status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == "owner")
            #expect(try await patchRole(ownerToken, memberId, "member").status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == "member")
            #expect(try await patchRole(ownerToken, ownerId, "member").status == .badRequest)
            #expect(try await patchRole(ownerToken, UUID().uuidString.lowercased(), "member").status == .notFound)

            let directAdd = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/members") { request in
                request.body = .init(string: "{\"userId\":\"\(memberId)\",\"role\":\"member\"}")
            }
            #expect(directAdd.status == .notFound)
        }
    }
}
