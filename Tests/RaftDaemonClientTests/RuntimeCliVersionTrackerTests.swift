import Foundation
import Testing
import RaftDaemonClient

private let at = ISO8601DateFormatter().date(from: "2026-10-18T08:00:00Z")!

@Test func versionsCompareByTheirDottedNumbers() {
    #expect((RuntimeCliVersionTracker.compare("codex-cli 0.163.0", "codex-cli 0.151.0") ?? 0) > 0)
    #expect((RuntimeCliVersionTracker.compare("2.1.301 (Claude Code)", "2.1.400") ?? 0) < 0)
    #expect(RuntimeCliVersionTracker.compare("1.2", "1.2.0") == 0)
    #expect(RuntimeCliVersionTracker.compare("dev", "1.0.0") == nil)
}

@Test func firstDetectionOnlyRecordsAndALaterDowngradeIsANotice() {
    let empty = RuntimeCliVersionState()
    let first = RuntimeCliVersionTracker.observe(state: empty, detected: [
        "codex": "codex-cli 0.163.0", "claude": "2.1.301",
    ], now: at)
    #expect(first.changes.isEmpty)
    let down = RuntimeCliVersionTracker.observe(state: first.next, detected: [
        "codex": "codex-cli 0.151.0", "claude": "2.1.301",
    ], now: at)
    #expect(down.changes == [.init(runtime: "codex", from: "codex-cli 0.163.0", to: "codex-cli 0.151.0", direction: "downgrade")])
    #expect(down.next.downgrades["codex"] == .init(from: "codex-cli 0.163.0", to: "codex-cli 0.151.0", at: "2026-10-18T08:00:00.000Z"))
    #expect(down.next.downgrades["claude"] == nil)
}

@Test func noticeClearsWhenBackAndKeepsTheGoodVersionAcrossASecondStepDown() {
    let empty = RuntimeCliVersionState()
    let recorded = RuntimeCliVersionTracker.observe(state: empty, detected: ["codex": "0.163.0"], now: at).next
    let once = RuntimeCliVersionTracker.observe(state: recorded, detected: ["codex": "0.155.0"], now: at).next
    let twice = RuntimeCliVersionTracker.observe(state: once, detected: ["codex": "0.151.0"], now: at).next
    #expect(twice.downgrades["codex"]?.from == "0.163.0")
    let back = RuntimeCliVersionTracker.observe(state: twice, detected: ["codex": "0.163.0"], now: at)
    #expect(back.changes.first?.direction == "upgrade")
    #expect(back.next.downgrades["codex"] == nil)
}

@Test func runtimeMissingFromOneDetectionKeepsItsRecord() {
    let empty = RuntimeCliVersionState()
    let recorded = RuntimeCliVersionTracker.observe(state: empty, detected: ["codex": "0.163.0"], now: at).next
    let missing = RuntimeCliVersionTracker.observe(state: recorded, detected: [:], now: at)
    #expect(missing.changes.isEmpty)
    #expect(missing.next.versions["codex"] == "0.163.0")
}

@Test func recordRoundTripsAndABadFileReadsAsEmpty() throws {
    let home = NSTemporaryDirectory() + "runtime-cli-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: home) }
    let empty = RuntimeCliVersionState()
    #expect(RuntimeCliVersionTracker.readState(slockHome: home) == empty)

    let first = RuntimeCliVersionTracker.observe(state: empty, detected: ["codex": "0.163.0"], now: at).next
    let state = RuntimeCliVersionTracker.observe(state: first, detected: ["codex": "0.151.0"], now: at).next
    try RuntimeCliVersionTracker.writeState(slockHome: home, state: state)
    #expect(RuntimeCliVersionTracker.readState(slockHome: home) == state)
    let raw = try String(contentsOfFile: RuntimeCliVersionTracker.path(slockHome: home), encoding: .utf8)
    #expect(raw.contains("\"schemaVersion\" : 1") || raw.contains("\"schemaVersion\": 1"))

    try "{not json".write(toFile: RuntimeCliVersionTracker.path(slockHome: home), atomically: true, encoding: .utf8)
    #expect(RuntimeCliVersionTracker.readState(slockHome: home) == empty)
}
