import Foundation
import Synchronization
import RaftDaemonClient
import Testing

private final class ProbeCount: Sendable {
    private let state = Mutex(0)
    var starts: Int { state.withLock { $0 } }
    func next() -> Int { state.withLock { $0 += 1; return $0 } }
}

private final class ProbeStarts: Sendable {
    private let state = Mutex([String]())
    var keys: [String] { state.withLock { $0 } }
    func append(_ key: String) { state.withLock { $0.append(key) } }
}

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
    let counter = ProbeCount()
    let task: @Sendable () async throws -> String = {
        _ = counter.next()
        return try await pending.wait()
    }
    async let first = gate.run("runtime_models:cursor", task)
    // Wait until the first run is actually registered and started; launching the
    // joiners before that races the gate's start path and can schedule a second
    // run (the assertion targets coalescing of overlapping requests, not start
    // ordering).
    while counter.starts == 0 { await Task.yield() }
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
    let counter = ProbeCount()
    let fresh: @Sendable () async throws -> Int = {
        return counter.next()
    }
    #expect(try await gate.run("k", fresh) == 1)
    #expect(try await gate.run("k", fresh) == 2)
    #expect(await gate.activeKeys.isEmpty)

    let a = Deferred<Void>(); let b = Deferred<Void>(); let c = Deferred<Void>()
    let started = ProbeStarts()
    func waitUntil(_ condition: @escaping @Sendable () -> Bool, timeoutMs: Int = 5_000) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    let pa = Task { try await gate.run("a") { started.append("a"); try await a.wait() } }
    await waitUntil { started.keys.contains("a") }
    let pb = Task { try await gate.run("b") { started.append("b"); try await b.wait() } }
    await waitUntil { started.keys.contains("b") }
    let pc = Task { try await gate.run("c") { started.append("c"); try await c.wait() } }
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(Set(started.keys) == ["a", "b"], "the third waits for a free slot; got \(started.keys)")
    a.resolve(())
    await waitUntil { started.keys.contains("c") }
    #expect(Set(started.keys) == ["a", "b", "c"], "a freed slot starts the next waiter; got \(started.keys)")
    b.resolve(())
    c.resolve(())
    _ = try await (pa.value, pb.value, pc.value)
}

@Test func failingRunRejectsJoinedCallersAndFreesKeyAndSlot() async throws {
    let gate = try ProbeGate(maxConcurrent: 1)
    let failing = Deferred<String>()
    let starts = ProbeStarts()
    let first: @Sendable () async throws -> String = {
        starts.append("first")
        return try await failing.wait()
    }
    let joined: @Sendable () async throws -> String = {
        starts.append("joined")
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
    #expect(starts.keys == ["first"], "the joined caller never started a second run")
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
    let started = ProbeStarts()
    let keys = ["runtime_models:cursor", "runtime_models:codex", "runtime_account_usage:kimi"]
    var runs: [Task<Void, Error>] = []
    for (index, key) in keys.enumerated() {
        runs.append(Task {
            try await gate.run(key) {
                started.append(key)
                try await slow[index].wait()
            }
        })
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(Set(started.keys) == Set(keys), "the default gate starts every different key at once; got \(started.keys)")
    for deferred in slow { deferred.resolve(()) }
    for run in runs { _ = try await run.value }
}
