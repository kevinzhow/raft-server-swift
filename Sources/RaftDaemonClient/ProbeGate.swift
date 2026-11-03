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

    private final class ResultBox: @unchecked Sendable {
        var value: Any?
        var error: Error?
    }

    private let maxConcurrent: Int
    private var inFlight: [String: (task: Task<Void, Error>, box: ResultBox)] = [:]
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
            try await existing.task.value
            if let error = existing.box.error { throw error }
            return existing.box.value as! T
        }
        let box = ResultBox()
        let handle = Task<Void, Error> { [self] in
            await acquire()
            do {
                let result = try await task()
                box.value = result
            } catch {
                box.error = error
                await releaseAndClear(key)
                throw error
            }
            await releaseAndClear(key)
        }
        inFlight[key] = (handle, box)
        try await handle.value
        if let error = box.error { throw error }
        return box.value as! T
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
