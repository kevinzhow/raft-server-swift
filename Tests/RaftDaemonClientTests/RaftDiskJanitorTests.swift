import Dispatch
import Foundation
import Synchronization
import Testing
import RaftDaemonClient

private let dayMs = 24 * 60 * 60 * 1000
private let nowMs = 1_791_115_200_000  // 2026-10-04T12:00:00Z

private func withHome(_ run: (String) throws -> Void) throws {
    let home = NSTemporaryDirectory() + "raft-disk-janitor-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    try run(home)
}

private func writeBytes(_ filePath: String, _ bytes: Int) throws {
    try FileManager.default.createDirectory(
        atPath: (filePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
    )
    try Data(repeating: 0, count: bytes).write(to: URL(fileURLWithPath: filePath))
}

private func age(_ target: String, _ ageMs: Int) throws {
    let date = Date(timeIntervalSince1970: Double(nowMs - ageMs) / 1000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target)
}

private func generation(_ home: String, _ migration: String, _ ageMs: Int) throws -> String {
    let root = home + "/migrations/" + migration + "/agent_migration_transport_1"
    try writeBytes(root + "/chunks/0.chunk", 1_000)
    try writeBytes(root + "/chunks/1.chunk", 500)
    try FileManager.default.createDirectory(atPath: root + "/extracting-abc123", withIntermediateDirectories: true)
    try writeBytes(root + "/arrival-report-v2.json", 10)
    for entry in ["chunks/0.chunk", "chunks/1.chunk", "chunks", "extracting-abc123", "arrival-report-v2.json", ""] {
        try age(root + "/" + entry, ageMs)
    }
    return root
}

private func entries(_ dir: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
}

// Deadlines bound a missing event; the timer hooks and pass continuations
// establish every interleaving. No delay is used to make callbacks overlap.
private func waitForJanitorEvent(
    _ signal: DispatchSemaphore, until condition: () -> Bool
) -> Bool {
    let deadline = DispatchTime.now() + .seconds(2)
    while !condition() {
        if signal.wait(timeout: deadline) == .timedOut { return condition() }
    }
    return true
}

private final class JanitorTimers: Sendable {
    struct Entry: Sendable {
        let id: Int
        let body: @Sendable () -> Void
        let delayMs: Int
    }

    private struct State: Sendable {
        var entries: [Entry] = []
        var pending: Set<Int> = []
        var returning: Set<Int> = []
        var cancelled: [Int] = []
        var nextId = 1
        var beforeReturn: (@Sendable (Entry) -> Void)?
        var onCancel: (@Sendable (Int) -> Void)?
    }

    private let state = Mutex(State())
    private let registrationChanged = DispatchSemaphore(value: 0)
    private let cancellationChanged = DispatchSemaphore(value: 0)

    var entries: [Entry] { state.withLock { $0.entries } }
    var pending: Set<Int> { state.withLock { $0.pending } }
    var cancelled: [Int] { state.withLock { $0.cancelled } }

    var timers: RaftDisk.Timers {
        RaftDisk.Timers(
            setTimeout: { [self] body, delayMs in register(body, delayMs: delayMs) },
            clearTimeout: { [self] token in cancel(token) }
        )
    }

    func beforeNextReturn(_ action: @escaping @Sendable (Entry) -> Void) {
        let retired = state.withLock { state in
            let retired = state.beforeReturn
            state.beforeReturn = action
            return retired
        }
        withExtendedLifetime(retired) {}
    }

    func onNextCancel(_ action: @escaping @Sendable (Int) -> Void) {
        let retired = state.withLock { state in
            let retired = state.onCancel
            state.onCancel = action
            return retired
        }
        withExtendedLifetime(retired) {}
    }

    private func register(_ body: @escaping @Sendable () -> Void, delayMs: Int) -> Int {
        let (entry, beforeReturn) = state.withLock { state in
            let entry = Entry(id: state.nextId, body: body, delayMs: delayMs)
            state.nextId += 1
            state.entries.append(entry)
            state.pending.insert(entry.id)
            let beforeReturn = state.beforeReturn
            state.beforeReturn = nil
            return (entry, beforeReturn)
        }
        beforeReturn?(entry)
        _ = state.withLock { $0.returning.insert(entry.id) }
        registrationChanged.signal()
        return entry.id
    }

    private func cancel(_ token: Int) {
        let onCancel = state.withLock { state in
            state.pending.remove(token)
            state.cancelled.append(token)
            let onCancel = state.onCancel
            state.onCancel = nil
            return onCancel
        }
        onCancel?(token)
        cancellationChanged.signal()
    }

    // Deliberately retain cancelled and fired bodies: a callback already queued
    // by a timer implementation can arrive late or arrive more than once.
    func fire(_ token: Int) {
        let body = state.withLock { state in
            state.pending.remove(token)
            return state.entries.first { $0.id == token }?.body
        }
        body?()
    }

    func waitForRegistration(_ token: Int) -> Bool {
        waitForJanitorEvent(registrationChanged) {
            state.withLock { $0.returning.contains(token) }
        }
    }

    func waitForCancellation(_ token: Int) -> Bool {
        waitForJanitorEvent(cancellationChanged) {
            state.withLock { $0.cancelled.contains(token) }
        }
    }
}

private final class JanitorPasses: Sendable {
    private struct State: Sendable {
        var started = 0
        var active = 0
        var maximumActive = 0
        var returned = 0
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        var released: Set<Int> = []
        var releasedAll = false
    }

    private let state = Mutex(State())
    private let startChanged = DispatchSemaphore(value: 0)
    private let returnChanged = DispatchSemaphore(value: 0)

    var started: Int { state.withLock { $0.started } }
    var active: Int { state.withLock { $0.active } }
    var maximumActive: Int { state.withLock { $0.maximumActive } }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let suspended = state.withLock { state in
                state.started += 1
                state.active += 1
                state.maximumActive = max(state.maximumActive, state.active)
                if state.releasedAll || state.released.contains(state.started) { return false }
                state.waiting[state.started] = continuation
                return true
            }
            startChanged.signal()
            if !suspended { continuation.resume() }
        }
        state.withLock {
            $0.active -= 1
            $0.returned += 1
        }
        returnChanged.signal()
    }

    func release(_ pass: Int) {
        let continuation = state.withLock { state in
            state.released.insert(pass)
            return state.waiting.removeValue(forKey: pass)
        }
        continuation?.resume()
    }

    func releaseAll() {
        let continuations = state.withLock { state in
            state.releasedAll = true
            let continuations = Array(state.waiting.values)
            state.waiting.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }

    func waitForStarts(_ count: Int) -> Bool {
        waitForJanitorEvent(startChanged) { started >= count }
    }

    func waitForReturns(_ count: Int) -> Bool {
        waitForJanitorEvent(returnChanged) { state.withLock { $0.returned >= count } }
    }
}

