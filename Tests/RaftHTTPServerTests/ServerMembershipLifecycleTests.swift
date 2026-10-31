import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverLeaveRemovalAndDeletionFollowRoles() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111341"
    let adminId = "11111111-1111-4111-8111-111111111342"
    let memberId = "11111111-1111-4111-8111-111111111343"
    let serverId = "33333333-3333-4333-8333-333333333502"
    for (id, email) in [
        (ownerId, "lifecycle-owner@slock.test"),
        (adminId, "lifecycle-admin@slock.test"),
        (memberId, "lifecycle-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "lifecycle", name: "Lifecycle", ownerId: ownerId)
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
            let ownerToken = try await login("lifecycle-owner@slock.test")
            let adminToken = try await login("lifecycle-admin@slock.test")
            let memberToken = try await login("lifecycle-member@slock.test")

            let leave = try await client.send(.post, headers: headers(memberToken), to: "/api/servers/\(serverId)/leave")
            #expect(leave.status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == nil)

            accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
            let nonAdminRemove = try await client.send(.delete, headers: headers(memberToken), to: "/api/servers/\(serverId)/members/\(adminId)")
            #expect(nonAdminRemove.status == .forbidden)

            let adminRemove = try await client.send(.delete, headers: headers(adminToken), to: "/api/servers/\(serverId)/members/\(memberId)")
            #expect(adminRemove.status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == nil)

            let adminRemoveOwner = try await client.send(.delete, headers: headers(adminToken), to: "/api/servers/\(serverId)/members/\(ownerId)")
            #expect(adminRemoveOwner.status == .badRequest)

            let ownerLeave = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/\(serverId)/leave")
            #expect(ownerLeave.status == .badRequest)

            accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "owner")
            let secondOwnerLeave = try await client.send(.post, headers: headers(memberToken), to: "/api/servers/\(serverId)/leave")
            #expect(secondOwnerLeave.status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: memberId) == nil)

            let nonOwnerDelete = try await client.send(.delete, headers: headers(adminToken), to: "/api/servers/\(serverId)")
            #expect(nonOwnerDelete.status == .forbidden)
            let ownerDelete = try await client.send(.delete, headers: headers(ownerToken), to: "/api/servers/\(serverId)")
            #expect(ownerDelete.status == .ok)
            #expect(accounts.oauth.serverIdsForMember(userId: ownerId).contains(serverId) == false)
            let repeated = try await client.send(.delete, headers: headers(ownerToken), to: "/api/servers/\(serverId)")
            #expect(repeated.status == .ok)
        }
    }
}
