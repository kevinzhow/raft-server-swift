import Foundation
import Testing
import RaftDaemonClient

private let mb = 1024 * 1024

private final class FakeClock: ProcessMemoryClock, @unchecked Sendable {
    private let lock = NSLock()
    private var nowValue = 0
    private var timers: [Int: (at: Int, body: @Sendable () -> Void)] = [:]
    private var nextId = 1

    var nowMs: Int {
        lock.lock(); defer { lock.unlock() }
        return nowValue
    }

    func schedule(afterMs: Int, _ body: @escaping @Sendable () -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        timers[id] = (nowValue + afterMs, body)
        return id
    }

    func cancel(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        timers[id] = nil
    }

    func advance(_ ms: Int) {
        let until = nowMs + ms
        while true {
            lock.lock()
            let due = timers.min { $0.value.at < $1.value.at }
            lock.unlock()
            guard let due, due.value.at <= until else { break }
            lock.lock()
            timers[due.key] = nil
            nowValue = due.value.at
            lock.unlock()
            due.value.body()
        }
        lock.lock(); nowValue = until; lock.unlock()
    }

    var pending: Int {
        lock.lock(); defer { lock.unlock() }
        return timers.count
    }
}

private func sampleAt(_ nowMs: Int, heapUsedMb: Int = 100) -> ProcessMemorySample {
    ProcessMemorySample(
        sampledAt: ProcessMemory.sample(nowMs: nowMs).sampledAt, pid: 4242, uptimeMs: nowMs,
        rssBytes: 300 * mb, heapUsedBytes: heapUsedMb * mb, heapTotalBytes: 150 * mb,
        externalBytes: 20 * mb, arrayBuffersBytes: 5 * mb,
        heapSpaceUsedBytes: ["old_space": 70 * mb, "code_space": 12 * mb, "large_object_space": 8 * mb],
        lazySchemasRegistered: 372, lazySchemasBuilt: 3
    )
}

@Test func samplesAfterStartupAndTracesAtMostEvery30Minutes() throws {
    let dir = NSTemporaryDirectory() + "process-memory-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let samplePath = dir + "/servers/s1/runner.memory.json"
    let clock = FakeClock()
    final class Traced: @unchecked Sendable { var items: [[String: Int]] = [] }
    let traced = Traced()
    final class Running: @unchecked Sendable { var value = 2 }
    let running = Running()
    let reporter = ProcessMemory.startReporter(
        clock: clock,
        trace: { attrs in traced.items.append(attrs) },
        context: { ["process_instance_id": 0, "agents_running": running.value, "agents_in_process": 1].mapValues { $0 } },
        samplePath: samplePath
    ) { now in sampleAt(now, heapUsedMb: 100 + now / 60_000) }

    clock.advance(59_000)
    #expect(traced.items.isEmpty, "nothing before the first sample")
    clock.advance(1_000)
    #expect(traced.items.count == 1)
    let firstWritten = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: samplePath))) as? [String: Any]
    #expect((firstWritten?["heapUsedBytes"] as? NSNumber)?.intValue == 101 * mb)

    clock.advance(25 * 60_000)
    #expect(traced.items.count == 1)
    let secondWritten = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: samplePath))) as? [String: Any]
    #expect((secondWritten?["heapUsedBytes"] as? NSNumber)?.intValue == 126 * mb)
    running.value = 5
    clock.advance(5 * 60_000)
    #expect(traced.items.count == 2)
    #expect(traced.items[1]["heap_used_mb"] == 131)
    #expect(traced.items[1]["agents_running"] == 5)
    let expected = Set(ProcessMemory.traceAttrs.filter { !$0.hasPrefix("service_") && $0 != "swap_mb" })
    #expect(Set(traced.items[1].keys) == expected)

    reporter.stop()
    #expect(clock.pending == 0, "stop clears the timer")
    clock.advance(60 * 60_000)
    #expect(traced.items.count == 2)
}