private final class DeadlineUpdatingWalkClock: Sendable {
    private struct State: Sendable {
        weak var budget: RaftDisk.WalkBudget?
        var launched = false
    }

    private let state = Mutex(State())
    private let updated = DispatchSemaphore(value: 0)
    private let workerExited = DispatchSemaphore(value: 0)

    func bind(_ budget: RaftDisk.WalkBudget) {
        state.withLock { $0.budget = budget }
    }

    func now() -> Int {
        let budget = state.withLock { state -> RaftDisk.WalkBudget? in
            guard !state.launched, let budget = state.budget else { return nil }
            state.launched = true
            return budget
        }
        guard let budget else { return 10 }
        Thread.detachNewThread { [self, budget] in
            defer { workerExited.signal() }
            let deadline = budget.deadlineMs
            budget.deadlineMs = deadline + 15
            updated.signal()
        }
        // A clock accidentally called under the budget lock must still return,
        // allowing the waiting worker to finish after that lock is released.
        _ = updated.wait(timeout: .now() + .seconds(2))
        return 10
    }

    func drain() -> Bool {
        guard state.withLock({ $0.launched }) else { return true }
        return workerExited.wait(timeout: .now() + .seconds(2)) == .success
    }
}

@Suite
struct RaftDiskJanitorTests {
@Test func measureSumsRegularFilesNeverFollowsSymlinksAndReportsTruncation() throws {
    try withHome { home in
        try writeBytes(home + "/a/one", 100)
        try writeBytes(home + "/a/b/two", 23)
        try writeBytes(home + "/outside/big", 10_000)
        try FileManager.default.createSymbolicLink(atPath: home + "/a/link", withDestinationPath: home + "/outside")

        let budget = RaftDisk.WalkBudget()
        #expect(RaftDisk.measureDirectoryBytes(home + "/a", budget: budget) == 123)
        #expect(budget.outcome == .complete)

        let tiny = RaftDisk.WalkBudget(maxEntries: 1)
        _ = RaftDisk.measureDirectoryBytes(home + "/a", budget: tiny)
        #expect(tiny.outcome == .truncated, "a partial walk must not read as a small complete number")
        #expect(RaftDisk.measureDirectoryBytes(home + "/missing", budget: RaftDisk.WalkBudget()) == 0)
    }
}

@Test func anArrivedGenerationLosesBulkDataButKeepsTheReport() throws {
    try withHome { home in
        let root = try generation(home, "m1", 0)
        let freed = RaftDisk.removeMigrationGenerationBulk(root, budget: RaftDisk.WalkBudget())
        #expect(freed == 1_500)
        #expect(entries(root) == ["arrival-report-v2.json"])
    }
}

@Test func janitorClearsOnlyGenerationsIdleForOverAWeek() throws {
    try withHome { home in
        let idle = try generation(home, "old", RaftDisk.migrationGenerationIdleMs + dayMs)
        let active = try generation(home, "recent", RaftDisk.migrationGenerationIdleMs - dayMs)
        let sourceSide = home + "/migrations/src/agent_migration_transport_2"
        try writeBytes(sourceSide + "/source-spool/part", 7)
        for entry in ["source-spool/part", "source-spool", ""] {
            try age(sourceSide + "/" + entry, 30 * dayMs)
        }
        try writeBytes(home + "/migrations/grant-target/arrival-report.json", 5)

        let result = RaftDisk.runJanitor(slockHome: home, nowMs: nowMs)
        #expect(entries(idle) == ["arrival-report-v2.json"])
        #expect(entries(active).sorted() == ["arrival-report-v2.json", "chunks", "extracting-abc123"])
        #expect(entries(sourceSide) == [])
        #expect(entries(home + "/migrations/grant-target") == ["arrival-report.json"])
        #expect(result.migrationGenerationsCleaned == 2)
        #expect(result.migrationFreedBytes == 1_507)
        #expect(result.sweepOutcome == .complete)
    }
}

@Test func janitorAppliesKeep3And30DayRuleToEveryAgent() throws {
    try withHome { home in
        let backups = home + "/migration-workspace-backups"
        try writeBytes(backups + "/agent-a/mig-1/MEMORY.md", 400)
        try age(backups + "/agent-a/mig-1", RaftDisk.backupMaxAgeMs + dayMs)
        for index in 0...RaftDisk.backupMaxPerAgent {
            let name = index == 0 ? "preexisting-mig-0" : "mig-\(index)"
            try writeBytes(backups + "/agent-b/" + name + "/f", 10)
            try age(backups + "/agent-b/" + name, (10 - index) * dayMs)
        }
        let result = RaftDisk.runJanitor(slockHome: home, nowMs: nowMs)
        #expect(entries(backups + "/agent-a") == [])
        #expect(entries(backups + "/agent-b").sorted() == ["mig-1", "mig-2", "mig-3"])
        let removals = result.backupsRemoved.sorted { $0.ownerAgentId < $1.ownerAgentId }
        #expect(removals == [
            .init(ownerAgentId: "agent-a", backupKind: "migration", ageDays: 31, freedBytes: 400),
            .init(ownerAgentId: "agent-b", backupKind: "preexisting", ageDays: 10, freedBytes: 10),
        ])
        #expect(result.backupsFreedBytes == 410)
    }
}

