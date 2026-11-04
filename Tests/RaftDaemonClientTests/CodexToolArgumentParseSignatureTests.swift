import Testing
import RaftDaemonClient

private let fixture = CodexToolArgumentParseSignature.upstreamFixture

@Test func matchesTheUpstreamIncidentLineVerbatim() {
    #expect(CodexToolArgumentParseSignature.isParseErrorChunk(fixture))
}

@Test func matchesRegardlessOfTheSerdeTail() {
    for tail in [
        "invalid type: floating point 14380.0, expected i32",
        "invalid type: string \"7\", expected u64",
        "invalid type: null, expected a sequence",
        "missing field `timeout_ms`",
    ] {
        #expect(CodexToolArgumentParseSignature.isParseErrorChunk(
            "ERROR codex_core::tools::router: error=failed to parse function arguments: \(tail)"
        ))
    }
}

@Test func doesNotMatchTheSiblingRouterError() {
    #expect(!CodexToolArgumentParseSignature.isParseErrorChunk(
        "ERROR codex_core::tools::router: error=write_stdin failed: stdin is closed for this session"
    ))
}

@Test func doesNotMatchAParseFailureOutsideTheToolRouter() {
    #expect(!CodexToolArgumentParseSignature.isParseErrorChunk(
        "ERROR codex_core::config: error=failed to parse function arguments: invalid type: floating point 1.0, expected i32"
    ))
}

@Test func toleratesMultiLineChunks() {
    let chunk = [
        "INFO codex_core::codex: turn started",
        "ERROR codex_core::tools::router: error=failed to parse function arguments: invalid type: floating point 14380.0, expected i32",
        "INFO codex_core::codex: turn continuing",
    ].joined(separator: "\n")
    #expect(CodexToolArgumentParseSignature.isParseErrorChunk(chunk))
}

@Test func ignoresEmptyAndUnrelatedChunks() {
    for text in [
        "", "   ", "Reconnecting... 1/5", "Falling back from WebSockets to HTTP",
        "ERROR codex_core::tools::router: error=report_agent_job_result handler received unsupported payload",
    ] {
        #expect(!CodexToolArgumentParseSignature.isParseErrorChunk(text), Comment(rawValue: "unexpected match on: \(text)"))
    }
}

@Test func thePinnedFixtureStillContainsBothHalves() {
    #expect(fixture.contains("codex_core::tools::router"))
    #expect(fixture.contains("failed to parse function arguments:"))
}

@Test func theTraceContractPinsTheSpanToIdentityAndModel() {
    let attrs = DaemonCoreTraceAttrContracts.spanAttrs("daemon.agent.tool_argument_parse_failed")
    #expect(attrs == ["agentId", "launchId", "runtime", "model"])
    for forbidden in ["stderr", "error", "arguments", "detail", "message"] {
        #expect(attrs?.contains(forbidden) == false, Comment(rawValue: "\(forbidden) must not be contracted"))
    }
}
