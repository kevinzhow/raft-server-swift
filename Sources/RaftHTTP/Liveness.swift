import Foundation

/// Background database liveness behind `/livez`.
///
/// Behavior is the one in `packages/server/src/dbLiveness.ts` at
/// raft-source v1.21.23-source.1. `/livez` never pings on the request path.
/// A fresh tracker is `unmonitored`, which is not a failure until production
/// asks for a status. The stale window is inclusive at the boundary:
/// `age > staleMs` is dead.

public let livezDbStaleMs = 60_000
public let livezDbPingIntervalMs = 5_000

public enum DbLivenessState: String, Equatable, Sendable {
    case ok
    case stale
    case unmonitored
}

public struct LivenessVerdict: Equatable, Sendable {
    public var ok: Bool
    public var db: DbLivenessState
    public var msSinceDbSuccess: Int?

    public init(ok: Bool, db: DbLivenessState, msSinceDbSuccess: Int?) {
        self.ok = ok
        self.db = db
        self.msSinceDbSuccess = msSinceDbSuccess
    }

    public static let unmonitored = LivenessVerdict(ok: true, db: .unmonitored, msSinceDbSuccess: nil)
}

public func livezStatus(_ verdict: LivenessVerdict, nodeEnv: String) -> Int {
    if !verdict.ok { return 503 }
    if verdict.db == .unmonitored && nodeEnv == "production" { return 503 }
    return 200
}

public actor DbLivenessTracker {
    private let ping: @Sendable () async throws -> Void
    private let now: @Sendable () -> Int
    private let intervalMs: Int
    private let staleMs: Int
    private var monitored = false
    private var lastSuccessAt = 0
    private var inFlight = false
    private var loop: Task<Void, Never>?

    public init(
        ping: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> Int = { Int((Date().timeIntervalSince1970 * 1000).rounded()) },
        intervalMs: Int = livezDbPingIntervalMs,
        staleMs: Int = livezDbStaleMs
    ) {
        self.ping = ping
        self.now = now
        self.intervalMs = intervalMs
        self.staleMs = staleMs
    }

    /// One ping. Never throws. A hung ping does not start another one.
    /// The first call marks the tracker monitored before the ping is awaited,
    /// so a fresh task keeps the full stale window when the database is slow.
    public func probeOnce() async {
        if !monitored {
            monitored = true
            lastSuccessAt = now()
        }
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        do {
            try await ping()
            lastSuccessAt = now()
        } catch is CancellationError {
            return
        } catch {
            // The age of lastSuccessAt is the signal.
        }
    }

    public func verdict(at: Int? = nil) -> LivenessVerdict {
        if !monitored { return .unmonitored }
        let age = (at ?? now()) - lastSuccessAt
        if age > staleMs {
            return LivenessVerdict(ok: false, db: .stale, msSinceDbSuccess: age)
        }
        return LivenessVerdict(ok: true, db: .ok, msSinceDbSuccess: age)
    }

    /// Marks the tracker monitored before the first ping resolves.
    public func start() {
        if loop != nil { return }
        if !monitored {
            monitored = true
            lastSuccessAt = now()
        }
        let interval = intervalMs
        loop = Task {
            while !Task.isCancelled {
                await self.probeOnce()
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(interval, 0)) * 1_000_000)
                } catch {
                    break
                }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }
}
