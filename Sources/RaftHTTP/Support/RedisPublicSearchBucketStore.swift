import Foundation
import RaftRedis
import Synchronization

/// Production service traffic uses one shared minute bucket for every valid key
/// and every search route. Redis errors never select the development memory store.
public final class RedisPublicSearchBucketStore: PublicSearchBucketStoring, PublicSearchInFlightGating, Sendable {
    public static let keyPrefix = "raft-landing-public-seo:rate:"
    private let client: RedisClient
    private let now: @Sendable () -> Date
    private let inFlight = Mutex(0)

    /// Use a client with connect and command timeouts no longer than 250ms.
    /// The request also has one combined deadline across connect, AUTH and EVAL.
    public init(client: RedisClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    /// Production bootstrap must propagate configuration errors; it must not
    /// replace this store with PublicSearchMemoryBucketStore after a failure.
    public convenience init(environment: [String: String]) throws {
        guard let url = environment["REDIS_URL"], !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RedisError.notConfigured
        }
        let configuration = try RedisConfiguration(
            url: url, connectTimeout: .milliseconds(250), commandTimeout: .milliseconds(250)
        )
        self.init(client: RedisClient(configuration: configuration))
    }

    public func consume(limit: Int) async -> PublicSearchBucketDecision {
        guard limit > 0,
              client.configuration.connectTimeout.nanoseconds <= 250_000_000,
              client.configuration.commandTimeout.nanoseconds <= 250_000_000 else { return .unavailable }
        // Capture time before Redis I/O, as upstream does for both key and retry.
        let at = floor(now().timeIntervalSince1970 * 1000)
        guard let window = Int64(exactly: floor(at / 60_000)) else { return .unavailable }
        do {
            let count = try await increment(key: Self.keyPrefix + String(window))
            if count > Int64(limit) {
                let seconds = ceil(((Double(window) + 1) * 60_000 - at) / 1000)
                return .rateLimited(retryAfter: Int(max(1, min(60, seconds))))
            }
            return .allowed
        } catch {
            // Includes authentication, connection, deadline, protocol and Lua errors.
            // A timed-out increment may have committed and is never retried here.
            return .unavailable
        }
    }

    /// Upstream's in-flight counter belongs to this process, after Redis admits
    /// the request. The middleware releases it once when that response ends.
    public func acquire(max: Int) -> Bool {
        inFlight.withLock { count in
            guard count < max else { return false }
            count += 1
            return true
        }
    }

    public func release() {
        inFlight.withLock { $0 = max(0, $0 - 1) }
    }

    private func increment(key: String) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Int64.self) { group in
            group.addTask { [client] in
                try await client.incrementWithTTL(key, ttlSeconds: 120)
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(250))
                throw RedisError.commandTimedOut
            }
            defer { group.cancelAll() }
            guard let count = try await group.next() else { throw RedisError.unexpectedResponse }
            return count
        }
    }
}
