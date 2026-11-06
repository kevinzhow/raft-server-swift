import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The migration status service reads two stores and cancels in one critical
/// section per migration family. These tests lock that section: concurrent
/// cancels cannot both pass the revision gate, and a boolean `expectedRevision`
/// keeps the retired `NSNumber` tolerance.

private let machineRef = "mig_" + String(repeating: "c", count: 22)
private let hostedRef = "mig_" + String(repeating: "d", count: 22)

private func makeService(
    directory: EmailLoginDirectory,
    userId: String,
    now: Date
) -> AgentMigrationStatusService {
    AgentMigrationStatusService(
        sessionUserId: { _ in userId },
        oauth: directory.oauth,
        agents: directory.agentsRuntimeStore,
        machines: directory.machinesAndComputersStore,
        emitRealtime: { _, _, _ in },
        cancelDispatch: { _, _, _, _, _ in },
        now: { now }
    )
}

@Test func machineMigrationCancelIsOneStoreCriticalSection() async throws {
    let directory = EmailLoginDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = MachineMigrationRecord(
        agentId: "agent-machine",
        serverId: "server-machine",
        supportRef: machineRef,
        revision: 5,
        state: "in_transit",
        sourceMachineId: "source-machine",
        targetMachineId: "target-machine",
        transportGeneration: "generation-machine"
    )
    directory.machinesAndComputersStore.machineMigrations = [machineRef: record]

    let store = directory.machinesAndComputersStore
    let winners = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
            group.addTask {
                switch store.cancelMachineMigration(
                    agentId: "agent-machine",
                    serverId: "server-machine",
                    migrationRef: machineRef,
                    expectedRevision: 5,
                    reason: "concurrent",
                    now: now
                ) {
                case .canceled: return true
                case .missing, .stale, .terminal: return false
                }
            }
        }
        var total = 0
        for await won in group where won { total += 1 }
        return total
    }

    #expect(winners == 1)
    let stored = try #require(store.machineMigrations[machineRef])
    #expect(stored.revision == 6)
    #expect(stored.state == "canceled_pre_flip")
    #expect(stored.cancelReason == "concurrent")
    #expect(stored.canceledAt == now)
    #expect(stored.cancelLastDispatchAt == now)
    #expect(stored.cancelDispatchAttempts == 1)
    #expect(stored.cancelGeneration != nil)
}

@Test func hostedMigrationCancelIsOneStoreCriticalSection() async throws {
    let directory = EmailLoginDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = HostedMigrationRecord(
        agentId: "agent-hosted",
        serverId: "server-hosted",
        supportRef: hostedRef,
        revision: 3,
        state: "in_transit",
        sourceMachineId: "source-hosted"
    )
    directory.agentsRuntimeStore.hostedMigrations = ["agent-hosted": record]

    let store = directory.agentsRuntimeStore
    let winners = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
            group.addTask {
                switch store.cancelHostedMigration(
                    agentId: "agent-hosted",
                    serverId: "server-hosted",
                    migrationRef: hostedRef,
                    expectedRevision: 3,
                    reason: "concurrent",
                    now: now
                ) {
                case .canceled: return true
                case .missing, .stale, .terminal: return false
                }
            }
        }
        var total = 0
        for await won in group where won { total += 1 }
        return total
    }

    #expect(winners == 1)
    let stored = try #require(store.hostedMigrations["agent-hosted"])
    #expect(stored.revision == 4)
    #expect(stored.state == "canceled_pre_flip")
    #expect(stored.canceledAt == now)
}

@Test func cancelAcceptsTheLegacyBooleanRevision() throws {
    let directory = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111625"
    let serverId = "33333333-3333-4333-8333-333333333670"
    directory.addAccount(id: ownerId, email: "migration-bool@slock.test", password: "password123")
    directory.oauth.addOwnedServer(id: serverId, slug: "migration-bool", name: "Migration Bool", ownerId: ownerId)
    let agent = directory.oauth.createAgent(serverId: serverId, name: "migration-bool-agent", creatorUserId: ownerId)
    let record = MachineMigrationRecord(
        agentId: agent,
        serverId: serverId,
        supportRef: machineRef,
        revision: 1,
        state: "in_transit",
        sourceMachineId: "source-bool",
        targetMachineId: "target-bool",
        transportGeneration: "generation-bool"
    )
    directory.machinesAndComputersStore.machineMigrations = [machineRef: record]

    // A JSON `true` reached the retired `as? NSNumber` cast as 1.
    let body = try JSONDecoder().decode(
        AgentMigrationCancelRequest.self,
        from: Data(#"{"migrationRef":"\#(machineRef)","expectedRevision":true}"#.utf8)
    )
    #expect(body.expectedRevision == 1)

    let response = try makeService(directory: directory, userId: ownerId, now: Date())
        .cancelMigration(authorization: nil, serverId: serverId, agentId: agent, request: body)
    guard case .machine(let status) = try #require(response.migration) else {
        Issue.record("expected a Computer migration status")
        return
    }
    #expect(status.revision == 2)
    #expect(status.state == "canceled_pre_flip")
    #expect(status.cancelReason == "user_canceled")
}
