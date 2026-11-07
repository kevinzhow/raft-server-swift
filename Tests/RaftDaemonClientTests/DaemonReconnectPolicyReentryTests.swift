import Synchronization
import Testing
import RaftDaemonClient

private final class WeakPolicyReconnectLoop: Sendable {
    private struct State: Sendable {
        weak var loop: DaemonReconnectLoop?
    }
    private let state = Mutex(State())

    func install(_ loop: DaemonReconnectLoop) {
        state.withLock { $0.loop = loop }
    }

    func get() -> DaemonReconnectLoop? {
        state.withLock { $0.loop }
    }
}

private struct PolicyReconnectFailure: Error {}

@Test func reconnectPolicyCanRequestStopDuringFailureBackoff() async {
    let reference = WeakPolicyReconnectLoop()
    let loop = DaemonReconnectLoop(
        policy: DaemonReconnectPolicy(minDelayMs: 1, maxDelayMs: 4, delayFor: { backoff in
            reference.get()?.stop()
            return backoff
        }),
        connect: { throw PolicyReconnectFailure() }
    )
    reference.install(loop)

    await loop.run(maxConnects: 1)

    #expect(loop.lastStop == .requested)
    #expect(loop.reconnectAttempt == 1)
}
