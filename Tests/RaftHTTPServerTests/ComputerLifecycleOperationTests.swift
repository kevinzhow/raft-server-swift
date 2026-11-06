import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func computerLifecycleOperationValidatesIdentityAuthorityAndOnlineState() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111674"
    let memberId = "11111111-1111-4111-8111-111111111675"
    let serverId = "33333333-3333-4333-8333-333333333691"
    for (id, email) in [
        (ownerId, "lifecycle-owner@slock.test"),
        (memberId, "lifecycle-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "lifecycle", name: "Lifecycle", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let managedMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "lifecycle-machine")
    accounts.linkComputerForTesting(serverId: serverId, machineId: managedMachine, attachedByUserId: ownerId)
    let rawMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "raw-machine")
    let operationId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let parentId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

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
            func run(_ bearer: String, machine: String? = nil, body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                let target = machine ?? managedMachine
                return try await client.send(.post, headers: headers, to: "/api/servers/\(serverId)/machines/\(target)/computer-lifecycle-operations") { request in
                    request.body = .init(string: body)
                }
            }
            let owner = try await token("lifecycle-owner@slock.test")
            let member = try await token("lifecycle-member@slock.test")
            let base = "{\"operationId\":\"\(operationId)\",\"parentOperationId\":\"\(parentId)\""

            #expect(try await run(owner, body: "\(base),\"action\":\"explode\"}").status == .badRequest)
            #expect(try await run(owner, body: "{\"action\":\"start\"}").status == .badRequest)
            #expect(try await run(owner, body: "\(base),\"action\":\"start\",\"targetVersion\":\"1.2.3\"}").status == .badRequest)
            #expect(try await run(owner, body: "\(base),\"action\":\"stop\",\"completionMode\":\"legacy_k_promoted\"}").status == .badRequest)
            #expect(try await run(member, body: "\(base),\"action\":\"start\"}").status == .forbidden)
            #expect(try await run(owner, machine: rawMachine, body: "\(base),\"action\":\"start\"}").status == .conflict)

            let started = try await run(owner, body: "\(base),\"action\":\"start\"}")
            #expect(started.status == .created)
            let startedBody = try JSONSerialization.jsonObject(with: Data((started.body.string ?? "").utf8)) as? [String: Any]
            #expect(startedBody?["operationId"] as? String == operationId)
            #expect(startedBody?["action"] as? String == "start")
            #expect(startedBody?["dispatchMode"] as? String == "local")

            accounts.setMachineOnline(machineId: managedMachine, online: true)
            #expect(try await run(owner, body: "\(base),\"action\":\"start\"}").status == .conflict)
            #expect(try await run(owner, body: "\(base),\"action\":\"stop\"}").status == .created)
            #expect(try await run(owner, body: "\(base),\"action\":\"upgrade\"}").status == .conflict)
            #expect(try await run(owner, body: "\(base),\"action\":\"upgrade\",\"completionMode\":\"legacy_k_promoted\",\"targetVersion\":\"1.2.3\"}").status == .conflict)
            #expect(try await run(owner, body: "\(base),\"action\":\"upgrade\",\"targetVersion\":\"1.2.3\"}").status == .created)
            accounts.setMachineOnline(machineId: managedMachine, online: false)
            #expect(try await run(owner, body: "\(base),\"action\":\"stop\"}").status == .conflict)
            #expect(try await run(owner, machine: "missing-machine", body: "\(base),\"action\":\"start\"}").status == .notFound)
        }
    }
}
