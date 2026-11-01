import Foundation
import Testing
@testable import RaftDaemonClient

private struct LoopFailure: Error {}

private final class ReconnectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [Int] = []
    private var connects = 0
    private var connected = 0
    private var scheduled: [(delay: Int, attempt: Int)] = []
    private var results: [Result<DaemonHandshake, Error>]

    init(_ results: [Result<DaemonHandshake, Error>]) {
        self.results = results
    }

    func nextResult() -> Result<DaemonHandshake, Error> {
        lock.lock()
        defer { lock.unlock() }
        connects += 1
        if results.isEmpty { return .failure(LoopFailure()) }
        return results.removeFirst()
    }

    func recordSleep(_ delay: Int) {
        lock.lock()
        delays.append(delay)
        lock.unlock()
    }

    func recordConnected() {
        lock.lock()
        connected += 1
        lock.unlock()
    }

    func recordScheduled(_ delay: Int, _ attempt: Int) {
        lock.lock()
        scheduled.append((delay, attempt))
        lock.unlock()
    }

    var snapshot: (delays: [Int], connects: Int, connected: Int, scheduled: [(delay: Int, attempt: Int)]) {
        lock.lock()
        defer { lock.unlock() }
        return (delays, connects, connected, scheduled)
    }
}

private let loopHandshake = DaemonHandshake(
    serverCapabilities: [],
    context: DaemonMachineContext(machineId: "m-1", serverId: "s-1", capabilities: [])
)

private func makeLoop(
    _ recorder: ReconnectRecorder,
    minDelayMs: Int = 10,
    maxDelayMs: Int = 40
) -> DaemonReconnectLoop {
    DaemonReconnectLoop(
        policy: DaemonReconnectPolicy(minDelayMs: minDelayMs, maxDelayMs: maxDelayMs, delayFor: { $0 }),
        connect: { try recorder.nextResult().get() },
        sleep: { ms in recorder.recordSleep(ms) },
        onConnected: { _, _ in recorder.recordConnected() },
        onScheduled: { delay, attempt in recorder.recordScheduled(delay, attempt) }
    )
}

@Test func reconnectLoopRetriesWithDoublingBackoffAndResetsAfterSuccess() async {
    let recorder = ReconnectRecorder([.failure(LoopFailure()), .failure(LoopFailure()), .success(loopHandshake)])
    let loop = makeLoop(recorder)
    await loop.run(maxConnects: 3)

    let snapshot = recorder.snapshot
    #expect(snapshot.connects == 3)
    #expect(snapshot.connected == 1)
    #expect(Array(snapshot.delays.prefix(2)) == [10, 20])
    #expect(snapshot.scheduled.map(\.attempt) == [1, 2, 0])
}

@Test func reconnectLoopCapsTheBackoffAtThePolicyMaximum() async {
    let recorder = ReconnectRecorder(Array(repeating: .failure(LoopFailure()), count: 5))
    let loop = makeLoop(recorder)
    await loop.run(maxConnects: 5)
    #expect(Array(recorder.snapshot.delays) == [10, 20, 40, 40, 40])
}

@Test func reconnectLoopResumesAfterASessionEnds() async {
    let recorder = ReconnectRecorder([.success(loopHandshake), .failure(LoopFailure())])
    let loop = makeLoop(recorder)
    await loop.run(maxConnects: 2)
    let snapshot = recorder.snapshot
    #expect(snapshot.connects == 2)
    #expect(snapshot.connected == 1)
    #expect(Array(snapshot.delays.prefix(1)) == [10])
}

@Test func reconnectLoopStopsOnAMigratedLegacyKey() async {
    let rejected = DaemonHandshakeRejection(statusCode: 401, reason: legacyMachineKeyMigratedReason)
    let recorder = ReconnectRecorder([.failure(rejected), .success(loopHandshake)])
    let loop = makeLoop(recorder)
    await loop.run(maxConnects: 5)
    let snapshot = recorder.snapshot
    #expect(snapshot.connects == 1)
    #expect(snapshot.connected == 0)
    #expect(snapshot.delays.isEmpty)
    #expect(loop.lastStop == .migratedKey)
}

@Test func reconnectLoopStopsWhenRequested() async {
    let recorder = ReconnectRecorder([.failure(LoopFailure())])
    let loop = makeLoop(recorder)
    loop.stop()
    await loop.run(maxConnects: 5)
    #expect(recorder.snapshot.connects == 0)
    #expect(loop.lastStop == .requested)
}
