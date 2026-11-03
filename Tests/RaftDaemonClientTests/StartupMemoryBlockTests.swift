import Foundation
import Testing
import RaftDaemonClient

private func workspaceWithMemory(_ content: String?) throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("memory-block-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let content {
        try content.write(toFile: (dir as NSString).appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
    }
    return dir
}

@Test func blockRunsOnlyWithTheServerFlagAndEnvCanOnlyTurnItOff() {
    #expect(!StartupMemoryBlock.resolveConfig(serverEnabled: nil, agentEnv: nil, processEnv: [:]).enabled)
    #expect(!StartupMemoryBlock.resolveConfig(serverEnabled: false, agentEnv: nil, processEnv: [:]).enabled)
    #expect(!StartupMemoryBlock.resolveConfig(
        serverEnabled: false,
        agentEnv: ["RAFT_STARTUP_MEMORY_BLOCK": "1"],
        processEnv: ["RAFT_STARTUP_MEMORY_BLOCK": "1"]
    ).enabled, "env cannot turn it on")
    let defaults = StartupMemoryBlock.resolveConfig(serverEnabled: true, agentEnv: nil, processEnv: [:])
    #expect(defaults.enabled)
    #expect(defaults.budgetTokens == 4_000)
    #expect(!StartupMemoryBlock.resolveConfig(serverEnabled: true, agentEnv: nil, processEnv: ["RAFT_STARTUP_MEMORY_BLOCK": "0"]).enabled)
    let fromProcess = StartupMemoryBlock.resolveConfig(
        serverEnabled: true, agentEnv: nil,
        processEnv: ["RAFT_STARTUP_MEMORY_BLOCK": "1", "RAFT_STARTUP_MEMORY_BLOCK_TOKENS": "2000"]
    )
    #expect(fromProcess.enabled)
    #expect(fromProcess.budgetTokens == 2_000)
    #expect(!StartupMemoryBlock.resolveConfig(
        serverEnabled: true, agentEnv: ["RAFT_STARTUP_MEMORY_BLOCK": "0"], processEnv: ["RAFT_STARTUP_MEMORY_BLOCK": "1"]
    ).enabled, "the per-agent value beats the process env")
}

@Test func missingEmptyAndWhitespaceOnlyMemoryYieldNoBlock() throws {
    #expect(StartupMemoryBlock.build(workspacePath: try workspaceWithMemory(nil)) == nil)
    #expect(StartupMemoryBlock.build(workspacePath: try workspaceWithMemory("")) == nil)
    #expect(StartupMemoryBlock.build(workspacePath: try workspaceWithMemory("  \n\n  ")) == nil)
}

@Test func aSmallIndexIsInjectedInFullWithANoReReadNote() throws {
    let block = try #require(StartupMemoryBlock.build(workspacePath: try workspaceWithMemory("# Memory\n- [note](notes/a.md)\n")))
    #expect(block.hasPrefix("<memory-index file=\"MEMORY.md\""))
    #expect(block.contains("- [note](notes/a.md)"))
    #expect(block.contains("complete=\"true\""))
    #expect(block.contains("no need to re-read MEMORY.md"))
    #expect(!block.lowercased().contains("recommended index size"))
}

@Test func anOversizeButWithinBudgetIndexGetsTheSameFactsOnlyFullNote() throws {
    let content = "# Memory\n" + String(repeating: "x", count: StartupMemoryBlock.recommendedMemoryMdBytes + 512)
    let block = try #require(StartupMemoryBlock.build(workspacePath: try workspaceWithMemory(content), budgetTokens: 8_000))
    #expect(block.contains("complete=\"true\""))
    let lower = block.lowercased()
    #expect(!lower.contains("recommended"))
    #expect(!lower.contains("move detail"))
    #expect(!lower.contains("cleaner"))
}

@Test func anOverBudgetFileIsHeadTruncatedAtALineBoundaryWithExactSizes() throws {
    let lines = (0..<3_000).map { "- line \($0) of the memory index" }
    let block = try #require(StartupMemoryBlock.build(workspacePath: try workspaceWithMemory(lines.joined(separator: "\n")), budgetTokens: 1_000))
    #expect(block.contains("- line 0 of the memory index"))
    #expect(!block.contains("- line 2999 of"))
    #expect(block.range(of: #"shown="first \d+\.\d KB" note="read the file for the rest""#, options: .regularExpression) != nil)
    #expect(!block.lowercased().contains("recommended"))
    let shown = block.components(separatedBy: "\n</memory-index>")[0]
    let lastLine = shown.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
    #expect(lastLine.range(of: #"^- line \d+ of the memory index$"#, options: .regularExpression) != nil)
    #expect(shown.utf8.count <= 1_000 * 4 + 200)
}

@Test func multibyteContentIsNeverSplitMidCodePoint() throws {
    let content = "# 记忆\n" + String(repeating: "记忆索引条目。", count: 2_000)
    let block = try #require(StartupMemoryBlock.build(workspacePath: try workspaceWithMemory(content), budgetTokens: 500))
    #expect(!block.contains("\u{FFFD}"))
}

@Test func applyPrependsAndMarksThePromptSourceAndIsANoOpWithoutABlock() {
    let untouched = StartupMemoryBlock.apply(block: nil, prompt: "wake", promptSource: "cold_start")
    #expect(untouched == (prompt: "wake", promptSource: "cold_start"))
    let applied = StartupMemoryBlock.apply(block: "## MEMORY.md ...", prompt: "wake", promptSource: "cold_start")
    #expect(applied == (prompt: "## MEMORY.md ...\n\nwake", promptSource: "cold_start_with_memory"))
}
