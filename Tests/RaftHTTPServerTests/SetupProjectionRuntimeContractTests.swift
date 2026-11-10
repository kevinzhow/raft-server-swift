import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Acceptance through the public route. No seeded online Bool or transport callback
/// is used as positive live-path evidence; the PG/NIO inventory fixture covers that.
@Test func setupProjectionRespectsTerminalOwnerPhaseAndNodeOwnerOnlyAdmission() async throws {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased(), admin = UUID().uuidString.lowercased()
    let member = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    accounts.addAccount(id: owner, email: "setup-complete-owner@example.test", password: "password123")
    accounts.addAccount(id: admin, email: "setup-complete-admin@example.test", password: "password123")
    accounts.markEmailVerified(userId: owner); accounts.markEmailVerified(userId: admin)
    accounts.oauth.addOwnedServer(id: server, slug: "setup-complete", name: "Setup Complete", ownerId: owner)
    accounts.oauth.addMember(serverId: server, userId: admin, role: "admin")
    accounts.addAccount(id: member, email: "setup-complete-member@example.test", password: "password123")
    accounts.markEmailVerified(userId: member)
    accounts.oauth.addMember(serverId: server, userId: member, role: "member")
    accounts.serversAndChannelsStore.setSetupPhase(serverId: server, userId: owner, phase: "complete")
    accounts.serversAndChannelsStore.setSetupPhase(serverId: server, userId: admin, phase: "complete")
    let ownerToken = accounts.mintAccessTokenForTesting(userId: owner)
    let adminToken = accounts.mintAccessTokenForTesting(userId: admin)
    let memberToken = accounts.mintAccessTokenForTesting(userId: member)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            // The pinned router mounts every `/:id` setup route behind
            // `requireServerMatchesParam`; the live client always sends the header.
            func projection(_ token: String) async throws -> [String: Any] {
                var headers = HTTPFields(); headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = server
                let response = try await client.send(.get, headers: headers, to: "/api/servers/\(server)/setup-projection")
                #expect(response.status == .ok)
                return try #require(try JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any])
            }
            func complete(_ token: String) async throws -> ClientResponse {
                var headers = HTTPFields(); headers[.authorization] = "Bearer \(token)"; headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = server
                return try await client.send(.post, headers: headers, to: "/api/servers/\(server)/setup-transition") { request in
                    request.body = .init(string: "{\"action\":\"complete\"}")
                }
            }
            func transition(_ token: String, _ action: String) async throws -> ClientResponse {
                var headers = HTTPFields(); headers[.authorization] = "Bearer \(token)"; headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = server
                return try await client.send(.post, headers: headers, to: "/api/servers/\(server)/setup-transition") { request in
                    request.body = .init(string: "{\"action\":\"\(action)\"}")
                }
            }
            // Every accepted start/complete is owner-only. Invalid legacy actions
            // are rejected before actor authority, matching the Node route.
            for forbidden in [adminToken, memberToken] {
                let denied = try await transition(forbidden, "start")
                #expect(denied.status == .forbidden)
                #expect(denied.body.string == "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
            }
            for action in ["reset", "return_to_server", "defer", "unknown"] {
                for token in [ownerToken, adminToken, memberToken] {
                    let invalid = try await transition(token, action)
                    #expect(invalid.status == .badRequest)
                    #expect(invalid.body.string == "{\"error\":\"INVALID_SETUP_ACTION\"}")
                }
            }
            let restarted = try await transition(ownerToken, "start")
            #expect(restarted.status == .ok)
            #expect(accounts.serversAndChannelsStore.setupPhase(serverId: server, userId: owner) == "complete")
            // Terminal completion is idempotent even with no current Computer.
            for _ in 0..<2 { #expect(try await complete(ownerToken).status == .ok) }
            for forbidden in [adminToken, memberToken] {
                let response = try await complete(forbidden)
                #expect(response.status == .forbidden)
                #expect(response.body.string == "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
            }
            let completed = try await projection(ownerToken)
            let expected: [String: Any] = [
                "surface": "complete", "phase": "complete", "currentStep": NSNull(), "blocksChat": false,
                "allowedExits": ["return_to_server"], "sideEffectState": ["transitions": "disabled", "completion": "disabled"],
                "gateReason": "setup_complete", "computerStatus": "unknown", "runtimeStatus": "unknown", "runtimeOptions": [],
                "hasConnectedComputer": false, "offlineComputers": [], "postSetup": ["surveyPending": false, "handoffPending": false],
            ]
            #expect(completed as NSDictionary == expected as NSDictionary)
            let administrative = try await projection(adminToken)
            #expect(administrative["surface"] as? String == "none")
            #expect(administrative["blocksChat"] as? Bool == false)
            #expect(administrative["phase"] is NSNull)
            #expect(administrative["gateReason"] as? String == "insufficient_permission")
            // A read must never write or upgrade the stored phase.
            #expect(accounts.serversAndChannelsStore.setupPhase(serverId: server, userId: owner) == "complete")
            accounts.serversAndChannelsStore.setSetupPhase(serverId: server, userId: owner, phase: "in_progress")
            let unusable = try await complete(ownerToken)
            #expect(unusable.status == .conflict)
            #expect(unusable.body.string == "{\"error\":\"OFFICIAL_ONBOARDING_AGENT_NOT_USABLE\"}")
            let noComputer = try await projection(ownerToken)
            #expect(noComputer["surface"] as? String == "computer_runtime")
            #expect(noComputer["blocksChat"] as? Bool == true)
            #expect(noComputer["gateReason"] as? String == "computer_offline")
            #expect(noComputer["hasConnectedComputer"] as? Bool == false)
            #expect((noComputer["offlineComputers"] as? [Any])?.isEmpty == true)
            #expect((noComputer["runtimeOptions"] as? [Any])?.isEmpty == true)
            #expect(accounts.serversAndChannelsStore.setupPhase(serverId: server, userId: owner) == "in_progress")
            accounts.serversAndChannelsStore.setSetupPhase(serverId: server, userId: owner, phase: "deferred")
            #expect(try await projection(ownerToken)["blocksChat"] as? Bool == false)
            let anonymous = try await client.get("/api/servers/\(server)/setup-projection")
            #expect(anonymous.status == .unauthorized)
        }
    }
}
