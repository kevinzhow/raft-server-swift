import Foundation
import Testing
import RaftDaemonClient

private func tempDir() -> String {
    let dir = NSTemporaryDirectory() + "raft-context-generation-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func deps(id: @escaping @Sendable () -> String = { UUID().uuidString }, now: @escaping @Sendable () -> Date = { Date() }, fs: ContextGeneration.FileSystem = .default) -> ContextGeneration.Deps {
    .init(fs: fs, now: now, newId: id)
}

private func readRecord(_ dir: String) -> ContextGeneration.Record? {
    ContextGeneration.read(transportDir: dir)
}

@Test func writesAPrivateJSONRecordWithAFreshContextId() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fixedNow = ISO8601DateFormatter().date(from: "2026-09-30T00:00:00Z")!
    let id = ContextGeneration.write(
        transportDir: dir, reason: "spawn", runtime: "claude", passiveAx: false,
        deps: deps(id: { "ctx-1" }, now: { fixedNow })
    )
    #expect(id == "ctx-1")
    #expect(readRecord(dir) == .init(
        contextId: "ctx-1", reason: "spawn", compactionReported: true,
        runtime: "claude", writtenAt: "2026-09-30T00:00:00.000Z", passiveAx: false
    ))
    let attributes = try FileManager.default.attributesOfItem(atPath: dir + "/context-generation")
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func everyWriteIssuesANewIdAndCompactionReplacesSpawn() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let first = ContextGeneration.write(transportDir: dir, reason: "spawn", runtime: "codex", passiveAx: false)
    let second = ContextGeneration.write(transportDir: dir, reason: "compaction", runtime: "codex", passiveAx: false)
    #expect(first != nil && second != nil)
    #expect(first != second)
    #expect(readRecord(dir)?.contextId == second)
    #expect(readRecord(dir)?.reason == "compaction")
}

@Test func failedWriteLeavesNoGenerationFileEvenWhenAStaleOneExisted() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    ContextGeneration.write(transportDir: dir, reason: "spawn", runtime: "claude", passiveAx: false, deps: deps(id: { "stale" }))
    #expect(readRecord(dir)?.contextId == "stale")
    let failing = ContextGeneration.FileSystem(
        read: { path in try String(contentsOfFile: path, encoding: .utf8) },
        write: { _, _ in throw NSError(domain: "ENOSPC", code: 28) },
        rename: { from, to in try FileManager.default.moveItem(atPath: from, toPath: to) },
        unlink: { path in if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) } }
    )
    let id = ContextGeneration.write(
        transportDir: dir, reason: "spawn", runtime: "claude", passiveAx: false, deps: deps(id: { "fresh" }, fs: failing)
    )
    #expect(id == nil)
    #expect(!FileManager.default.fileExists(atPath: dir + "/context-generation"))
}

@Test func failedRenameLeavesNeitherStaleNorTempFile() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    ContextGeneration.write(transportDir: dir, reason: "spawn", runtime: "claude", passiveAx: false, deps: deps(id: { "stale" }))
    let failing = ContextGeneration.FileSystem(
        read: { path in try String(contentsOfFile: path, encoding: .utf8) },
        write: { path, contents in try contents.write(toFile: path, atomically: false, encoding: .utf8) },
        rename: { _, _ in throw NSError(domain: "EIO", code: 5) },
        unlink: { path in if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) } }
    )
    #expect(ContextGeneration.write(transportDir: dir, reason: "compaction", runtime: "claude", passiveAx: false, deps: deps(fs: failing)) == nil)
    #expect(!FileManager.default.fileExists(atPath: dir + "/context-generation"))
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    #expect(remaining.isEmpty, "the temp file is cleaned up too")
}

@Test func writingNeverThrowsEvenWhenTheDirectoryIsMissing() {
    let missing = tempDir() + "/gone"
    #expect(ContextGeneration.write(transportDir: missing, reason: "spawn", runtime: "claude", passiveAx: false) == nil)
}

@Test func everyRegisteredRuntimeHasAnExplicitCompactionAnswer() {
    for runtime in ContextGeneration.registeredRuntimeIds {
        #expect(ContextGeneration.runtimeReportsCompaction[runtime] != nil, "runtime \(runtime) needs an entry")
    }
    #expect(!ContextGeneration.reportsCompaction("gemini"))
    #expect(ContextGeneration.reportsCompaction("pi"))
    #expect(!ContextGeneration.reportsCompaction("not-a-runtime"))
}

private func launchDirs() -> (root: String, launch: (String) -> String) {
    let root = tempDir()
    return (root, { name in
        let dir = root + "/agent-1/" + name
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    })
}

