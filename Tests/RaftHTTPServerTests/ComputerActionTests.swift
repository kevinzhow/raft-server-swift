import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
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

@Test func computerControlRequiresAReportedVersionAndReturnsRequestIdentity() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111415"
    let serverId = "33333333-3333-4333-8333-333333333541"
    accounts.addAccount(id: ownerId, email: "computer-version-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "computer-version", name: "Computer Version", ownerId: ownerId)
    let unversioned = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "unversioned-computer")
    accounts.linkComputerForTesting(serverId: serverId, machineId: unversioned, online: true, version: nil)
    let live = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "live-computer")
    accounts.linkComputerForTesting(serverId: serverId, machineId: live, online: true, version: "1.0.0")
    let future = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "future-computer")
    accounts.linkComputerForTesting(serverId: serverId, machineId: future, online: true, version: "99.0.0")

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
                request.body = .init(string: "{\"email\":\"computer-version-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func action(_ machineId: String, _ action: String, _ body: String = "{}") async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/machines/\(machineId)/computer/\(action)") { request in
                    request.body = .init(string: body)
                }
            }
            func json(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let missingTarget = try await action(unversioned, "upgrade")
            #expect(missingTarget.status == .badRequest)
            #expect(try json(missingTarget)["code"] as? String == "invalid_target_version")

            let unsupported = try await action(unversioned, "restart")
            #expect(unsupported.status == .conflict)
            #expect(try json(unsupported)["code"] as? String == "computer_control_unsupported")
            #expect(try json(unsupported)["error"] as? String == "Raft couldn't verify the Computer version. Reconnect the Computer, then try again.")

            let restarted = try await action(live, "restart")
            #expect(restarted.status == .ok)
            let restartedBody = try json(restarted)
            #expect(restartedBody["ok"] as? Bool == true)
            #expect(restartedBody["action"] as? String == "restart")
            #expect(restartedBody["requestId"] is String)
            #expect(restartedBody["operationId"] is String)

            #expect(try await action(future, "restart").status == .ok)
        }
    }
}
