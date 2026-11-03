import Foundation

/// The MEMORY.md startup index injected into a fresh runtime turn: a small file
/// is shown in full with a no-re-read note, an over-budget one is head-truncated
/// at a line boundary with exact sizes and the recommendation to read the file.
/// Ported from the upstream daemon helper.
public struct StartupMemoryBlockConfig: Sendable, Equatable {
    public var enabled: Bool
    public var budgetTokens: Int
}

public enum StartupMemoryBlock {
    public static let recommendedMemoryMdBytes = 24_576
    public static let defaultBudgetTokens = 4_000
    public static let bytesPerToken = 4

    /// The block runs only with the server flag; env can turn it off but never
    /// on, and a per-agent env value beats the process env.
    public static func resolveConfig(
        serverEnabled: Bool?,
        agentEnv: [String: String]?,
        processEnv: [String: String]
    ) -> StartupMemoryBlockConfig {
        guard serverEnabled == true else {
            return StartupMemoryBlockConfig(enabled: false, budgetTokens: defaultBudgetTokens)
        }
        func value(_ key: String) -> String? {
            agentEnv?[key] ?? processEnv[key]
        }
        let enabled = (value("RAFT_STARTUP_MEMORY_BLOCK") ?? "1") != "0"
        let budget = Int(value("RAFT_STARTUP_MEMORY_BLOCK_TOKENS") ?? "") ?? defaultBudgetTokens
        return StartupMemoryBlockConfig(enabled: enabled, budgetTokens: budget)
    }

    /// Build the block from the workspace's MEMORY.md; nil when the file is
    /// missing, empty or whitespace-only.
    public static func build(workspacePath: String, budgetTokens: Int = defaultBudgetTokens) -> String? {
        let path = (workspacePath as NSString).appendingPathComponent("MEMORY.md")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let budgetBytes = budgetTokens * bytesPerToken
        if content.utf8.count <= budgetBytes {
            return "<memory-index file=\"MEMORY.md\" complete=\"true\" note=\"no need to re-read MEMORY.md\">\n\(content)\n</memory-index>"
        }
        var shownLines: [String] = []
        var used = 0
        for line in content.components(separatedBy: "\n") {
            let lineBytes = line.utf8.count + 1
            if used + lineBytes > budgetBytes { break }
            used += lineBytes
            shownLines.append(line)
        }
        var shown = shownLines.joined(separator: "\n")
        if shown.isEmpty, let firstLine = content.components(separatedBy: "\n").first {
            shown = firstLine
        }
        let kb = String(format: "%.1f", Double(shown.utf8.count) / 1024.0)
        return "<memory-index file=\"MEMORY.md\" shown=\"first \(kb) KB\" note=\"read the file for the rest\">\n\(shown)\n</memory-index>"
    }

    /// Prepends the block and marks the prompt source; a nil block is a no-op.
    public static func apply(block: String?, prompt: String, promptSource: String) -> (prompt: String, promptSource: String) {
        guard let block else { return (prompt, promptSource) }
        return ("\(block)\n\n\(prompt)", "\(promptSource)_with_memory")
    }
}
