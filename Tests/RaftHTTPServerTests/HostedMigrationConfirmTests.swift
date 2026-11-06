import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private final class MigrationEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []

    func append(room: String, event: String, payload: String?) {
        lock.lock()
        storage.append((room, event, payload))
        lock.unlock()
    }

    var events: [(room: String, event: String, payload: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Test func hostedMigrationConfirmationChecksGateAuthorityAndRevision() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111721"
    let adminId = "11111111-1111-4111-8111-111111111722"
    let memberId = "11111111-1111-4111-8111-111111111723"
    let creatorId = "11111111-1111-4111-8111-111111111724"
    let serverId = "33333333-3333-4333-8333-333333333725"
    for (id, email, role) in [
        (ownerId, "migration-owner@slock.test", "owner"),
        (adminId, "migration-admin@slock.test", "admin"),
        (memberId, "migration-member@slock.test", "member"),
        (creatorId, "migration-creator@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "migration", name: "Migration", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "migration-source")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "migration-agent", creatorUserId: ownerId)
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    let creatorAgent = accounts.oauth.createAgent(serverId: serverId, name: "creator-agent", creatorUserId: creatorId)
    accounts.setAgentMachineForTesting(agentId: creatorAgent, machineId: machine)
    let ref = "mig_abcdefghijklmnopqrstuv"
    let events = MigrationEventBox()
    accounts.realtimeEmitter = { room, event, payload in
        events.append(room: room, event: event, payload: payload)
    }

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
            func confirm(_ bearer: String?, body: String, agentId: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                if let bearer { headers[.authorization] = "Bearer \(bearer)" }
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: headers, to: "/api/agents/\(agentId ?? agent)/migration/confirm-hosted") { request in
                    request.body = .init(string: body)
                }
            }
            func payload(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let owner = try await token("migration-owner@slock.test")
            let member = try await token("migration-member@slock.test")
            let creator = try await token("migration-creator@slock.test")
            let valid = "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":1}"

            #expect(try await confirm(nil, body: valid).status == .unauthorized)
            let gated = try await confirm(owner, body: valid)
            #expect(gated.status == .forbidden)
            #expect(payload(gated)["code"] as? String == "agent_migration_ui_disabled")
            #expect((payload(gated)["details"] as? [String: Any])?["failureReason"] as? String == "agent_migration_ui_disabled")

            accounts.enableAgentMigrationForTesting(serverId: serverId)
            let missing = try await confirm(owner, body: valid, agentId: "missing-agent")
            #expect(missing.status == .notFound)
            #expect(payload(missing)["code"] as? String == "AGENT_NOT_FOUND")
            let refused = try await confirm(member, body: valid)
            #expect(refused.status == .forbidden)
            #expect(payload(refused)["code"] as? String == "not_supported")

            let hostedOff = try await confirm(owner, body: valid)
            #expect(hostedOff.status == .forbidden)
            #expect(payload(hostedOff)["code"] as? String == "HOSTED_TARGET_UNAVAILABLE")

            accounts.enableHostedMigrationForTesting(serverId: serverId)
            for badRef in ["", "mig_short", "mig_abcdefghijklmnopqrstu!", "xig_abcdefghijklmnopqrstuv"] {
                let invalid = try await confirm(owner, body: "{\"migrationRef\":\"\(badRef)\",\"expectedRevision\":1}")
                #expect(invalid.status == .badRequest, "ref \(badRef)")
                #expect(payload(invalid)["code"] as? String == "MIGRATION_REF_INVALID")
            }
            for badRevision in ["0", "-1", "1.5", "\"1\"", "null"] {
                let invalid = try await confirm(owner, body: "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":\(badRevision)}")
                #expect(invalid.status == .badRequest, "revision \(badRevision)")
                #expect(payload(invalid)["code"] as? String == "MIGRATION_REVISION_INVALID")
            }

            let notFound = try await confirm(owner, body: valid)
            #expect(notFound.status == .notFound)
            #expect(payload(notFound)["code"] as? String == "MIGRATION_NOT_FOUND")

            accounts.seedHostedMigrationForTesting(agentId: agent, serverId: serverId, supportRef: ref, revision: 2, sourceMachineId: machine)
            let stale = try await confirm(owner, body: valid)
            #expect(stale.status == .conflict)
            #expect(payload(stale)["code"] as? String == "MIGRATION_REVISION_STALE")

            accounts.seedHostedMigrationForTesting(agentId: agent, serverId: serverId, supportRef: ref, revision: 1, state: "arriving", sourceMachineId: machine)
            let notReady = try await confirm(owner, body: valid)
            #expect(notReady.status == .conflict)
            #expect(payload(notReady)["code"] as? String == "HOSTED_REVIEW_NOT_READY")

            accounts.seedHostedMigrationForTesting(agentId: agent, serverId: serverId, supportRef: ref, revision: 1, sourceMachineId: machine)
            accounts.setHostedRuntimeStateForTesting(agentId: agent, state: "active")
            let used = try await confirm(owner, body: valid)
            #expect(used.status == .conflict)
            #expect(payload(used)["code"] as? String == "HOSTED_TARGET_ALREADY_USED")

            let otherMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "migration-other")
            accounts.setAgentMachineForTesting(agentId: creatorAgent, machineId: otherMachine)
            accounts.seedHostedMigrationForTesting(agentId: creatorAgent, serverId: serverId, supportRef: ref, revision: 1, sourceMachineId: machine)
            let mismatch = try await confirm(creator, body: valid, agentId: creatorAgent)
            #expect(mismatch.status == .conflict)
            #expect(payload(mismatch)["code"] as? String == "HOSTED_REVIEW_NOT_READY")

            accounts.seedHostedMigrationForTesting(agentId: creatorAgent, serverId: serverId, supportRef: ref, revision: 1, sourceMachineId: otherMachine)
            let confirmed = try await confirm(creator, body: valid, agentId: creatorAgent)
            #expect(confirmed.status == .ok)
            let migration = payload(confirmed)["migration"] as? [String: Any]
            #expect(migration?["migrationRef"] as? String == ref)
            #expect(migration?["agentId"] as? String == creatorAgent)
            #expect(migration?["state"] as? String == "arriving")
            #expect(migration?["targetKind"] as? String == "hosted")
            #expect(migration?["targetMachineId"] is NSNull)
            #expect(accounts.oauth.agentRuntimeInfo(id: creatorAgent)?.runtime == "external")
            #expect(accounts.hostedRuntimeStateForTesting(agentId: creatorAgent) == "provisioning")
            let updates = events.events.filter { $0.event == "agent:migration-updated" }
            #expect(updates.map { $0.room } == ["user:\(ownerId)", "user:\(adminId)"])
            let update = updates.first
            let eventBody = (update?.payload.flatMap { $0.data(using: .utf8) })
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            #expect(eventBody?["state"] as? String == "arriving")
            #expect(eventBody?["revision"] as? Int == 2)

            let replay = try await confirm(creator, body: valid, agentId: creatorAgent)
            #expect(replay.status == .conflict)
            #expect(payload(replay)["code"] as? String == "MIGRATION_REVISION_STALE")
        }
    }
}