@Test func footprintReportsRaftsOwnDirectoriesSeparately() throws {
    try withHome { home in
        _ = try generation(home, "m1", 0)
        try writeBytes(home + "/migration-workspace-backups/agent-a/mig-1/f", 300)
        try writeBytes(home + "/cli-transport/agent-a/launch-1/raft", 20)
        try writeBytes(home + "/agent-proxy-tokens/agent-a/launch-1.token", 5)
        try writeBytes(home + "/agents/agent-a/huge-workspace-file", 99_999)
        #expect(RaftDisk.measureFootprint(slockHome: home) == .init(
            raftMigrationChunksBytes: 1_510, raftWorkspaceBackupsBytes: 300,
            raftLaunchDirsBytes: 25, measureOutcome: .complete
        ))
    }
}

@Test func theJanitorScheduleWaitsNeverOverlapsAndStopsCleanly() async throws {
    final class Pending: @unchecked Sendable {
        var timers: [(id: Int, fn: @Sendable () -> Void, ms: Int)] = []
        var nextId = 1
    }
    let pending = Pending()
    let timers = RaftDisk.Timers(
        setTimeout: { fn, ms in
            let id = pending.nextId
            pending.nextId += 1
            pending.timers.append((id, fn, ms))
            return id
        },
        clearTimeout: { id in pending.timers.removeAll { $0.id == id } }
    )
    final class Passes: @unchecked Sendable {
        var count = 0
        var finish: (@Sendable () -> Void)?
    }
    let passes = Passes()
    let schedule = RaftDisk.scheduleJanitor(
        pass: {
            passes.count += 1
            await withCheckedContinuation { continuation in
                passes.finish = { continuation.resume() }
            }
        },
        timers: timers, initialDelayMs: 600, intervalMs: 86_400
    )
    #expect(pending.timers.map(\.ms) == [600])
    let first = pending.timers.removeFirst()
    first.fn()
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(passes.count == 1)
    #expect(pending.timers.isEmpty, "the next pass is armed only after this one finishes")
    passes.finish?()
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(pending.timers.map(\.ms) == [86_400])
    schedule.stop()
    #expect(pending.timers.isEmpty)
}

