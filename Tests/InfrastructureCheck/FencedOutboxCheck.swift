import Foundation
import RaftPersistence

extension FencedWriterCheck {
    static func exerciseOutbox(
        a: PostgresPersistence, b: PostgresPersistence, lease: WriterLease, oldEpoch: Int64,
        configuration: PostgresPersistenceConfiguration, namespace: Namespace,
        counterKey: DurableKey, counter: Snapshot, absentKey: DurableKey
    ) async throws {
        let key = try namespace.key(.messagesAndThreads, "outbox-snapshot")
        let first = try DurableEffect(
            kind: DurableEffectKind("fenced.delivery"), payload: Data([0, 1, 127, 128, 255, 34, 10])
        )
        let initial = Snapshot(revision: 1, fact: Fact(value: 1, witness: "atomic-effect"))
        try await check(.atomicEffect) {
            // The dedicated DB must have no unrelated due work. No cleanup or
            // acknowledgement ever targets an effect found by an arbitrary ID.
            try require(try await b.pendingOutbox(limit: PersistenceLimits.maximumOutboxBatch).isEmpty)
            let result = try single(try await b.compareAndSwap([
                .put(initial.fact, key: key, codecVersion: 1, expectedRevision: nil),
            ], expectedWriterEpoch: lease.epoch, effects: [first]))
            try require(result.key == key && result.revision == 1 && !result.deleted)
            try await assertSnapshot(a, key, initial)
            let entry = try await effect(b, first)
            try require(entry.writerEpoch == lease.epoch && entry.sequence > 0 && entry.attempts == 0)
            try require(entry.deliveredAt == nil && entry.exhaustedAt == nil && entry.lastFailure == nil)
            try require(try await b.pendingOutbox().map(\.effect.effectID) == [first.effectID])
        }
        try await check(.duplicateEffect) {
            let rolledBackEffect = try DurableEffect(kind: DurableEffectKind("fenced.rollback"), payload: Data([9, 0, 9]))
            try await expect(.duplicate) {
                _ = try await b.compareAndSwap([
                    .put(Fact(value: -1, witness: "duplicate-must-rollback"), key: key,
                         codecVersion: 1, expectedRevision: 1),
                ], expectedWriterEpoch: lease.epoch, effects: [rolledBackEffect, first])
            }
            try await assertSnapshot(a, key, initial)
            try require(try await b.outboxEffect(effectID: rolledBackEffect.effectID) == nil)
            let original = try await effect(b, first)
            try require(original.attempts == 0 && original.deliveredAt == nil && original.writerEpoch == lease.epoch)
        }
        try await check(.conflictEffect) {
            let notCommitted = try DurableEffect(kind: DurableEffectKind("fenced.conflict"), payload: Data([4, 0, 4]))
            try await expect(.conflict(expected: 99, actual: 1)) {
                _ = try await b.compareAndSwap([
                    .put(Fact(value: -2, witness: "conflict-must-not-append"), key: key,
                         codecVersion: 1, expectedRevision: 99),
                ], expectedWriterEpoch: lease.epoch, effects: [notCommitted])
            }
            try await assertSnapshot(a, key, initial)
            try require(try await b.outboxEffect(effectID: notCommitted.effectID) == nil)
        }
        let oldClaim = try await ownClaim(b, effect: first, epoch: lease.epoch, ttl: 1)
        try require(oldClaim.entry.attempts == 1 && oldClaim.claimedWriterEpoch == lease.epoch)
        try await check(.wrongClaimEpoch) {
            try await expect(.claimLost) { try await b.markDelivered(oldClaim, expectedWriterEpoch: oldEpoch) }
            let entry = try await effect(b, first)
            try require(entry.deliveredAt == nil && entry.attempts == 1)
            try await assertSnapshot(a, key, initial)
        }
        try await check(.expiredClaim) {
            try await Task.sleep(for: .milliseconds(1200))
            try await expect(.claimLost) { try await b.markDelivered(oldClaim, expectedWriterEpoch: lease.epoch) }
            let entry = try await effect(b, first)
            try require(entry.deliveredAt == nil && entry.attempts == 1)
        }
        let newClaim = try await check(.replacedClaim) {
            let claim = try await ownClaim(b, effect: first, epoch: lease.epoch, ttl: 30)
            try require(claim.claimToken != oldClaim.claimToken && claim.entry.attempts == 2)
            try require(claim.claimedWriterEpoch == lease.epoch && claim.expiresAt > oldClaim.expiresAt)
            try await expect(.claimLost) { try await b.markDelivered(oldClaim, expectedWriterEpoch: lease.epoch) }
            try require(try await effect(b, first).deliveredAt == nil)
            return claim
        }
        try await check(.delivered) {
            try await b.markDelivered(newClaim, expectedWriterEpoch: lease.epoch)
            let retained = try await effect(b, first)
            try require(retained.deliveredAt != nil && retained.exhaustedAt == nil && retained.attempts == 2)
            try require(try await b.pendingOutbox().contains { $0.effect.effectID == first.effectID } == false)
        }
        try await exerciseKindFilteredOutbox(persistence: b, epoch: lease.epoch, namespace: namespace)
        let retryEffect = try DurableEffect(kind: DurableEffectKind("fenced.retry"), payload: Data([2, 0, 2]))
        let retrySnapshot = Snapshot(revision: 2, fact: Fact(value: 2, witness: "retry-effect"))
        try await check(.retry) {
            let updated = try single(try await b.compareAndSwap([
                .put(retrySnapshot.fact, key: key, codecVersion: 1, expectedRevision: 1),
            ], expectedWriterEpoch: lease.epoch, effects: [retryEffect]))
            try require(updated.revision == 2 && !updated.deleted)
            try await assertSnapshot(a, key, retrySnapshot)
            try await firstRetry(b, effect: retryEffect, epoch: lease.epoch)
        }
        let closingEffect = try DurableEffect(kind: DurableEffectKind("fenced.close"), payload: Data([3, 0, 3]))
        let closingSnapshot = Snapshot(revision: 3, fact: Fact(value: 3, witness: "closed-ack-effect"))
        let closingClaim = try await check(.leaseClosed) {
            let updated = try single(try await b.compareAndSwap([
                .put(closingSnapshot.fact, key: key, codecVersion: 1, expectedRevision: 2),
            ], expectedWriterEpoch: lease.epoch, effects: [closingEffect]))
            try require(updated.revision == 3 && !updated.deleted)
            let claim = try await ownClaim(b, effect: closingEffect, epoch: lease.epoch, ttl: 1)
            // close awaits closure of the actual dedicated PostgreSQL socket.
            // This does not inject or claim coverage of an unknown COMMIT result.
            await lease.close()
            let health = await lease.healthSnapshot()
            try require(health.status == .closed && !health.isHealthy)
            try await expect(.leaseClosed) { try await b.markDelivered(claim, expectedWriterEpoch: lease.epoch) }
            try require(try await effect(a, closingEffect).deliveredAt == nil)
            try await assertSnapshot(a, key, closingSnapshot)
            return claim
        }
        try await check(.persistenceClosed) {
            await b.close()
            try await expect(.persistenceClosed) { try await b.markDelivered(closingClaim, expectedWriterEpoch: lease.epoch) }
            try await expect(.persistenceClosed) { _ = try await b.outboxEffect(effectID: closingEffect.effectID) }
            try await expect(.persistenceClosed) {
                _ = try await b.compareAndSwap([
                    .put(Fact(value: -4, witness: "closed"), key: key, codecVersion: 1, expectedRevision: 3),
                ], expectedWriterEpoch: lease.epoch)
            }
            try await assertSnapshot(a, key, closingSnapshot)
        }
        // Close both initial pools before opening another instance; persistence,
        // rather than either instance's memory, must supply the same facts.
        await a.close()
        let reopened = try await PostgresPersistence.start(configuration: configuration, migrate: false)
        do {
            try await check(.reopen) {
                try await reopened.ping()
                try await assertSnapshot(reopened, counterKey, counter)
                try await assertSnapshot(reopened, key, closingSnapshot)
                try require(try await reopened.read(absentKey) == nil)
                for delivered in [first, retryEffect] {
                    let retained = try await effect(reopened, delivered)
                    try require(retained.deliveredAt != nil && retained.exhaustedAt == nil)
                }
                let retained = try await effect(reopened, closingEffect)
                try require(retained.deliveredAt == nil && retained.attempts == 1 && retained.writerEpoch == lease.epoch)
                try await expect(.fence) {
                    _ = try await reopened.compareAndSwap([
                        .put(Fact(value: -5, witness: "reopened-unfenced"), key: absentKey,
                             codecVersion: 1, expectedRevision: nil),
                    ])
                }
                try require(try await reopened.read(absentKey) == nil)
            }
            let recoveredLease = try await check(.recoveredClaim) {
                guard let recovered = try await reopened.tryAcquireWriterLease(heartbeatInterval: .milliseconds(100)) else {
                    throw Reason.assertion
                }
                try require(recovered.epoch > lease.epoch)
                try await expect(.fence) { try await reopened.markDelivered(closingClaim, expectedWriterEpoch: lease.epoch) }
                try await Task.sleep(for: .milliseconds(1200))
                let claim = try await ownClaim(reopened, effect: closingEffect, epoch: recovered.epoch, ttl: 30)
                try require(claim.claimToken != closingClaim.claimToken && claim.entry.attempts == 2)
                try require(claim.entry.writerEpoch == lease.epoch && claim.claimedWriterEpoch == recovered.epoch)
                try await reopened.markDelivered(claim, expectedWriterEpoch: recovered.epoch)
                try require(try await effect(reopened, closingEffect).deliveredAt != nil)
                return recovered
            }
            try await check(.cleanup) {
                let deleted = try await reopened.compareAndSwap([
                    .delete(key: counterKey, expectedRevision: counter.revision),
                    .delete(key: key, expectedRevision: closingSnapshot.revision),
                ], expectedWriterEpoch: recoveredLease.epoch)
                try require(deleted.count == 2 && deleted.allSatisfy(\.deleted))
                try require(deleted.first { $0.key == counterKey }?.revision == counter.revision + 1)
                try require(deleted.first { $0.key == key }?.revision == closingSnapshot.revision + 1)
                try require(try await reopened.read(counterKey) == nil)
                try require(try await reopened.read(key) == nil)
                try require(try await reopened.read(absentKey) == nil)
                for delivered in [first, retryEffect, closingEffect] {
                    let retained = try await effect(reopened, delivered)
                    try require(retained.deliveredAt != nil && retained.exhaustedAt == nil)
                }
                try require(try await reopened.pendingOutbox(limit: PersistenceLimits.maximumOutboxBatch).isEmpty)
            }
        } catch {
            await reopened.close()
            throw error
        }
        await reopened.close()
    }

