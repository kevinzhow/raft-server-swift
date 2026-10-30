import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func aDemotedMachineRegistrantKeepsOnlyTheExactMachine() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111263"
    let adminId = "11111111-1111-4111-8111-111111111262"
    let serverId = "33333333-3333-4333-8333-333333333451"
    accounts.addAccount(id: ownerId, email: "machine-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: adminId, email: "machine-admin@slock.test", password: "password123")
    accounts.markEmailVerified(userId: adminId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "machine-rbac", name: "Machine RBAC", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    let ownMachine = accounts.registerMachine(serverId: serverId, userId: adminId, name: "Admin machine")
    let foreignMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Owner machine")

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
                request.body = .init(string: "{\"email\":\"machine-admin@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            func patch(_ machineId: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/machines/\(machineId)") { request in
                    request.body = .init(string: "{\"description\":\"edited\"}")
                }
            }

            accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "member")
            #expect(try await patch(ownMachine).status == .ok)
            #expect(try await patch(foreignMachine).status == .forbidden)

            let rotated = try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/machines/\(ownMachine)/rotate-key")
            #expect(rotated.status == .ok)
            #expect(((try JSONSerialization.jsonObject(with: Data((rotated.body.string ?? "").utf8)) as? [String: Any])?["apiKey"] as? String)?.isEmpty == false)
            let foreignRotate = try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/machines/\(foreignMachine)/rotate-key")
            #expect(foreignRotate.status == .forbidden)
            let foreignDelete = try await client.send(.delete, headers: headers, to: "/api/servers/\(serverId)/machines/\(foreignMachine)")
            #expect(foreignDelete.status == .forbidden)
            let ownDelete = try await client.send(.delete, headers: headers, to: "/api/servers/\(serverId)/machines/\(ownMachine)")
            #expect(ownDelete.status == .ok)

            accounts.oauth.removeMember(serverId: serverId, userId: adminId)
            #expect(try await patch(ownMachine).status == .forbidden)
        }
    }
}
