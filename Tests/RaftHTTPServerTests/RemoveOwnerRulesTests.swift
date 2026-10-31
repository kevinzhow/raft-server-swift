import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func anotherOwnerCanBeRemovedButNeverTheLastOne() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111421"
    let adminId = "11111111-1111-4111-8111-111111111422"
    let secondOwnerId = "11111111-1111-4111-8111-111111111423"
    let serverId = "33333333-3333-4333-8333-333333333545"
    for (id, email) in [
        (ownerId, "remove-owner@slock.test"),
        (adminId, "remove-admin@slock.test"),
        (secondOwnerId, "remove-second-owner@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "remove-owner", name: "Remove Owner", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: secondOwnerId, role: "owner")

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
            let ownerToken = try await login("remove-owner@slock.test")
            let adminToken = try await login("remove-admin@slock.test")
            func remove(_ token: String, _ targetId: String) async throws -> ClientResponse {
                try await client.send(.delete, headers: headers(token), to: "/api/servers/\(serverId)/members/\(targetId)")
            }

            #expect(try await remove(adminToken, secondOwnerId).status == .forbidden)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: secondOwnerId) == "owner")
            #expect(try await remove(ownerToken, secondOwnerId).status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: secondOwnerId) == nil)
            #expect(try await remove(ownerToken, ownerId).status == .badRequest)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: ownerId) == "owner")
        }
    }
}