@Test func stoppingDuringRearmRegistrationCancelsTheLateToken() throws {
    let timers = JanitorTimers()
    let passes = JanitorPasses()
    let schedule = RaftDisk.scheduleJanitor(
        pass: { await passes.run() }, timers: timers.timers,
        initialDelayMs: 13, intervalMs: 29
    )
    defer { schedule.stop(); passes.releaseAll() }
    // init has already returned its first token. Stop during the next arm,
    // after the old implementation's shouldArm check but before token return.
    timers.beforeNextReturn { entry in
        #expect(entry.delayMs == 29)
        schedule.stop()
    }

    timers.fire(1)
    let started = passes.waitForStarts(1)
    try #require(started)
    passes.release(1)
    let registered = timers.waitForRegistration(2)
    try #require(registered)
    let lateTokenCancelled = timers.waitForCancellation(2)

    #expect(lateTokenCancelled, "stop must also cancel a registration whose token was not available yet")
    #expect(timers.pending.isEmpty)
    #expect(timers.entries.map(\.delayMs) == [13, 29])
    #expect(passes.started == 1)
}

@Test func aSynchronousRearmCallbackCannotLeaveItsReturnedTokenActive() throws {
    let timers = JanitorTimers()
    let passes = JanitorPasses()
    let schedule = RaftDisk.scheduleJanitor(
        pass: { await passes.run() }, timers: timers.timers,
        initialDelayMs: 13, intervalMs: 29
    )
    defer { schedule.stop(); passes.releaseAll() }
    // Only the second registration fires inline, so there is no recursive
    // construction or unbounded fake-timer loop.
    timers.beforeNextReturn { entry in timers.fire(entry.id) }

    timers.fire(1)
    let firstStarted = passes.waitForStarts(1)
    try #require(firstStarted)
    passes.release(1)
    let secondStarted = passes.waitForStarts(2)
    try #require(secondStarted)
    let returned = timers.waitForRegistration(2)
    try #require(returned)
    let consumedTokenCancelled = timers.waitForCancellation(2)

    #expect(consumedTokenCancelled, "a callback that ran before token return must not republish its consumed token")
    #expect(passes.active == 1)
    #expect(passes.maximumActive == 1)
    #expect(timers.entries.map(\.delayMs) == [13, 29])
}

