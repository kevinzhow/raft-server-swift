import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private final class LeaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(machineId: String, role: String)] = []

    func append(_ machineId: String, _ role: String) {
        lock.lock()
        storage.append((machineId, role))
        lock.unlock()
    }

    var values: [(machineId: String, role: String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct MachineMigrationFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let source: String
    let target: String
    let agent: String
}

private func makeMachineMigrationFixture(suffix: String) -> MachineMigrationFixture {
    let accounts = EmailLoginDirectory()
    let n = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 1_010_000 + n)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 1_010_000 + n)
    let ownerEmail = "machine-transport-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "machine-transport-\(suffix)", name: "Machine Transport", ownerId: ownerId)
    let source = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "source-\(suffix)")
    let target = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "target-\(suffix)")
    accounts.setMachineRuntimesForTesting(machineId: source, runtimes: ["codex"])
    accounts.setMachineRuntimesForTesting(machineId: target, runtimes: ["codex"])
    accounts.setMachineOnline(machineId: target, online: true)
    accounts.machineMigrationCapabilities[source] = ["migration/v3"]
    accounts.machineMigrationCapabilities[target] = ["migration/v3"]
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "transport-agent-\(suffix)", creatorUserId: ownerId, runtime: "codex")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: source)
    return MachineMigrationFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        source: source,
        target: target,
        agent: agent
    )
}

private func transportLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func transportHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func transportObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func machineMigrationProvisionsLeasesAndReportsTransportFailure() async throws {
    let fixture = makeMachineMigrationFixture(suffix: "1501")
    let leases = LeaseCollector()
    fixture.accounts.installMachineMigrationLeaseDispatchForTesting { machineId, role, _ in
        leases.append(machineId, role)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await transportLogin(client, email: fixture.ownerEmail)
            let headers = transportHeaders(token, fixture.serverId)
            func migrate(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: "/api/agents/\(fixture.agent)/migrate")) { request in
                    request.body = .init(string: body)
                }
            }
            let started = try await migrate("{\"targetComputer\":\"\(fixture.target)\"}")
            #expect(started.status == .ok)
            let startedBody = try transportObject(started)
            let ref = try #require(startedBody["migrationRef"] as? String)
            #expect(ref.hasPrefix("mig_"))
            #expect(startedBody["state"] as? String == "provisioning")
            #expect(startedBody["sourceMachineId"] as? String == fixture.source)
            #expect(startedBody["targetMachineId"] as? String == fixture.target)
            #expect(startedBody["prepDeadlineAt"] is String)
            #expect(!startedBody.keys.contains("migrationId"))
            #expect(leases.values.map { "\($0.machineId):\($0.role)" } == ["\(fixture.source):source", "\(fixture.target):target"])

            let duplicate = try await migrate("{\"targetComputer\":\"\(fixture.target)\"}")
            #expect(duplicate.status == .conflict)
            #expect(try transportObject(duplicate)["code"] as? String == "MIGRATION_ALREADY_IN_PROGRESS")

            let status = try await client.get(URI(string: "/api/agents/\(fixture.agent)/migration"), headers: headers)
            #expect(status.status == .ok)
            let migration = try #require(try transportObject(status)["migration"] as? [String: Any])
            #expect(migration["migrationRef"] as? String == ref)
            #expect(migration["state"] as? String == "provisioning")
            #expect(migration["targetMachineId"] as? String == fixture.target)
            #expect(!migration.keys.contains("transportControlManifest"))
            #expect(!migration.keys.contains("sourceTransportTokenHash"))
            #expect(!migration.keys.contains("targetTransportTokenHash"))
            #expect(!migration.keys.contains("transferSummary"))

            fixture.accounts.markMachineMigrationTransportLostForTesting(
                supportRef: ref,
                message: "MIGRATION_OBJECT_STORE_DOWNLOAD_RETRY_EXHAUSTED:404"
            )
            let failed = try await client.get(URI(string: "/api/agents/\(fixture.agent)/migration"), headers: headers)
            let failedMigration = try #require(try transportObject(failed)["migration"] as? [String: Any])
            #expect(failedMigration["state"] as? String == "failed")
            #expect(failedMigration["failureReason"] as? String == "MIGRATION_TRANSPORT_LOST")
            #expect(failedMigration["transportErrorCode"] as? String == "MIGRATION_TRANSPORT_LOST")
            #expect(failedMigration["transportErrorMessage"] as? String == "MIGRATION_OBJECT_STORE_DOWNLOAD_RETRY_EXHAUSTED:404")
            #expect(failedMigration["transportLostAt"] is String)
            #expect(failedMigration["transportTeardownAt"] is String)
        }
    }
}