    static func effect(_ database: PostgresPersistence, _ expected: DurableEffect) async throws -> DurableOutboxEntry {
        guard let entry = try await database.outboxEffect(effectID: expected.effectID) else { throw Reason.assertion }
        try require(entry.effect.effectID == expected.effectID && entry.effect.kind == expected.kind)
        try require(entry.effect.payload == expected.payload)
        return entry
    }

    static func ownClaim(
        _ database: PostgresPersistence, effect expected: DurableEffect, epoch: Int64, ttl: Int
    ) async throws -> DurableOutboxClaim {
        let pending = try await database.pendingOutbox(limit: PersistenceLimits.maximumOutboxBatch)
        try require(pending.count == 1 && pending.first?.effect.effectID == expected.effectID)
        let claims = try await database.claimOutbox(expectedWriterEpoch: epoch, limit: 1, visibilityTimeoutSeconds: ttl)
        guard claims.count == 1, let claim = claims.first else { throw Reason.assertion }
        try require(claim.entry.effect.effectID == expected.effectID && claim.entry.effect.payload == expected.payload)
        try require(claim.entry.effect.kind == expected.kind && claim.claimedWriterEpoch == epoch)
        try require(claim.entry.deliveredAt == nil && claim.entry.exhaustedAt == nil)
        return claim
    }

