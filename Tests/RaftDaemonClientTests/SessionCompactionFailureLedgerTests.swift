import Foundation
import Testing
import RaftDaemonClient

private func temporaryAgentsDir() -> String {
    let dir = NSTemporaryDirectory() + "compaction-ledger-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@Test func threeConsecutiveFailuresRefuseResumeAndSurviveARestart() throws {
    let dir = temporaryAgentsDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(SessionCompactionFailureLedger.sessionNeedsResetThreshold == 3)
    let ledger = SessionCompactionFailureLedger(agentsDir: dir)
    #expect(ledger.recordFailure(agentId: "agent-1", sessionId: "session-a", model: "deepseek/v4") == 1)
    #expect(ledger.recordFailure(agentId: "agent-1", sessionId: "session-a", model: "deepseek/v4") == 2)
    #expect(ledger.needsReset(agentId: "agent-1", sessionId: "session-a", model: "deepseek/v4") == nil, "two is not yet stuck")
    #expect(ledger.recordFailure(agentId: "agent-1", sessionId: "session-a", model: "deepseek/v4") == 3)
    let restarted = SessionCompactionFailureLedger(agentsDir: dir)
    #expect(restarted.needsReset(agentId: "agent-1", sessionId: "session-a", model: "deepseek/v4") == 3, "kept on disk across a daemon restart")

    let path = dir + "/agent-1/.raft/compaction-failures.json"
    let stored = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    #expect(Set(stored.keys) == ["count", "model", "sessionId", "updatedAtMs", "version"])
}

@Test func resetSessionAnotherModelOrASuccessfulCompactionClearsIt() {
    let dir = temporaryAgentsDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let ledger = SessionCompactionFailureLedger(agentsDir: dir)
    for _ in 0..<3 { ledger.recordFailure(agentId: "agent-1", sessionId: "session-a", model: "m1") }
    #expect(ledger.needsReset(agentId: "agent-1", sessionId: "session-b", model: "m1") == nil, "a reset session is not refused")
    #expect(ledger.needsReset(agentId: "agent-1", sessionId: "session-a", model: "m2") == nil, "another model may fit")
    #expect(ledger.recordFailure(agentId: "agent-1", sessionId: "session-b", model: "m1") == 1, "a different session starts over")
    for _ in 0..<3 { ledger.recordFailure(agentId: "agent-1", sessionId: "session-b", model: "m1") }
    ledger.clear(agentId: "agent-1")
    #expect(ledger.needsReset(agentId: "agent-1", sessionId: "session-b", model: "m1") == nil)
    ledger.clear(agentId: "agent-1")
}

@Test func agentsAreIndependentAndADamagedFileReadsAsNoRecord() throws {
    let dir = temporaryAgentsDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let ledger = SessionCompactionFailureLedger(agentsDir: dir)
    for _ in 0..<3 { ledger.recordFailure(agentId: "agent-1", sessionId: "s", model: nil) }
    #expect(ledger.needsReset(agentId: "agent-2", sessionId: "s", model: nil) == nil)
    #expect(ledger.needsReset(agentId: "agent-1", sessionId: "s", model: nil) == 3)

    let path = dir + "/agent-1/.raft/compaction-failures.json"
    try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
    #expect(ledger.needsReset(agentId: "agent-1", sessionId: "s", model: nil) == nil, "a damaged record is no record")
    #expect(ledger.recordFailure(agentId: "agent-1", sessionId: "s", model: nil) == 1, "a damaged record restarts the count")
}
