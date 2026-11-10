import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
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
    // A completed flow with its `normal` provenance and the owner's first
    // handoff acknowledgment; the reset must clear the whole setup group in the
    // same mutation that clears the phases.
    accounts.serversAndChannelsStore.completeSetup(serverId: serverId, userId: ownerId)
    accounts.serversAndChannelsStore.acknowledgeSetupHandoff(
        serverId: serverId, originalOwnerId: ownerId,
        at: Date(timeIntervalSinceReferenceDate: 812_345_678.5)
    )

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
            func post(_ bearer: String?, _ path: String, headerServerId: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                if let headerServerId { headers[HTTPField.Name("X-Server-Id")!] = headerServerId }
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
            #expect((resetBody?["postSetup"] as? [String: Any])?["surveyPending"] as? Bool == false)
            #expect((resetBody?["postSetup"] as? [String: Any])?["handoffPending"] as? Bool == false)
            #expect(accounts.serversAndChannelsStore.setupCompletionReason(serverId: serverId, userId: ownerId) == nil)
            #expect(accounts.serversAndChannelsStore.setupHandoffReceipt(serverId: serverId, ownerId: ownerId) == nil)

            let agent = accounts.oauth.createAgent(serverId: serverId, name: "setup-agent")
            accounts.addServerAgent(serverId: serverId, id: agent, name: "setup-agent", avatarUrl: nil, status: "inactive")
            let refused = try await post(owner, reset)
            #expect(refused.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((refused.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "SERVER_ALREADY_SET_UP")

            // The three setup routes sit behind the pinned `/:id` lockdown:
            // a matching X-Server-Id plus live membership reach the handler,
            // and an unknown server is 403 `Not a member of this server`.
            #expect(try await post(admin, handoff, headerServerId: serverId).status == .forbidden)
            #expect(try await post(nil, handoff, headerServerId: serverId).status == .unauthorized)
            let unknownHandoff = try await post(
                owner,
                "/api/servers/33333333-3333-4333-8333-333333333999/setup-handoff",
                headerServerId: "33333333-3333-4333-8333-333333333999"
            )
            #expect(unknownHandoff.status == .forbidden)
            #expect(unknownHandoff.body.string == "{\"error\":\"Not a member of this server\"}")
            let handoffResponse = try await post(owner, handoff, headerServerId: serverId)
            #expect(handoffResponse.status == .ok)
            #expect(try await post(owner, handoff, headerServerId: serverId).status == .ok)
        }
    }
}
