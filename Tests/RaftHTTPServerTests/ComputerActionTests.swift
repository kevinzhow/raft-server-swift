import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func computerControlNeedsManageMachinesAndAReachableComputer() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111413"
    let memberId = "11111111-1111-4111-8111-111111111414"
    let serverId = "33333333-3333-4333-8333-333333333540"
    accounts.addAccount(id: ownerId, email: "computer-control-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "computer-control-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "computer-control", name: "Computer Control", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let rawMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "raw-daemon-machine")
    let offlineMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "offline-computer")
    accounts.linkComputerForTesting(serverId: serverId, machineId: offlineMachine, online: false)

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
            let ownerToken = try await login("computer-control-owner@slock.test")
            let memberToken = try await login("computer-control-member@slock.test")
            func action(_ token: String, _ machineId: String, _ action: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/servers/\(serverId)/machines/\(machineId)/computer/\(action)")
            }
            func code(_ response: ClientResponse) throws -> String? {
                try (JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String
            }

            #expect(try await action(memberToken, offlineMachine, "restart").status == .forbidden)
            let unknown = try await action(ownerToken, rawMachine, "frobnicate")
            #expect(unknown.status == .badRequest)
            #expect(try code(unknown) == "unknown_action")
            let raw = try await action(ownerToken, rawMachine, "restart")
            #expect(raw.status == .conflict)
            #expect(try code(raw) == "not_a_computer")
            let offline = try await action(ownerToken, offlineMachine, "restart")
            #expect(offline.status == .conflict)
            #expect(try code(offline) == "computer_offline")

            accounts.linkComputerForTesting(serverId: serverId, machineId: offlineMachine, online: true)
            #expect(try await action(ownerToken, offlineMachine, "restart").status == .ok)
        }
    }
}
