import Dispatch
import Synchronization
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

@Test func concurrentPerCallTokenReportsKeepExactTotalsAndCompleteSnapshots() {
    let acc = TurnTokenAccumulator()
    let reports = 256
    let camel: [String: Double] = [
        "inputTokens": 1, "outputTokens": 2,
        "cachedInputTokens": 3, "cacheCreationInputTokens": 4,
    ]
    let snake: [String: Double] = [
        "input_tokens": 1, "output_tokens": 2,
        "cached_read_tokens": 3, "cache_write_tokens": 4,
    ]
    let snapshots = Mutex<[TurnTokenCounts]>([])
    DispatchQueue.concurrentPerform(iterations: reports) { index in
        switch index % 3 {
        case 0:
            RuntimeTurnTokens.note(acc, name: "token_usage", source: "claude_result_usage", attrs: camel)
        case 1:
            RuntimeTurnTokens.note(acc, name: "token_usage", source: "pi_message_end_usage", attrs: snake)
        default:
            RuntimeTurnTokens.note(acc, name: "token_usage", source: "kimi_turn_step_completed_usage", attrs: snake)
        }
        let snapshot = RuntimeTurnTokens.counts(for: acc)
        snapshots.withLock { $0.append(snapshot) }
    }
    let observed = snapshots.withLock { $0 }
    #expect(observed.count == reports)
    #expect(observed.allSatisfy { snapshot in
        guard let input = snapshot.input, (1...reports).contains(input) else { return false }
        return snapshot == TurnTokenCounts(input: input, output: input * 2, cacheRead: input * 3, cacheWrite: input * 4)
    }, "each public snapshot contains only complete reports, never a partial field update")
    #expect(RuntimeTurnTokens.counts(for: acc) == TurnTokenCounts(
        input: 256, output: 512, cacheRead: 768, cacheWrite: 1_024
    ))
    #expect(RuntimeTurnTokens.traceAttrs(acc) == [
        "input_tokens": 256, "output_tokens": 512,
        "cache_read_tokens": 768, "cache_write_tokens": 1_024,
    ])
}

@Test func concurrentCodexTokenReportsKeepCompleteSessionSnapshots() throws {
    let acc = TurnTokenAccumulator()
    RuntimeTurnTokens.note(acc, name: "token_usage", source: "codex_thread_token_usage_updated", attrs: [
        "inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0,
        "lastInputTokens": 0, "lastCachedInputTokens": 0, "lastOutputTokens": 0,
    ])
    let reports = 256
    let snapshots = Mutex<[TurnTokenCounts]>([])
    DispatchQueue.concurrentPerform(iterations: reports) { index in
        let value = index + 1
        // Once the public seed report establishes the base, later totals need
        // no last-report fields. Their arrival order is deliberately unspecified.
        RuntimeTurnTokens.note(acc, name: "token_usage", source: "codex_thread_token_usage_updated", attrs: [
            "inputTokens": Double(value * 4), "cachedInputTokens": Double(value * 3),
            "outputTokens": Double(value * 2),
        ])
        let snapshot = RuntimeTurnTokens.counts(for: acc)
        snapshots.withLock { $0.append(snapshot) }
    }
    let observed = snapshots.withLock { $0 }
    #expect(observed.count == reports)
    #expect(observed.allSatisfy { snapshot in
        guard let input = snapshot.input, (1...reports).contains(input) else { return false }
        return snapshot == TurnTokenCounts(input: input, output: input * 2, cacheRead: input * 3)
    }, "each public snapshot belongs to one complete session total; unreported cacheWrite stays nil")
    let final = RuntimeTurnTokens.counts(for: acc)
    let input = try #require(final.input)
    #expect((1...reports).contains(input))
    guard (1...reports).contains(input) else { return }
    #expect(final == TurnTokenCounts(input: input, output: input * 2, cacheRead: input * 3))
    #expect(acc.sessionBase == TurnTokenCounts(input: 0, output: 0, cacheRead: 0))
    #expect(acc.sessionLatest == final)
    #expect(RuntimeTurnTokens.traceAttrs(acc) == [
        "input_tokens": input, "output_tokens": input * 2, "cache_read_tokens": input * 3,
    ])
    RuntimeTurnTokens.note(acc, name: "token_usage", source: "codex_thread_token_usage_updated", attrs: [
        "inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0,
    ])
    #expect(RuntimeTurnTokens.counts(for: acc) == TurnTokenCounts(input: 0, output: 0, cacheRead: 0))
    #expect(acc.sessionLatest == TurnTokenCounts(input: 0, output: 0, cacheRead: 0))
}