@Test func resumingAConfirmedSessionReusesItsContextIdEvenFromAnotherLaunchDir() throws {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let first = launch("launch-1")
    let spawnId = ContextGeneration.publishSpawn(transportDir: first, runtime: "claude", passiveAx: false)
    ContextGeneration.bindToSession(transportDir: first, runtime: "claude", sessionId: "s1", expectedSessionId: nil)
    let second = launch("launch-2")
    #expect(ContextGeneration.publishSpawn(transportDir: second, runtime: "claude", resumeSessionId: "s1", passiveAx: false) == spawnId)
    #expect(readRecord(second)?.reason == "resume")
    let attributes = try FileManager.default.attributesOfItem(atPath: root + "/agent-1/sessions.json")
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func resumeGetsANewIdWhenTheSessionIsUnknownOrTheRuntimeNeverReportsCompaction() {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = launch("launch-1")
    let spawnId = ContextGeneration.publishSpawn(transportDir: dir, runtime: "gemini", passiveAx: false)
    ContextGeneration.bindToSession(transportDir: dir, runtime: "gemini", sessionId: "g1", expectedSessionId: nil)
    #expect(ContextGeneration.publishSpawn(transportDir: dir, runtime: "gemini", resumeSessionId: "g1", passiveAx: false) != spawnId)
    #expect(readRecord(dir)?.reason == "spawn")
    ContextGeneration.publishSpawn(transportDir: dir, runtime: "claude", resumeSessionId: "never-seen", passiveAx: false)
    #expect(readRecord(dir)?.reason == "spawn")
}

@Test func aPlannedSpawnIdIsTheOnePublishedAndPlanningWritesNothing() {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let first = launch("launch-1")
    let spawnId = ContextGeneration.publishSpawn(transportDir: first, runtime: "claude", passiveAx: true)
    ContextGeneration.bindToSession(transportDir: first, runtime: "claude", sessionId: "s1", expectedSessionId: nil)
    let second = launch("launch-2")
    let resumed = ContextGeneration.planSpawn(transportDir: second, runtime: "claude", resumeSessionId: "s1")
    #expect(resumed == .init(contextId: spawnId!, reason: "resume"))
    let fresh = ContextGeneration.planSpawn(transportDir: second, runtime: "claude", resumeSessionId: nil)
    #expect(fresh.reason == "spawn")
    #expect(fresh.contextId != spawnId)
    #expect(readRecord(second) == nil, "planning publishes nothing")
    #expect(ContextGeneration.publishSpawn(transportDir: second, runtime: "claude", passiveAx: true, plan: fresh) == fresh.contextId)
    #expect(readRecord(second)?.contextId == fresh.contextId)
    #expect(readRecord(second)?.reason == "spawn")
}

@Test func bindingASessionReturnsTheIdNowCurrent() {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = launch("launch-1")
    let spawnId = ContextGeneration.publishSpawn(transportDir: dir, runtime: "claude", resumeSessionId: "s1", passiveAx: false)
    #expect(ContextGeneration.bindToSession(transportDir: dir, runtime: "claude", sessionId: "s1", expectedSessionId: "s1") == spawnId)
    let rebound = ContextGeneration.bindToSession(transportDir: dir, runtime: "claude", sessionId: "s2", expectedSessionId: "s1")
    #expect(rebound != spawnId, "another session than the one resumed: a new id")
    #expect(readRecord(dir)?.contextId == rebound)
    #expect(ContextGeneration.bindToSession(transportDir: launch("empty"), runtime: "claude", sessionId: "s3", expectedSessionId: nil) == nil)
}

@Test func sessionInitReportingAnotherSessionIssuesANewIdBoundToIt() {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let first = launch("launch-1")
    let originalId = ContextGeneration.publishSpawn(transportDir: first, runtime: "claude", passiveAx: false)
    ContextGeneration.bindToSession(transportDir: first, runtime: "claude", sessionId: "s1", expectedSessionId: nil)
    let second = launch("launch-2")
    #expect(ContextGeneration.publishSpawn(transportDir: second, runtime: "claude", resumeSessionId: "s1", passiveAx: false) == originalId)
    ContextGeneration.bindToSession(transportDir: second, runtime: "claude", sessionId: "s2", expectedSessionId: "s1")
    let freshId = readRecord(second)?.contextId
    #expect(freshId != nil)
    #expect(freshId != originalId, "the fresh session must not inherit s1's context id")
    let third = launch("launch-3")
    #expect(ContextGeneration.publishSpawn(transportDir: third, runtime: "claude", resumeSessionId: "s2", passiveAx: false) == freshId)
}

@Test func aCompactionRebindsTheSessionSoALaterResumeGetsThePostCompactionId() {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let first = launch("launch-1")
    let spawnId = ContextGeneration.publishSpawn(transportDir: first, runtime: "codex", passiveAx: false)
    ContextGeneration.bindToSession(transportDir: first, runtime: "codex", sessionId: "c1", expectedSessionId: nil)
    let compactedId = ContextGeneration.write(transportDir: first, reason: "compaction", runtime: "codex", passiveAx: false)
    ContextGeneration.rememberSession(transportDir: first, sessionId: "c1", contextId: compactedId)
    #expect(compactedId != spawnId)
    #expect(ContextGeneration.publishSpawn(transportDir: launch("launch-2"), runtime: "codex", resumeSessionId: "c1", passiveAx: false) == compactedId)
}

@Test func failedTableWriteDropsTheWholeTable() {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = launch("launch-1")
    let spawnId = ContextGeneration.publishSpawn(transportDir: dir, runtime: "claude", passiveAx: false)
    ContextGeneration.bindToSession(transportDir: dir, runtime: "claude", sessionId: "s1", expectedSessionId: nil)
    let failing = ContextGeneration.FileSystem(
        read: { path in try String(contentsOfFile: path, encoding: .utf8) },
        write: { path, contents in
            if path.contains("sessions.json") { throw NSError(domain: "ENOSPC", code: 28) }
            try contents.write(toFile: path, atomically: false, encoding: .utf8)
        },
        rename: { from, to in try FileManager.default.moveItem(atPath: from, toPath: to) },
        unlink: { path in if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) } }
    )
    let compactedId = ContextGeneration.write(transportDir: dir, reason: "compaction", runtime: "claude", passiveAx: false, deps: deps(fs: failing))
    ContextGeneration.rememberSession(transportDir: dir, sessionId: "s1", contextId: compactedId, deps: deps(fs: failing))
    #expect(!FileManager.default.fileExists(atPath: root + "/agent-1/sessions.json"))
    let resumedId = ContextGeneration.publishSpawn(transportDir: launch("launch-2"), runtime: "claude", resumeSessionId: "s1", passiveAx: false)
    #expect(resumedId != spawnId)
    #expect(resumedId != compactedId)
}

