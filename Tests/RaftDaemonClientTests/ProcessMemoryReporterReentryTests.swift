import Foundation
import Synchronization
import Testing
import RaftDaemonClient

private final class MemoryInputClock: ProcessMemoryClock {
    private struct Timer: Sendable {
        var at: Int
        var body: @Sendable () -> Void
    }
    private struct State: Sendable {
        var now = 0
        var nextId = 1
        var timers: [Int: Timer] = [:]
    }
    private let state = Mutex(State())

    var nowMs: Int { state.withLock { $0.now } }

    func schedule(afterMs: Int, _ body: @escaping @Sendable () -> Void) -> Int {
        state.withLock { state in
            let id = state.nextId
            state.nextId += 1
            state.timers[id] = Timer(at: state.now + afterMs, body: body)
            return id
        }
    }

    func cancel(_ id: Int) {
        let retired = state.withLock { $0.timers.removeValue(forKey: id) }
        withExtendedLifetime(retired) {}
    }

    func advance(_ ms: Int) {
        let until = state.withLock { $0.now + ms }
        while true {
            let due: Timer? = state.withLock { state in
                guard let next = state.timers.min(by: { $0.value.at < $1.value.at }),
                      next.value.at <= until else {
                    state.now = until
                    return nil
                }
                state.now = next.value.at
                return state.timers.removeValue(forKey: next.key)
            }
            guard let due else { return }
            due.body()
        }
    }
}

private final class WeakMemoryReporter: Sendable {
    private struct State: Sendable {
        weak var reporter: ProcessMemory.Reporter?
    }
    private let state = Mutex(State())

    func install(_ reporter: ProcessMemory.Reporter) {
        state.withLock { $0.reporter = reporter }
    }

    func get() -> ProcessMemory.Reporter? {
        state.withLock { $0.reporter }
    }
}

@Test func sampleCanStopItsReporterAndStillWriteTheAdmittedSample() throws {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
    let name = "process-memory-reentry-\(UUID().uuidString)"
    let directory = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
    defer {
        if directory.deletingLastPathComponent() == root && directory.lastPathComponent == name {
            try? FileManager.default.removeItem(at: directory)
        }
    }
    let samplePath = directory.appendingPathComponent("sample.json").path
    let clock = MemoryInputClock()
    let reference = WeakMemoryReporter()
    let reporter = ProcessMemory.startReporter(
        clock: clock,
        trace: { _ in },
        samplePath: samplePath,
        sample: { now in
            reference.get()?.stop()
            return ProcessMemorySample(
                sampledAt: "1970-01-01T00:00:00.001Z", pid: 4242, uptimeMs: now,
                rssBytes: 300, heapUsedBytes: 100, heapTotalBytes: 150,
                externalBytes: 20, arrayBuffersBytes: 5, swapBytes: 7,
                heapSpaceUsedBytes: ["old_space": 70], lazySchemasRegistered: 11, lazySchemasBuilt: 3
            )
        },
        sampleMs: 10,
        firstSampleMs: 1
    )
    reference.install(reporter)
    defer { reporter.stop() }

    clock.advance(1)

    let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: samplePath)))
    let expected: [String: Any] = [
        "sampledAt": "1970-01-01T00:00:00.001Z", "pid": 4242, "uptimeMs": 1,
        "rssBytes": 300, "heapUsedBytes": 100, "heapTotalBytes": 150,
        "externalBytes": 20, "arrayBuffersBytes": 5, "swapBytes": 7,
        "heapSpaceUsedBytes": ["old_space": 70], "lazySchemas": ["registered": 11, "built": 3],
    ]
    let actualJSON = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
    let expectedJSON = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
    #expect(actualJSON == expectedJSON)
}
