import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func machineRuntimeQueriesRequireAuthorityAndAnActualProductionBridge() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111650"
    let memberId = "11111111-1111-4111-8111-111111111651"
    let serverId = "33333333-3333-4333-8333-333333333681"
    for (id, email) in [
        (ownerId, "runtime-options-owner@slock.test"),
        (memberId, "runtime-options-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-options", name: "Runtime Options", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "runtime-machine")

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
            func get(_ bearer: String, _ path: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                return try await client.get(URI(string: path), headers: headers)
            }
            let owner = try await token("runtime-options-owner@slock.test")
            let member = try await token("runtime-options-member@slock.test")
            let base = "/api/servers/\(serverId)/machines/\(machine)"

            #expect(try await get(member, "\(base)/runtime-options").status == .forbidden)
            // Positive inventory/model assertions now use the real PG/NIO
            // postgresPublishedInventoryAndMachineQueries scene.

            #expect(try await get(member, "\(base)/runtime-models/codex").status == .forbidden)
            let modelsResponse = try await get(owner, "\(base)/runtime-models/codex")
            #expect(modelsResponse.status == .ok)
            let modelsBody = try JSONSerialization.jsonObject(with: Data((modelsResponse.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(modelsBody as NSDictionary == ["kind": "error", "retryable": true, "code": "computer_offline"] as NSDictionary)

        }
    }
}
