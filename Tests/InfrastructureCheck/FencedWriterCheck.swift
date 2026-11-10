import Foundation
import RaftPersistence
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Real PostgreSQL acceptance on an isolated database. Enabling a writer epoch
/// permanently disables the legacy nil-epoch API in that database.
enum FencedWriterCheck {
    enum Label: String, Sendable {
        case isolated = "fenced-isolated-database"
        case migration = "fenced-postgres-migrate"
        case instances = "fenced-two-postgres-instances"
        case firstLease = "fenced-first-writer-lease"
        case competition = "fenced-competing-writer-denied"
        case nilEpoch = "fenced-nil-epoch-denied"
        case initialCAS = "fenced-current-epoch-cas"
        case heartbeatCAS = "fenced-sequential-cas-across-heartbeats"
        case concurrentCAS = "fenced-concurrent-command-one-winner"
        case replacement = "fenced-replacement-epoch-increases"
        case staleEpoch = "fenced-stale-epoch-preserves-data"
        case replacementCAS = "fenced-replacement-writer-cas"
        case atomicEffect = "fenced-outbox-atomic-snapshot-and-effect"
        case duplicateEffect = "fenced-outbox-duplicate-rolls-back-snapshot"
        case conflictEffect = "fenced-outbox-cas-conflict-does-not-append"
        case wrongClaimEpoch = "fenced-outbox-wrong-epoch-ack-denied"
        case expiredClaim = "fenced-outbox-expired-claim-denied"
        case replacedClaim = "fenced-outbox-new-token-rejects-old-token"
        case delivered = "fenced-outbox-delivered-retained-not-pending"
        case retry = "fenced-outbox-first-backoff-and-retry"
        case leaseClosed = "fenced-outbox-closed-lease-ack-denied"
        case persistenceClosed = "fenced-outbox-closed-persistence-ack-denied"
        case reopen = "fenced-reopen-preserves-snapshots-and-effects"
        case recoveredClaim = "fenced-reopen-reclaims-and-delivers"
        case cleanup = "fenced-own-namespace-tombstones-retain-effects"
    }

    enum Reason: String, Error, Sendable { case assertion, configuration, persistence, unexpected }
    struct Failure: Error { let label: Label; let reason: Reason }
    struct Fact: Codable, Equatable, Sendable { let value: Int; let witness: String }
    struct Snapshot: Sendable { let revision: Int64; let fact: Fact }
    struct Namespace: Sendable {
        let value = "raft-fenced-check:" + UUID().uuidString.lowercased()
        func key(_ domain: DurableDomain, _ suffix: String) throws -> DurableKey {
            try DurableKey(domain: domain, aggregateID: value + ":" + suffix)
        }
    }
    enum Rejection: Sendable {
        case fence, leaseClosed, persistenceClosed, claimLost, duplicate
        case conflict(expected: Int64, actual: Int64)
    }
    enum ConcurrentResult: Sendable {
        case committed(Fact, DurableRevision)
        case busy, conflict
    }

    static func run(databaseURL: String) async {
        do {
            try await runChecks(databaseURL: databaseURL)
            print("PASS fencing-only-complete")
        } catch let failure as Failure {
            print("FAIL \(failure.label.rawValue) [\(failure.reason.rawValue)]")
            exit(1)
        } catch {
            // No error description, connection URL, payload, aggregate ID or token.
            print("FAIL fenced-configuration [configuration]")
            exit(1)
        }
    }

    static func runChecks(databaseURL: String) async throws {
        let configuration = try await check(.isolated) {
            guard URLComponents(string: databaseURL)?.path == "/raft_fenced_check" else {
                throw Reason.configuration
            }
            return try PostgresPersistenceConfiguration(databaseURL: databaseURL)
        }
        try await check(.migration) { try await PostgresPersistence.migrate(configuration: configuration) }
        let (a, b) = try await check(.instances) {
            let first = try await PostgresPersistence.start(configuration: configuration, migrate: false)
            do {
                let second = try await PostgresPersistence.start(configuration: configuration, migrate: false)
                do { try await first.ping(); try await second.ping() }
                catch { await second.close(); throw error }
                return (first, second)
            } catch {
                await first.close()
                throw error
            }
        }
        do {
            try await exerciseWriters(a: a, b: b, configuration: configuration)
        } catch {
            await b.close()
            await a.close()
            throw error
        }
        await b.close()
        await a.close()
    }

