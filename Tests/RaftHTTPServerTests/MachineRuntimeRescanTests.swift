import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func runtimeRescanRequiresAnOnlineMachineAndManagementAuthority() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111662"
    let memberId = "11111111-1111-4111-8111-111111111663"
    let serverId = "33333333-3333-4333-8333-333333333685"
    for (id, email) in [
        (ownerId, "rescan-owner@slock.test"),
        (memberId, "rescan-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "rescan", name: "Rescan", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "rescan-machine")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func rescan(_ bearer: String, _ machineId: String = machine) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                return try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/machines/\(machineId)/runtimes/rescan")
            }
            let owner = try await token("rescan-owner@slock.test")
            let member = try await token("rescan-member@slock.test")

            let offline = try await rescan(owner)
            #expect(offline.status == .conflict)
            let offlineBody = try JSONSerialization.jsonObject(with: Data((offline.body.string ?? "").utf8)) as? [String: Any]
            #expect(offlineBody?["error"] as? String == "Computer is offline")

            accounts.setMachineOnline(machineId: machine, online: true)
            let online = try await rescan(owner)
            #expect(online.status == .ok)
            let onlineBody = try JSONSerialization.jsonObject(with: Data((online.body.string ?? "").utf8)) as? [String: Any]
            #expect(onlineBody?["requested"] as? Bool == true)
            #expect(try await rescan(member).status == .forbidden)
            #expect(try await rescan(owner, "missing-machine").status == .notFound)
        }
    }
}
