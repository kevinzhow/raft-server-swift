import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private final class MigrationCancelDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(machineId: String, role: String, ref: String, generation: String, stopAgent: Bool)] = []

    func append(_ machineId: String, _ role: String, _ ref: String, _ generation: String, _ stopAgent: Bool) {
        lock.lock()
        storage.append((machineId, role, ref, generation, stopAgent))
        lock.unlock()
    }

    var deliveries: [(machineId: String, role: String, ref: String, generation: String, stopAgent: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Test func machineMigrationCancelDispatchesTheFrozenGenerationToBothComputers() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001004001"
    let ownerId = "11111111-1111-4111-8111-000001004001"
    let memberId = "11111111-1111-4111-8111-000001004002"
    let ownerEmail = "migration-cancel-owner@slock.test"
    let memberEmail = "migration-cancel-member@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "migration-cancel", name: "Migration Cancel", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let source = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "cancel-source")
    let target = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "cancel-target")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "cancel-agent", creatorUserId: ownerId)
    let ref = "mig_" + String(repeating: "c", count: 22)
    accounts.seedMachineMigrationForTesting(
        agentId: agent,
        serverId: serverId,
        supportRef: ref,
        revision: 5,
        state: "in_transit",
        sourceMachineId: source,
        targetMachineId: target,
        transportGeneration: "route-transport-generation"
    )
    let dispatcher = MigrationCancelDispatcher()
    accounts.agentsRuntimeStore.agentMigrationCancelDispatch = { machineId, role, ref, generation, stopAgent in
        dispatcher.append(machineId, role, ref, generation, stopAgent)
    }

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
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func cancel(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: URI(string: "/api/agents/\(agent)/migration/cancel")) { request in
                    request.body = .init(string: body)
                }
            }
            let owner = try await login(ownerEmail)
            let member = try await login(memberEmail)

            let status = try await client.get(URI(string: "/api/agents/\(agent)/migration"), headers: headers(owner))
            let statusMigration = try #require(((try JSONSerialization.jsonObject(with: Data((status.body.string ?? "").utf8))) as? [String: Any])?["migration"] as? [String: Any])
            #expect(statusMigration["migrationRef"] as? String == ref)
            #expect(statusMigration["state"] as? String == "in_transit")
            #expect(statusMigration["revision"] as? Int == 5)
            #expect(statusMigration["targetMachineId"] as? String == target)
            #expect(statusMigration["targetKind"] as? String == "computer")

            let denied = try await cancel(member, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":5}")
            #expect(denied.status == .forbidden)
            #expect(dispatcher.deliveries.isEmpty)

            for body in [
                "{\"migrationId\":\"internal\",\"expectedRevision\":5}",
                "{\"migrationRef\":\"\(ref)\",\"migrationId\":\"internal\",\"expectedRevision\":5}",
                "{\"migrationRef\":\"bad-ref\",\"expectedRevision\":5}",
            ] {
                let invalid = try await cancel(owner, body)
                #expect(invalid.status == .badRequest)
                #expect(((try JSONSerialization.jsonObject(with: Data((invalid.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "MIGRATION_REF_INVALID")
            }
            #expect(dispatcher.deliveries.isEmpty)

            let notFound = try await cancel(owner, "{\"migrationRef\":\"mig_dddddddddddddddddddddd\",\"expectedRevision\":5}")
            #expect(notFound.status == .notFound)
            let stale = try await cancel(owner, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":4}")
            #expect(stale.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((stale.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "MIGRATION_REVISION_STALE")

            let canceled = try await cancel(owner, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":5,\"reason\":\"owner requested\"}")
            #expect(canceled.status == .ok)
            let body = (try JSONSerialization.jsonObject(with: Data((canceled.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let migration = try #require(body["migration"] as? [String: Any])
            #expect(migration["migrationRef"] as? String == ref)
            #expect(migration["state"] as? String == "canceled_pre_flip")
            #expect(migration["revision"] as? Int == 6)
            #expect(migration["cancelReason"] as? String == "owner requested")
            #expect(migration["cancelNeedsAttention"] as? Bool == false)
            #expect(migration["cancelDispatchAttempts"] as? Int == 1)
            #expect(migration["cancelLastDispatchAt"] is String)
            #expect(migration["cancelErrorCode"] is NSNull)
            #expect(!migration.keys.contains("migrationId"))

            let deliveries = dispatcher.deliveries
            #expect(deliveries.count == 2)
            #expect(deliveries.map { $0.machineId } == [source, target])
            #expect(deliveries.map { $0.role } == ["source", "target"])
            #expect(deliveries.allSatisfy { $0.ref == ref && $0.generation == "route-transport-generation" && $0.stopAgent == false })

            let terminal = try await cancel(owner, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":6}")
            #expect(terminal.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((terminal.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "MIGRATION_NOT_CANCELABLE")
        }
    }
}
