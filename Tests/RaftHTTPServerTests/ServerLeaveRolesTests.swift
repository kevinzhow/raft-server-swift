import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func leaveRemovesAdminsAndMembersButRejectsTheOnlyOwner() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111383"
    let adminId = "11111111-1111-4111-8111-111111111384"
    let memberId = "11111111-1111-4111-8111-111111111385"
    let serverId = "33333333-3333-4333-8333-333333333524"
    for (id, email) in [
        (ownerId, "leave-owner@slock.test"),
        (adminId, "leave-admin@slock.test"),
        (memberId, "leave-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "leave-roles", name: "Leave Roles", ownerId: ownerId)
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
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("leave-owner@slock.test")
            let adminToken = try await login("leave-admin@slock.test")
            let memberToken = try await login("leave-member@slock.test")
            func leave(_ token: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/servers/\(serverId)/leave")
            }

            #expect(try await leave(ownerToken).status == .badRequest)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: ownerId) == "owner")
            #expect(try await leave(adminToken).status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: adminId) == nil)
            #expect(try await leave(memberToken).status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == nil)
        }
    }
}