    static func exerciseWriters(
        a: PostgresPersistence, b: PostgresPersistence,
        configuration: PostgresPersistenceConfiguration
    ) async throws {
        let namespace = Namespace()
        let key = try namespace.key(.feedback, "writer-counter")
        let absent = try namespace.key(.notifications, "nil-epoch-must-stay-absent")
        let leaseA = try await check(.firstLease) {
            guard let lease = try await a.tryAcquireWriterLease(heartbeatInterval: .milliseconds(100)) else {
                throw Reason.assertion
            }
            let health = await lease.healthSnapshot()
            try require(lease.epoch > 0 && health.isHealthy)
            return lease
        }
        try await check(.competition) {
            try require(try await b.tryAcquireWriterLease(heartbeatInterval: .milliseconds(100)) == nil)
        }
        try await check(.nilEpoch) {
            for database in [a, b] {
                try await expect(.fence) {
                    _ = try await database.compareAndSwap([
                        .put(Fact(value: -1, witness: "unfenced"), key: absent, codecVersion: 1, expectedRevision: nil),
                    ])
                }
                try require(try await database.read(absent) == nil)
            }
        }
        let initial = Fact(value: 0, witness: "sequential")
        let firstRevision = try await check(.initialCAS) {
            let result = try single(try await a.compareAndSwap([
                .put(initial, key: key, codecVersion: 1, expectedRevision: nil),
            ], expectedWriterEpoch: leaseA.epoch))
            try require(result.key == key && result.revision == 1 && !result.deleted)
            try await assertSnapshot(a, key, Snapshot(revision: 1, fact: initial))
            return result.revision
        }
        let sequentialRevision = try await check(.heartbeatCAS) {
            try await sequentialCAS(a, lease: leaseA, key: key, startingRevision: firstRevision)
        }
        let parallelSnapshot = try await check(.concurrentCAS) {
            try await concurrentCAS(a, epoch: leaseA.epoch, key: key, revision: sequentialRevision)
        }
        let leaseB = try await check(.replacement) {
            await leaseA.close()
            let oldHealth = await leaseA.healthSnapshot()
            try require(oldHealth.status == .closed && !oldHealth.isHealthy)
            guard let lease = try await WriterLease.tryAcquire(on: b, heartbeatInterval: .milliseconds(100)) else {
                throw Reason.assertion
            }
            let health = await lease.healthSnapshot()
            try require(lease.epoch > leaseA.epoch && health.isHealthy)
            return lease
        }
        try await check(.staleEpoch) {
            for database in [b, a] {
                try await expect(.fence) {
                    _ = try await database.compareAndSwap([
                        .put(Fact(value: -2, witness: "stale"), key: key, codecVersion: 1,
                             expectedRevision: parallelSnapshot.revision),
                    ], expectedWriterEpoch: leaseA.epoch)
                }
                try await assertSnapshot(b, key, parallelSnapshot)
            }
            try await expect(.fence) {
                _ = try await b.compareAndSwap([
                    .put(Fact(value: -3, witness: "unfenced"), key: absent, codecVersion: 1, expectedRevision: nil),
                ])
            }
            try require(try await b.read(absent) == nil)
        }
        let persisted = try await check(.replacementCAS) {
            let fact = Fact(value: 500, witness: "replacement-writer")
            let result = try single(try await b.compareAndSwap([
                .put(fact, key: key, codecVersion: 1, expectedRevision: parallelSnapshot.revision),
            ], expectedWriterEpoch: leaseB.epoch))
            let snapshot = Snapshot(revision: parallelSnapshot.revision + 1, fact: fact)
            try require(result.revision == snapshot.revision && !result.deleted)
            try await assertSnapshot(a, key, snapshot)
            return snapshot
        }
        try await exerciseOutbox(
            a: a, b: b, lease: leaseB, oldEpoch: leaseA.epoch, configuration: configuration,
            namespace: namespace, counterKey: key, counter: persisted, absentKey: absent
        )
    }

