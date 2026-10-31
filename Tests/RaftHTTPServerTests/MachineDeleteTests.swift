import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func deletingAMachineRemovesItAndRefusesLaterDeletes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111389"
    let memberId = "11111111-1111-4111-8111-111111111390"
    let serverId = "33333333-3333-4333-8333-333333333527"
    accounts.addAccount(id: ownerId, email: "machine-delete-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "machine-delete-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "machine-delete", name: "Machine Delete", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "delete-me")
    let otherMachineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "keep-me")

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
            let ownerToken = try await login("machine-delete-owner@slock.test")
            let memberToken = try await login("machine-delete-member@slock.test")

            #expect(try await client.send(.delete, headers: headers(memberToken), to: "/api/servers/\(serverId)/machines/\(machineId)").status == .forbidden)
            let removed = try await client.send(.delete, headers: headers(ownerToken), to: "/api/servers/\(serverId)/machines/\(machineId)")
            #expect(removed.status == .ok)
            #expect(accounts.machineCount(serverId: serverId) == 1)

            let list = try await client.send(.get, headers: headers(ownerToken), to: "/api/servers/\(serverId)/machines")
            let rows = (try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [String: Any])?["machines"] as? [[String: Any]] ?? []
            #expect(rows.compactMap { $0["id"] as? String } == [otherMachineId])

            #expect(try await client.send(.delete, headers: headers(ownerToken), to: "/api/servers/\(serverId)/machines/\(machineId)").status == .notFound)
        }
    }
}