@Test func aFailedFileWriteIsReportedAndSamplingContinues() {
    let clock = FakeClock()
    final class Traced: @unchecked Sendable { var items: [[String: Int]] = [] }
    final class Errors: @unchecked Sendable { var items: [Error] = [] }
    let traced = Traced()
    let errors = Errors()
    let reporter = ProcessMemory.startReporter(
        clock: clock,
        trace: { traced.items.append($0) },
        samplePath: "/proc/1/nested/runner.memory.json",
        sample: { sampleAt($0) },
        onWriteError: { errors.items.append($0) }
    )
    clock.advance(60_000 + 30 * 60_000)
    #expect(errors.items.count == 7)
    #expect(traced.items.count == 2)
    reporter.stop()
}

@Test func sampleAttributesAreWholeMegabytes() {
    let attrs = ProcessMemory.traceAttributes(sampleAt(90_000))
    #expect(attrs["rss_mb"] == 300)
    #expect(attrs["old_space_mb"] == 70)
    #expect(attrs["lazy_schemas_built"] == 3)
}

@Test func aRealSampleCarriesTheProcessOwnNumbers() {
    let sample = ProcessMemory.sample(nowMs: Int(Date().timeIntervalSince1970 * 1000))
    #expect(sample.pid == Int(ProcessInfo.processInfo.processIdentifier))
    #expect(sample.rssBytes > 0 && sample.heapUsedBytes > 0)
    #expect(sample.heapSpaceUsedBytes["old_space"] != nil)
}

@Test func serviceSampleIsCarriedOnlyWhileFresh() throws {
    let dir = NSTemporaryDirectory() + "service-memory-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = dir + "/service.memory.json"
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = Int(formatter.date(from: "2026-10-15T09:00:00.000Z")!.timeIntervalSince1970 * 1000)
    #expect(ProcessMemory.serviceAttributes(samplePath: file, nowMs: now).isEmpty, "no file")
    #expect(ProcessMemory.serviceAttributes(samplePath: nil, nowMs: now).isEmpty, "no path")

    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: file))
    }
    try write(["sampledAt": "2026-10-15T08:56:00.000Z", "rssBytes": 75 * mb, "heapUsedBytes": 14 * mb])
    #expect(ProcessMemory.serviceAttributes(samplePath: file, nowMs: now) == ["service_rss_mb": 75, "service_heap_used_mb": 14])
    try write(["sampledAt": "2026-10-15T08:56:00.000Z", "rssBytes": 18 * mb, "heapUsedBytes": 14 * mb, "swapBytes": 182 * mb])
    #expect(ProcessMemory.serviceAttributes(samplePath: file, nowMs: now) == ["service_rss_mb": 18, "service_heap_used_mb": 14, "service_swap_mb": 182])
    try write(["sampledAt": "2026-10-15T08:30:00.000Z", "rssBytes": 75 * mb, "heapUsedBytes": 14 * mb])
    #expect(ProcessMemory.serviceAttributes(samplePath: file, nowMs: now).isEmpty, "older than 15 minutes")
    try "{".write(toFile: file, atomically: true, encoding: .utf8)
    #expect(ProcessMemory.serviceAttributes(samplePath: file, nowMs: now).isEmpty)
}

@Test func swapComesFromVmSwapAndIsAbsentWhenUnknown() {
    #expect(ProcessMemory.readSwapBytes(statusText: "Name:\traft\nVmRSS:\t   18256 kB\nVmSwap:\t  186844 kB\n") == 186844 * 1024)
    #expect(ProcessMemory.readSwapBytes(statusText: "Name:\traft\n") == nil)
    var withSwap = sampleAt(1)
    withSwap.swapBytes = 181 * mb
    #expect(ProcessMemory.traceAttributes(withSwap)["swap_mb"] == 181)
    #expect(ProcessMemory.traceAttributes(sampleAt(1))["swap_mb"] == nil)
}
