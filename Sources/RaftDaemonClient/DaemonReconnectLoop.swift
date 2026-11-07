import Foundation
import Synchronization

/// Live reconnect policy for the `RaftDaemon` process.
///
/// The handshake client is one-shot: `DaemonClient.connect` returns after the
/// `machine:context` frame and closes. The loop therefore treats a returned
/// session as ended and resumes after the normal delay; failures grow the
/// delay exponentially, and the migrated legacy key is terminal.
public struct DaemonReconnectPolicy: Sendable {
    public var minDelayMs: Int
    public var maxDelayMs: Int
    public var delayFor: @Sendable (Int) -> Int

    public init(
        minDelayMs: Int = 1_000,
        maxDelayMs: Int = daemonMaxReconnectDelayMs,
        delayFor: @escaping @Sendable (Int) -> Int = { backoff in
            jitteredReconnectDelay(backoffMs: backoff) { Double.random(in: 0..<1) }
        }
    ) {
        self.minDelayMs = minDelayMs
        self.maxDelayMs = maxDelayMs
        self.delayFor = delayFor
    }
}

public enum DaemonReconnectStop: Equatable, Sendable {
    case requested
    case migratedKey
}

public final class DaemonReconnectLoop: Sendable {
    public typealias Connect = @Sendable () async throws -> DaemonHandshake
    public typealias Sleep = @Sendable (Int) async throws -> Void

    private let policy: DaemonReconnectPolicy
    private let connect: Connect
    private let sleep: Sleep
    private let onConnected: @Sendable (DaemonHandshake, Int) -> Void
    private let onScheduled: @Sendable (Int, Int) -> Void
    private let onStopped: @Sendable (DaemonReconnectStop, Error?) -> Void

    private struct State: Sendable {
        var stopped = false
        var attempt = 0
        var delayMs: Int
        var stopReason: DaemonReconnectStop?
    }
    private let state: Mutex<State>

    public init(
        policy: DaemonReconnectPolicy = DaemonReconnectPolicy(),
        connect: @escaping Connect,
        sleep: @escaping Sleep = { ms in
            try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
        },
        onConnected: @escaping @Sendable (DaemonHandshake, Int) -> Void = { _, _ in },
        onScheduled: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        onStopped: @escaping @Sendable (DaemonReconnectStop, Error?) -> Void = { _, _ in }
    ) {
        self.policy = policy
        self.connect = connect
        self.sleep = sleep
        self.onConnected = onConnected
        self.onScheduled = onScheduled
        self.onStopped = onStopped
        self.state = Mutex(State(delayMs: policy.minDelayMs))
    }

    public var reconnectAttempt: Int {
        return state.withLock { state in
            return state.attempt
        }
    }

    public var lastStop: DaemonReconnectStop? {
        return state.withLock { state in
            return state.stopReason
        }
    }

    public func stop() {
        state.withLock { state in
            state.stopped = true
            state.stopReason = .requested
        }
    }

    private func recordStop(_ reason: DaemonReconnectStop) {
        state.withLock { state in
            state.stopReason = reason
            state.stopped = true
        }
    }

    /// Runs until stopped, the migrated key is refused, or `maxConnects`
    /// connect calls have completed (tests use the bound).
    public func run(maxConnects: Int? = nil) async {
        var connects = 0
        while !isStopped() {
            if let maxConnects, connects >= maxConnects { return }
            connects += 1
            do {
                let handshake = try await connect()
                let attemptAfterSuccess = resetAfterSuccess()
                onConnected(handshake, attemptAfterSuccess)
                let delay = nextDelayAfterSessionEnd()
                onScheduled(delay, attemptAfterSuccess)
                if isStopped() { return }
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
            } catch is CancellationError {
                return
            } catch let rejection as DaemonHandshakeRejection {
                if isTerminalMigratedKeyRejection(statusCode: rejection.statusCode, reason: rejection.reason) {
                    recordStop(.migratedKey)
                    onStopped(.migratedKey, rejection)
                    return
                }
                guard await scheduleFailure() else { return }
            } catch {
                guard await scheduleFailure() else { return }
            }
        }
    }

    private func recordFailure() -> (delay: Int, attempt: Int, stopped: Bool) {
        let reserved = state.withLock { state in
            state.attempt += 1
            let backoff = state.delayMs
            let doubled = backoff.multipliedReportingOverflow(by: 2)
            if !doubled.overflow {
                state.delayMs = min(max(policy.minDelayMs, doubled.partialValue), policy.maxDelayMs)
            }
            return (backoff: backoff, attempt: state.attempt)
        }
        let delay = policy.delayFor(reserved.backoff)
        _ = min(max(policy.minDelayMs, reserved.backoff * 2), policy.maxDelayMs)
        let stopped = state.withLock { $0.stopped }
        return (delay, reserved.attempt, stopped)
    }

    private func scheduleFailure() async -> Bool {
        let failure = recordFailure()
        guard !failure.stopped else { return false }
        onScheduled(failure.delay, failure.attempt)
        do {
            try await sleep(failure.delay)
            return true
        } catch {
            return false
        }
    }

    private func resetAfterSuccess() -> Int {
        return state.withLock { state in
            state.attempt = 0
            state.delayMs = policy.minDelayMs
            let current = state.attempt
            return current
        }
    }

    private func nextDelayAfterSessionEnd() -> Int {
        let backoff = state.withLock { $0.delayMs }
        return policy.delayFor(backoff)
    }

    private func isStopped() -> Bool {
        return state.withLock { state in
            return state.stopped
        }
    }
}
