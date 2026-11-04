import Foundation
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