    static func firstRetry(_ database: PostgresPersistence, effect expected: DurableEffect, epoch: Int64) async throws {
        let first = try await ownClaim(database, effect: expected, epoch: epoch, ttl: 30)
        try require(first.entry.attempts == 1)
        try await database.recordFailure(first, expectedWriterEpoch: epoch, code: .unavailable)
        let failed = try await effect(database, expected)
        try require(failed.attempts == 1 && failed.lastFailure == .unavailable)
        try require(failed.deliveredAt == nil && failed.exhaustedAt == nil)
        // Both timestamps below come from PostgreSQL. The first backoff must be
        // at least one second after the prior due time and within this real claim.
        try require(failed.nextAttemptAt.timeIntervalSince(first.entry.nextAttemptAt) >= 1)
        try require(failed.nextAttemptAt <= first.expiresAt)
        try require(try await database.pendingOutbox().contains { $0.effect.effectID == expected.effectID } == false)
        try await expect(.claimLost) { try await database.markDelivered(first, expectedWriterEpoch: epoch) }
        try await Task.sleep(for: .milliseconds(1200))
        let retry = try await ownClaim(database, effect: expected, epoch: epoch, ttl: 30)
        try require(retry.entry.attempts == 2 && retry.claimToken != first.claimToken)
        try require(retry.entry.lastFailure == .unavailable)
        try await database.markDelivered(retry, expectedWriterEpoch: epoch)
        let retained = try await effect(database, expected)
        try require(retained.deliveredAt != nil && retained.attempts == 2 && retained.lastFailure == .unavailable)
        // The ten-attempt exhaustion timeline is deliberately not claimed by
        // this bounded first-retry check; no SQL, failpoint or fake clock is used.
    }
}