    static func sequentialCAS(
        _ database: PostgresPersistence, lease: WriterLease, key: DurableKey, startingRevision: Int64
    ) async throws -> Int64 {
        var revision = startingRevision
        for value in 1...300 {
            let result = try single(try await database.compareAndSwap([
                .put(Fact(value: value, witness: "sequential"), key: key, codecVersion: 1, expectedRevision: revision),
            ], expectedWriterEpoch: lease.epoch))
            try require(result.key == key && result.revision == revision + 1 && !result.deleted)
            revision = result.revision
            try await Task.sleep(for: .milliseconds(1))
            // Three idle windows also allow the real 100ms monitor to run.
            // A writerBusy from the internal heartbeat fails this check: no retry.
            if value.isMultiple(of: 100) { try await Task.sleep(for: .milliseconds(120)) }
        }
        try require((await lease.healthSnapshot()).isHealthy)
        try await assertSnapshot(database, key, Snapshot(
            revision: startingRevision + 300, fact: Fact(value: 300, witness: "sequential")
        ))
        return revision
    }

    static func concurrentCAS(
        _ database: PostgresPersistence, epoch: Int64, key: DurableKey, revision: Int64
    ) async throws -> Snapshot {
        let results = try await withThrowingTaskGroup(of: ConcurrentResult.self) { group in
            for witness in ["concurrent-left", "concurrent-right"] {
                group.addTask {
                    let fact = Fact(value: 301, witness: witness)
                    do {
                        let result = try single(try await database.compareAndSwap([
                            .put(fact, key: key, codecVersion: 1, expectedRevision: revision),
                        ], expectedWriterEpoch: epoch))
                        return .committed(fact, result)
                    } catch let error as PersistenceError {
                        if error == .writerBusy { return .busy }
                        if case .conflict(let expected, let actual) = error,
                           expected == revision, actual == revision + 1 { return .conflict }
                        throw error
                    }
                }
            }
            var results: [ConcurrentResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        var winners: [Snapshot] = []
        var denied = 0
        for result in results {
            switch result {
            case .committed(let fact, let written):
                try require(written.key == key && written.revision == revision + 1 && !written.deleted)
                winners.append(Snapshot(revision: written.revision, fact: fact))
            case .busy, .conflict: denied += 1
            }
        }
        guard winners.count == 1, denied == 1, let winner = winners.first else { throw Reason.assertion }
        try await assertSnapshot(database, key, winner)
        return winner
    }

    static func require(_ condition: Bool) throws {
        guard condition else { throw Reason.assertion }
    }

    static func single(_ revisions: [DurableRevision]) throws -> DurableRevision {
        guard revisions.count == 1, let result = revisions.first else { throw Reason.assertion }
        return result
    }

    static func assertSnapshot(_ database: PostgresPersistence, _ key: DurableKey, _ expected: Snapshot) async throws {
        guard let document = try await database.read(key) else { throw Reason.assertion }
        try require(document.key == key && document.revision == expected.revision)
        try require(try document.decode(Fact.self, codecVersion: 1) == expected.fact)
    }

    static func expect(_ rejection: Rejection, _ operation: @Sendable () async throws -> Void) async throws {
        do { try await operation() }
        catch let error as PersistenceError {
            switch (rejection, error) {
            case (.fence, .writerLeaseRequired), (.fence, .writerLeaseLost), (.fence, .writerEpochMismatch),
                 (.leaseClosed, .writerLeaseLost), (.persistenceClosed, .closed), (.claimLost, .outboxClaimLost): return
            case (.duplicate, .database(_, let state, _)) where state == "23505": return
            case (.conflict(let expected, let actual), .conflict(let foundExpected, let foundActual))
                where foundExpected == expected && foundActual == actual: return
            default: throw error
            }
        }
        throw Reason.assertion
    }

    @discardableResult
    static func check<Value: Sendable>(
        _ label: Label, _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            let result = try await operation()
            print("PASS \(label.rawValue)")
            return result
        } catch {
            let reason: Reason
            if let specific = error as? Reason { reason = specific }
            else if error is PersistenceError { reason = .persistence }
            else { reason = .unexpected }
            throw Failure(label: label, reason: reason)
        }
    }
}
