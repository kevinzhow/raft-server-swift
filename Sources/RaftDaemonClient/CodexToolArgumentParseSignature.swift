import Foundation

/// task #1127 — the one sanctioned stderr text signature in the Codex driver.
/// When Codex's tool router cannot deserialize the model's tool arguments it
/// emits a Rust tracing line on stderr and keeps going, so no structured event
/// carries the fact. This converts that text observation into the typed
/// `ToolArgumentParseError` code; everything downstream uses the code.
///
/// Both halves of the signature must appear on the same line: an unrelated
/// router error and an unrelated parse failure in one chunk must not combine.
/// Ported from the upstream daemon signature.
public enum CodexToolArgumentParseSignature {
    /// Verbatim upstream line from the originating incident (artin's Mac,
    /// 2026-09-14T19:18:44Z, Codex CLI 0.153.4).
    public static let upstreamFixture =
        "ERROR codex_core::tools::router: error=failed to parse function arguments: invalid type: floating point 14380.0, expected i32"

    static let tracingTarget = "codex_core::tools::router"
    static let parseSentence = "failed to parse function arguments:"

    /// True when a Codex stderr chunk reports a tool-argument parse failure.
    /// The chunk is split on `\r?\n` only (the driver attaches raw chunks).
    public static func isParseErrorChunk(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        return lines.contains { line in
            line.contains(tracingTarget) && line.contains(parseSentence)
        }
    }
}

/// The daemon core trace attr contract for the parse-failure span: identity and
/// model only, so rejected argument values can never be added as attributes.
public enum DaemonCoreTraceAttrContracts {
    public static let contracts: [String: [String]] = [
        "daemon.agent.tool_argument_parse_failed": ["agentId", "launchId", "runtime", "model"],
    ]
    public static func spanAttrs(_ span: String) -> [String]? {
        contracts[span]
    }
}
