import Foundation

/// One gate for machine probes the server can trigger repeatedly. A probe key
/// already in flight is joined (same result, no second process); different keys
/// respect an optional concurrency cap in FIFO order; a failing run rejects
/// every joined caller and frees both the key and the slot. Ported from the
/// upstream daemon probe gate.
public actor ProbeGate {
    public enum InvalidLimit: Error, CustomStringConvertible, Equatable {
        case notPositive(Int)
        public var description: String { "ProbeGate maxConcurrent must be a positive integer or Infinity" }
    }

    private let maxConcurrent: Int
    private var inFlight: [String: Task<any Sendable, Error>] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var running = 0

    /// `maxConcurrent` nil means unlimited (the daemon default).
    public init(maxConcurrent: Int? = nil) throws {
        if let maxConcurrent, maxConcurrent < 1 {
            throw InvalidLimit.notPositive(maxConcurrent)
        }
        self.maxConcurrent = maxConcurrent ?? Int.max
    }

    public var activeKeys: [String] {
        Array(inFlight.keys)
    }

    public func run<T: Sendable>(_ key: String, _ task: @escaping @Sendable () async throws -> T) async throws -> T {
        if let existing = inFlight[key] {
            return try await existing.value as! T
        }
        // Every submitted result is Sendable. Keep its existential value in the
        // shared Task instead of mutating an untyped box across suspension.
        // A key still denotes one result type, as in the original API.
        let handle = Task<any Sendable, Error> { [self] in
            await acquire()
            do {
                let result = try await task()
                await releaseAndClear(key)
                return result
            } catch {
                await releaseAndClear(key)
                throw error
            }
        }
        inFlight[key] = handle
        return try await handle.value as! T
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseAndClear(_ key: String) {
        inFlight[key] = nil
        running -= 1
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            running += 1
            next.resume()
        }
    }
}
