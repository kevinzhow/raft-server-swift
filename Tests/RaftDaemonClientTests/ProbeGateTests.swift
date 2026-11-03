import Foundation
import RaftDaemonClient
import Testing

private final class Deferred<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var buffered: Result<T, Error>?

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let buffered {
                lock.unlock()
                continuation.resume(with: buffered)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ value: T) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            buffered = .success(value)
            lock.unlock()
        }
    }

    func reject(_ error: Error) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: error)
        } else {
            buffered = .failure(error)
            lock.unlock()
        }
    }
}

private struct ProbeCrash: Error {}

@Test func concurrentRequestsForTheSameKeyShareOneRunAndResult() async throws {
    let gate = try ProbeGate(maxConcurrent: 2)
    let pending = Deferred<String>()
    final class Counter: @unchecked Sendable { var starts = 0 }
    let counter = Counter()
    let task: @Sendable () async throws -> String = {
        counter.starts += 1
        return try await pending.wait()
    }
    async let first = gate.run("runtime_models:cursor", task)
    async let second = gate.run("runtime_models:cursor", task)
    async let third = gate.run("runtime_models:cursor", task)
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(counter.starts == 1, "only one probe process for overlapping requests")
    pending.resolve("241 models")
    let results = try await [first, second, third]
    #expect(results == ["241 models", "241 models", "241 models"])
}

@Test func settledRunStartsAFreshRunAndDifferentKeysRespectTheLimitInOrder() async throws {
    let gate = try ProbeGate(maxConcurrent: 2)
    final class Counter: @unchecked Sendable { var starts = 0 }
    let counter = Counter()
    let fresh: @Sendable () async throws -> Int = {
        counter.starts += 1
        return counter.starts
    }
    #expect(try await gate.run("k", fresh) == 1)
    #expect(try await gate.run("k", fresh) == 2)
    #expect(await gate.activeKeys.isEmpty)

    let a = Deferred<Void>(); let b = Deferred<Void>(); let c = Deferred<Void>()
    final class Started: @unchecked Sendable { var keys: [String] = [] }
    let started = Started()
    let pa = Task { try await gate.run("a") { started.keys.append("a"); try await a.wait() } }
    let pb = Task { try await gate.run("b") { started.keys.append("b"); try await b.wait() } }
    let pc = Task { try await gate.run("c") { started.keys.append("c"); try await c.wait() } }
    func waitUntil(_ condition: @escaping @Sendable () -> Bool, timeoutMs: Int = 2_000) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    await waitUntil { started.keys.count >= 2 }
    #expect(Set(started.keys) == ["a", "b"], "the third waits for a free slot; got \(started.keys)")
    a.resolve(())
    await waitUntil { started.keys.count >= 3 }
    #expect(Set(started.keys) == ["a", "b", "c"], "a freed slot starts the next waiter; got \(started.keys)")
    b.resolve(())
    c.resolve(())
    _ = try await (pa.value, pb.value, pc.value)
}

@Test func failingRunRejectsJoinedCallersAndFreesKeyAndSlot() async throws {
    let gate = try ProbeGate(maxConcurrent: 1)
    let failing = Deferred<String>()
    final class Starts: @unchecked Sendable { var values: [String] = [] }
    let starts = Starts()
    let first: @Sendable () async throws -> String = {
        starts.values.append("first")
        return try await failing.wait()
    }
    let joined: @Sendable () async throws -> String = {
        starts.values.append("joined")
        return "never"
    }
    let firstRun = Task { try await gate.run("k", first) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let joinedRun = Task { try await gate.run("k", joined) }
    try await Task.sleep(nanoseconds: 50_000_000)
    failing.reject(ProbeCrash())
    var firstFailed = false
    do { _ = try await firstRun.value } catch { firstFailed = true }
    var joinedFailed = false
    do { _ = try await joinedRun.value } catch { joinedFailed = true }
    #expect(firstFailed)
    #expect(joinedFailed)
    #expect(starts.values == ["first"], "the joined caller never started a second run")
    let fresh: @Sendable () async throws -> String = { "fresh" }
    #expect(try await gate.run("k", fresh) == "fresh", "the key is usable again")
    let slot: @Sendable () async throws -> String = { "slot freed" }
    #expect(try await gate.run("other", slot) == "slot freed")
}

@Test func limitMustBePositiveAndTheDefaultGateNeverQueuesDifferentKeys() async throws {
    #expect(throws: ProbeGate.InvalidLimit.self) { _ = try ProbeGate(maxConcurrent: 0) }
    _ = try ProbeGate(maxConcurrent: nil)

    let gate = try ProbeGate()
    let slow = [Deferred<Void>(), Deferred<Void>(), Deferred<Void>()]
    final class Started: @unchecked Sendable { var keys: [String] = [] }
    let started = Started()
    let keys = ["runtime_models:cursor", "runtime_models:codex", "runtime_account_usage:kimi"]
    var runs: [Task<Void, Error>] = []
    for (index, key) in keys.enumerated() {
        runs.append(Task {
            try await gate.run(key) {
                started.keys.append(key)
                try await slow[index].wait()
            }
        })
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(Set(started.keys) == Set(keys), "the default gate starts every different key at once; got \(started.keys)")
    for deferred in slow { deferred.resolve(()) }
    for run in runs { _ = try await run.value }
}