@Test func machineMigrationAdmissionGatesRefuseBeforeCreatingState() async throws {
    let fixture = makeMachineMigrationFixture(suffix: "1502")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await transportLogin(client, email: fixture.ownerEmail)
            let headers = transportHeaders(token, fixture.serverId)
            func migrate(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: "/api/agents/\(fixture.agent)/migrate")) { request in
                    request.body = .init(string: body)
                }
            }
            func statusMigration() async throws -> Any? {
                let response = try await client.get(URI(string: "/api/agents/\(fixture.agent)/migration"), headers: headers)
                return try transportObject(response)["migration"]
            }

            fixture.accounts.machineMigrationCapabilities[fixture.target] = ["migration:chunk-upload-v1"]
            let capability = try await migrate("{\"targetComputer\":\"\(fixture.target)\"}")
            #expect(capability.status == .init(code: 422, reasonPhrase: "Unprocessable Entity"))
            let capabilityBody = try transportObject(capability)
            #expect(capabilityBody["code"] as? String == "MIGRATION_RESUMABLE_CAPABILITY_REQUIRED")
            #expect((capabilityBody["details"] as? [String: Any])?["side"] as? String == "target")
            #expect(try await statusMigration() is NSNull)

            fixture.accounts.machineMigrationCapabilities[fixture.target] = ["migration/v3"]
            fixture.accounts.setMachineOnline(machineId: fixture.target, online: false)
            let offline = try await migrate("{\"targetComputer\":\"\(fixture.target)\"}")
            #expect(offline.status == .conflict)
            #expect(try transportObject(offline)["code"] as? String == "TARGET_COMPUTER_OFFLINE")

            fixture.accounts.setMachineOnline(machineId: fixture.target, online: true)
            fixture.accounts.setMachineRuntimeDetectionForTesting(machineId: fixture.target, status: "pending")
            let pending = try await migrate("{\"targetComputer\":\"\(fixture.target)\"}")
            #expect(pending.status == .conflict)
            #expect(try transportObject(pending)["code"] as? String == "TARGET_RUNTIME_DETECTION_PENDING")
            fixture.accounts.setMachineRuntimeDetectionForTesting(machineId: fixture.target, status: nil)

            fixture.accounts.setMigrationServerPlanForTesting(serverId: fixture.serverId, plan: "free")
            let free = try await migrate("{\"targetComputer\":\"\(fixture.target)\"}")
            #expect(free.status == .forbidden)
            #expect(try transportObject(free)["code"] as? String == "MIGRATION_PRO_PLAN_REQUIRED")
            fixture.accounts.setMigrationServerPlanForTesting(serverId: fixture.serverId, plan: nil)

            fixture.accounts.installMachineMigrationProvisionerForTesting { _, _ in nil }
            let failed = try await migrate("{\"targetComputer\":\"\(fixture.target)\"}")
            #expect(failed.status == .init(code: 422, reasonPhrase: "Unprocessable Entity"))
            #expect(try transportObject(failed)["code"] as? String == "MIGRATION_TRANSPORT_PROVISION_FAILED")
            #expect(try await statusMigration() is NSNull)
        }
    }
}