@Test func duplicateTimerCallbacksCannotOverlapJanitorPasses() throws {
    let timers = JanitorTimers()
    let passes = JanitorPasses()
    let schedule = RaftDisk.scheduleJanitor(
        pass: { await passes.run() }, timers: timers.timers,
        initialDelayMs: 13, intervalMs: 29
    )
    defer { schedule.stop(); passes.releaseAll() }

    timers.fire(1)
    let firstStarted = passes.waitForStarts(1)
    try #require(firstStarted)
    timers.fire(1)
    let duplicateStarted = passes.waitForStarts(2)

    #expect(!duplicateStarted, "the first pass is held open while its timer body is delivered twice")
    #expect(passes.started == 1)
    #expect(passes.active == 1)
    #expect(passes.maximumActive == 1)
    #expect(timers.entries.map(\.delayMs) == [13], "no interval begins before the admitted pass finishes")
}

@Test func anOldTimerCallbackCannotReplaceTheNextJanitorTimer() throws {
    let timers = JanitorTimers()
    let passes = JanitorPasses()
    let schedule = RaftDisk.scheduleJanitor(
        pass: { await passes.run() }, timers: timers.timers,
        initialDelayMs: 13, intervalMs: 29
    )
    defer { schedule.stop(); passes.releaseAll() }

    timers.fire(1)
    let firstStarted = passes.waitForStarts(1)
    try #require(firstStarted)
    passes.release(1)
    let nextRegistered = timers.waitForRegistration(2)
    try #require(nextRegistered)
    timers.fire(1)
    let stalePassStarted = passes.waitForStarts(2)

    #expect(!stalePassStarted)
    #expect(passes.started == 1)
    #expect(timers.pending == [2])
    #expect(timers.entries.map(\.delayMs) == [13, 29])
    schedule.stop()
    let nextCancelled = timers.waitForCancellation(2)
    #expect(nextCancelled, "the stale callback must not erase the newer timer's cancellation token")
}

@Test func callbacksAfterStopCannotStartAJanitorPass() {
    let timers = JanitorTimers()
    let passes = JanitorPasses()
    let schedule = RaftDisk.scheduleJanitor(
        pass: { await passes.run() }, timers: timers.timers,
        initialDelayMs: 13, intervalMs: 29
    )
    defer { schedule.stop(); passes.releaseAll() }

    schedule.stop()
    #expect(timers.cancelled == [1])
    timers.fire(1)
    let unexpectedPassStarted = passes.waitForStarts(1)

    #expect(!unexpectedPassStarted)
    #expect(passes.started == 0)
    #expect(timers.entries.map(\.delayMs) == [13])
}

@Test func stopDoesNotJoinAnAdmittedJanitorPassOrRearmIt() throws {
    let timers = JanitorTimers()
    let passes = JanitorPasses()
    let schedule = RaftDisk.scheduleJanitor(
        pass: { await passes.run() }, timers: timers.timers,
        initialDelayMs: 13, intervalMs: 29
    )
    defer { schedule.stop(); passes.releaseAll() }

    timers.fire(1)
    let started = passes.waitForStarts(1)
    try #require(started)
    schedule.stop()

    #expect(passes.active == 1, "stop returns while the already admitted pass remains suspended")
    passes.release(1)
    let returned = passes.waitForReturns(1)
    try #require(returned)
    #expect(passes.active == 0)
    #expect(timers.entries.map(\.delayMs) == [13])
    #expect(timers.pending.isEmpty)
}

