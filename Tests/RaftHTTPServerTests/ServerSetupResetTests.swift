import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func setupResetIsOwnerOnlyAndRefusesAfterAnAgentExists() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111671"
    let adminId = "11111111-1111-4111-8111-111111111672"
    let memberId = "11111111-1111-4111-8111-111111111673"
    let serverId = "33333333-3333-4333-8333-333333333690"
    for (id, email, role) in [
        (ownerId, "setup-owner@slock.test", "owner"),
        (adminId, "setup-admin@slock.test", "admin"),
        (memberId, "setup-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "setup", name: "Setup", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "setup-machine")
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, attachedByUserId: ownerId)

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
            func post(_ bearer: String?, _ path: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                return try await client.send(.post, headers: headers, to: URI(string: path))
            }
            let owner = try await token("setup-owner@slock.test")
            let admin = try await token("setup-admin@slock.test")
            let member = try await token("setup-member@slock.test")
            let reset = "/api/servers/\(serverId)/setup-reset"
            let handoff = "/api/servers/\(serverId)/setup-handoff"

            #expect(try await post(admin, reset).status == .forbidden)
            #expect(try await post(member, reset).status == .forbidden)
            let resetResponse = try await post(owner, reset)
            #expect(resetResponse.status == .ok)
            let resetBody = try JSONSerialization.jsonObject(with: Data((resetResponse.body.string ?? "").utf8)) as? [String: Any]
            #expect(resetBody?["phase"] as? String == "not_started")
            #expect(resetBody?["revokedComputers"] as? Int == 1)

            let agent = accounts.oauth.createAgent(serverId: serverId, name: "setup-agent")
            accounts.addServerAgent(serverId: serverId, id: agent, name: "setup-agent", avatarUrl: nil, status: "inactive")
            let refused = try await post(owner, reset)
            #expect(refused.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((refused.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "SERVER_ALREADY_SET_UP")

            #expect(try await post(admin, handoff).status == .forbidden)
            #expect(try await post(nil, handoff).status == .unauthorized)
            #expect(try await post(owner, "/api/servers/33333333-3333-4333-8333-333333333999/setup-handoff").status == .notFound)
            let handoffResponse = try await post(owner, handoff)
            #expect(handoffResponse.status == .ok)
            #expect(try await post(owner, handoff).status == .ok)
        }
    }
}