@Test func forgettingARetiredSessionAndTheTableSizeCap() {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = launch("launch-1")
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let clock = deps(now: { counter.value += 1; return Date(timeIntervalSince1970: Double(counter.value)) })
    for index in 0...ContextGeneration.maxRememberedSessions {
        ContextGeneration.rememberSession(transportDir: dir, sessionId: "s\(index)", contextId: "ctx-\(index)", deps: clock)
    }
    let raw = try! String(contentsOfFile: root + "/agent-1/sessions.json", encoding: .utf8)
    let object = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
    let sessions = object["sessions"] as! [String: Any]
    #expect(sessions.count == ContextGeneration.maxRememberedSessions)
    #expect(sessions["s0"] == nil, "the least recently updated session is dropped")
    ContextGeneration.rememberSession(transportDir: dir, sessionId: "s1", contextId: nil)
    ContextGeneration.publishSpawn(transportDir: dir, runtime: "claude", resumeSessionId: "s1", passiveAx: false)
    #expect(readRecord(dir)?.reason == "spawn")
    ContextGeneration.publishSpawn(transportDir: dir, runtime: "claude", resumeSessionId: "s2", passiveAx: false)
    #expect(readRecord(dir)?.contextId == "ctx-2")
}

@Test func theRecordCarriesThePassiveAxGate() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    ContextGeneration.write(transportDir: dir, reason: "spawn", runtime: "claude", passiveAx: true)
    #expect(readRecord(dir)?.passiveAx == true)
    ContextGeneration.write(transportDir: dir, reason: "compaction", runtime: "claude", passiveAx: false)
    #expect(readRecord(dir)?.passiveAx == false)
}

@Test func spawnAndResumePublishTheGateAndASessionMismatchCarriesIt() {
    let (root, launch) = launchDirs()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let first = launch("launch-1")
    ContextGeneration.publishSpawn(transportDir: first, runtime: "claude", passiveAx: true)
    #expect(readRecord(first)?.passiveAx == true)
    ContextGeneration.bindToSession(transportDir: first, runtime: "claude", sessionId: "s1", expectedSessionId: nil)
    let second = launch("launch-2")
    ContextGeneration.publishSpawn(transportDir: second, runtime: "claude", resumeSessionId: "s1", passiveAx: true)
    #expect(readRecord(second)?.reason == "resume")
    #expect(readRecord(second)?.passiveAx == true)
    ContextGeneration.bindToSession(transportDir: second, runtime: "claude", sessionId: "s2", expectedSessionId: "s1")
    #expect(readRecord(second)?.reason == "spawn")
    #expect(readRecord(second)?.passiveAx == true, "the new id keeps the gate this process was spawned with")
}

@Test func configPassiveAxTurnsTheGateOnOnlyForExplicitTrue() {
    #expect(ContextGeneration.configPassiveAx(["passiveAx": true]))
    #expect(!ContextGeneration.configPassiveAx(["passiveAx": false]))
    #expect(!ContextGeneration.configPassiveAx([:]), "a config from an older Server has no field")
    #expect(!ContextGeneration.configPassiveAx(["passiveAx": "true"]))
}
