import Testing
import RaftDaemonClient

private func usage(_ source: String, _ attrs: [String: Double], name: String = "token_usage") -> (String, String, [String: Double]) {
    (name, source, attrs)
}

@Test func claudePerTurnResultUsageMapsToTheFourFields() {
    let acc = TurnTokenAccumulator()
    RuntimeTurnTokens.note(acc, name: "token_usage", source: "claude_result_usage", attrs: [
        "inputTokens": 12, "outputTokens": 900, "cachedInputTokens": 80_000,
        "cacheCreationInputTokens": 3_000, "totalCostUsd": 0.4,
    ])
    #expect(RuntimeTurnTokens.traceAttrs(acc) == [
        "input_tokens": 12, "output_tokens": 900, "cache_read_tokens": 80_000, "cache_write_tokens": 3_000,
    ])
}

@Test func perCallReportsAddUpOverTheTurn() {
    let acc = TurnTokenAccumulator()
    RuntimeTurnTokens.note(acc, name: "token_usage", source: "pi_message_end_usage", attrs: [
        "input_tokens": 100, "output_tokens": 10, "cached_read_tokens": 1_000,
    ])
    RuntimeTurnTokens.note(acc, name: "token_usage", source: "pi_message_end_usage", attrs: [
        "input_tokens": 50, "output_tokens": 5, "cached_read_tokens": 1_100,
    ])
    #expect(RuntimeTurnTokens.traceAttrs(acc) == [
        "input_tokens": 150, "output_tokens": 15, "cache_read_tokens": 2_100,
    ])

    let kimi = TurnTokenAccumulator()
    RuntimeTurnTokens.note(kimi, name: "token_usage", source: "kimi_turn_step_completed_usage", attrs: [
        "input_tokens": 7, "output_tokens": 3, "cached_read_tokens": 0, "cache_write_tokens": 40,
    ])
    #expect(RuntimeTurnTokens.traceAttrs(kimi) == [
        "input_tokens": 7, "output_tokens": 3, "cache_read_tokens": 0, "cache_write_tokens": 40,
    ])
}

@Test func codexSessionTotalsBecomeThisTurnsUsage() {
    let acc = TurnTokenAccumulator()
    RuntimeTurnTokens.note(acc, name: "token_usage", source: "codex_thread_token_usage_updated", attrs: [
        "inputTokens": 13_000, "cachedInputTokens": 10_500, "outputTokens": 600,
        "lastInputTokens": 3_000, "lastCachedInputTokens": 2_500, "lastOutputTokens": 100,
    ])
    RuntimeTurnTokens.note(acc, name: "token_usage", source: "codex_thread_token_usage_updated", attrs: [
        "inputTokens": 17_000, "cachedInputTokens": 13_500, "outputTokens": 800,
        "lastInputTokens": 4_000, "lastCachedInputTokens": 3_000, "lastOutputTokens": 200,
    ])
    #expect(RuntimeTurnTokens.traceAttrs(acc) == [
        "input_tokens": 1_500, "output_tokens": 300, "cache_read_tokens": 5_500,
    ])
}

@Test func unusableReportsLeaveTheFieldsOff() {
    let noLast = TurnTokenAccumulator()
    RuntimeTurnTokens.note(noLast, name: "token_usage", source: "codex_thread_token_usage_updated", attrs: [
        "inputTokens": 13_000, "cachedInputTokens": 10_500, "outputTokens": 600,
    ])
    #expect(RuntimeTurnTokens.traceAttrs(noLast).isEmpty)

    let reset = TurnTokenAccumulator()
    RuntimeTurnTokens.note(reset, name: "token_usage", source: "codex_thread_token_usage_updated", attrs: [
        "inputTokens": 13_000, "cachedInputTokens": 10_500, "outputTokens": 600,
        "lastInputTokens": 3_000, "lastCachedInputTokens": 2_500, "lastOutputTokens": 100,
    ])
    RuntimeTurnTokens.note(reset, name: "token_usage", source: "codex_thread_token_usage_updated", attrs: [
        "inputTokens": 900, "cachedInputTokens": 0, "outputTokens": 20,
        "lastInputTokens": 900, "lastCachedInputTokens": 0, "lastOutputTokens": 20,
    ])
    #expect(RuntimeTurnTokens.traceAttrs(reset).isEmpty, "totals that went backwards give no number")

    let gemini = TurnTokenAccumulator()
    RuntimeTurnTokens.note(gemini, name: "token_usage", source: "gemini_result_stats", attrs: ["total_tokens": 5_000])
    RuntimeTurnTokens.note(gemini, name: "rate_limits", source: "claude_result_usage", attrs: ["inputTokens": 1])
    #expect(RuntimeTurnTokens.traceAttrs(gemini).isEmpty)
}
