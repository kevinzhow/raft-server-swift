import Foundation

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

public final class DaemonReconnectLoop: @unchecked Sendable {
    public typealias Connect = @Sendable () async throws -> DaemonHandshake
    public typealias Sleep = @Sendable (Int) async throws -> Void

    private let lock = NSLock()
    private let policy: DaemonReconnectPolicy
    private let connect: Connect
    private let sleep: Sleep
    private let onConnected: @Sendable (DaemonHandshake, Int) -> Void
    private let onScheduled: @Sendable (Int, Int) -> Void
    private let onStopped: @Sendable (DaemonReconnectStop, Error?) -> Void

    private var stopped = false
    private var attempt = 0
    private var delayMs: Int
    private var stopReason: DaemonReconnectStop?

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
        self.delayMs = policy.minDelayMs
    }

    public var reconnectAttempt: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempt
    }

    public var lastStop: DaemonReconnectStop? {
        lock.lock()
        defer { lock.unlock() }
        return stopReason
    }

    public func stop() {
        lock.lock()
        stopped = true
        stopReason = .requested
        lock.unlock()
    }

    private func recordStop(_ reason: DaemonReconnectStop) {
        lock.lock()
        stopReason = reason
        stopped = true
        lock.unlock()
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
        lock.lock()
        attempt += 1
        let backoff = delayMs
        let delay = policy.delayFor(backoff)
        delayMs = min(max(policy.minDelayMs, backoff * 2), policy.maxDelayMs)
        let result = (delay, attempt, stopped)
        lock.unlock()
        return result
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
        lock.lock()
        attempt = 0
        delayMs = policy.minDelayMs
        let current = attempt
        lock.unlock()
        return current
    }

    private func nextDelayAfterSessionEnd() -> Int {
        lock.lock()
        let backoff = delayMs
        lock.unlock()
        return policy.delayFor(backoff)
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
