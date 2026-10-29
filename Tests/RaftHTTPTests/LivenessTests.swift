import Foundation
import Testing
@testable import RaftHTTP

/// Behavior pinned by `packages/server/src/dbLiveness.test.ts` at
/// raft-source v1.21.23-source.1.

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int
    private var pingCount = 0
    private var failingStored = false

    init(_ value: Int) { stored = value }

    var failing: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failingStored
        }
        set {
            lock.lock()
            failingStored = newValue
            lock.unlock()
        }
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func advance(_ ms: Int) {
        lock.lock()
        stored += ms
        lock.unlock()
    }

    var pings: Int {
        lock.lock()
        defer { lock.unlock() }
        return pingCount
    }

    func notePing() {
        lock.lock()
        pingCount += 1
        lock.unlock()
    }
}

private struct ProbeFailure: Error {}

private func tracker(_ clock: Clock, ping: @escaping @Sendable () async throws -> Void) -> DbLivenessTracker {
    DbLivenessTracker(ping: ping, now: { clock.value })
}

@Test func anUnstartedTrackerIsUnmonitored() async {
    let clock = Clock(1_000_000)
    let subject = tracker(clock) {}
    let verdict = await subject.verdict()
    #expect(verdict == .unmonitored)
}

@Test func readingTheVerdictNeverPings() async {
    let clock = Clock(1_000_000)
    let subject = tracker(clock) { clock.notePing() }
    await subject.probeOnce()
    let before = clock.pings
    for _ in 0..<10 {
        _ = await subject.verdict()
    }
    #expect(clock.pings == before)
}

@Test func aShortDatabasePauseKeepsTheTaskAlive() async {
    let clock = Clock(1_000_000)
    let subject = DbLivenessTracker(
        ping: {
            clock.notePing()
            if clock.failing { throw ProbeFailure() }
        },
        now: { clock.value }
    )
    await subject.probeOnce()
    clock.failing = true
    clock.advance(2_200)
    await subject.probeOnce()
    let verdict = await subject.verdict()
    #expect(verdict.ok)
    #expect(verdict.db == .ok)
}

@Test func theStaleWindowTurns503AndRecoveryReturns200() async {
    let clock = Clock(1_000_000)
    let subject = DbLivenessTracker(
        ping: {
            if clock.failing { throw ProbeFailure() }
        },
        now: { clock.value }
    )
    await subject.probeOnce()
    clock.failing = true
    clock.advance(livezDbStaleMs)
    await subject.probeOnce()
    let atBoundary = await subject.verdict()
    #expect(atBoundary.ok)

    clock.advance(1)
    await subject.probeOnce()
    let dead = await subject.verdict()
    #expect(dead.ok == false)
    #expect(dead.db == .stale)
    #expect(dead.msSinceDbSuccess == livezDbStaleMs + 1)

    clock.failing = false
    await subject.probeOnce()
    let recovered = await subject.verdict()
    #expect(recovered == LivenessVerdict(ok: true, db: .ok, msSinceDbSuccess: 0))
}

@Test func aFreshTaskKeepsTheFullWindowWhenTheFirstPingsFail() async {
    let clock = Clock(1_000_000)
    let subject = tracker(clock) { throw ProbeFailure() }
    await subject.probeOnce()
    clock.advance(livezDbStaleMs - 1)
    await subject.probeOnce()
    let verdict = await subject.verdict()
    #expect(verdict.ok)
}

private actor Gate {
    private var entered = false
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enteredPing() async {
        entered = true
        let waiting = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
        if opened { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        opened = true
        let waiting = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

@Test func aHungPingDoesNotStackFurtherPings() async {
    let gate = Gate()
    let clock = Clock(1_000_000)
    let subject = tracker(clock) {
        clock.notePing()
        await gate.enteredPing()
    }
    async let first: Void = subject.probeOnce()
    await gate.waitUntilEntered()
    await subject.probeOnce()
    await subject.probeOnce()
    #expect(clock.pings == 1)
    await gate.open()
    await first
    #expect(clock.pings == 1)
}

@Test func productionRefusesAnUnmonitoredTracker() {
    let unmonitored = LivenessVerdict.unmonitored
    #expect(livezStatus(unmonitored, nodeEnv: "production") == 503)
    #expect(livezStatus(unmonitored, nodeEnv: "test") == 200)
    #expect(livezStatus(LivenessVerdict(ok: true, db: .ok, msSinceDbSuccess: 10), nodeEnv: "production") == 200)
    #expect(livezStatus(LivenessVerdict(ok: false, db: .stale, msSinceDbSuccess: 60_001), nodeEnv: "production") == 503)
}

@Test func startMarksTheTrackerMonitoredBeforeTheFirstPingResolves() async {
    let subject = DbLivenessTracker(
        ping: { try await Task.sleep(nanoseconds: 3_600_000_000_000) },
        intervalMs: 60_000
    )
    await subject.start()
    let verdict = await subject.verdict()
    #expect(verdict.db == .ok)
    await subject.stop()
}