@Test func timerCancellationCanReenterStopAndDeliverAnOldCallback() {
    let timers = JanitorTimers()
    let passes = JanitorPasses()
    let schedule = RaftDisk.scheduleJanitor(
        pass: { await passes.run() }, timers: timers.timers,
        initialDelayMs: 13, intervalMs: 29
    )
    defer { schedule.stop(); passes.releaseAll() }
    timers.onNextCancel { token in
        schedule.stop()
        timers.fire(token)
    }

    schedule.stop()
    let unexpectedPassStarted = passes.waitForStarts(1)

    #expect(timers.cancelled == [1], "reentrant stop observes the completed reset")
    #expect(!unexpectedPassStarted)
    #expect(passes.started == 0)
    #expect(timers.pending.isEmpty)
}

@Test func aPendingJanitorTimerKeepsOnlyAWeakScheduleReference() {
    let timers = JanitorTimers()
    let passes = JanitorPasses()
    var schedule: RaftDisk.JanitorSchedule? = RaftDisk.scheduleJanitor(
        pass: { await passes.run() }, timers: timers.timers,
        initialDelayMs: 13, intervalMs: 29
    )
    weak var weakSchedule = schedule
    #expect(timers.entries.map(\.delayMs) == [13])
    schedule = nil

    #expect(weakSchedule == nil, "the pending timer body must not retain the schedule owner")
    timers.fire(1)
    weakSchedule?.stop()
    passes.releaseAll()
    #expect(passes.started == 0)
}

@Test(arguments: [64, 65]) func walkBudgetFlatBatchesOverdrawUntilTheNextProbe(_ fileCount: Int) throws {
    try withHome { home in
        let root = home + "/a"
        for index in 0..<fileCount { try writeBytes(root + "/\(index)", 1) }
        let budget = RaftDisk.WalkBudget(maxEntries: 1, nowMs: 0, now: { 0 })
        let bytes = RaftDisk.measureDirectoryBytes(root, budget: budget)
        #expect(bytes == 64)
        #expect(budget.entriesLeft == -63)
        let expected: RaftDisk.MeasureOutcome = fileCount == 64 ? .complete : .truncated
        #expect(budget.outcome == expected, "a final batch has no later probe to mark truncation")
    }
}

@Test func sharedWalkBudgetKeepsAllConcurrentMeasurementsAndConsumption() throws {
    try withHome { home in
        let root = home + "/a"
        try writeBytes(root + "/one", 7)
        let budget = RaftDisk.WalkBudget(maxEntries: 512, nowMs: 0, now: { 0 })
        let measured = Mutex<[Int]>([])
        DispatchQueue.concurrentPerform(iterations: 256) { _ in
            let bytes = RaftDisk.measureDirectoryBytes(root, budget: budget)
            measured.withLock { $0.append(bytes) }
        }
        let bytes = measured.withLock { $0 }
        #expect(bytes.count == 256)
        #expect(bytes.allSatisfy { $0 == 7 })
        #expect(bytes.reduce(0, +) == 1_792)
        #expect(budget.entriesLeft == 256)
        #expect(budget.outcome == .complete)
    }
}

@Test func walkBudgetClockCanUpdateTheLiveDeadlineOutsideOwnedLocks() throws {
    try withHome { home in
        let root = home + "/a"
        try writeBytes(root + "/one", 7)
        let clock = DeadlineUpdatingWalkClock()
        let budget = RaftDisk.WalkBudget(maxEntries: 1, deadlineMs: 5, nowMs: 0, now: { clock.now() })
        clock.bind(budget)
        let bytes = RaftDisk.measureDirectoryBytes(root, budget: budget)
        // Drain before any throwing assertion. The worker only touches budget
        // values; it never owns or accesses this temporary directory.
        let drained = clock.drain()
        #expect(drained, "the clock worker must finish after the measurement returns")
        guard drained else { return }
        #expect(bytes == 7, "now=10 must compare against the worker-updated deadline=20, not the old 5")
        #expect(budget.outcome == .complete)
        #expect(budget.entriesLeft == 0)
        #expect(budget.deadlineMs == 20, "the measurement must sample the clock and retain its public deadline update")
    }
}
}
